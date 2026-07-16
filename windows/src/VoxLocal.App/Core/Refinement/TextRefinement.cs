namespace VoxLocal.Core.Refinement;

public enum RefinementPreset
{
    /// <summary>No changes at all — refinement short-circuits.</summary>
    RawTranscript,
    /// <summary>Punctuation, capitalization, filler-word removal.</summary>
    CleanDictation,
    /// <summary>Same as clean, plus tightening of wordy phrases.</summary>
    Concise,
    /// <summary>Clean plus a neutral business tone.</summary>
    BusinessStyle,
    /// <summary>Fix only obvious recognition errors; keep the spoken wording.</summary>
    PreserveSpokenWording,
    /// <summary>User-supplied instruction appended to the strict base rules.</summary>
    Custom,
}

public static class RefinementPresetExtensions
{
    /// <summary>Localization key, e.g. "refine.preset.cleanDictation".</summary>
    public static string TitleKey(this RefinementPreset preset)
    {
        var name = preset.ToString();
        return $"refine.preset.{char.ToLowerInvariant(name[0])}{name[1..]}";
    }
}

/// <param name="Language">BCP-47-ish language code detected or selected ("ru", "en", null = unknown).</param>
public sealed record RefinementContext(
    string? Language,
    RefinementPreset Preset,
    string? CustomInstruction = null,
    double TimeoutSeconds = 20);

public abstract record RefinementAvailability
{
    public sealed record Available : RefinementAvailability;
    public sealed record ServerUnreachable(string Reason) : RefinementAvailability;
    public sealed record ModelMissing(IReadOnlyList<string> AvailableModels) : RefinementAvailability;
}

public abstract class RefinementException : Exception
{
    protected RefinementException(string message) : base(message) { }
}

public sealed class RefinementUnavailableException : RefinementException
{
    public RefinementUnavailableException(string reason) : base($"refinement unavailable: {reason}") { }
}

public sealed class RefinementTimeoutException : RefinementException
{
    public RefinementTimeoutException() : base("refinement timed out") { }
}

public sealed class RefinementInvalidResponseException : RefinementException
{
    public RefinementInvalidResponseException(string reason) : base($"invalid refinement response: {reason}") { }
}

public sealed class NonLocalEndpointException : RefinementException
{
    public NonLocalEndpointException(string endpoint) : base($"non-local endpoint rejected: {endpoint}") { }
}

public interface ITextRefinementProvider
{
    Task<string> RefineAsync(string transcript, RefinementContext context, CancellationToken cancellationToken = default);
    Task<RefinementAvailability> CheckAvailabilityAsync();
}

/// <summary>Pass-through provider used when refinement is disabled.</summary>
public sealed class NoRefinementProvider : ITextRefinementProvider
{
    public Task<string> RefineAsync(string transcript, RefinementContext context, CancellationToken cancellationToken = default) =>
        Task.FromResult(transcript);

    public Task<RefinementAvailability> CheckAvailabilityAsync() =>
        Task.FromResult<RefinementAvailability>(new RefinementAvailability.Available());
}
