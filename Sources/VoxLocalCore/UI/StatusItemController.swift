import AppKit
import Combine

/// Menu-bar presence: icon reflecting the dictation state plus the command
/// menu required by the product spec.
@MainActor
public final class StatusItemController: NSObject, NSMenuDelegate {
    private let statusItem: NSStatusItem
    private let dictation: DictationController
    private let modelManager: ModelManager
    private let openSettings: () -> Void
    private var cancellables = Set<AnyCancellable>()

    public init(
        dictation: DictationController,
        modelManager: ModelManager,
        openSettings: @escaping () -> Void
    ) {
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        self.dictation = dictation
        self.modelManager = modelManager
        self.openSettings = openSettings
        super.init()

        let menu = NSMenu()
        menu.delegate = self
        // Manual isEnabled control below requires disabling auto-enabling.
        menu.autoenablesItems = false
        statusItem.menu = menu
        updateIcon(for: .idle)

        dictation.$state
            .receive(on: DispatchQueue.main)
            .sink { [weak self] state in
                self?.updateIcon(for: state)
            }
            .store(in: &cancellables)
    }

    private func updateIcon(for state: DictationState) {
        guard let button = statusItem.button else { return }
        let symbol: String
        switch state {
        case .recording: symbol = "mic.fill"
        case .transcribing, .stopping, .refining, .inserting: symbol = "waveform"
        case .error: symbol = "mic.slash"
        default: symbol = "mic"
        }
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: L10n.t("app.name"))
        image?.isTemplate = true
        button.image = image
        button.toolTip = "\(L10n.t("app.name")) — \(L10n.t("state.\(state.rawValue)"))"
    }

    // Rebuild on every open so labels follow state and language changes.
    public func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let state = dictation.state

        let status = NSMenuItem(
            title: L10n.t("menu.status", L10n.t("state.\(state.rawValue)")),
            action: nil, keyEquivalent: "")
        status.isEnabled = false
        menu.addItem(status)
        if !dictation.statusMessage.isEmpty {
            let detail = NSMenuItem(title: dictation.statusMessage, action: nil, keyEquivalent: "")
            detail.isEnabled = false
            menu.addItem(detail)
        }
        menu.addItem(.separator())

        let start = NSMenuItem(title: L10n.t("menu.start"), action: #selector(startDictation), keyEquivalent: "")
        start.target = self
        start.isEnabled = state == .idle
        menu.addItem(start)

        let stop = NSMenuItem(title: L10n.t("menu.stop"), action: #selector(stopDictation), keyEquivalent: "")
        stop.target = self
        stop.isEnabled = state == .recording
        menu.addItem(stop)

        let cancel = NSMenuItem(title: L10n.t("menu.cancel"), action: #selector(cancelDictation), keyEquivalent: "")
        cancel.target = self
        cancel.isEnabled = [.preparing, .recording, .stopping, .transcribing, .refining, .inserting].contains(state)
        menu.addItem(cancel)

        menu.addItem(.separator())

        let settings = NSMenuItem(title: L10n.t("menu.settings"), action: #selector(openSettingsWindow), keyEquivalent: ",")
        settings.target = self
        menu.addItem(settings)

        let models = NSMenuItem(title: L10n.t("menu.models"), action: #selector(openModelsFolder), keyEquivalent: "")
        models.target = self
        menu.addItem(models)

        let logs = NSMenuItem(title: L10n.t("menu.logs"), action: #selector(openLogs), keyEquivalent: "")
        logs.target = self
        menu.addItem(logs)

        menu.addItem(.separator())

        let quit = NSMenuItem(title: L10n.t("menu.quit"), action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
    }

    @objc private func startDictation() { dictation.startDictation() }
    @objc private func stopDictation() { dictation.stopAndProcess() }
    @objc private func cancelDictation() { dictation.cancelDictation() }
    @objc private func openSettingsWindow() { openSettings() }

    @objc private func openModelsFolder() {
        NSWorkspace.shared.open(modelManager.modelsDirectory)
    }

    @objc private func openLogs() {
        NSWorkspace.shared.open(Log.shared.directory)
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}
