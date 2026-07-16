import AppKit
import Carbon.HIToolbox
import Foundation

public enum HotkeyError: Error, Equatable {
    /// Registration failed — usually because another app owns the combo.
    case conflict(KeyCombo)
    case registrationFailed(OSStatus)
}

/// System-wide hotkeys via Carbon `RegisterEventHotKey`. This supports both
/// key-down and key-up events (needed for press-and-hold) and requires no
/// Accessibility permission. An additional Escape hotkey is registered only
/// while a dictation session is active, so Escape behaves normally the rest
/// of the time.
public final class HotkeyManager {
    public var onMainKeyDown: (() -> Void)?
    public var onMainKeyUp: (() -> Void)?
    public var onEscape: (() -> Void)?

    private static let signature: OSType = 0x564F_584C // "VOXL"
    private static let mainHotkeyID: UInt32 = 1
    private static let escapeHotkeyID: UInt32 = 2

    private var eventHandler: EventHandlerRef?
    private var mainHotkey: EventHotKeyRef?
    private var escapeHotkey: EventHotKeyRef?
    private(set) public var registeredCombo: KeyCombo?

    // Modifier-only hotkey (e.g. a bare right ⌥): Carbon can't register a
    // lone modifier, so we watch flagsChanged events instead. The global
    // monitor needs the Accessibility permission the app already requests
    // for text insertion.
    private var flagsMonitors: [Any] = []
    private var modifierIsDown = false

    /// NSDeviceIndependentModifierFlagsMask; spelled out because the macOS 13
    /// SDK's Swift overlay lacks `.deviceIndependentFlagsOnly`.
    static let deviceIndependentMask = NSEvent.ModifierFlags(rawValue: 0xFFFF_0000)

    private static let modifierFlagByKeyCode: [UInt32: NSEvent.ModifierFlags] = [
        54: .command, 55: .command,
        56: .shift, 60: .shift,
        58: .option, 61: .option,
        59: .control, 62: .control,
        63: .function,
    ]

    public init() {}

    deinit {
        unregisterMainHotkey()
        unregisterEscape()
        if let eventHandler {
            RemoveEventHandler(eventHandler)
        }
    }

    private func installHandlerIfNeeded() {
        guard eventHandler == nil else { return }
        var eventTypes = [
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed)),
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyReleased)),
        ]
        let selfPtr = Unmanaged.passUnretained(self).toOpaque()
        InstallEventHandler(
            GetEventDispatcherTarget(),
            { _, event, userData -> OSStatus in
                guard let event, let userData else { return OSStatus(eventNotHandledErr) }
                let manager = Unmanaged<HotkeyManager>.fromOpaque(userData).takeUnretainedValue()
                return manager.handle(event: event)
            },
            eventTypes.count,
            &eventTypes,
            selfPtr,
            &eventHandler)
    }

    private func handle(event: EventRef) -> OSStatus {
        var hotkeyID = EventHotKeyID()
        let status = GetEventParameter(
            event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
            nil, MemoryLayout<EventHotKeyID>.size, nil, &hotkeyID)
        guard status == noErr, hotkeyID.signature == Self.signature else {
            return OSStatus(eventNotHandledErr)
        }
        let kind = GetEventKind(event)
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            switch (hotkeyID.id, Int(kind)) {
            case (Self.mainHotkeyID, kEventHotKeyPressed):
                self.onMainKeyDown?()
            case (Self.mainHotkeyID, kEventHotKeyReleased):
                self.onMainKeyUp?()
            case (Self.escapeHotkeyID, kEventHotKeyPressed):
                self.onEscape?()
            default:
                break
            }
        }
        return noErr
    }

    /// Registers the main dictation shortcut. Throws `.conflict` when the
    /// system rejects the combo (already taken by another application).
    /// The new combo is registered *before* the old one is removed, so a
    /// failed change keeps the previously working shortcut alive.
    public func registerMainHotkey(_ combo: KeyCombo) throws {
        if combo.isModifierOnly {
            registerModifierOnlyHotkey(combo)
            return
        }
        installHandlerIfNeeded()
        var ref: EventHotKeyRef?
        let hotkeyID = EventHotKeyID(signature: Self.signature, id: Self.mainHotkeyID)
        let status = RegisterEventHotKey(
            combo.keyCode, combo.modifiers, hotkeyID,
            GetEventDispatcherTarget(), 0, &ref)
        guard status == noErr, let ref else {
            Log.shared.error("hotkey registration failed (OSStatus \(status)) for \(combo.displayString)")
            if status == OSStatus(-9878) { // eventHotKeyExistsErr
                throw HotkeyError.conflict(combo)
            }
            throw HotkeyError.registrationFailed(status)
        }
        unregisterMainHotkey()
        mainHotkey = ref
        registeredCombo = combo
        Log.shared.info("hotkey registered: \(combo.displayString)")
    }

    public func unregisterMainHotkey() {
        if let mainHotkey {
            UnregisterEventHotKey(mainHotkey)
            self.mainHotkey = nil
        }
        removeFlagsMonitors()
        registeredCombo = nil
    }

    // MARK: - Modifier-only hotkey (flagsChanged monitors)

    private func registerModifierOnlyHotkey(_ combo: KeyCombo) {
        unregisterMainHotkey()
        let handler: (NSEvent) -> Void = { [weak self] event in
            self?.handleFlagsChanged(event, combo: combo)
        }
        if let global = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged, handler: handler) {
            flagsMonitors.append(global)
        } else {
            Log.shared.error("global flagsChanged monitor unavailable — modifier-only hotkey needs the Accessibility permission")
        }
        flagsMonitors.append(NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { event in
            handler(event)
            return event
        } as Any)
        registeredCombo = combo
        Log.shared.info("hotkey registered: \(combo.displayString) (modifier-only)")
    }

    private func handleFlagsChanged(_ event: NSEvent, combo: KeyCombo) {
        guard UInt32(event.keyCode) == combo.keyCode,
              let flag = Self.modifierFlagByKeyCode[combo.keyCode] else { return }
        let isDown = event.modifierFlags.intersection(HotkeyManager.deviceIndependentMask).contains(flag)
        if isDown, !modifierIsDown {
            modifierIsDown = true
            DispatchQueue.main.async { [weak self] in self?.onMainKeyDown?() }
        } else if !isDown, modifierIsDown {
            modifierIsDown = false
            DispatchQueue.main.async { [weak self] in self?.onMainKeyUp?() }
        }
    }

    private func removeFlagsMonitors() {
        for monitor in flagsMonitors {
            NSEvent.removeMonitor(monitor)
        }
        flagsMonitors.removeAll()
        modifierIsDown = false
    }

    /// Escape is captured system-wide only while dictation is in flight.
    public func registerEscape() {
        installHandlerIfNeeded()
        guard escapeHotkey == nil else { return }
        var ref: EventHotKeyRef?
        let hotkeyID = EventHotKeyID(signature: Self.signature, id: Self.escapeHotkeyID)
        let status = RegisterEventHotKey(
            53, 0, hotkeyID, GetEventDispatcherTarget(), 0, &ref)
        if status == noErr, let ref {
            escapeHotkey = ref
        } else {
            // Not fatal: cancellation stays available from the menu bar.
            Log.shared.info("escape hotkey unavailable (OSStatus \(status))")
        }
    }

    public func unregisterEscape() {
        if let escapeHotkey {
            UnregisterEventHotKey(escapeHotkey)
            self.escapeHotkey = nil
        }
    }
}
