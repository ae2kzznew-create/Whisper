using System.Text.Json;
using System.Text.Json.Serialization;
using System.Text.RegularExpressions;

namespace VoxLocal.Core.Transcription;

/// <summary>
/// Parses whisper-cli JSON output (-oj) and optionally strips common
/// non-speech annotations that Whisper emits.
/// </summary>
public static class WhisperOutputParser
{
    public sealed record Output(string Text, string? DetectedLanguage);

    private sealed class WhisperJson
    {
        [JsonPropertyName("transcription")]
        public List<Segment>? Transcription { get; set; }

        [JsonPropertyName("result")]
        public ResultInfo? Result { get; set; }

        public sealed class Segment
        {
            [JsonPropertyName("text")]
            public string Text { get; set; } = "";
        }

        public sealed class ResultInfo
        {
            [JsonPropertyName("language")]
            public string? Language { get; set; }
        }
    }

    public static Output Parse(byte[] jsonData, bool removeArtifacts)
    {
        var decoded = JsonSerializer.Deserialize<WhisperJson>(jsonData)
            ?? throw new JsonException("empty whisper JSON");
        var joined = string.Concat((decoded.Transcription ?? new()).Select(s => s.Text));
        var cleaned = removeArtifacts ? StripArtifacts(joined) : joined;
        var text = NormalizeWhitespace(cleaned);
        return new Output(text, decoded.Result?.Language);
    }

    // ---- Artifact removal ----

    /// <summary>Square-bracket annotations are never real dictation output.</summary>
    private static readonly Regex BracketPattern = new(@"\[[^\]\n]{0,60}\]", RegexOptions.Compiled);

    /// <summary>
    /// Parenthesised annotations are removed only when they match known
    /// noise markers, so real speech like "(so to speak)" survives.
    /// </summary>
    private static readonly string[] KnownParenMarkers =
    {
        "music", "applause", "laughter", "laughing", "typing", "silence",
        "inaudible", "noise", "coughing", "sighs", "sigh", "beep", "clicking",
        "музыка", "аплодисменты", "смех", "тишина", "шум", "неразборчиво",
        "вздох", "кашель", "щелчок",
    };

    private static readonly Regex ParenPattern = new(
        @"\((?:" + string.Join("|", KnownParenMarkers) + @")[^)\n]{0,20}\)",
        RegexOptions.Compiled | RegexOptions.IgnoreCase | RegexOptions.CultureInvariant);

    public static string StripArtifacts(string text)
    {
        var result = BracketPattern.Replace(text, " ");
        result = ParenPattern.Replace(result, " ");
        result = result.Replace("♪", " ");
        return result;
    }

    public static string NormalizeWhitespace(string text)
    {
        var collapsed = string.Join("\n",
            text.Split('\n', '\r')
                .Select(line => string.Join(" ", line.Split(' ', '\t').Where(w => w.Length > 0)))
                .Where(line => line.Length > 0));
        return collapsed.Trim();
    }
}
