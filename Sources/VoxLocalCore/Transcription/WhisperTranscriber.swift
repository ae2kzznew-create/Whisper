import Foundation

/// Runs the bundled whisper-cli against a WAV file and returns parsed text.
public final class WhisperTranscriber: @unchecked Sendable {
    public struct Transcript: Equatable, Sendable {
        public let text: String
        public let detectedLanguage: String?
    }

    private let runner: SubprocessRunning
    private let binaryOverride: URL?

    public init(runner: SubprocessRunning = ProcessSubprocessRunner(), binaryOverride: URL? = nil) {
        self.runner = runner
        self.binaryOverride = binaryOverride
    }

    /// Candidate locations for whisper-cli, in priority order:
    /// 1. `VOXLOCAL_WHISPER_CLI` environment variable (tests, development),
    /// 2. the app bundle's auxiliary executable (packaged app),
    /// 3. the in-repo build output (running via `swift run` from the repo).
    public static func binaryCandidates() -> [URL] {
        var candidates: [URL] = []
        if let env = ProcessInfo.processInfo.environment["VOXLOCAL_WHISPER_CLI"], !env.isEmpty {
            candidates.append(URL(fileURLWithPath: env))
        }
        if let bundled = Bundle.main.url(forAuxiliaryExecutable: "whisper-cli") {
            candidates.append(bundled)
        }
        let cwd = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        candidates.append(cwd.appendingPathComponent("vendor/whisper.cpp/build/bin/whisper-cli"))
        return candidates
    }

    public func locateBinary() throws -> URL {
        if let binaryOverride {
            return binaryOverride
        }
        let candidates = Self.binaryCandidates()
        let fm = FileManager.default
        for url in candidates where fm.isExecutableFile(atPath: url.path) {
            return url
        }
        let searched = candidates.map { PathRedactor.redact($0.path) }.joined(separator: ", ")
        throw VoxLocalError.whisperBinaryMissing(searched)
    }

    public func transcribe(
        audioURL: URL,
        modelURL: URL,
        language: String,
        threads: Int,
        removeArtifacts: Bool,
        timeout: TimeInterval = 180
    ) async throws -> Transcript {
        let binary = try locateBinary()

        guard FileManager.default.fileExists(atPath: audioURL.path) else {
            throw VoxLocalError.recordingFailed("audio file vanished before transcription")
        }
        switch ModelManager.validateModelFile(at: modelURL) {
        case .valid: break
        case .missing: throw VoxLocalError.modelMissing(modelURL.path)
        case .tooSmall, .badMagic: throw VoxLocalError.modelInvalid(modelURL.path)
        }

        let outputBase = FileManager.default.temporaryDirectory
            .appendingPathComponent("voxlocal-out-\(UUID().uuidString)")
        let jsonURL = URL(fileURLWithPath: outputBase.path + ".json")
        defer { try? FileManager.default.removeItem(at: jsonURL) }

        let args = WhisperCommandBuilder.arguments(
            modelPath: modelURL.path,
            audioPath: audioURL.path,
            language: language,
            threads: threads,
            outputBase: outputBase.path)

        Log.shared.info("whisper-cli starting (model \(modelURL.lastPathComponent), lang \(language), threads \(threads))")
        let started = Date()

        let result: SubprocessResult
        do {
            result = try await runner.run(executable: binary, arguments: args, timeout: timeout)
        } catch SubprocessError.timeout {
            throw VoxLocalError.transcriptionTimeout
        } catch SubprocessError.launchFailed(let reason) {
            if reason.localizedCaseInsensitiveContains("bad cpu type")
                || reason.localizedCaseInsensitiveContains("badarch") {
                throw VoxLocalError.unsupportedArchitecture(reason)
            }
            throw VoxLocalError.transcriptionFailed(exitCode: -1, detail: reason)
        }

        try Task.checkCancellation()

        guard result.exitCode == 0 else {
            let stderrTail = String(data: result.stderr.suffix(600), encoding: .utf8) ?? ""
            if stderrTail.localizedCaseInsensitiveContains("failed to load model")
                || stderrTail.localizedCaseInsensitiveContains("invalid model") {
                throw VoxLocalError.modelInvalid(modelURL.path)
            }
            throw VoxLocalError.transcriptionFailed(exitCode: result.exitCode, detail: stderrTail)
        }

        guard let jsonData = try? Data(contentsOf: jsonURL) else {
            throw VoxLocalError.transcriptionOutputMissing
        }
        let output: WhisperOutputParser.Output
        do {
            output = try WhisperOutputParser.parse(jsonData: jsonData, removeArtifacts: removeArtifacts)
        } catch {
            throw VoxLocalError.transcriptionOutputMissing
        }

        let elapsed = String(format: "%.1f", Date().timeIntervalSince(started))
        Log.shared.info("whisper-cli finished in \(elapsed)s (chars: \(output.text.count), lang: \(output.detectedLanguage ?? "?"))")
        return Transcript(text: output.text, detectedLanguage: output.detectedLanguage)
    }
}
