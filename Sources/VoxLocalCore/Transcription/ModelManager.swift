import Foundation

/// Manages local ggml model files: discovery, integrity validation and
/// downloads with progress. Models live in
/// `~/Library/Application Support/VoxLocal/models`.
public final class ModelManager: NSObject, ObservableObject {
    public struct InstalledModel: Identifiable, Hashable, Sendable {
        public let name: String
        public let url: URL
        public let sizeBytes: Int64
        public var id: String { name }
    }

    /// ggml container magic ("ggml" read as a little-endian UInt32).
    static let ggmlMagic: UInt32 = 0x6767_6D6C
    static let minimumModelBytes: Int64 = 1_000_000

    @Published public private(set) var installedModels: [InstalledModel] = []
    @Published public private(set) var downloadProgress: Double?
    @Published public private(set) var downloadingModel: String?

    public let modelsDirectory: URL
    private var downloadTask: URLSessionDownloadTask?
    private var downloadContinuation: CheckedContinuation<URL, Error>?
    private lazy var session = URLSession(configuration: .ephemeral, delegate: self, delegateQueue: nil)

    public init(modelsDirectory: URL? = nil) {
        self.modelsDirectory = modelsDirectory ?? FileManager.default
            .homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/VoxLocal/models", isDirectory: true)
        super.init()
        try? FileManager.default.createDirectory(at: self.modelsDirectory, withIntermediateDirectories: true)
        refreshInstalledModels()
    }

    // MARK: - Discovery & validation

    public func refreshInstalledModels() {
        let fm = FileManager.default
        let urls = (try? fm.contentsOfDirectory(at: modelsDirectory, includingPropertiesForKeys: [.fileSizeKey]))
            ?? []
        let models = urls
            .filter { $0.pathExtension == "bin" }
            .compactMap { url -> InstalledModel? in
                guard case .valid = Self.validateModelFile(at: url) else { return nil }
                let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? 0
                return InstalledModel(name: Self.modelName(fromFileName: url.lastPathComponent), url: url, sizeBytes: size)
            }
            .sorted { $0.sizeBytes < $1.sizeBytes }
        DispatchQueue.main.async { self.installedModels = models }
    }

    public static func modelName(fromFileName fileName: String) -> String {
        var name = fileName
        if name.hasPrefix("ggml-") { name.removeFirst(5) }
        if name.hasSuffix(".bin") { name.removeLast(4) }
        return name
    }

    public enum ValidationResult: Equatable, Sendable {
        case valid
        case missing
        case tooSmall
        case badMagic
    }

    /// Checks existence, a minimum plausible size and the ggml magic number.
    public static func validateModelFile(at url: URL) -> ValidationResult {
        let fm = FileManager.default
        guard fm.fileExists(atPath: url.path) else { return .missing }
        guard let size = (try? fm.attributesOfItem(atPath: url.path)[.size]) as? Int64,
              size >= minimumModelBytes else { return .tooSmall }
        guard let handle = try? FileHandle(forReadingFrom: url),
              let head = try? handle.read(upToCount: 4), head.count == 4 else { return .badMagic }
        try? handle.close()
        let magic = head.withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }.littleEndian
        return magic == ggmlMagic ? .valid : .badMagic
    }

    /// URL where a model with the given name is expected.
    public func expectedURL(forModelName name: String) -> URL {
        modelsDirectory.appendingPathComponent("ggml-\(name).bin")
    }

    /// Resolves the model selected in settings to a validated file URL.
    public func resolveModel(named name: String) throws -> URL {
        let url = expectedURL(forModelName: name)
        switch Self.validateModelFile(at: url) {
        case .valid:
            return url
        case .missing:
            throw VoxLocalError.modelMissing(url.path)
        case .tooSmall, .badMagic:
            throw VoxLocalError.modelInvalid(url.path)
        }
    }

    // MARK: - Download

    public var isDownloading: Bool { downloadingModel != nil }

    /// Downloads a catalog model. The UI must show `info.sizeLabel` and get
    /// explicit user confirmation before calling this.
    @discardableResult
    public func download(_ info: WhisperModelInfo) async throws -> URL {
        guard !isDownloading else {
            throw NSError(domain: "VoxLocal", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: L10n.t("models.download.busy")])
        }
        await MainActor.run {
            downloadingModel = info.name
            downloadProgress = 0
        }
        defer {
            Task { @MainActor in
                self.downloadingModel = nil
                self.downloadProgress = nil
            }
        }
        Log.shared.info("model download started: \(info.name) (~\(info.approxMB) MB)")

        let tempURL: URL = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                downloadContinuation = continuation
                let task = session.downloadTask(with: info.downloadURL)
                downloadTask = task
                task.resume()
            }
        } onCancel: {
            downloadTask?.cancel()
        }

        let destination = expectedURL(forModelName: info.name)
        let fm = FileManager.default
        try? fm.removeItem(at: destination)
        try fm.moveItem(at: tempURL, to: destination)

        guard case .valid = Self.validateModelFile(at: destination) else {
            try? fm.removeItem(at: destination)
            throw VoxLocalError.modelInvalid(destination.path)
        }
        Log.shared.info("model download finished: \(info.name)")
        refreshInstalledModels()
        return destination
    }

    public func cancelDownload() {
        downloadTask?.cancel()
    }
}

extension ModelManager: URLSessionDownloadDelegate {
    public func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                           didFinishDownloadingTo location: URL) {
        // Move out of the system temp slot synchronously; the delegate
        // deletes `location` as soon as this method returns.
        let holding = FileManager.default.temporaryDirectory
            .appendingPathComponent("voxlocal-model-\(UUID().uuidString).bin")
        do {
            if let http = downloadTask.response as? HTTPURLResponse, http.statusCode != 200 {
                throw NSError(domain: "VoxLocal", code: http.statusCode,
                              userInfo: [NSLocalizedDescriptionKey: "HTTP \(http.statusCode)"])
            }
            try FileManager.default.moveItem(at: location, to: holding)
            downloadContinuation?.resume(returning: holding)
        } catch {
            downloadContinuation?.resume(throwing: error)
        }
        downloadContinuation = nil
    }

    public func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                           didWriteData bytesWritten: Int64, totalBytesWritten: Int64,
                           totalBytesExpectedToWrite: Int64) {
        guard totalBytesExpectedToWrite > 0 else { return }
        let progress = Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)
        DispatchQueue.main.async { self.downloadProgress = progress }
    }

    public func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error {
            downloadContinuation?.resume(throwing: error)
            downloadContinuation = nil
        }
    }
}
