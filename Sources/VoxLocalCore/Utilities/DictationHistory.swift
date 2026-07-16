import Foundation

/// Optional local journal of recognized text (opt-in via settings). Plain
/// text, stored only on this Mac; audio is never saved regardless. Lets the
/// user recover a dictation even if insertion failed or the clipboard was
/// overwritten.
public final class DictationHistory {
    public static let shared = DictationHistory()

    public let fileURL: URL

    init(fileURL: URL? = nil) {
        if let fileURL {
            self.fileURL = fileURL
        } else {
            let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
                ?? FileManager.default.homeDirectoryForCurrentUser
            self.fileURL = base.appendingPathComponent("VoxLocal/DictationHistory.txt")
        }
    }

    public func append(_ text: String) {
        let formatter = DateFormatter()
        formatter.dateFormat = "dd.MM.yyyy HH:mm:ss"
        let entry = "[\(formatter.string(from: Date()))]\n\(text)\n\n"
        guard let data = entry.data(using: .utf8) else { return }
        do {
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true)
            if FileManager.default.fileExists(atPath: fileURL.path),
               let handle = try? FileHandle(forWritingTo: fileURL) {
                defer { try? handle.close() }
                try handle.seekToEnd()
                try handle.write(contentsOf: data)
            } else {
                try data.write(to: fileURL)
            }
        } catch {
            // Never let journaling break dictation; note the failure only.
            Log.shared.error("history append failed: \(error.localizedDescription)")
        }
    }

    /// Opens the journal in the default text editor, creating it first so
    /// the open call cannot fail on a missing file.
    public func revealInEditor() {
        if !FileManager.default.fileExists(atPath: fileURL.path) {
            try? FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true)
            try? Data().write(to: fileURL)
        }
    }
}
