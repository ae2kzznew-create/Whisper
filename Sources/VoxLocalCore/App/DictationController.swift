import AppKit
import Combine
import Foundation

/// Orchestrates one dictation session end-to-end:
/// idle → preparing → recording → stopping → transcribing → (refining) →
/// inserting → completed → idle, with cancelled/error side exits.
/// A single instance serializes sessions — overlap is impossible because
/// every entry point checks the state machine first.
@MainActor
public final class DictationController: ObservableObject {
    @Published public private(set) var state: DictationState = .idle
    /// Localized secondary message for the overlay/menu (error details,
    /// clipboard fallback explanations).
    @Published public private(set) var statusMessage: String = ""
    @Published public private(set) var micLevel: Float = 0

    /// When set, the pipeline delivers the final text here instead of
    /// inserting into another app (used by the onboarding test dictation).
    public var testModeSink: ((String) -> Void)?

    /// Notifies UI layers (overlay window, status item) about state changes.
    public var onStateChange: ((DictationState) -> Void)?

    private var machine = DictationStateMachine()
    private let settings: SettingsStore
    private let permissions: PermissionsChecking
    private let recorder: AudioRecorder
    private let transcriber: WhisperTranscriber
    private let modelManager: ModelManager
    private let inserter: TextInserter
    private let hotkeys: HotkeyManager

    private var targetApp: NSRunningApplication?
    private var pipelineTask: Task<Void, Never>?
    private var idleResetTask: Task<Void, Never>?
    private var stopRequestedWhilePreparing = false

    public init(
        settings: SettingsStore,
        permissions: PermissionsChecking,
        recorder: AudioRecorder,
        transcriber: WhisperTranscriber,
        modelManager: ModelManager,
        inserter: TextInserter,
        hotkeys: HotkeyManager
    ) {
        self.settings = settings
        self.permissions = permissions
        self.recorder = recorder
        self.transcriber = transcriber
        self.modelManager = modelManager
        self.inserter = inserter
        self.hotkeys = hotkeys

        recorder.levelHandler = { [weak self] level in
            self?.micLevel = level
        }
        recorder.deviceInterruptionHandler = { [weak self] in
            guard let self, self.state == .recording else { return }
            self.recorder.cancel()
            self.fail(.microphoneUnavailable)
        }
    }

    // MARK: - Hotkey entry points

    private var lastToggleDown = Date.distantPast

    public func handleHotkeyDown() {
        switch settings.hotkeyMode {
        case .pressAndHold:
            startDictation()
        case .toggle:
            // Key auto-repeat delivers extra pressed events; debounce them so
            // holding the combo doesn't instantly stop a just-started session.
            let now = Date()
            guard now.timeIntervalSince(lastToggleDown) > 0.35 else { return }
            lastToggleDown = now
            if machine.state == .idle {
                startDictation()
            } else if machine.state == .recording {
                stopAndProcess()
            }
        }
    }

    public func handleHotkeyUp() {
        guard settings.hotkeyMode == .pressAndHold else { return }
        switch machine.state {
        case .recording:
            stopAndProcess()
        case .preparing:
            // Key released before the engine started: stop as soon as it does.
            stopRequestedWhilePreparing = true
        default:
            break
        }
    }

    // MARK: - Session control

    public func startDictation() {
        guard machine.state == .idle else { return }
        idleResetTask?.cancel()
        stopRequestedWhilePreparing = false
        statusMessage = ""
        targetApp = NSWorkspace.shared.frontmostApplication
        advance(to: .preparing)

        Task { [weak self] in
            await self?.prepareAndRecord()
        }
    }

    private func prepareAndRecord() async {
        let modelName = settings.whisperModel
        let modelInstalled = (try? modelManager.resolveModel(named: modelName)) != nil
        var preflight = DictationPreflight.evaluate(
            microphone: permissions.microphoneStatus,
            accessibilityTrusted: permissions.accessibilityTrusted,
            modelInstalled: modelInstalled,
            modelName: modelName)

        if case .needsMicrophoneRequest = preflight {
            let granted = await permissions.requestMicrophoneAccess()
            guard machine.state == .preparing else { return } // cancelled meanwhile
            preflight = granted
                ? DictationPreflight.evaluate(
                    microphone: .granted,
                    accessibilityTrusted: permissions.accessibilityTrusted,
                    modelInstalled: modelInstalled,
                    modelName: modelName)
                : .blockedMicrophoneDenied
        }

        guard machine.state == .preparing else { return }

        switch preflight {
        case .blockedMicrophoneDenied:
            permissions.openMicrophoneSettings()
            fail(.microphonePermissionDenied)
            return
        case .blockedModelMissing(let name):
            fail(.modelMissing(name))
            return
        case .needsMicrophoneRequest:
            fail(.microphonePermissionDenied)
            return
        case .ready(let warnAccessibilityMissing):
            if warnAccessibilityMissing {
                statusMessage = L10n.t("insert.reason.noAccessibility")
            }
        }

        do {
            try recorder.start(deviceUID: settings.inputDeviceUID)
        } catch let error as VoxLocalError {
            fail(error)
            return
        } catch {
            fail(.recordingFailed(error.localizedDescription))
            return
        }

        advance(to: .recording)
        hotkeys.registerEscape()

        if stopRequestedWhilePreparing {
            stopRequestedWhilePreparing = false
            stopAndProcess()
        }
    }

    public func stopAndProcess() {
        guard machine.state == .recording else { return }
        advance(to: .stopping)

        let recording: RecordingResult
        do {
            recording = try recorder.stop()
        } catch let error as VoxLocalError {
            fail(error)
            return
        } catch {
            fail(.recordingFailed(error.localizedDescription))
            return
        }

        advance(to: .transcribing)
        micLevel = 0

        let language = settings.spokenLanguage.whisperCode
        let threads = settings.whisperThreads
        let removeArtifacts = settings.removeArtifacts
        let modelName = settings.whisperModel

        pipelineTask = Task { [weak self] in
            guard let self else { return }
            defer { try? FileManager.default.removeItem(at: recording.audioURL) }
            do {
                let modelURL = try self.modelManager.resolveModel(named: modelName)
                let transcript = try await self.transcriber.transcribe(
                    audioURL: recording.audioURL,
                    modelURL: modelURL,
                    language: language,
                    threads: threads,
                    removeArtifacts: removeArtifacts)
                try Task.checkCancellation()

                guard !transcript.text.isEmpty else {
                    self.fail(.emptyRecording)
                    return
                }

                var finalText = transcript.text
                if self.settings.refinementEnabled, self.settings.refinementPreset != .rawTranscript {
                    self.advance(to: .refining)
                    let context = RefinementContext(
                        language: transcript.detectedLanguage,
                        preset: self.settings.refinementPreset,
                        customInstruction: self.settings.customInstruction,
                        timeout: self.settings.refinementTimeout)
                    let pipeline = RefinementPipeline(provider: self.makeRefinementProvider())
                    let outcome = await pipeline.refine(transcript.text, context: context)
                    try Task.checkCancellation()
                    finalText = outcome.text
                    if outcome.usedFallback {
                        self.statusMessage = L10n.t("refine.fallback.notice")
                    }
                }

                guard self.machine.state == .transcribing || self.machine.state == .refining else { return }
                self.advance(to: .inserting)

                if let sink = self.testModeSink {
                    sink(finalText)
                    self.finishCompleted(message: "")
                    return
                }

                let outcome = await self.inserter.insert(
                    finalText,
                    into: self.targetApp,
                    mode: self.settings.insertionMode,
                    accessibilityTrusted: self.permissions.accessibilityTrusted)
                try Task.checkCancellation()

                switch outcome {
                case .insertedViaAccessibility, .pastedViaClipboard:
                    self.finishCompleted(message: "")
                case .clipboardOnly(let reasonKey):
                    self.finishCompleted(message: L10n.t(reasonKey))
                }
            } catch is CancellationError {
                // cancelDictation() already moved the machine to .cancelled.
            } catch let error as VoxLocalError {
                self.fail(error)
            } catch {
                self.fail(.transcriptionFailed(exitCode: -1, detail: error.localizedDescription))
            }
        }
    }

    /// Builds a fresh provider from current settings for each session, so
    /// endpoint/model changes apply immediately.
    private func makeRefinementProvider() -> TextRefinementProvider {
        guard settings.refinementEnabled else { return NoRefinementProvider() }
        do {
            return try OllamaRefinementProvider(
                endpoint: settings.ollamaEndpoint,
                model: settings.ollamaModel)
        } catch {
            Log.shared.info("refinement provider unavailable (\(error)); using raw transcript")
            return NoRefinementProvider()
        }
    }

    public func cancelDictation() {
        guard machine.isCancellable else { return }
        pipelineTask?.cancel()
        pipelineTask = nil
        if recorder.isRecording {
            recorder.cancel()
        }
        micLevel = 0
        advance(to: .cancelled)
        statusMessage = ""
        testModeSink = nil
        hotkeys.unregisterEscape()
        scheduleIdleReset(after: 1.0)
        Log.shared.info("dictation cancelled by user")
    }

    // MARK: - Completion / failure

    private func finishCompleted(message: String) {
        statusMessage = message
        advance(to: .completed)
        testModeSink = nil
        hotkeys.unregisterEscape()
        scheduleIdleReset(after: message.isEmpty ? 1.4 : 3.5)
    }

    private func fail(_ error: VoxLocalError) {
        guard machine.state != .cancelled, machine.state != .idle else { return }
        Log.shared.error(error.logDetail)
        statusMessage = L10n.t(error.messageKey)
        micLevel = 0
        advance(to: .error)
        testModeSink = nil
        hotkeys.unregisterEscape()
        scheduleIdleReset(after: 4.0)
    }

    private func scheduleIdleReset(after seconds: Double) {
        idleResetTask?.cancel()
        idleResetTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self?.resetToIdle()
        }
    }

    private func resetToIdle() {
        guard machine.state == .completed || machine.state == .cancelled || machine.state == .error else { return }
        statusMessage = ""
        advance(to: .idle)
    }

    private func advance(to next: DictationState) {
        do {
            try machine.transition(to: next)
            state = machine.state
            onStateChange?(machine.state)
        } catch {
            Log.shared.error("state machine: \(error)")
        }
    }
}
