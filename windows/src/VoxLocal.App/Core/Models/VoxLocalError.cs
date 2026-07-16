namespace VoxLocal.Core.Models;

/// <summary>
/// User-facing errors of the dictation pipeline. <see cref="MessageKey"/> maps to a
/// localized string; detail values carry technical context for the log only.
/// </summary>
public abstract record VoxLocalError
{
    public sealed record MicrophonePermissionDenied : VoxLocalError;
    public sealed record MicrophoneUnavailable : VoxLocalError;
    public sealed record RecordingFailed(string Detail) : VoxLocalError;
    public sealed record EmptyRecording : VoxLocalError;
    public sealed record WhisperBinaryMissing(string SearchedPath) : VoxLocalError;
    public sealed record ModelMissing(string Path) : VoxLocalError;
    public sealed record ModelInvalid(string Path) : VoxLocalError;
    public sealed record TranscriptionFailed(int ExitCode, string Detail) : VoxLocalError;
    public sealed record TranscriptionTimeout : VoxLocalError;
    public sealed record TranscriptionOutputMissing : VoxLocalError;
    public sealed record UnsupportedArchitecture(string Architecture) : VoxLocalError;
    public sealed record HotkeyConflict(string Combo) : VoxLocalError;
    public sealed record InsertionTargetGone : VoxLocalError;
    public sealed record Cancelled : VoxLocalError;

    public string MessageKey => this switch
    {
        MicrophonePermissionDenied => "error.mic.denied",
        MicrophoneUnavailable => "error.mic.unavailable",
        RecordingFailed => "error.recording.failed",
        EmptyRecording => "error.recording.empty",
        WhisperBinaryMissing => "error.whisper.binary",
        ModelMissing => "error.whisper.model.missing",
        ModelInvalid => "error.whisper.model.invalid",
        TranscriptionFailed => "error.whisper.failed",
        TranscriptionTimeout => "error.whisper.timeout",
        TranscriptionOutputMissing => "error.whisper.output",
        UnsupportedArchitecture => "error.whisper.arch",
        HotkeyConflict => "error.hotkey.conflict",
        InsertionTargetGone => "error.insert.target.gone",
        Cancelled => "state.cancelled",
        _ => throw new InvalidOperationException($"unknown error case: {GetType().Name}"),
    };

    /// <summary>Technical detail for logs. Never contains transcript text or audio.</summary>
    public string LogDetail => this switch
    {
        RecordingFailed e => $"recording failed: {e.Detail}",
        WhisperBinaryMissing e => $"whisper-cli not found, searched: {PathRedactor.Redact(e.SearchedPath)}",
        ModelMissing e => $"model missing at {PathRedactor.Redact(e.Path)}",
        ModelInvalid e => $"model invalid at {PathRedactor.Redact(e.Path)}",
        TranscriptionFailed e => $"whisper exit {e.ExitCode}: {e.Detail}",
        UnsupportedArchitecture e => $"unsupported architecture: {e.Architecture}",
        HotkeyConflict e => $"hotkey conflict: {e.Combo}",
        _ => ToString(),
    };
}

/// <summary>Exception wrapper so the error union can flow through async call stacks.</summary>
public sealed class VoxLocalException : Exception
{
    public VoxLocalError Error { get; }

    public VoxLocalException(VoxLocalError error) : base(error.LogDetail)
    {
        Error = error;
    }
}

/// <summary>Replaces the user's profile directory prefix in paths before logging.</summary>
public static class PathRedactor
{
    public static string Redact(string path)
    {
        var home = Environment.GetFolderPath(Environment.SpecialFolder.UserProfile);
        if (string.IsNullOrEmpty(home) || !path.StartsWith(home, StringComparison.OrdinalIgnoreCase))
        {
            return path;
        }
        return "~" + path[home.Length..];
    }
}
