import Foundation
import Combine

public enum HotkeyMode: String, CaseIterable, Sendable {
    /// Record while the shortcut is held; stop on release.
    case pressAndHold
    /// First press starts, second press stops.
    case toggle
}

public enum InsertionMode: String, CaseIterable, Sendable {
    /// Try Accessibility insertion, then paste, then clipboard.
    case automatic
    /// Always just place the result on the clipboard.
    case clipboardOnly
}

public enum SpokenLanguage: String, CaseIterable, Sendable {
    case auto
    case russian = "ru"
    case english = "en"

    /// Value passed to whisper-cli `-l`.
    public var whisperCode: String { self == .auto ? "auto" : rawValue }
}

/// All persisted user settings. Backed by `UserDefaults` (injectable for
/// tests). Every property writes through immediately.
public final class SettingsStore: ObservableObject {
    private let defaults: UserDefaults

    private enum Key {
        static let hotkeyKeyCode = "hotkey.keyCode"
        static let hotkeyModifiers = "hotkey.modifiers"
        static let hotkeyMode = "hotkey.mode"
        static let inputDeviceUID = "audio.inputDeviceUID"
        static let whisperModel = "whisper.model"
        static let spokenLanguage = "whisper.language"
        static let whisperThreads = "whisper.threads"
        static let removeArtifacts = "whisper.removeArtifacts"
        static let keepModelWarm = "whisper.keepWarm"
        static let historyEnabled = "history.enabled"
        static let refinementEnabled = "refine.enabled"
        static let ollamaEndpoint = "refine.ollamaEndpoint"
        static let ollamaModel = "refine.ollamaModel"
        static let refinementPreset = "refine.preset"
        static let customInstruction = "refine.customInstruction"
        static let refinementTimeout = "refine.timeout"
        static let insertionMode = "insert.mode"
        static let launchAtLogin = "app.launchAtLogin"
        static let interfaceLanguage = "app.interfaceLanguage"
        static let logLevel = "app.logLevel"
        static let onboardingCompleted = "app.onboardingCompleted"
    }

    public static let defaultOllamaEndpoint = "http://127.0.0.1:11434"
    public static let defaultHotkeyKeyCode: UInt32 = 49 // Space
    public static let defaultHotkeyModifiers: UInt32 = 0x0800 // Carbon optionKey

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults

        hotkeyKeyCode = UInt32(defaults.object(forKey: Key.hotkeyKeyCode) as? Int ?? Int(Self.defaultHotkeyKeyCode))
        hotkeyModifiers = UInt32(defaults.object(forKey: Key.hotkeyModifiers) as? Int ?? Int(Self.defaultHotkeyModifiers))
        hotkeyMode = HotkeyMode(rawValue: defaults.string(forKey: Key.hotkeyMode) ?? "") ?? .pressAndHold
        inputDeviceUID = defaults.string(forKey: Key.inputDeviceUID)
        whisperModel = defaults.string(forKey: Key.whisperModel) ?? "base"
        spokenLanguage = SpokenLanguage(rawValue: defaults.string(forKey: Key.spokenLanguage) ?? "") ?? .auto
        whisperThreads = defaults.object(forKey: Key.whisperThreads) as? Int
            ?? min(8, max(2, ProcessInfo.processInfo.activeProcessorCount / 2))
        removeArtifacts = defaults.object(forKey: Key.removeArtifacts) as? Bool ?? true
        keepModelWarm = defaults.object(forKey: Key.keepModelWarm) as? Bool ?? false
        historyEnabled = defaults.object(forKey: Key.historyEnabled) as? Bool ?? false
        refinementEnabled = defaults.object(forKey: Key.refinementEnabled) as? Bool ?? false
        ollamaEndpoint = defaults.string(forKey: Key.ollamaEndpoint) ?? Self.defaultOllamaEndpoint
        ollamaModel = defaults.string(forKey: Key.ollamaModel) ?? ""
        refinementPreset = RefinementPreset(rawValue: defaults.string(forKey: Key.refinementPreset) ?? "") ?? .cleanDictation
        customInstruction = defaults.string(forKey: Key.customInstruction) ?? ""
        refinementTimeout = defaults.object(forKey: Key.refinementTimeout) as? Double ?? 20.0
        insertionMode = InsertionMode(rawValue: defaults.string(forKey: Key.insertionMode) ?? "") ?? .automatic
        launchAtLogin = defaults.object(forKey: Key.launchAtLogin) as? Bool ?? false
        interfaceLanguage = L10n.Language(rawValue: defaults.string(forKey: Key.interfaceLanguage) ?? "") ?? .russian
        logLevel = LogLevel(rawValue: defaults.object(forKey: Key.logLevel) as? Int ?? LogLevel.info.rawValue) ?? .info
        onboardingCompleted = defaults.object(forKey: Key.onboardingCompleted) as? Bool ?? false
    }

    @Published public var hotkeyKeyCode: UInt32 {
        didSet { defaults.set(Int(hotkeyKeyCode), forKey: Key.hotkeyKeyCode) }
    }
    @Published public var hotkeyModifiers: UInt32 {
        didSet { defaults.set(Int(hotkeyModifiers), forKey: Key.hotkeyModifiers) }
    }
    @Published public var hotkeyMode: HotkeyMode {
        didSet { defaults.set(hotkeyMode.rawValue, forKey: Key.hotkeyMode) }
    }
    @Published public var inputDeviceUID: String? {
        didSet { defaults.set(inputDeviceUID, forKey: Key.inputDeviceUID) }
    }
    @Published public var whisperModel: String {
        didSet { defaults.set(whisperModel, forKey: Key.whisperModel) }
    }
    @Published public var spokenLanguage: SpokenLanguage {
        didSet { defaults.set(spokenLanguage.rawValue, forKey: Key.spokenLanguage) }
    }
    @Published public var whisperThreads: Int {
        didSet { defaults.set(whisperThreads, forKey: Key.whisperThreads) }
    }
    @Published public var removeArtifacts: Bool {
        didSet { defaults.set(removeArtifacts, forKey: Key.removeArtifacts) }
    }
    @Published public var keepModelWarm: Bool {
        didSet { defaults.set(keepModelWarm, forKey: Key.keepModelWarm) }
    }
    @Published public var historyEnabled: Bool {
        didSet { defaults.set(historyEnabled, forKey: Key.historyEnabled) }
    }
    @Published public var refinementEnabled: Bool {
        didSet { defaults.set(refinementEnabled, forKey: Key.refinementEnabled) }
    }
    @Published public var ollamaEndpoint: String {
        didSet { defaults.set(ollamaEndpoint, forKey: Key.ollamaEndpoint) }
    }
    @Published public var ollamaModel: String {
        didSet { defaults.set(ollamaModel, forKey: Key.ollamaModel) }
    }
    @Published public var refinementPreset: RefinementPreset {
        didSet { defaults.set(refinementPreset.rawValue, forKey: Key.refinementPreset) }
    }
    @Published public var customInstruction: String {
        didSet { defaults.set(customInstruction, forKey: Key.customInstruction) }
    }
    @Published public var refinementTimeout: Double {
        didSet { defaults.set(refinementTimeout, forKey: Key.refinementTimeout) }
    }
    @Published public var insertionMode: InsertionMode {
        didSet { defaults.set(insertionMode.rawValue, forKey: Key.insertionMode) }
    }
    @Published public var launchAtLogin: Bool {
        didSet { defaults.set(launchAtLogin, forKey: Key.launchAtLogin) }
    }
    @Published public var interfaceLanguage: L10n.Language {
        didSet {
            defaults.set(interfaceLanguage.rawValue, forKey: Key.interfaceLanguage)
            L10n.setLanguage(interfaceLanguage)
        }
    }
    @Published public var logLevel: LogLevel {
        didSet {
            defaults.set(logLevel.rawValue, forKey: Key.logLevel)
            Log.shared.level = logLevel
        }
    }
    @Published public var onboardingCompleted: Bool {
        didSet { defaults.set(onboardingCompleted, forKey: Key.onboardingCompleted) }
    }

    public func resetOnboarding() {
        onboardingCompleted = false
    }
}
