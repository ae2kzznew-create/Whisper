import AppKit
import Carbon.HIToolbox
import Foundation

/// A global shortcut: virtual key code + Carbon modifier mask.
public struct KeyCombo: Equatable, Codable, Sendable {
    public let keyCode: UInt32
    /// Carbon modifier mask (cmdKey/shiftKey/optionKey/controlKey).
    public let modifiers: UInt32

    public init(keyCode: UInt32, modifiers: UInt32) {
        self.keyCode = keyCode
        self.modifiers = modifiers
    }

    public static let carbonCmd: UInt32 = UInt32(cmdKey)
    public static let carbonShift: UInt32 = UInt32(shiftKey)
    public static let carbonOption: UInt32 = UInt32(optionKey)
    public static let carbonControl: UInt32 = UInt32(controlKey)

    /// Default: ⌥Space.
    public static let `default` = KeyCombo(keyCode: 49, modifiers: carbonOption)

    public static func fromNSEvent(keyCode: UInt16, flags: NSEvent.ModifierFlags) -> KeyCombo {
        var mods: UInt32 = 0
        if flags.contains(.command) { mods |= carbonCmd }
        if flags.contains(.shift) { mods |= carbonShift }
        if flags.contains(.option) { mods |= carbonOption }
        if flags.contains(.control) { mods |= carbonControl }
        return KeyCombo(keyCode: UInt32(keyCode), modifiers: mods)
    }

    public var displayString: String {
        var parts = ""
        if modifiers & Self.carbonControl != 0 { parts += "⌃" }
        if modifiers & Self.carbonOption != 0 { parts += "⌥" }
        if modifiers & Self.carbonShift != 0 { parts += "⇧" }
        if modifiers & Self.carbonCmd != 0 { parts += "⌘" }
        return parts + Self.keyName(for: keyCode)
    }

    static let specialKeyNames: [UInt32: String] = [
        49: "Space", 36: "↩", 48: "⇥", 51: "⌫", 53: "Esc",
        123: "←", 124: "→", 125: "↓", 126: "↑",
        122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5", 97: "F6",
        98: "F7", 100: "F8", 101: "F9", 109: "F10", 103: "F11", 111: "F12",
        115: "Home", 119: "End", 116: "PgUp", 121: "PgDn", 117: "⌦",
    ]

    public static func keyName(for keyCode: UInt32) -> String {
        if let special = specialKeyNames[keyCode] {
            return special
        }
        // Translate through the current keyboard layout.
        if let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
           let layoutDataPtr = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) {
            let layoutData = unsafeBitCast(layoutDataPtr, to: CFData.self) as Data
            var deadKeyState: UInt32 = 0
            var chars = [UniChar](repeating: 0, count: 4)
            var length = 0
            let status = layoutData.withUnsafeBytes { (bytes: UnsafeRawBufferPointer) -> OSStatus in
                let layout = bytes.bindMemory(to: UCKeyboardLayout.self).baseAddress!
                return UCKeyTranslate(
                    layout, UInt16(keyCode), UInt16(kUCKeyActionDisplay), 0,
                    UInt32(LMGetKbdType()), UInt32(kUCKeyTranslateNoDeadKeysBit),
                    &deadKeyState, chars.count, &length, &chars)
            }
            if status == noErr, length > 0 {
                return String(utf16CodeUnits: chars, count: length).uppercased()
            }
        }
        return "Key \(keyCode)"
    }
}
