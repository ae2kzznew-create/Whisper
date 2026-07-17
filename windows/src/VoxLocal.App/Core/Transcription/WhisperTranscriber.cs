using System.Text;
using VoxLocal.Core.Models;
using VoxLocal.Core.Utilities;

namespace VoxLocal.Core.Transcription;

/// <summary>Runs the bundled whisper-cli.exe against a WAV file and returns parsed text.</summary>
public sealed class WhisperTranscriber
{
    public sealed record Transcript(string Text, string? DetectedLanguage);

    private readonly ISubprocessRunner _runner;
    private readonly string? _binaryOverride;

    public WhisperTranscriber(ISubprocessRunner? runner = null, string? binaryOverride = null)
    {
        _runner = runner ?? new ProcessSubprocessRunner();
        _binaryOverride = binaryOverride;
    }

    /// <summary>
    /// Candidate locations for whisper-cli.exe, in priority order:
    /// 1. VOXLOCAL_WHISPER_CLI environment variable (tests, development),
    /// 2. next to the application executable (packaged app),
    /// 3. the in-repo CMake build output (running from the repo).
    /// </summary>
    public static IReadOnlyList<string> BinaryCandidates()
    {
        var candidates = new List<string>();
        var env = Environment.GetEnvironmentVariable("VOXLOCAL_WHISPER_CLI");
        if (!string.IsNullOrEmpty(env))
        {
            candidates.Add(env);
        }
        candidates.Add(Path.Combine(AppContext.BaseDirectory, "whisper-cli.exe"));
        var cwd = Directory.GetCurrentDirectory();
        candidates.Add(Path.Combine(cwd, "vendor", "whisper.cpp", "build", "bin", "Release", "whisper-cli.exe"));
        candidates.Add(Path.Combine(cwd, "vendor", "whisper.cpp", "build", "bin", "whisper-cli.exe"));
        return candidates;
    }

    public string LocateBinary()
    {
        if (_binaryOverride is not null)
        {
            return _binaryOverride;
        }
        var candidates = BinaryCandidates();
        foreach (var path in candidates)
        {
            // Windows has no executable bit; existence is the practical check.
            if (File.Exists(path)) return path;
        }
        var searched = string.Join(", ", candidates.Select(PathRedactor.Redact));
        throw new VoxLocalException(new VoxLocalError.WhisperBinaryMissing(searched));
    }

    /// <summary>Non-throwing variant of <see cref="LocateBinary"/> for status screens (onboarding).</summary>
    public bool TryLocateBinary(out string? path)
    {
        try
        {
            path = LocateBinary();
            return true;
        }
        catch (VoxLocalException)
        {
            path = null;
            return false;
        }
    }

    public async Task<Transcript> TranscribeAsync(
        string audioPath,
        string modelPath,
        string language,
        int threads,
        bool removeArtifacts,
        TimeSpan? timeout = null,
        CancellationToken cancellationToken = default)
    {
        var binary = LocateBinary();

        if (!File.Exists(audioPath))
        {
            throw new VoxLocalException(new VoxLocalError.RecordingFailed("audio file vanished before transcription"));
        }
        switch (ModelManager.ValidateModelFile(modelPath))
        {
            case ModelManager.ValidationResult.Valid:
                break;
            case ModelManager.ValidationResult.Missing:
                throw new VoxLocalException(new VoxLocalError.ModelMissing(modelPath));
            default:
                throw new VoxLocalException(new VoxLocalError.ModelInvalid(modelPath));
        }

        var outputBase = Path.Combine(Path.GetTempPath(), $"voxlocal-out-{Guid.NewGuid()}");
        var jsonPath = outputBase + ".json";
        try
        {
            var args = WhisperCommandBuilder.Arguments(modelPath, audioPath, language, threads, outputBase);

            Log.Shared.Info($"whisper-cli starting (model {Path.GetFileName(modelPath)}, lang {language}, threads {threads})");
            var started = DateTime.UtcNow;

            SubprocessResult result;
            try
            {
                result = await _runner.RunAsync(binary, args, timeout ?? TimeSpan.FromSeconds(180), cancellationToken)
                    .ConfigureAwait(false);
            }
            catch (SubprocessTimeoutException)
            {
                throw new VoxLocalException(new VoxLocalError.TranscriptionTimeout());
            }
            catch (SubprocessLaunchException ex)
            {
                // ERROR_BAD_EXE_FORMAT (193): wrong bitness or corrupted exe —
                // the Windows analogue of macOS "bad CPU type".
                if (ex.InnerException is System.ComponentModel.Win32Exception { NativeErrorCode: 193 }
                    || ex.Message.Contains("not a valid", StringComparison.OrdinalIgnoreCase))
                {
                    throw new VoxLocalException(new VoxLocalError.UnsupportedArchitecture(ex.Message));
                }
                throw new VoxLocalException(new VoxLocalError.TranscriptionFailed(-1, ex.Message));
            }

            cancellationToken.ThrowIfCancellationRequested();

            if (result.ExitCode != 0)
            {
                var tail = result.Stderr.Length <= 600 ? result.Stderr : result.Stderr[^600..];
                var stderrTail = Encoding.UTF8.GetString(tail);
                if (stderrTail.Contains("failed to load model", StringComparison.OrdinalIgnoreCase)
                    || stderrTail.Contains("invalid model", StringComparison.OrdinalIgnoreCase))
                {
                    throw new VoxLocalException(new VoxLocalError.ModelInvalid(modelPath));
                }
                throw new VoxLocalException(new VoxLocalError.TranscriptionFailed(result.ExitCode, stderrTail));
            }

            byte[] jsonData;
            try
            {
                jsonData = await File.ReadAllBytesAsync(jsonPath, cancellationToken).ConfigureAwait(false);
            }
            catch (Exception e) when (e is IOException or UnauthorizedAccessException)
            {
                throw new VoxLocalException(new VoxLocalError.TranscriptionOutputMissing());
            }

            WhisperOutputParser.Output output;
            try
            {
                output = WhisperOutputParser.Parse(jsonData, removeArtifacts);
            }
            catch (Exception)
            {
                throw new VoxLocalException(new VoxLocalError.TranscriptionOutputMissing());
            }

            var elapsed = (DateTime.UtcNow - started).TotalSeconds;
            Log.Shared.Info($"whisper-cli finished in {elapsed:F1}s (chars: {output.Text.Length}, lang: {output.DetectedLanguage ?? "?"})");
            return new Transcript(output.Text, output.DetectedLanguage);
        }
        finally
        {
            try { File.Delete(jsonPath); } catch { /* best effort */ }
        }
    }
}
