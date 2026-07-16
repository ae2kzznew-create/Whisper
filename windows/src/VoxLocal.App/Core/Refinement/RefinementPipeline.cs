using VoxLocal.Core.Utilities;

namespace VoxLocal.Core.Refinement;

/// <summary>
/// Applies optional refinement with all fallback guarantees: any provider
/// failure, timeout, cancellation of the provider call, or an implausible
/// result returns the raw transcript unchanged (with a local log warning).
/// </summary>
public sealed class RefinementPipeline
{
    /// <param name="UsedFallback">True when the raw transcript was used (refinement skipped/failed).</param>
    public sealed record Outcome(string Text, bool UsedFallback, string? FallbackReason);

    private readonly ITextRefinementProvider _provider;

    public RefinementPipeline(ITextRefinementProvider provider)
    {
        _provider = provider;
    }

    public async Task<Outcome> RefineAsync(
        string transcript,
        RefinementContext context,
        CancellationToken cancellationToken = default)
    {
        if (context.Preset == RefinementPreset.RawTranscript)
        {
            return new Outcome(transcript, UsedFallback: false, FallbackReason: null);
        }
        try
        {
            var refined = await _provider.RefineAsync(transcript, context, cancellationToken).ConfigureAwait(false);
            switch (RefinementSafeguard.Validate(transcript, refined))
            {
                case RefinementSafeguard.Verdict.Accepted accepted:
                    Log.Shared.Info($"refinement accepted ({transcript.Length} -> {accepted.Text.Length} chars)");
                    return new Outcome(accepted.Text, UsedFallback: false, FallbackReason: null);
                case RefinementSafeguard.Verdict.Rejected rejected:
                    Log.Shared.Info($"refinement rejected, using raw transcript: {rejected.Reason}");
                    return new Outcome(transcript, UsedFallback: true, rejected.Reason);
                default:
                    return new Outcome(transcript, UsedFallback: true, "unknown verdict");
            }
        }
        catch (OperationCanceledException)
        {
            Log.Shared.Info("refinement cancelled, using raw transcript");
            return new Outcome(transcript, UsedFallback: true, "cancelled");
        }
        catch (RefinementTimeoutException)
        {
            Log.Shared.Info("refinement timed out, using raw transcript");
            return new Outcome(transcript, UsedFallback: true, "timeout");
        }
        catch (Exception e)
        {
            Log.Shared.Info($"refinement failed, using raw transcript: {e.Message}");
            return new Outcome(transcript, UsedFallback: true, e.ToString());
        }
    }
}
