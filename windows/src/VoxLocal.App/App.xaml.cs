using System.Windows;
using Microsoft.Win32;
using VoxLocal.Core.Audio;
using VoxLocal.Core.Hotkeys;
using VoxLocal.Core.Insertion;
using VoxLocal.Core.Permissions;
using VoxLocal.Core.Settings;
using VoxLocal.Core.Transcription;
using VoxLocal.Core.Utilities;

namespace VoxLocal.App;

/// <summary>
/// Application entry object (AppDelegate analogue): builds the dependency
/// graph, registers the global hotkey, owns the tray icon and windows.
/// Tray-only app: ShutdownMode is OnExplicitShutdown and no main window is
/// created — the WPF counterpart of LSUIElement.
/// </summary>
public partial class App : Application
{
    private SettingsStore _settings = null!;
    private PermissionsService _permissions = null!;
    private ModelManager _modelManager = null!;
    private HotkeyManager _hotkeys = null!;
    private DictationController _dictation = null!;
    private OverlayWindowController _overlay = null!;
    private TrayIconController _trayIcon = null!;
    private SettingsDependencies _deps = null!;

    private Window? _settingsWindow;
    private Window? _onboardingWindow;

    protected override void OnStartup(StartupEventArgs e)
    {
        base.OnStartup(e);
        ShutdownMode = ShutdownMode.OnExplicitShutdown;

        // SettingsStore applies L10n language and log level on load.
        _settings = new SettingsStore();
        var version = typeof(App).Assembly.GetName().Version?.ToString(3) ?? "dev";
        Log.Shared.Info($"VoxLocal starting (v{version})");

        // Normal sessions delete their temp WAV themselves; this sweep only
        // catches leftovers from crashes or power loss.
        CleanupOrphanedTempAudio();

        _permissions = new PermissionsService();
        _modelManager = new ModelManager();
        _hotkeys = new HotkeyManager();

        _dictation = new DictationController(
            settings: _settings,
            permissions: _permissions,
            recorder: new AudioRecorder(),
            transcriber: new WhisperTranscriber(),
            modelManager: _modelManager,
            inserter: new TextInserter(),
            hotkeys: _hotkeys);

        _overlay = new OverlayWindowController(_dictation);

        _deps = new SettingsDependencies(
            Settings: _settings,
            ModelManager: _modelManager,
            Permissions: _permissions,
            Dictation: _dictation,
            ApplyHotkey: combo => RegisterHotkey(combo));

        _trayIcon = new TrayIconController(
            dictation: _dictation,
            modelManager: _modelManager,
            openSettings: ShowSettings,
            exit: Shutdown);

        _hotkeys.OnMainKeyDown = () => _dictation.HandleHotkeyDown();
        _hotkeys.OnMainKeyUp = () => _dictation.HandleHotkeyUp();
        _hotkeys.OnEscape = () => _dictation.CancelDictation();

        var error = RegisterHotkey(_settings.Hotkey);
        if (error is not null)
        {
            ShowHotkeyConflictAlert(error);
        }

        // SMAppService → HKCU Run key; keep it in sync with the setting.
        LaunchAtLogin.Apply(_settings.LaunchAtLogin);
        _settings.PropertyChanged += (_, args) =>
        {
            if (args.PropertyName == nameof(SettingsStore.LaunchAtLogin))
            {
                LaunchAtLogin.Apply(_settings.LaunchAtLogin);
            }
        };

        if (!_settings.OnboardingCompleted)
        {
            ShowOnboarding();
        }
    }

    protected override void OnExit(ExitEventArgs e)
    {
        _dictation?.CancelDictation();
        _hotkeys?.UnregisterMainHotkey();
        _hotkeys?.UnregisterEscape();
        _trayIcon?.Dispose();
        Log.Shared.Info("VoxLocal terminating");
        Log.Shared.Sync();
        base.OnExit(e);
    }

    /// <summary>
    /// Deletes voxlocal-*.wav files left in %TEMP% by sessions that were
    /// interrupted abnormally (crash, power loss). Only files older than one
    /// hour are removed, so a recording from another live instance is never
    /// touched. No transcript text is ever written to disk, so temp audio is
    /// the only per-session artifact to clean up.
    /// </summary>
    private static void CleanupOrphanedTempAudio()
    {
        try
        {
            var cutoff = DateTime.UtcNow.AddHours(-1);
            foreach (var file in System.IO.Directory.EnumerateFiles(Path.GetTempPath(), "voxlocal-*.wav"))
            {
                try
                {
                    if (File.GetLastWriteTimeUtc(file) < cutoff)
                    {
                        File.Delete(file);
                        Log.Shared.Info("removed orphaned temp audio file");
                    }
                }
                catch (IOException)
                {
                    // in use or already gone — skip
                }
                catch (UnauthorizedAccessException)
                {
                    // not ours to delete — skip
                }
            }
        }
        catch (Exception e)
        {
            Log.Shared.Error($"temp audio cleanup failed: {e.Message}");
        }
    }

    /// <summary>Registers the shortcut; returns a localized error message on
    /// failure.</summary>
    private string? RegisterHotkey(KeyCombo combo)
    {
        try
        {
            _hotkeys.RegisterMainHotkey(combo);
            return null;
        }
        catch (HotkeyConflictException)
        {
            return L10n.T("error.hotkey.conflict", combo.DisplayString);
        }
        catch (Exception)
        {
            return L10n.T("error.hotkey.failed", combo.DisplayString);
        }
    }

    private static void ShowHotkeyConflictAlert(string message) =>
        MessageBox.Show(
            message + "\n" + L10n.T("alert.hotkeyConflict.hint"),
            L10n.T("alert.hotkeyConflict.title"),
            MessageBoxButton.OK,
            MessageBoxImage.Warning);

    // ---- Windows ----

    public void ShowSettings()
    {
        if (_settingsWindow is null)
        {
            _settingsWindow = new SettingsWindow(_deps)
            {
                Title = L10n.T("settings.title"),
                WindowStartupLocation = WindowStartupLocation.CenterScreen,
            };
            _settingsWindow.Closed += (_, _) => _settingsWindow = null;
        }
        _settingsWindow.Show();
        _settingsWindow.Activate();
    }

    public void ShowOnboarding()
    {
        if (_onboardingWindow is null)
        {
            _onboardingWindow = new OnboardingWindow(_deps, onFinished: () => _onboardingWindow?.Close())
            {
                Title = L10n.T("onboarding.title"),
                WindowStartupLocation = WindowStartupLocation.CenterScreen,
            };
            _onboardingWindow.Closed += (_, _) => _onboardingWindow = null;
        }
        _onboardingWindow.Show();
        _onboardingWindow.Activate();
    }
}

/// <summary>Shared dependencies handed to the settings/onboarding UI.</summary>
public sealed record SettingsDependencies(
    SettingsStore Settings,
    ModelManager ModelManager,
    PermissionsService Permissions,
    DictationController Dictation,
    Func<KeyCombo, string?> ApplyHotkey);

/// <summary>SMAppService analogue: launch-at-login via the HKCU Run key.</summary>
internal static class LaunchAtLogin
{
    private const string RunKey = @"Software\Microsoft\Windows\CurrentVersion\Run";
    private const string ValueName = "VoxLocal";

    public static void Apply(bool enabled)
    {
        try
        {
            using var key = Registry.CurrentUser.OpenSubKey(RunKey, writable: true);
            if (key is null)
            {
                return;
            }
            if (enabled && Environment.ProcessPath is { } exe)
            {
                key.SetValue(ValueName, $"\"{exe}\"");
            }
            else if (!enabled)
            {
                key.DeleteValue(ValueName, throwOnMissingValue: false);
            }
        }
        catch (Exception e)
        {
            Log.Shared.Error($"launch-at-login update failed: {e.Message}");
        }
    }
}
