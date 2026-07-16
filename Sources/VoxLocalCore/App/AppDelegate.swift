import AppKit
import Combine
import SwiftUI

/// Application entry object: builds the dependency graph, registers the
/// global hotkey, owns the status item and windows.
@MainActor
public final class AppDelegate: NSObject, NSApplicationDelegate {
    private var settings: SettingsStore!
    private var permissions: PermissionsService!
    private var modelManager: ModelManager!
    private var hotkeys: HotkeyManager!
    private var dictation: DictationController!
    private var overlay: OverlayWindowController!
    private var statusItem: StatusItemController!
    private var deps: SettingsDependencies!

    private var warmTranscriber: WhisperServerTranscriber!
    private var gigaTranscriber: GigaAMTranscriber!
    private var cancellables = Set<AnyCancellable>()

    private var settingsWindow: NSWindow?
    private var onboardingWindow: NSWindow?

    public override init() {
        super.init()
    }

    public func applicationDidFinishLaunching(_ notification: Notification) {
        settings = SettingsStore()
        L10n.setLanguage(settings.interfaceLanguage)
        Log.shared.level = settings.logLevel
        Log.shared.info("VoxLocal starting (v\(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev"))")

        permissions = PermissionsService()
        modelManager = ModelManager()
        hotkeys = HotkeyManager()

        dictation = DictationController(
            settings: settings,
            permissions: permissions,
            recorder: AudioRecorder(),
            transcriber: WhisperTranscriber(),
            modelManager: modelManager,
            inserter: TextInserter(),
            hotkeys: hotkeys)

        warmTranscriber = WhisperServerTranscriber()
        dictation.warmTranscriber = warmTranscriber
        // Free the memory as soon as the warm-model setting is switched off.
        settings.$keepModelWarm
            .removeDuplicates()
            .sink { [weak self] enabled in
                if !enabled {
                    self?.warmTranscriber?.stop()
                }
            }
            .store(in: &cancellables)

        gigaTranscriber = GigaAMTranscriber()
        dictation.gigaTranscriber = gigaTranscriber
        settings.$engine
            .removeDuplicates()
            .sink { [weak self] engine in
                if engine != .gigaam {
                    self?.gigaTranscriber?.stop()
                }
            }
            .store(in: &cancellables)

        overlay = OverlayWindowController(dictation: dictation)

        deps = SettingsDependencies(
            settings: settings,
            modelManager: modelManager,
            permissions: permissions,
            dictation: dictation,
            applyHotkey: { [weak self] combo in
                self?.registerHotkey(combo)
            })

        statusItem = StatusItemController(
            dictation: dictation,
            modelManager: modelManager,
            openSettings: { [weak self] in self?.showSettings() })

        hotkeys.onMainKeyDown = { [weak self] in self?.dictation.handleHotkeyDown() }
        hotkeys.onMainKeyUp = { [weak self] in self?.dictation.handleHotkeyUp() }
        hotkeys.onEscape = { [weak self] in self?.dictation.cancelDictation() }

        let combo = KeyCombo(keyCode: settings.hotkeyKeyCode, modifiers: settings.hotkeyModifiers)
        if let error = registerHotkey(combo) {
            showHotkeyConflictAlert(message: error)
        }

        if !settings.onboardingCompleted {
            showOnboarding()
        }
    }

    public func applicationWillTerminate(_ notification: Notification) {
        dictation?.cancelDictation()
        warmTranscriber?.stop()
        gigaTranscriber?.stop()
        hotkeys?.unregisterMainHotkey()
        hotkeys?.unregisterEscape()
        Log.shared.info("VoxLocal terminating")
        Log.shared.sync()
    }

    /// Registers the shortcut; returns a localized error message on failure.
    @discardableResult
    private func registerHotkey(_ combo: KeyCombo) -> String? {
        do {
            try hotkeys.registerMainHotkey(combo)
            return nil
        } catch HotkeyError.conflict {
            return L10n.t("error.hotkey.conflict", combo.displayString)
        } catch {
            return L10n.t("error.hotkey.failed", combo.displayString)
        }
    }

    private func showHotkeyConflictAlert(message: String) {
        let alert = NSAlert()
        alert.messageText = L10n.t("alert.hotkeyConflict.title")
        alert.informativeText = message + "\n" + L10n.t("alert.hotkeyConflict.hint")
        alert.alertStyle = .warning
        alert.addButton(withTitle: L10n.t("common.ok"))
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }

    // MARK: - Windows

    public func showSettings() {
        if settingsWindow == nil {
            let window = NSWindow(contentViewController: NSHostingController(rootView: SettingsView(deps: deps)))
            window.title = L10n.t("settings.title")
            window.styleMask = [.titled, .closable, .miniaturizable]
            window.isReleasedWhenClosed = false
            window.center()
            settingsWindow = window
        }
        settingsWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    public func showOnboarding() {
        if onboardingWindow == nil {
            let view = OnboardingView(deps: deps) { [weak self] in
                self?.onboardingWindow?.close()
            }
            let window = NSWindow(contentViewController: NSHostingController(rootView: view))
            window.title = L10n.t("onboarding.title")
            window.styleMask = [.titled, .closable]
            window.isReleasedWhenClosed = false
            window.center()
            onboardingWindow = window
        }
        onboardingWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}
