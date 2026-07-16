import AppKit
import ServiceManagement
import SwiftUI

/// Container passed into settings/onboarding so views can reach services.
@MainActor
public final class SettingsDependencies: ObservableObject {
    public let settings: SettingsStore
    public let modelManager: ModelManager
    public let permissions: PermissionsChecking
    public let dictation: DictationController
    /// Re-registers the global hotkey; returns a localized error, nil on success.
    public let applyHotkey: (KeyCombo) -> String?

    public init(
        settings: SettingsStore,
        modelManager: ModelManager,
        permissions: PermissionsChecking,
        dictation: DictationController,
        applyHotkey: @escaping (KeyCombo) -> String?
    ) {
        self.settings = settings
        self.modelManager = modelManager
        self.permissions = permissions
        self.dictation = dictation
        self.applyHotkey = applyHotkey
    }
}

public struct SettingsView: View {
    @ObservedObject var settings: SettingsStore
    let deps: SettingsDependencies

    public init(deps: SettingsDependencies) {
        self.deps = deps
        self.settings = deps.settings
    }

    public var body: some View {
        TabView {
            GeneralSettingsTab(settings: settings, deps: deps)
                .tabItem { Label(L10n.t("settings.tab.general"), systemImage: "gearshape") }
            TranscriptionSettingsTab(settings: settings, modelManager: deps.modelManager)
                .tabItem { Label(L10n.t("settings.tab.transcription"), systemImage: "waveform") }
            RefinementSettingsTab(settings: settings)
                .tabItem { Label(L10n.t("settings.tab.refinement"), systemImage: "wand.and.stars") }
            PrivacySettingsTab(settings: settings)
                .tabItem { Label(L10n.t("settings.tab.privacy"), systemImage: "lock.shield") }
        }
        .frame(width: 560, height: 520)
    }
}

// MARK: - General

struct GeneralSettingsTab: View {
    @ObservedObject var settings: SettingsStore
    let deps: SettingsDependencies
    @State private var hotkeyError: String?
    @State private var loginItemError: String?
    @State private var devices: [AudioDeviceFinder.Device] = []

    var body: some View {
        Form {
            Section(L10n.t("settings.hotkey.section")) {
                HStack {
                    Text(L10n.t("settings.hotkey"))
                    Spacer()
                    HotkeyRecorderView(
                        current: KeyCombo(keyCode: settings.hotkeyKeyCode, modifiers: settings.hotkeyModifiers)
                    ) { combo in
                        if let error = deps.applyHotkey(combo) {
                            hotkeyError = error
                        } else {
                            hotkeyError = nil
                            settings.hotkeyKeyCode = combo.keyCode
                            settings.hotkeyModifiers = combo.modifiers
                        }
                    }
                }
                if let hotkeyError {
                    Text(hotkeyError)
                        .font(.callout)
                        .foregroundStyle(.red)
                }
                Picker(L10n.t("settings.hotkey.mode"), selection: $settings.hotkeyMode) {
                    Text(L10n.t("settings.hotkey.mode.hold")).tag(HotkeyMode.pressAndHold)
                    Text(L10n.t("settings.hotkey.mode.toggle")).tag(HotkeyMode.toggle)
                }
                .pickerStyle(.radioGroup)
            }

            Section(L10n.t("settings.audio.section")) {
                Picker(L10n.t("settings.mic"), selection: Binding(
                    get: { settings.inputDeviceUID ?? "" },
                    set: { settings.inputDeviceUID = $0.isEmpty ? nil : $0 })
                ) {
                    Text(L10n.t("settings.mic.default")).tag("")
                    ForEach(devices) { device in
                        Text(device.name).tag(device.uid)
                    }
                }
            }

            Section(L10n.t("settings.insertion.section")) {
                Picker(L10n.t("settings.insertion"), selection: $settings.insertionMode) {
                    Text(L10n.t("settings.insertion.auto")).tag(InsertionMode.automatic)
                    Text(L10n.t("settings.insertion.clipboard")).tag(InsertionMode.clipboardOnly)
                }
                .pickerStyle(.radioGroup)
            }

            Section(L10n.t("settings.app.section")) {
                Toggle(L10n.t("settings.launchAtLogin"), isOn: Binding(
                    get: { settings.launchAtLogin },
                    set: { newValue in
                        settings.launchAtLogin = newValue
                        loginItemError = LoginItemService.setEnabled(newValue)
                    }))
                if let loginItemError {
                    Text(loginItemError)
                        .font(.callout)
                        .foregroundStyle(.orange)
                }
                Picker(L10n.t("settings.language.ui"), selection: $settings.interfaceLanguage) {
                    Text(L10n.t("settings.language.ui.ru")).tag(L10n.Language.russian)
                    Text(L10n.t("settings.language.ui.en")).tag(L10n.Language.english)
                    Text(L10n.t("settings.language.ui.system")).tag(L10n.Language.system)
                }
            }
        }
        .formStyle(.grouped)
        .onAppear { devices = AudioDeviceFinder.inputDevices() }
    }
}

/// Captures the next key press (with modifiers) via local event monitors.
/// A lone modifier key (e.g. bare right ⌥) is captured too: press and
/// release it without any other key in between.
struct HotkeyRecorderView: View {
    let current: KeyCombo
    let onCapture: (KeyCombo) -> Void
    @State private var recording = false
    @State private var monitors: [Any] = []
    @State private var pendingModifier: UInt32?

    var body: some View {
        Button(recording ? L10n.t("settings.hotkey.press") : current.displayString) {
            recording ? stopRecording() : startRecording()
        }
        .accessibilityLabel(L10n.t("settings.hotkey"))
        .onDisappear { stopRecording() }
    }

    private func startRecording() {
        recording = true
        pendingModifier = nil
        if let keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown, handler: { event in
            defer { stopRecording() }
            if event.keyCode == 53 { // Esc cancels recording
                return nil
            }
            let combo = KeyCombo.fromNSEvent(keyCode: event.keyCode, flags: event.modifierFlags)
            onCapture(combo)
            return nil
        }) {
            monitors.append(keyMonitor)
        }
        if let flagsMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged, handler: { event in
            let keyCode = UInt32(event.keyCode)
            let combo = KeyCombo(keyCode: keyCode, modifiers: 0)
            guard combo.isModifierOnly else {
                pendingModifier = nil
                return event
            }
            let stillHeld = !event.modifierFlags
                .intersection(HotkeyManager.deviceIndependentMask)
                .isEmpty
            if stillHeld {
                // Modifier went down — candidate until another key arrives.
                pendingModifier = keyCode
                return event
            }
            if pendingModifier == keyCode {
                onCapture(combo)
                stopRecording()
                return nil
            }
            pendingModifier = nil
            return event
        }) {
            monitors.append(flagsMonitor)
        }
    }

    private func stopRecording() {
        recording = false
        pendingModifier = nil
        for monitor in monitors {
            NSEvent.removeMonitor(monitor)
        }
        monitors.removeAll()
    }
}

enum LoginItemService {
    /// Returns a localized error string, or nil on success.
    static func setEnabled(_ enabled: Bool) -> String? {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            return nil
        } catch {
            return L10n.t("settings.launchAtLogin.error", error.localizedDescription)
        }
    }
}

// MARK: - Transcription

struct TranscriptionSettingsTab: View {
    @ObservedObject var settings: SettingsStore
    @ObservedObject var modelManager: ModelManager
    @State private var confirmDownload: WhisperModelInfo?
    @State private var downloadError: String?

    var body: some View {
        Form {
            Section(L10n.t("settings.model.installed")) {
                if modelManager.installedModels.isEmpty {
                    Text(L10n.t("settings.model.none"))
                        .foregroundStyle(.secondary)
                }
                Picker(L10n.t("settings.model"), selection: $settings.whisperModel) {
                    ForEach(modelManager.installedModels) { model in
                        Text("\(model.name) (\(ByteCountFormatter.string(fromByteCount: model.sizeBytes, countStyle: .file)))")
                            .tag(model.name)
                    }
                    if !modelManager.installedModels.contains(where: { $0.name == settings.whisperModel }) {
                        Text(L10n.t("settings.model.notInstalled", settings.whisperModel))
                            .tag(settings.whisperModel)
                    }
                }
            }

            Section(L10n.t("settings.model.download")) {
                ForEach(WhisperModelCatalog.models) { info in
                    HStack {
                        Text(info.name)
                        if !info.multilingual {
                            Text(L10n.t("settings.model.englishOnly"))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text(info.sizeLabel)
                            .foregroundStyle(.secondary)
                        if modelManager.installedModels.contains(where: { $0.name == info.name }) {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundStyle(.green)
                                .accessibilityLabel(L10n.t("settings.model.installedAx"))
                        } else if modelManager.downloadingModel == info.name {
                            ProgressView(value: modelManager.downloadProgress ?? 0)
                                .frame(width: 90)
                            Button(L10n.t("common.cancel")) {
                                modelManager.cancelDownload()
                            }
                        } else {
                            Button(L10n.t("settings.model.get")) {
                                confirmDownload = info
                            }
                            .disabled(modelManager.isDownloading)
                        }
                    }
                }
                if let downloadError {
                    Text(downloadError)
                        .font(.callout)
                        .foregroundStyle(.red)
                }
            }

            Section(L10n.t("settings.recognition.section")) {
                Picker(L10n.t("settings.spoken"), selection: $settings.spokenLanguage) {
                    Text(L10n.t("settings.spoken.auto")).tag(SpokenLanguage.auto)
                    Text(L10n.t("settings.spoken.ru")).tag(SpokenLanguage.russian)
                    Text(L10n.t("settings.spoken.en")).tag(SpokenLanguage.english)
                }
                Stepper(value: $settings.whisperThreads, in: 1...16) {
                    Text(L10n.t("settings.threads", settings.whisperThreads))
                }
                Toggle(L10n.t("settings.artifacts"), isOn: $settings.removeArtifacts)
                Toggle(L10n.t("settings.keepWarm"), isOn: $settings.keepModelWarm)
                Text(L10n.t("settings.keepWarm.hint"))
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onAppear { modelManager.refreshInstalledModels() }
        // Explicit size confirmation before any model download.
        .confirmationDialog(
            L10n.t("settings.model.confirm.title"),
            isPresented: Binding(get: { confirmDownload != nil }, set: { if !$0 { confirmDownload = nil } })
        ) {
            if let info = confirmDownload {
                Button(L10n.t("settings.model.confirm.download", info.sizeLabel)) {
                    start(info)
                }
                Button(L10n.t("common.cancel"), role: .cancel) {}
            }
        } message: {
            if let info = confirmDownload {
                Text(L10n.t("settings.model.confirm.message", info.name, info.sizeLabel))
            }
        }
    }

    private func start(_ info: WhisperModelInfo) {
        confirmDownload = nil
        downloadError = nil
        Task {
            do {
                _ = try await modelManager.download(info)
            } catch is CancellationError {
                // user cancelled — nothing to report
            } catch let error as URLError where error.code == .cancelled {
                // user cancelled — nothing to report
            } catch {
                downloadError = L10n.t("settings.model.download.error", error.localizedDescription)
            }
        }
    }
}

// MARK: - Refinement

struct RefinementSettingsTab: View {
    @ObservedObject var settings: SettingsStore
    @State private var availability: String?
    @State private var ollamaModels: [String] = []

    var body: some View {
        Form {
            Section {
                Toggle(L10n.t("settings.refine.enabled"), isOn: $settings.refinementEnabled)
                Text(L10n.t("settings.refine.hint"))
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            Section(L10n.t("settings.refine.ollama.section")) {
                TextField(L10n.t("settings.refine.endpoint"), text: $settings.ollamaEndpoint)
                    .textFieldStyle(.roundedBorder)
                HStack {
                    TextField(L10n.t("settings.refine.model"), text: $settings.ollamaModel)
                        .textFieldStyle(.roundedBorder)
                    if !ollamaModels.isEmpty {
                        Picker("", selection: $settings.ollamaModel) {
                            ForEach(ollamaModels, id: \.self) { Text($0).tag($0) }
                        }
                        .labelsHidden()
                        .frame(width: 30)
                    }
                }
                HStack {
                    Button(L10n.t("settings.refine.check")) { check() }
                    if let availability {
                        Text(availability)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                }
                HStack {
                    Text(L10n.t("settings.refine.timeout"))
                    Slider(value: $settings.refinementTimeout, in: 5...60, step: 5)
                    Text("\(Int(settings.refinementTimeout)) s")
                        .monospacedDigit()
                }
            }
            .disabled(!settings.refinementEnabled)

            Section(L10n.t("settings.refine.preset.section")) {
                Picker(L10n.t("settings.refine.preset"), selection: $settings.refinementPreset) {
                    ForEach(RefinementPreset.allCases, id: \.self) { preset in
                        Text(L10n.t(preset.titleKey)).tag(preset)
                    }
                }
                if settings.refinementPreset == .custom {
                    TextEditor(text: $settings.customInstruction)
                        .frame(height: 70)
                        .font(.system(size: 12))
                        .accessibilityLabel(L10n.t("settings.refine.custom"))
                }
            }
            .disabled(!settings.refinementEnabled)
        }
        .formStyle(.grouped)
    }

    private func check() {
        availability = L10n.t("settings.refine.status.checking")
        let endpoint = settings.ollamaEndpoint
        let model = settings.ollamaModel
        Task {
            do {
                let provider = try OllamaRefinementProvider(endpoint: endpoint, model: model)
                let names = try await provider.installedModels()
                ollamaModels = names
                if model.isEmpty {
                    availability = L10n.t("settings.refine.status.pickModel", names.joined(separator: ", "))
                } else {
                    switch await provider.checkAvailability() {
                    case .available:
                        availability = L10n.t("settings.refine.status.ok")
                    case .modelMissing(let available):
                        availability = L10n.t("settings.refine.status.nomodel", available.joined(separator: ", "))
                    case .serverUnreachable(let reason):
                        availability = L10n.t("settings.refine.status.unreachable", reason)
                    }
                }
            } catch RefinementError.nonLocalEndpoint {
                availability = L10n.t("settings.refine.nonlocal")
            } catch {
                availability = L10n.t("settings.refine.status.unreachable", error.localizedDescription)
            }
        }
    }
}

// MARK: - Privacy

struct PrivacySettingsTab: View {
    @ObservedObject var settings: SettingsStore

    var body: some View {
        Form {
            Section(L10n.t("privacy.title")) {
                ForEach(1...5, id: \.self) { index in
                    Label(L10n.t("privacy.p\(index)"), systemImage: "checkmark.shield")
                        .font(.callout)
                }
            }
            Section(L10n.t("settings.history.section")) {
                Toggle(L10n.t("settings.history.enabled"), isOn: $settings.historyEnabled)
                Text(L10n.t("settings.history.hint"))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Button(L10n.t("settings.history.open")) {
                    DictationHistory.shared.revealInEditor()
                    NSWorkspace.shared.open(DictationHistory.shared.fileURL)
                }
            }
            Section(L10n.t("settings.diagnostics.section")) {
                Picker(L10n.t("settings.loglevel"), selection: $settings.logLevel) {
                    Text(L10n.t("settings.loglevel.off")).tag(LogLevel.off)
                    Text(L10n.t("settings.loglevel.error")).tag(LogLevel.error)
                    Text(L10n.t("settings.loglevel.info")).tag(LogLevel.info)
                    Text(L10n.t("settings.loglevel.debug")).tag(LogLevel.debug)
                }
                Text(L10n.t("privacy.logs"))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Button(L10n.t("menu.logs")) {
                    NSWorkspace.shared.open(Log.shared.directory)
                }
            }
            Section {
                Button(L10n.t("settings.resetOnboarding")) {
                    settings.resetOnboarding()
                }
            }
        }
        .formStyle(.grouped)
    }
}
