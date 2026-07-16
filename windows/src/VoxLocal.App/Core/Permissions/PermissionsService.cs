using System.Diagnostics;
using Microsoft.Win32;
using NAudio.CoreAudioApi;

namespace VoxLocal.Core.Permissions;

public enum PermissionStatus
{
    NotDetermined,
    Granted,
    Denied,
}

/// <summary>
/// Abstraction over permission checks so permission-dependent logic can be
/// unit-tested with mocks. On Windows only the microphone matters: there is
/// no Accessibility permission (UI Automation and SendInput work without
/// user consent), so that entire surface from the macOS version is gone.
/// </summary>
public interface IPermissionsChecking
{
    PermissionStatus MicrophoneStatus { get; }
    /// <summary>Windows shows no system prompt for desktop apps; this probes
    /// the default capture device instead.</summary>
    Task<bool> RequestMicrophoneAccessAsync();
    void OpenMicrophoneSettings();
}

public sealed class PermissionsService : IPermissionsChecking
{
    private const string ConsentKey =
        @"Software\Microsoft\Windows\CurrentVersion\CapabilityAccessManager\ConsentStore\microphone";

    /// <summary>
    /// Desktop (unpackaged) apps are governed by the global "Let desktop
    /// apps access your microphone" toggle, reflected in the registry
    /// consent store — the Windows counterpart of the TCC database.
    /// </summary>
    public PermissionStatus MicrophoneStatus
    {
        get
        {
            try
            {
                using var nonPackaged = Registry.CurrentUser.OpenSubKey($@"{ConsentKey}\NonPackaged");
                using var global = Registry.CurrentUser.OpenSubKey(ConsentKey);
                var value = nonPackaged?.GetValue("Value") as string
                    ?? global?.GetValue("Value") as string;
                return value switch
                {
                    "Allow" => PermissionStatus.Granted,
                    "Deny" => PermissionStatus.Denied,
                    _ => PermissionStatus.NotDetermined,
                };
            }
            catch (Exception)
            {
                return PermissionStatus.NotDetermined;
            }
        }
    }

    /// <summary>
    /// AVCaptureDevice.requestAccess → a short probe of the default capture
    /// device. Success means audio input actually works end to end.
    /// </summary>
    public Task<bool> RequestMicrophoneAccessAsync() => Task.Run(() =>
    {
        try
        {
            using var capture = new WasapiCapture();
            capture.StartRecording();
            capture.StopRecording();
            return true;
        }
        catch (Exception)
        {
            return false;
        }
    });

    /// <summary>x-apple.systempreferences → ms-settings deep link.</summary>
    public void OpenMicrophoneSettings()
    {
        Process.Start(new ProcessStartInfo("ms-settings:privacy-microphone")
        {
            UseShellExecute = true,
        });
    }
}

/// <summary>
/// Result of the pre-flight check before a dictation session starts.
/// Pure decision logic (unit-tested with mocked permission states).
/// The macOS "warn about missing Accessibility" branch is gone: Windows
/// needs no such permission, so Ready carries no warning flag.
/// </summary>
public abstract record DictationPreflight
{
    public sealed record Ready : DictationPreflight;
    public sealed record NeedsMicrophoneRequest : DictationPreflight;
    public sealed record BlockedMicrophoneDenied : DictationPreflight;
    public sealed record BlockedModelMissing(string ModelName) : DictationPreflight;

    public static DictationPreflight Evaluate(
        PermissionStatus microphone,
        bool modelInstalled,
        string modelName) => microphone switch
    {
        PermissionStatus.Denied => new BlockedMicrophoneDenied(),
        PermissionStatus.NotDetermined => new NeedsMicrophoneRequest(),
        _ => modelInstalled
            ? new Ready()
            : new BlockedModelMissing(modelName),
    };
}
