import AppKit
import Foundation

/// Snapshot of one pasteboard item: type identifier → data.
public struct PasteboardItemSnapshot: Equatable, Sendable {
    public let types: [String: Data]

    public init(types: [String: Data]) {
        self.types = types
    }
}

/// Abstraction over `NSPasteboard` so clipboard save/restore logic is
/// unit-testable without touching the real system clipboard.
public protocol Pasteboarding: AnyObject {
    var changeCount: Int { get }
    func snapshotItems() -> [PasteboardItemSnapshot]
    /// Writes a plain string; returns the resulting changeCount.
    @discardableResult
    func writeString(_ string: String) -> Int
    /// Restores previously snapshotted items; returns the resulting changeCount.
    @discardableResult
    func restore(_ items: [PasteboardItemSnapshot]) -> Int
}

public final class SystemPasteboard: Pasteboarding {
    private let pasteboard: NSPasteboard

    public init(pasteboard: NSPasteboard = .general) {
        self.pasteboard = pasteboard
    }

    public var changeCount: Int { pasteboard.changeCount }

    public func snapshotItems() -> [PasteboardItemSnapshot] {
        (pasteboard.pasteboardItems ?? []).map { item in
            var types: [String: Data] = [:]
            for type in item.types {
                if let data = item.data(forType: type) {
                    types[type.rawValue] = data
                }
            }
            return PasteboardItemSnapshot(types: types)
        }
    }

    @discardableResult
    public func writeString(_ string: String) -> Int {
        pasteboard.clearContents()
        pasteboard.setString(string, forType: .string)
        return pasteboard.changeCount
    }

    @discardableResult
    public func restore(_ items: [PasteboardItemSnapshot]) -> Int {
        pasteboard.clearContents()
        let restored = items.map { snapshot -> NSPasteboardItem in
            let item = NSPasteboardItem()
            for (type, data) in snapshot.types {
                item.setData(data, forType: NSPasteboard.PasteboardType(type))
            }
            return item
        }
        if !restored.isEmpty {
            pasteboard.writeObjects(restored)
        }
        return pasteboard.changeCount
    }
}

/// Decides whether the previous clipboard contents may be restored after a
/// synthetic paste. Pure logic, unit-tested: restore only when nobody else
/// has written to the pasteboard since our own write.
public enum ClipboardRestorePolicy {
    public static func shouldRestore(changeCountAfterOurWrite: Int, currentChangeCount: Int, hadPreviousContent: Bool) -> Bool {
        hadPreviousContent && currentChangeCount == changeCountAfterOurWrite
    }
}
