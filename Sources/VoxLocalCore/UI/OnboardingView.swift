import AppKit
import SwiftUI

/// First-run wizard: explains the privacy model, walks through microphone
/// and Accessibility permissions, engine/model installation, the optional
/// Ollama setup, the shortcut, and ends with a test dictation.
public struct OnboardingView: View {
    enum Step: Int, CaseIterable {
        case welcome, microphone, accessibility, engine, model, ollama, hotkey, test, done
    }

    let deps: SettingsDependencies
    let onFinish: () -> Void

    @State private var step: Step = .welcome
    @State private var micStatus: PermissionStatus = .notDetermined
    @State private var axTrusted = false
    @State private var engineFound: String?
    @State private var ollamaStatus: String?
    @State private var confirmDownload: WhisperModelInfo?
    @State private var downloadError: String?
    @State private var testResult: String = ""
    @ObservedObject private var modelManager: ModelManager
    @ObservedObject private var dictation: DictationController

    public init(deps: SettingsDependencies, onFinish: @escaping () -> Void) {
        self.deps = deps
        self.onFinish = onFinish
        self.modelManager = deps.modelManager
        self.dictation = deps.dictation
    }

    public var body: some View {
        VStack(spacing: 0) {
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .padding(24)
            Divider()
            footer
                .padding(16)
        }
        .frame(width: 560, height: 460)
        .onAppear(perform: refreshStatuses)
    }

    private func refreshStatuses() {
        micStatus = deps.permissions.microphoneStatus
        axTrusted = deps.permissions.accessibilityTrusted
        let transcriber = WhisperTranscriber()
        engineFound = (try? transcriber.locateBinary())?.path
        modelManager.refreshInstalledModels()
    }

    // MARK: - Steps

    @ViewBuilder
    private var content: some View {
        switch step {
        case .welcome:
            stepLayout("hand.wave", "onboarding.welcome.title") {
                Text(L10n.t("onboarding.welcome.text"))
                ForEach(1...4, id: \.self) { index in
                    Label(L10n.t("onboarding.welcome.point\(index)"), systemImage: "checkmark.circle")
                        .font(.callout)
                }
            }
        case .microphone:
            stepLayout("mic", "onboarding.mic.title") {
                Text(L10n.t("onboarding.mic.text"))
                statusRow(for: micStatus)
                HStack {
                    if micStatus == .notDetermined {
                        Button(L10n.t("onboarding.mic.grant")) {
                            Task {
                                _ = await deps.permissions.requestMicrophoneAccess()
                                refreshStatuses()
                            }
                        }
                        .buttonStyle(.borderedProminent)
                    }
                    if micStatus == .denied {
                        Button(L10n.t("onboarding.openSettings")) {
                            deps.permissions.openMicrophoneSettings()
                        }
                    }
                    Button(L10n.t("onboarding.recheck")) { refreshStatuses() }
                }
            }
        case .accessibility:
            stepLayout("accessibility", "onboarding.ax.title") {
                Text(L10n.t("onboarding.ax.text"))
                statusRow(granted: axTrusted)
                HStack {
                    Button(L10n.t("onboarding.openSettings")) {
                        deps.permissions.promptForAccessibility()
                        deps.permissions.openAccessibilitySettings()
                    }
                    Button(L10n.t("onboarding.recheck")) { refreshStatuses() }
                }
                Text(L10n.t("onboarding.ax.optional"))
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        case .engine:
            stepLayout("cpu", "onboarding.engine.title") {
                if let engineFound {
                    statusRow(granted: true)
                    Text(L10n.t("onboarding.engine.ok", PathRedactor.redact(engineFound)))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                } else {
                    statusRow(granted: false)
                    Text(L10n.t("onboarding.engine.missing"))
                        .font(.callout)
                }
                Button(L10n.t("onboarding.recheck")) { refreshStatuses() }
            }
        case .model:
            stepLayout("square.and.arrow.down", "onboarding.model.title") {
                Text(L10n.t("onboarding.model.text"))
                modelPickerSection
            }
        case .ollama:
            stepLayout("wand.and.stars", "onboarding.ollama.title") {
                Text(L10n.t("onboarding.ollama.text"))
                HStack {
                    Button(L10n.t("settings.refine.check")) { checkOllama() }
                    if let ollamaStatus {
                        Text(ollamaStatus)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                }
                Text(L10n.t("onboarding.ollama.optional"))
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        case .hotkey:
            stepLayout("keyboard", "onboarding.hotkey.title") {
                Text(L10n.t("onboarding.hotkey.text",
                            KeyCombo(keyCode: deps.settings.hotkeyKeyCode,
                                     modifiers: deps.settings.hotkeyModifiers).displayString))
                Text(L10n.t("onboarding.hotkey.modes"))
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        case .test:
            stepLayout("waveform.circle", "onboarding.test.title") {
                Text(L10n.t("onboarding.test.text"))
                HStack {
                    Button(dictation.state == .recording ? L10n.t("onboarding.test.stop") : L10n.t("onboarding.test.start")) {
                        toggleTestDictation()
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(![.idle, .recording].contains(dictation.state))
                    Text(L10n.t("state.\(dictation.state.rawValue)"))
                        .foregroundStyle(.secondary)
                }
                if !testResult.isEmpty {
                    GroupBox(L10n.t("onboarding.test.result")) {
                        Text(testResult)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .textSelection(.enabled)
                    }
                }
            }
        case .done:
            stepLayout("checkmark.seal", "onboarding.done.title") {
                Text(L10n.t("onboarding.done.text"))
            }
        }
    }

    @ViewBuilder
    private var modelPickerSection: some View {
        let installed = modelManager.installedModels
        if !installed.isEmpty {
            Label(L10n.t("onboarding.model.installed", installed.map(\.name).joined(separator: ", ")),
                  systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
        }
        // Compact catalog: recommended default plus alternates.
        ForEach(WhisperModelCatalog.models.filter { ["tiny", "base", "small"].contains($0.name) }) { info in
            HStack {
                Text(info.name == WhisperModelCatalog.defaultModelName
                     ? L10n.t("onboarding.model.recommended", info.name)
                     : info.name)
                Spacer()
                Text(info.sizeLabel).foregroundStyle(.secondary)
                if installed.contains(where: { $0.name == info.name }) {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                } else if modelManager.downloadingModel == info.name {
                    ProgressView(value: modelManager.downloadProgress ?? 0)
                        .frame(width: 90)
                    Button(L10n.t("common.cancel")) { modelManager.cancelDownload() }
                } else {
                    Button(L10n.t("settings.model.get")) { confirmDownload = info }
                        .disabled(modelManager.isDownloading)
                }
            }
        }
        if let downloadError {
            Text(downloadError).font(.callout).foregroundStyle(.red)
        }
        Text(L10n.t("onboarding.model.more"))
            .font(.callout)
            .foregroundStyle(.secondary)
        // Same confirmation contract as Settings: size shown, explicit consent.
        if let info = confirmDownload {
            GroupBox {
                VStack(alignment: .leading, spacing: 8) {
                    Text(L10n.t("settings.model.confirm.message", info.name, info.sizeLabel))
                    HStack {
                        Button(L10n.t("settings.model.confirm.download", info.sizeLabel)) {
                            confirmDownload = nil
                            downloadError = nil
                            let selected = info
                            Task {
                                do {
                                    _ = try await modelManager.download(selected)
                                    deps.settings.whisperModel = selected.name
                                } catch is CancellationError {
                                } catch let error as URLError where error.code == .cancelled {
                                } catch {
                                    downloadError = L10n.t("settings.model.download.error", error.localizedDescription)
                                }
                            }
                        }
                        .buttonStyle(.borderedProminent)
                        Button(L10n.t("common.cancel")) { confirmDownload = nil }
                    }
                }
            }
        }
    }

    private func checkOllama() {
        ollamaStatus = L10n.t("settings.refine.status.checking")
        Task {
            do {
                let provider = try OllamaRefinementProvider(
                    endpoint: deps.settings.ollamaEndpoint,
                    model: deps.settings.ollamaModel)
                let models = try await provider.installedModels()
                ollamaStatus = models.isEmpty
                    ? L10n.t("onboarding.ollama.noModels")
                    : L10n.t("onboarding.ollama.found", models.joined(separator: ", "))
            } catch {
                ollamaStatus = L10n.t("onboarding.ollama.unavailable")
            }
        }
    }

    private func toggleTestDictation() {
        if dictation.state == .recording {
            dictation.stopAndProcess()
        } else if dictation.state == .idle {
            testResult = ""
            dictation.testModeSink = { text in
                testResult = text
                dictation.testModeSink = nil
            }
            dictation.startDictation()
        }
    }

    // MARK: - Chrome

    private func stepLayout(_ symbol: String, _ titleKey: String, @ViewBuilder body: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Image(systemName: symbol)
                    .font(.system(size: 26))
                    .foregroundStyle(.tint)
                Text(L10n.t(titleKey))
                    .font(.title2.weight(.semibold))
            }
            body()
            Spacer(minLength: 0)
        }
    }

    private func statusRow(for status: PermissionStatus) -> some View {
        statusRow(granted: status == .granted,
                  label: status == .notDetermined ? L10n.t("onboarding.status.notdetermined") : nil)
    }

    private func statusRow(granted: Bool, label: String? = nil) -> some View {
        Label(
            label ?? (granted ? L10n.t("onboarding.status.granted") : L10n.t("onboarding.status.denied")),
            systemImage: granted ? "checkmark.circle.fill" : "xmark.circle")
        .foregroundStyle(granted ? .green : .orange)
    }

    private var footer: some View {
        HStack {
            ProgressView(value: Double(step.rawValue), total: Double(Step.done.rawValue))
                .frame(width: 140)
                .accessibilityLabel(L10n.t("onboarding.progress.ax"))
            Spacer()
            if step != .welcome {
                Button(L10n.t("onboarding.back")) {
                    if dictation.state != .idle { dictation.cancelDictation() }
                    step = Step(rawValue: step.rawValue - 1) ?? .welcome
                    refreshStatuses()
                }
            }
            if step != .done {
                Button(L10n.t("onboarding.next")) {
                    if dictation.state != .idle { dictation.cancelDictation() }
                    step = Step(rawValue: step.rawValue + 1) ?? .done
                    refreshStatuses()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
            } else {
                Button(L10n.t("onboarding.finish")) {
                    deps.settings.onboardingCompleted = true
                    onFinish()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
            }
        }
    }
}
