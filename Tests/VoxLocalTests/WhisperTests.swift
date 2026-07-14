import XCTest
@testable import VoxLocalCore

final class WhisperCommandBuilderTests: XCTestCase {
    func testArgumentConstruction() {
        let args = WhisperCommandBuilder.arguments(
            modelPath: "/models/ggml-base.bin",
            audioPath: "/tmp/a.wav",
            language: "ru",
            threads: 4,
            outputBase: "/tmp/out")
        XCTAssertEqual(args, [
            "-m", "/models/ggml-base.bin",
            "-f", "/tmp/a.wav",
            "-l", "ru",
            "-t", "4",
            "-oj",
            "-of", "/tmp/out",
            "-np",
        ])
    }

    func testThreadClamping() {
        let low = WhisperCommandBuilder.arguments(modelPath: "m", audioPath: "a", language: "auto", threads: 0, outputBase: "o")
        XCTAssertTrue(low.contains("1"))
        let high = WhisperCommandBuilder.arguments(modelPath: "m", audioPath: "a", language: "auto", threads: 99, outputBase: "o")
        XCTAssertTrue(high.contains("16"))
    }

    func testAutoLanguagePassedThrough() {
        let args = WhisperCommandBuilder.arguments(modelPath: "m", audioPath: "a", language: "auto", threads: 4, outputBase: "o")
        let langIndex = args.firstIndex(of: "-l")!
        XCTAssertEqual(args[langIndex + 1], "auto")
    }
}

final class WhisperOutputParserTests: XCTestCase {
    private let sampleJSON = """
    {
      "systeminfo": "x",
      "result": { "language": "ru" },
      "transcription": [
        { "timestamps": {"from": "00:00:00,000", "to": "00:00:02,000"}, "offsets": {"from": 0, "to": 2000}, "text": " Привет," },
        { "timestamps": {"from": "00:00:02,000", "to": "00:00:04,000"}, "offsets": {"from": 2000, "to": 4000}, "text": " это тест." }
      ]
    }
    """.data(using: .utf8)!

    func testParseJoinsSegmentsAndDetectsLanguage() throws {
        let output = try WhisperOutputParser.parse(jsonData: sampleJSON, removeArtifacts: false)
        XCTAssertEqual(output.text, "Привет, это тест.")
        XCTAssertEqual(output.detectedLanguage, "ru")
    }

    func testParseEmptyTranscription() throws {
        let json = #"{"transcription": [], "result": {"language": "en"}}"#.data(using: .utf8)!
        let output = try WhisperOutputParser.parse(jsonData: json, removeArtifacts: true)
        XCTAssertEqual(output.text, "")
    }

    func testInvalidJSONThrows() {
        XCTAssertThrowsError(try WhisperOutputParser.parse(jsonData: Data("not json".utf8), removeArtifacts: false))
    }

    func testArtifactRemovalBrackets() {
        let cleaned = WhisperOutputParser.stripArtifacts(from: "[BLANK_AUDIO] Привет [музыка] мир [typing sounds]")
        XCTAssertEqual(WhisperOutputParser.normalizeWhitespace(cleaned), "Привет мир")
    }

    func testArtifactRemovalKnownParens() {
        let cleaned = WhisperOutputParser.stripArtifacts(from: "(music) Hello (applause) world (музыка играет)")
        XCTAssertEqual(WhisperOutputParser.normalizeWhitespace(cleaned), "Hello world")
    }

    func testRealSpeechParensPreserved() {
        let text = "Это важно (так сказать) для всех."
        let cleaned = WhisperOutputParser.stripArtifacts(from: text)
        XCTAssertEqual(WhisperOutputParser.normalizeWhitespace(cleaned), text)
    }

    func testCyrillicSurvivesPipeline() throws {
        let json = #"{"transcription": [{"text": " Съешь ещё этих мягких французских булок."}]}"#.data(using: .utf8)!
        let output = try WhisperOutputParser.parse(jsonData: json, removeArtifacts: true)
        XCTAssertEqual(output.text, "Съешь ещё этих мягких французских булок.")
    }

    func testWhitespaceNormalizationPreservesLineBreaks() {
        let normalized = WhisperOutputParser.normalizeWhitespace("  строка   один \n\n строка два  ")
        XCTAssertEqual(normalized, "строка один\nстрока два")
    }
}

/// Mock subprocess runner for error-path tests.
struct MockRunner: SubprocessRunning {
    var result: Result<SubprocessResult, Error>
    /// Written to `<outputBase>.json` before returning, emulating whisper-cli.
    var jsonToWrite: String?

    func run(executable: URL, arguments: [String], timeout: TimeInterval) async throws -> SubprocessResult {
        if let jsonToWrite,
           let ofIndex = arguments.firstIndex(of: "-of"),
           ofIndex + 1 < arguments.count {
            let jsonURL = URL(fileURLWithPath: arguments[ofIndex + 1] + ".json")
            try jsonToWrite.data(using: .utf8)!.write(to: jsonURL)
        }
        return try result.get()
    }
}

final class WhisperTranscriberTests: XCTestCase {
    private var tempDir: URL!
    private var modelURL: URL!
    private var audioURL: URL!
    private var fakeBinary: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("voxlocal-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)

        // Plausible fake ggml model: magic + padding beyond the size floor.
        modelURL = tempDir.appendingPathComponent("ggml-fake.bin")
        var data = Data([0x6C, 0x6D, 0x67, 0x67]) // "ggml" magic little-endian
        data.append(Data(count: 1_100_000))
        try data.write(to: modelURL)

        audioURL = tempDir.appendingPathComponent("audio.wav")
        try Data(count: 128).write(to: audioURL)

        fakeBinary = tempDir.appendingPathComponent("whisper-cli")
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: fakeBinary)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fakeBinary.path)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    func testMissingBinaryError() async throws {
        let transcriber = WhisperTranscriber(
            runner: MockRunner(result: .success(SubprocessResult(exitCode: 0, stdout: Data(), stderr: Data()))),
            binaryOverride: nil)
        // Ensure no env override interferes and cwd has no vendor build.
        if ProcessInfo.processInfo.environment["VOXLOCAL_WHISPER_CLI"] == nil,
           !FileManager.default.isExecutableFile(atPath: "vendor/whisper.cpp/build/bin/whisper-cli") {
            do {
                _ = try await transcriber.transcribe(
                    audioURL: audioURL, modelURL: modelURL, language: "auto",
                    threads: 2, removeArtifacts: true)
                XCTFail("expected whisperBinaryMissing")
            } catch let error as VoxLocalError {
                guard case .whisperBinaryMissing = error else {
                    return XCTFail("wrong error: \(error)")
                }
            } catch {
                XCTFail("unexpected error type: \(error)")
            }
        } else {
            throw XCTSkip("a real whisper-cli is discoverable in this environment; missing-binary path not testable here")
        }
    }

    func testMissingModelError() async throws {
        let transcriber = WhisperTranscriber(
            runner: MockRunner(result: .success(SubprocessResult(exitCode: 0, stdout: Data(), stderr: Data()))),
            binaryOverride: fakeBinary)
        do {
            _ = try await transcriber.transcribe(
                audioURL: audioURL,
                modelURL: tempDir.appendingPathComponent("ggml-nope.bin"),
                language: "auto", threads: 2, removeArtifacts: true)
            XCTFail("expected modelMissing")
        } catch let error as VoxLocalError {
            guard case .modelMissing = error else { return XCTFail("wrong error: \(error)") }
        }
    }

    func testInvalidModelError() async throws {
        let badModel = tempDir.appendingPathComponent("ggml-bad.bin")
        try Data(repeating: 0xAB, count: 2_000_000).write(to: badModel)
        let transcriber = WhisperTranscriber(
            runner: MockRunner(result: .success(SubprocessResult(exitCode: 0, stdout: Data(), stderr: Data()))),
            binaryOverride: fakeBinary)
        do {
            _ = try await transcriber.transcribe(
                audioURL: audioURL, modelURL: badModel,
                language: "auto", threads: 2, removeArtifacts: true)
            XCTFail("expected modelInvalid")
        } catch let error as VoxLocalError {
            guard case .modelInvalid = error else { return XCTFail("wrong error: \(error)") }
        }
    }

    func testProcessFailureMapsToTranscriptionFailed() async throws {
        let runner = MockRunner(result: .success(SubprocessResult(
            exitCode: 3, stdout: Data(), stderr: Data("some backend error".utf8))))
        let transcriber = WhisperTranscriber(runner: runner, binaryOverride: fakeBinary)
        do {
            _ = try await transcriber.transcribe(
                audioURL: audioURL, modelURL: modelURL,
                language: "auto", threads: 2, removeArtifacts: true)
            XCTFail("expected transcriptionFailed")
        } catch let error as VoxLocalError {
            guard case .transcriptionFailed(let code, let detail) = error else {
                return XCTFail("wrong error: \(error)")
            }
            XCTAssertEqual(code, 3)
            XCTAssertTrue(detail.contains("backend error"))
        }
    }

    func testTimeoutMapsToTranscriptionTimeout() async throws {
        let transcriber = WhisperTranscriber(
            runner: MockRunner(result: .failure(SubprocessError.timeout)),
            binaryOverride: fakeBinary)
        do {
            _ = try await transcriber.transcribe(
                audioURL: audioURL, modelURL: modelURL,
                language: "auto", threads: 2, removeArtifacts: true)
            XCTFail("expected timeout")
        } catch let error as VoxLocalError {
            XCTAssertEqual(error, .transcriptionTimeout)
        }
    }

    func testSuccessfulParseFlow() async throws {
        let runner = MockRunner(
            result: .success(SubprocessResult(exitCode: 0, stdout: Data(), stderr: Data())),
            jsonToWrite: #"{"result": {"language": "en"}, "transcription": [{"text": " Hello world."}]}"#)
        let transcriber = WhisperTranscriber(runner: runner, binaryOverride: fakeBinary)
        let transcript = try await transcriber.transcribe(
            audioURL: audioURL, modelURL: modelURL,
            language: "en", threads: 2, removeArtifacts: true)
        XCTAssertEqual(transcript.text, "Hello world.")
        XCTAssertEqual(transcript.detectedLanguage, "en")
    }
}
