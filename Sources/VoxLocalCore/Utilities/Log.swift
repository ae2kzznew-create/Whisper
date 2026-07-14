import Foundation

public enum LogLevel: Int, Comparable, CaseIterable, Sendable {
    case off = 0
    case error = 1
    case info = 2
    case debug = 3

    public static func < (lhs: LogLevel, rhs: LogLevel) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    public var label: String {
        switch self {
        case .off: return "OFF"
        case .error: return "ERROR"
        case .info: return "INFO"
        case .debug: return "DEBUG"
        }
    }
}

/// Bounded local file logger. Privacy rules enforced by convention at every
/// call site: no raw audio, no transcript contents, no clipboard contents —
/// only lengths, states and redacted paths. Rotates at `maxBytes`, keeping
/// one previous generation, so total disk use stays bounded.
public final class Log: @unchecked Sendable {
    public static let shared = Log()

    private let queue = DispatchQueue(label: "voxlocal.log", qos: .utility)
    private let maxBytes: UInt64
    private let fileManager = FileManager.default
    private var handle: FileHandle?
    private let formatter: DateFormatter

    public var level: LogLevel = .info
    public let directory: URL
    public let fileURL: URL

    public init(directory: URL? = nil, maxBytes: UInt64 = 1_000_000) {
        self.maxBytes = maxBytes
        let dir = directory ?? FileManager.default
            .homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/VoxLocal", isDirectory: true)
        self.directory = dir
        self.fileURL = dir.appendingPathComponent("voxlocal.log")
        formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        try? fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    public func error(_ message: String) { write(.error, message) }
    public func info(_ message: String) { write(.info, message) }
    public func debug(_ message: String) { write(.debug, message) }

    private func write(_ level: LogLevel, _ message: String) {
        guard self.level >= level, self.level != .off else { return }
        let line = "\(formatter.string(from: Date())) [\(level.label)] \(message)\n"
        queue.async { [self] in
            rotateIfNeeded()
            if handle == nil {
                if !fileManager.fileExists(atPath: fileURL.path) {
                    fileManager.createFile(atPath: fileURL.path, contents: nil)
                }
                handle = try? FileHandle(forWritingTo: fileURL)
                _ = try? handle?.seekToEnd()
            }
            if let data = line.data(using: .utf8) {
                try? handle?.write(contentsOf: data)
            }
        }
    }

    private func rotateIfNeeded() {
        guard let size = try? fileManager.attributesOfItem(atPath: fileURL.path)[.size] as? UInt64,
              size > maxBytes else { return }
        try? handle?.close()
        handle = nil
        let previous = directory.appendingPathComponent("voxlocal.log.1")
        try? fileManager.removeItem(at: previous)
        try? fileManager.moveItem(at: fileURL, to: previous)
    }

    /// Flushes pending writes; used by tests.
    public func sync() {
        queue.sync {}
    }
}
