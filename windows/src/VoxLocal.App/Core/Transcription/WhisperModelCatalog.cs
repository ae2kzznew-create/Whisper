using System.Globalization;

namespace VoxLocal.Core.Transcription;

/// <summary>
/// A known downloadable ggml Whisper model. Sizes are approximate and shown
/// to the user before any download starts.
/// </summary>
public sealed record WhisperModelInfo(string Name, int ApproxMB, bool Multilingual)
{
    public string Id => Name;
    public string FileName => $"ggml-{Name}.bin";

    /// <summary>
    /// Official upstream source — the same Hugging Face repository used by
    /// whisper.cpp's own download-ggml-model script.
    /// </summary>
    public Uri DownloadUrl => new($"https://huggingface.co/ggerganov/whisper.cpp/resolve/main/{FileName}");

    public string SizeLabel => ApproxMB >= 1000
        ? $"{(ApproxMB / 1000.0).ToString("F1", CultureInfo.InvariantCulture)} GB"
        : $"{ApproxMB} MB";
}

public static class WhisperModelCatalog
{
    public static readonly IReadOnlyList<WhisperModelInfo> Models = new[]
    {
        new WhisperModelInfo("tiny", 78, true),
        new WhisperModelInfo("tiny.en", 78, false),
        new WhisperModelInfo("base", 148, true),
        new WhisperModelInfo("base.en", 148, false),
        new WhisperModelInfo("small", 488, true),
        new WhisperModelInfo("small.en", 488, false),
        new WhisperModelInfo("medium", 1530, true),
        new WhisperModelInfo("large-v3", 3100, true),
        new WhisperModelInfo("large-v3-turbo", 1620, true),
    };

    public const string DefaultModelName = "base";

    public static WhisperModelInfo? Info(string name) =>
        Models.FirstOrDefault(m => m.Name == name);
}
