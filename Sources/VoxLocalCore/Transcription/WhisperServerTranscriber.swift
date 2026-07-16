import Darwin
import Foundation

enum WhisperServerError: Error {
    case binaryMissing
    case startFailed(String)
    case badResponse(String)
}

/// Keeps a local `whisper-server` (whisper.cpp) child process alive so the
/// model stays loaded in memory between dictations — removing the per-run
/// model-load cost of `whisper-cli`. Bound strictly to 127.0.0.1 on a port
/// chosen by the OS; audio never leaves the machine.
///
/// Used only when the "keep model warm" setting is on. Any failure here is
/// non-fatal: DictationController falls back to the whisper-cli path.
@MainActor
public final class WhisperServerTranscriber {
    private var process: Process?
    private var port = 0
    private var currentModelPath = ""
    private var currentThreads = 0

    public init() {}

    /// Candidate locations for whisper-server, mirroring WhisperTranscriber.
    public static func binaryCandidates() -> [URL] {
        var candidates: [URL] = []
        if let env = ProcessInfo.processInfo.environment["VOXLOCAL_WHISPER_SERVER"], !env.isEmpty {
            candidates.append(URL(fileURLWithPath: env))
        }
        if let bundled = Bundle.main.url(forAuxiliaryExecutable: "whisper-server") {
            candidates.append(bundled)
        }
        let cwd = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        candidates.append(cwd.appendingPathComponent("vendor/whisper.cpp/build/bin/whisper-server"))
        return candidates
    }

    static func locateBinary() throws -> URL {
        let fm = FileManager.default
        for url in binaryCandidates() where fm.isExecutableFile(atPath: url.path) {
            return url
        }
        throw WhisperServerError.binaryMissing
    }

    /// Starts (or restarts) the server if it is not already running with the
    /// requested model and thread count. Waits until it accepts requests.
    public func ensureRunning(modelURL: URL, threads: Int) async throws {
        if let process, process.isRunning,
           currentModelPath == modelURL.path, currentThreads == threads {
            return
        }
        stop()

        let binary = try Self.locateBinary()
        let port = Self.findFreeLoopbackPort()
        let process = Process()
        process.executableURL = binary
        process.arguments = [
            "-m", modelURL.path,
            "--host", "127.0.0.1",
            "--port", String(port),
            "-t", String(threads),
        ]
        // The server logs request contents at higher verbosity; discard all
        // output so no dictation-related data reaches any log.
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            throw WhisperServerError.startFailed(error.localizedDescription)
        }
        self.process = process
        self.port = port
        currentModelPath = modelURL.path
        currentThreads = threads

        Log.shared.info("whisper-server starting (model \(modelURL.lastPathComponent), port \(port), threads \(threads))")
        let deadline = Date().addingTimeInterval(45)
        while Date() < deadline {
            try Task.checkCancellation()
            if !process.isRunning {
                stop()
                throw WhisperServerError.startFailed("server exited during startup")
            }
            if await isResponding() {
                Log.shared.info("whisper-server ready")
                return
            }
            try? await Task.sleep(nanoseconds: 300_000_000)
        }
        stop()
        throw WhisperServerError.startFailed("server did not become ready in time")
    }

    public func stop() {
        if let process, process.isRunning {
            process.terminate()
        }
        process = nil
        port = 0
        currentModelPath = ""
        currentThreads = 0
    }

    public func transcribe(
        audioURL: URL,
        language: String,
        removeArtifacts: Bool
    ) async throws -> WhisperTranscriber.Transcript {
        guard let process, process.isRunning, port > 0 else {
            throw WhisperServerError.startFailed("server not running")
        }
        let audioData = try Data(contentsOf: audioURL)
        let boundary = "voxlocal-\(UUID().uuidString)"

        var body = Data()
        func field(_ name: String, _ value: String) {
            body.append("--\(boundary)\r\n".data(using: .utf8)!)
            body.append("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n".data(using: .utf8)!)
        }
        field("response_format", "json")
        field("language", language)
        field("temperature", "0.0")
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"file\"; filename=\"audio.wav\"\r\n".data(using: .utf8)!)
        body.append("Content-Type: audio/wav\r\n\r\n".data(using: .utf8)!)
        body.append(audioData)
        body.append("\r\n--\(boundary)--\r\n".data(using: .utf8)!)

        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/inference")!)
        request.httpMethod = "POST"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 180

        let started = Date()
        Log.shared.info("whisper-server inference starting (lang \(language))")
        let (data, response) = try await URLSession.shared.upload(for: request, from: body)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            let code = (response as? HTTPURLResponse)?.statusCode ?? -1
            throw WhisperServerError.badResponse("HTTP \(code)")
        }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rawText = json["text"] as? String else {
            throw WhisperServerError.badResponse("unexpected response body")
        }

        let cleaned = removeArtifacts ? WhisperOutputParser.stripArtifacts(from: rawText) : rawText
        let text = WhisperOutputParser.normalizeWhitespace(cleaned)
        let elapsed = String(format: "%.1f", Date().timeIntervalSince(started))
        Log.shared.info("whisper-server finished in \(elapsed)s (chars: \(text.count))")
        return WhisperTranscriber.Transcript(text: text, detectedLanguage: nil)
    }

    private func isResponding() async -> Bool {
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/")!)
        request.timeoutInterval = 1
        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            return response is HTTPURLResponse
        } catch {
            return false
        }
    }

    /// Asks the OS for a free TCP port on the loopback interface.
    static func findFreeLoopbackPort() -> Int {
        let fallbackPort = 18653
        let sock = socket(AF_INET, SOCK_STREAM, 0)
        guard sock >= 0 else { return fallbackPort }
        defer { close(sock) }
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = 0
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        let bindResult = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(sock, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bindResult == 0 else { return fallbackPort }
        var assigned = sockaddr_in()
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        let nameResult = withUnsafeMutablePointer(to: &assigned) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getsockname(sock, $0, &len)
            }
        }
        guard nameResult == 0 else { return fallbackPort }
        return Int(UInt16(bigEndian: assigned.sin_port))
    }
}
