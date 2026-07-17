using System.ComponentModel;
using System.Runtime.InteropServices;
using VoxLocal.Core.Audio;
using VoxLocal.Core.History;
using VoxLocal.Core.Hotkeys;
using VoxLocal.Core.Insertion;
using VoxLocal.Core.Models;
using VoxLocal.Core.Permissions;
using VoxLocal.Core.Refinement;
using VoxLocal.Core.Settings;
using VoxLocal.Core.Transcription;
using VoxLocal.Core.Utilities;

namespace VoxLocal.App;

/// <summary>
/// Orchestrates one dictation session end-to-end:
/// idle → preparing → recording → stopping → transcribing → (refining) →
/// inserting → completed → idle, with cancelled/error side exits.
/// A single instance serializes sessions — overlap is impossible because
/// every entry point checks the state machine first.
/// Must be created and used on the WPF UI (Dispatcher) thread — the
/// analogue of @MainActor.
/// </summary>
public sealed class DictationController : INotifyPropertyChanged
{
    private static class NativeMethods
    {
        [DllImport("user32.dll")]
        public static extern IntPtr GetForegroundWindow();
    }

    private DictationState _state = DictationState.Idle;
    private string _statusMessage = "";
    private float _micLevel;

    public DictationState State
    {
        get => _state;
        private set { _state = value; Notify(nameof(State)); }
    }

    /// <summary>Localized secondary message for the overlay/menu (error
    /// details, clipboard fallback explanations).</summary>
    public string StatusMessage
    {
        get => _statusMessage;
        private set { _statusMessage = value; Notify(nameof(StatusMessage)); }
    }

    public float MicLevel
    {
        get => _micLevel;
        private set { _micLevel = value; Notify(nameof(MicLevel)); }
    }

    /// <summary>When set, the pipeline delivers the final text here instead
    /// of inserting into another app (used by the onboarding test dictation).</summary>
    public Action<string>? TestModeSink { get; set; }

    /// <summary>Notifies UI layers (overlay window, tray icon) about state changes.</summary>
    public event Action<DictationState>? StateChanged;

    public event PropertyChangedEventHandler? PropertyChanged;

    private readonly DictationStateMachine _machine = new();
    private readonly SettingsStore _settings;
    private readonly IPermissionsChecking _permissions;
    private readonly AudioRecorder _recorder;
    private readonly WhisperTranscriber _transcriber;
    private readonly ModelManager _modelManager;
    private readonly TextInserter _inserter;
    private readonly HotkeyManager _hotkeys;
    private readonly HistoryStore? _history;
    private readonly SynchronizationContext _ui;

    private IntPtr _targetWindow;
    private CancellationTokenSource? _pipelineCts;
    private CancellationTokenSource? _idleResetCts;
    private bool _stopRequestedWhilePreparing;
    private DateTime _lastToggleDown = DateTime.MinValue;

    public DictationController(
        SettingsStore settings,
        IPermissionsChecking permissions,
        AudioRecorder recorder,
        WhisperTranscriber transcriber,
        ModelManager modelManager,
        TextInserter inserter,
        HotkeyManager hotkeys,
        HistoryStore? history = null)
    {
        _settings = settings;
        _permissions = permissions;
        _recorder = recorder;
        _transcriber = transcriber;
        _modelManager = modelManager;
        _inserter = inserter;
        _hotkeys = hotkeys;
        _history = history;
        _ui = SynchronizationContext.Current ?? new SynchronizationContext();

        // Recorder callbacks arrive on the capture thread — marshal to UI.
        _recorder.LevelHandler = level => _ui.Post(_ => MicLevel = level, null);
        _recorder.DeviceInterruptionHandler = () => _ui.Post(_ =>
        {
            if (State != DictationState.Recording)
            {
                return;
            }
            _recorder.Cancel();
            Fail(new VoxLocalError.MicrophoneUnavailable());
        }, null);
    }

    // ---- Hotkey entry points ----

    public void HandleHotkeyDown()
    {
        switch (_settings.HotkeyMode)
        {
            case HotkeyMode.PressAndHold:
                StartDictation();
                break;
            case HotkeyMode.Toggle:
                // Key auto-repeat delivers extra pressed events; debounce them
                // so holding the combo doesn't instantly stop a just-started
                // session.
                var now = DateTime.UtcNow;
                if ((now - _lastToggleDown).TotalSeconds <= 0.35)
                {
                    return;
                }
                _lastToggleDown = now;
                if (_machine.State == DictationState.Idle)
                {
                    StartDictation();
                }
                else if (_machine.State == DictationState.Recording)
                {
                    StopAndProcess();
                }
                break;
        }
    }

    public void HandleHotkeyUp()
    {
        if (_settings.HotkeyMode != HotkeyMode.PressAndHold)
        {
            return;
        }
        switch (_machine.State)
        {
            case DictationState.Recording:
                StopAndProcess();
                break;
            case DictationState.Preparing:
                // Key released before the engine started: stop as soon as it does.
                _stopRequestedWhilePreparing = true;
                break;
        }
    }

    // ---- Session control ----

    public void StartDictation()
    {
        if (_machine.State != DictationState.Idle)
        {
            return;
        }
        _idleResetCts?.Cancel();
        _stopRequestedWhilePreparing = false;
        StatusMessage = "";
        // NSWorkspace.frontmostApplication → the HWND owning the caret now.
        _targetWindow = NativeMethods.GetForegroundWindow();
        Advance(DictationState.Preparing);
        _ = PrepareAndRecordAsync();
    }

    private async Task PrepareAndRecordAsync()
    {
        var modelName = _settings.WhisperModel;
        bool modelInstalled;
        try
        {
            _modelManager.ResolveModel(modelName);
            modelInstalled = true;
        }
        catch (VoxLocalException)
        {
            modelInstalled = false;
        }

        var preflight = DictationPreflight.Evaluate(
            _permissions.MicrophoneStatus, modelInstalled, modelName);

        if (preflight is DictationPreflight.NeedsMicrophoneRequest)
        {
            var granted = await _permissions.RequestMicrophoneAccessAsync();
            if (_machine.State != DictationState.Preparing)
            {
                return; // cancelled meanwhile
            }
            preflight = granted
                ? DictationPreflight.Evaluate(PermissionStatus.Granted, modelInstalled, modelName)
                : new DictationPreflight.BlockedMicrophoneDenied();
        }

        if (_machine.State != DictationState.Preparing)
        {
            return;
        }

        switch (preflight)
        {
            case DictationPreflight.BlockedMicrophoneDenied:
                _permissions.OpenMicrophoneSettings();
                Fail(new VoxLocalError.MicrophonePermissionDenied());
                return;
            case DictationPreflight.BlockedModelMissing missing:
                Fail(new VoxLocalError.ModelMissing(missing.ModelName));
                return;
            case DictationPreflight.NeedsMicrophoneRequest:
                Fail(new VoxLocalError.MicrophonePermissionDenied());
                return;
            case DictationPreflight.Ready:
                break; // no accessibility warning on Windows
        }

        try
        {
            _recorder.Start(_settings.InputDeviceId);
        }
        catch (VoxLocalException e)
        {
            Fail(e.Error);
            return;
        }
        catch (Exception e)
        {
            Fail(new VoxLocalError.RecordingFailed(e.Message));
            return;
        }

        Advance(DictationState.Recording);
        _hotkeys.RegisterEscape();

        if (_stopRequestedWhilePreparing)
        {
            _stopRequestedWhilePreparing = false;
            StopAndProcess();
        }
    }

    public void StopAndProcess()
    {
        if (_machine.State != DictationState.Recording)
        {
            return;
        }
        Advance(DictationState.Stopping);

        RecordingResult recording;
        try
        {
            recording = _recorder.Stop();
        }
        catch (VoxLocalException e)
        {
            Fail(e.Error);
            return;
        }
        catch (Exception e)
        {
            Fail(new VoxLocalError.RecordingFailed(e.Message));
            return;
        }

        Advance(DictationState.Transcribing);
        MicLevel = 0;

        var language = _settings.SpokenLanguage.WhisperCode();
        var threads = _settings.WhisperThreads;
        var removeArtifacts = _settings.RemoveArtifacts;
        var modelName = _settings.WhisperModel;

        _pipelineCts = new CancellationTokenSource();
        _ = RunPipelineAsync(recording, modelName, language, threads, removeArtifacts, _pipelineCts.Token);
    }

    private async Task RunPipelineAsync(
        RecordingResult recording,
        string modelName,
        string language,
        int threads,
        bool removeArtifacts,
        CancellationToken ct)
    {
        try
        {
            try
            {
                var modelPath = _modelManager.ResolveModel(modelName);
                var transcript = await _transcriber.TranscribeAsync(
                    recording.AudioPath, modelPath, language, threads, removeArtifacts, cancellationToken: ct);
                ct.ThrowIfCancellationRequested();

                if (string.IsNullOrEmpty(transcript.Text))
                {
                    Fail(new VoxLocalError.EmptyRecording());
                    return;
                }

                var finalText = transcript.Text;
                if (_settings.RefinementEnabled && _settings.RefinementPreset != RefinementPreset.RawTranscript)
                {
                    Advance(DictationState.Refining);
                    var context = new RefinementContext(
                        Language: transcript.DetectedLanguage,
                        Preset: _settings.RefinementPreset,
                        CustomInstruction: _settings.CustomInstruction,
                        TimeoutSeconds: _settings.RefinementTimeout);
                    var pipeline = new RefinementPipeline(MakeRefinementProvider());
                    var outcome = await pipeline.RefineAsync(transcript.Text, context, ct);
                    ct.ThrowIfCancellationRequested();
                    finalText = outcome.Text;
                    if (outcome.UsedFallback)
                    {
                        StatusMessage = L10n.T("refine.fallback.notice");
                    }
                }

                if (_machine.State != DictationState.Transcribing && _machine.State != DictationState.Refining)
                {
                    return;
                }
                Advance(DictationState.Inserting);

                if (TestModeSink is { } sink)
                {
                    sink(finalText);
                    FinishCompleted("");
                    return;
                }

                // Wispr-Flow-style safety net: the text is saved to the local
                // history BEFORE insertion, so it can be recovered from the
                // tray menu even if the paste into the target app fails.
                _history?.Add(finalText);

                var insertion = await _inserter.InsertAsync(
                    finalText, _targetWindow, _settings.InsertionMode, ct);
                ct.ThrowIfCancellationRequested();

                switch (insertion)
                {
                    case InsertionOutcome.InsertedViaAutomation:
                    case InsertionOutcome.PastedViaClipboard:
                    case InsertionOutcome.TypedViaKeyboard:
                        FinishCompleted("");
                        break;
                    case InsertionOutcome.ClipboardOnly clipboardOnly:
                        FinishCompleted(L10n.T(clipboardOnly.ReasonKey));
                        break;
                }
            }
            finally
            {
                // Delete the temp WAV immediately — no transcript audio is kept.
                try
                {
                    File.Delete(recording.AudioPath);
                }
                catch (IOException)
                {
                }
            }
        }
        catch (OperationCanceledException)
        {
            // CancelDictation() already moved the machine to Cancelled.
        }
        catch (VoxLocalException e)
        {
            Fail(e.Error);
        }
        catch (Exception e)
        {
            Fail(new VoxLocalError.TranscriptionFailed(-1, e.Message));
        }
    }

    /// <summary>Builds a fresh provider from current settings for each
    /// session, so endpoint/model changes apply immediately.</summary>
    private ITextRefinementProvider MakeRefinementProvider()
    {
        if (!_settings.RefinementEnabled)
        {
            return new NoRefinementProvider();
        }
        try
        {
            return new OllamaRefinementProvider(_settings.OllamaEndpoint, _settings.OllamaModel);
        }
        catch (Exception e)
        {
            Log.Shared.Info($"refinement provider unavailable ({e.Message}); using raw transcript");
            return new NoRefinementProvider();
        }
    }

    public void CancelDictation()
    {
        if (!_machine.IsCancellable)
        {
            return;
        }
        _pipelineCts?.Cancel();
        _pipelineCts = null;
        if (_recorder.IsRecording)
        {
            _recorder.Cancel();
        }
        MicLevel = 0;
        Advance(DictationState.Cancelled);
        StatusMessage = "";
        TestModeSink = null;
        _hotkeys.UnregisterEscape();
        ScheduleIdleReset(1.0);
        Log.Shared.Info("dictation cancelled by user");
    }

    // ---- Completion / failure ----

    private void FinishCompleted(string message)
    {
        StatusMessage = message;
        Advance(DictationState.Completed);
        TestModeSink = null;
        _hotkeys.UnregisterEscape();
        ScheduleIdleReset(message.Length == 0 ? 1.4 : 3.5);
    }

    private void Fail(VoxLocalError error)
    {
        if (_machine.State is DictationState.Cancelled or DictationState.Idle)
        {
            return;
        }
        Log.Shared.Error(error.LogDetail);
        StatusMessage = L10n.T(error.MessageKey);
        MicLevel = 0;
        Advance(DictationState.Error);
        TestModeSink = null;
        _hotkeys.UnregisterEscape();
        ScheduleIdleReset(4.0);
    }

    private void ScheduleIdleReset(double seconds)
    {
        _idleResetCts?.Cancel();
        var cts = new CancellationTokenSource();
        _idleResetCts = cts;
        _ = ResetAfterAsync(seconds, cts.Token);
    }

    private async Task ResetAfterAsync(double seconds, CancellationToken ct)
    {
        try
        {
            await Task.Delay(TimeSpan.FromSeconds(seconds), ct);
        }
        catch (TaskCanceledException)
        {
            return;
        }
        ResetToIdle();
    }

    private void ResetToIdle()
    {
        if (_machine.State is not (DictationState.Completed or DictationState.Cancelled or DictationState.Error))
        {
            return;
        }
        StatusMessage = "";
        Advance(DictationState.Idle);
    }

    private void Advance(DictationState next)
    {
        try
        {
            _machine.Transition(next);
            State = _machine.State;
            StateChanged?.Invoke(_machine.State);
        }
        catch (InvalidTransitionException e)
        {
            Log.Shared.Error($"state machine: {e.Message}");
        }
    }

    private void Notify(string name) =>
        PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(name));
}
