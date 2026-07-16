using System.Globalization;
using System.Text.RegularExpressions;

namespace VoxLocal.Core.Refinement;

/// <summary>
/// Validates LLM-refined text against the original transcript. When the
/// result is empty, implausibly different or bloated, the pipeline falls
/// back to the raw transcript and records a local warning.
/// </summary>
public static class RefinementSafeguard
{
    public abstract record Verdict
    {
        public sealed record Accepted(string Text) : Verdict;
        public sealed record Rejected(string Reason) : Verdict;
    }

    /// <summary>
    /// Common LLM refusal/meta openings that indicate the model answered
    /// instead of editing.
    /// </summary>
    internal static readonly string[] RefusalMarkers =
    {
        "as an ai", "i'm sorry", "i am sorry", "i cannot", "i can't",
        "here is the corrected", "here's the corrected", "sure,", "sure!",
        "как ии", "как искусственный интеллект", "я не могу", "извините",
        "вот исправленный", "конечно,", "конечно!",
    };

    public static Verdict Validate(string original, string refined)
    {
        var cleaned = refined.Trim();
        if (cleaned.Length == 0)
        {
            return new Verdict.Rejected("empty refinement result");
        }

        var lowered = cleaned.ToLowerInvariant();
        foreach (var marker in RefusalMarkers)
        {
            if (lowered.StartsWith(marker, StringComparison.Ordinal))
            {
                return new Verdict.Rejected("looks like an LLM meta-response");
            }
        }

        // Substantially longer output means invented content.
        var maxLength = Math.Max((int)(original.Length * 1.6), original.Length + 120);
        if (cleaned.Length > maxLength)
        {
            return new Verdict.Rejected($"refined text much longer than original ({cleaned.Length} vs {original.Length} chars)");
        }

        // Word-overlap sanity check for texts long enough to compare.
        var originalWords = SignificantWords(original);
        if (originalWords.Count >= 8)
        {
            var refinedWords = SignificantWords(cleaned);
            var overlap = Jaccard(originalWords, refinedWords);
            if (overlap < 0.2)
            {
                return new Verdict.Rejected(
                    $"refined text too dissimilar (overlap {overlap.ToString("F2", CultureInfo.InvariantCulture)})");
            }
        }

        return new Verdict.Accepted(cleaned);
    }

    /// <summary>CharacterSet.alphanumerics → Unicode letter/digit categories.</summary>
    private static readonly Regex NonAlphanumeric = new(@"[^\p{L}\p{Nd}]+", RegexOptions.Compiled);

    internal static HashSet<string> SignificantWords(string text) =>
        NonAlphanumeric.Split(text.ToLowerInvariant())
            .Where(w => w.Length >= 3)
            .ToHashSet();

    internal static double Jaccard(HashSet<string> a, HashSet<string> b)
    {
        if (a.Count == 0 && b.Count == 0)
        {
            return 1;
        }
        var union = a.Union(b).Count();
        if (union == 0)
        {
            return 1;
        }
        return (double)a.Intersect(b).Count() / union;
    }
}
