import XCTest
@testable import VoxLocalCore

/// End-to-end smoke test without a microphone:
/// `say` synthesizes speech → `afconvert` produces 16 kHz mono WAV →
/// whisper-cli transcribes it locally → the text must be non-empty.
///
/// Skips with a precise message when the whisper-cli binary or a model is
/// not present. A skip is reported as a skip — never as a pass.
final class IntegrationSmokeTests: XCTestCase {
    private static var repoRoot: URL {
        // .../Tests/VoxLocalTests/IntegrationSmokeTests.swift → repo root
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private func locateWhisperCLI() -> URL? {
        var candidates = [
            Self.repoRoot.appendingPathComponent("vendor/whisper.cpp/build/bin/whisper-cli"),
        ]
        if let env = ProcessInfo.processInfo.environment["VOXLOCAL_WHISPER_CLI"], !env.isEmpty {
            candidates.insert(URL(fileURLWithPath: env), at: 0)
        }
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    private func locateModel() -> URL? {
        var candidates: [URL] = []
        if let env = ProcessInfo.processInfo.environment["VOXLOCAL_MODEL_PATH"], !env.isEmpty {
            candidates.append(URL(fileURLWithPath: env))
        }
        let appSupport = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/VoxLocal/models")
        for name in ["base", "small", "tiny", "base.en", "tiny.en"] {
            candidates.append(appSupport.appendingPathComponent("ggml-\(name).bin"))
            candidates.append(Self.repoRoot.appendingPathComponent("models/ggml-\(name).bin"))
        }
        return candidates.first { ModelManager.validateModelFile(at: $0) == .valid }
    }

    @discardableResult
    private func run(_ executable: String, _ arguments: [String]) throws -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        try process.run()
        process.waitUntilExit()
        return process.terminationStatus
    }

    func testSynthesizedSpeechTranscribesToNonEmptyText() async throws {
        guard let whisperCLI = locateWhisperCLI() else {
            throw XCTSkip("SKIPPED: whisper-cli not built. Run ./scripts/bootstrap.sh, then re-run tests.")
        }
        guard let modelURL = locateModel() else {
            throw XCTSkip("SKIPPED: no Whisper model installed. Run ./scripts/download_model.sh base (≈148 MB), then re-run tests.")
        }

        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("voxlocal-integration-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        // 1. Synthesize a short English phrase with the system voice.
        let aiff = tempDir.appendingPathComponent("phrase.aiff")
        let sayStatus = try run("/usr/bin/say", ["-o", aiff.path, "This is a local dictation test. One two three."])
        guard sayStatus == 0, FileManager.default.fileExists(atPath: aiff.path) else {
            throw XCTSkip("SKIPPED: /usr/bin/say could not synthesize audio in this environment (status \(sayStatus)).")
        }

        // 2. Convert to the 16 kHz mono PCM16 WAV Whisper expects.
        let wav = tempDir.appendingPathComponent("phrase.wav")
        let convStatus = try run("/usr/bin/afconvert", ["-f", "WAVE", "-d", "LEI16@16000", "-c", "1", aiff.path, wav.path])
        XCTAssertEqual(convStatus, 0, "afconvert failed")

        // 3. Transcribe through the production code path.
        let transcriber = WhisperTranscriber(binaryOverride: whisperCLI)
        let transcript = try await transcriber.transcribe(
            audioURL: wav,
            modelURL: modelURL,
            language: "en",
            threads: 4,
            removeArtifacts: true,
            timeout: 300)

        // 4. Non-empty text with expected content.
        XCTAssertFalse(transcript.text.isEmpty, "transcription produced empty text")
        let lowered = transcript.text.lowercased()
        XCTAssertTrue(
            lowered.contains("test") || lowered.contains("dictation") || lowered.contains("three"),
            "unexpected transcription: \(transcript.text)")
    }
}
