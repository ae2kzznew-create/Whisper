import Foundation

enum GigaAMError: Error {
    case runtimeMissing
    case startFailed(String)
    case badResponse(String)
}

/// Optional Russian-focused engine: Sber's GigaAM v3 (ONNX, RNNT with
/// punctuation), noticeably more accurate and faster than Whisper for
/// Russian speech on CPU-only Macs.
///
/// Runs a small Python worker (line protocol: WAV path in → JSON out) that
/// keeps the model loaded between dictations. The runtime (python venv +
/// model) is not bundled: it is detected on disk — by default the runtime
/// shipped inside WordRiver.app — and can be overridden with environment
/// variables. Everything is local; nothing leaves the machine.
///
/// Any failure here is non-fatal: DictationController falls back to Whisper.
@MainActor
public final class GigaAMTranscriber {
    public struct Runtime {
        public let python: URL
        public let script: URL
        public let modelDir: URL

        /// Detection order: VOXLOCAL_GIGAAM_* environment overrides, then
        /// the WordRiver.app runtime location.
        public static func detect() -> Runtime? {
            let env = ProcessInfo.processInfo.environment
            let base = URL(fileURLWithPath: env["VOXLOCAL_GIGAAM_RUNTIME"]
                ?? "/Applications/WordRiver.app/Contents/Resources/runtime")
            let python = base.appendingPathComponent("venv/bin/python3")
            let script = base.appendingPathComponent("backend/gigaam_server.py")
            let modelDir = base.appendingPathComponent("models/gigaam-v3-onnx")
            let fm = FileManager.default
            guard fm.isExecutableFile(atPath: python.path),
                  fm.fileExists(atPath: script.path),
                  fm.fileExists(atPath: modelDir.path) else {
                return nil
            }
            return Runtime(python: python, script: script, modelDir: modelDir)
        }
    }

    public static var isAvailable: Bool { Runtime.detect() != nil }

    private var process: Process?
    private var stdinHandle: FileHandle?
    private var reader: PipeLineReader?

    public init() {}

    public func ensureRunning() async throws {
        if let process, process.isRunning {
            return
        }
        stop()
        guard let runtime = Runtime.detect() else {
            throw GigaAMError.runtimeMissing
        }

        let process = Process()
        process.executableURL = runtime.python
        process.arguments = [runtime.script.path, "--model-dir", runtime.modelDir.path]
        let stdinPipe = Pipe()
        let stdoutPipe = Pipe()
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            throw GigaAMError.startFailed(error.localizedDescription)
        }
        self.process = process
        stdinHandle = stdinPipe.fileHandleForWriting
        let reader = PipeLineReader(handle: stdoutPipe.fileHandleForReading)
        self.reader = reader

        Log.shared.info("gigaam worker starting (model \(runtime.modelDir.lastPathComponent))")
        // The worker prints READY once the model is loaded, or a JSON error.
        // A crash closes the pipe and readLine returns nil.
        guard let line = await reader.readLine(timeout: 120) else {
            stop()
            throw GigaAMError.startFailed("worker exited during startup")
        }
        guard line == "READY" else {
            stop()
            throw GigaAMError.startFailed(String(line.prefix(200)))
        }
        Log.shared.info("gigaam worker ready")
    }

    public func stop() {
        if let stdinHandle {
            try? stdinHandle.write(contentsOf: "__QUIT__\n".data(using: .utf8)!)
        }
        if let process, process.isRunning {
            process.terminate()
        }
        process = nil
        stdinHandle = nil
        reader = nil
    }

    public func transcribe(audioURL: URL) async throws -> WhisperTranscriber.Transcript {
        guard let process, process.isRunning, let stdinHandle, let reader else {
            throw GigaAMError.startFailed("worker not running")
        }
        let started = Date()
        Log.shared.info("gigaam inference starting")
        do {
            try stdinHandle.write(contentsOf: (audioURL.path + "\n").data(using: .utf8)!)
        } catch {
            stop()
            throw GigaAMError.badResponse("worker pipe closed")
        }
        guard let line = await reader.readLine(timeout: 180) else {
            stop()
            throw GigaAMError.badResponse("no reply from worker")
        }
        guard let data = line.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw GigaAMError.badResponse("unparseable reply")
        }
        if let ok = json["ok"] as? Bool, ok, let rawText = json["text"] as? String {
            let text = WhisperOutputParser.normalizeWhitespace(rawText)
            let elapsed = String(format: "%.1f", Date().timeIntervalSince(started))
            Log.shared.info("gigaam finished in \(elapsed)s (chars: \(text.count))")
            return WhisperTranscriber.Transcript(text: text, detectedLanguage: "ru")
        }
        let detail = (json["error"] as? String) ?? "unknown worker error"
        throw GigaAMError.badResponse(String(detail.prefix(200)))
    }
}

/// Accumulates pipe output on a background queue and hands out one line at a
/// time. Single consumer; EOF (process death) unblocks with nil.
final class PipeLineReader: @unchecked Sendable {
    private let handle: FileHandle
    private var buffer = Data()
    private let queue = DispatchQueue(label: "org.voxlocal.gigaam.pipe-reader")

    init(handle: FileHandle) {
        self.handle = handle
    }

    func readLine(timeout: TimeInterval) async -> String? {
        await withCheckedContinuation { continuation in
            queue.async { [weak self] in
                guard let self else {
                    continuation.resume(returning: nil)
                    return
                }
                let deadline = Date().addingTimeInterval(timeout)
                while Date() < deadline {
                    if let newline = self.buffer.firstIndex(of: 0x0A) {
                        let lineData = self.buffer[self.buffer.startIndex..<newline]
                        let line = String(data: lineData, encoding: .utf8)?
                            .trimmingCharacters(in: .whitespacesAndNewlines)
                        self.buffer.removeSubrange(self.buffer.startIndex...newline)
                        continuation.resume(returning: line)
                        return
                    }
                    let chunk = self.handle.availableData // blocks until data or EOF
                    if chunk.isEmpty {
                        continuation.resume(returning: nil) // EOF
                        return
                    }
                    self.buffer.append(chunk)
                }
                continuation.resume(returning: nil)
            }
        }
    }
}
