namespace VoxLocal.Core.Models;

/// <summary>Lifecycle states of one dictation session.</summary>
public enum DictationState
{
    Idle,
    Preparing,
    Recording,
    Stopping,
    Transcribing,
    Refining,
    Inserting,
    Completed,
    Cancelled,
    Error,
}

public sealed class InvalidTransitionException : Exception
{
    public DictationState From { get; }
    public DictationState To { get; }

    public InvalidTransitionException(DictationState from, DictationState to)
        : base($"invalid dictation transition {from} → {to}")
    {
        From = from;
        To = to;
    }
}

/// <summary>
/// Explicit state machine for the dictation lifecycle. Rejects transitions
/// that are not part of the documented graph, which prevents overlapping
/// sessions and out-of-order pipeline steps.
/// </summary>
public sealed class DictationStateMachine
{
    public DictationState State { get; private set; }

    public static readonly IReadOnlyDictionary<DictationState, IReadOnlySet<DictationState>> AllowedTransitions =
        new Dictionary<DictationState, IReadOnlySet<DictationState>>
        {
            [DictationState.Idle] = new HashSet<DictationState> { DictationState.Preparing },
            [DictationState.Preparing] = new HashSet<DictationState> { DictationState.Recording, DictationState.Cancelled, DictationState.Error },
            [DictationState.Recording] = new HashSet<DictationState> { DictationState.Stopping, DictationState.Cancelled, DictationState.Error },
            [DictationState.Stopping] = new HashSet<DictationState> { DictationState.Transcribing, DictationState.Cancelled, DictationState.Error },
            [DictationState.Transcribing] = new HashSet<DictationState> { DictationState.Refining, DictationState.Inserting, DictationState.Cancelled, DictationState.Error },
            [DictationState.Refining] = new HashSet<DictationState> { DictationState.Inserting, DictationState.Cancelled, DictationState.Error },
            [DictationState.Inserting] = new HashSet<DictationState> { DictationState.Completed, DictationState.Cancelled, DictationState.Error },
            [DictationState.Completed] = new HashSet<DictationState> { DictationState.Idle },
            [DictationState.Cancelled] = new HashSet<DictationState> { DictationState.Idle },
            [DictationState.Error] = new HashSet<DictationState> { DictationState.Idle },
        };

    public DictationStateMachine(DictationState state = DictationState.Idle)
    {
        State = state;
    }

    /// <summary>True while a session is in flight (a new session must not start).</summary>
    public bool IsActive => State != DictationState.Idle;

    /// <summary>True while the session can still be cancelled by the user.</summary>
    public bool IsCancellable => State is DictationState.Preparing
        or DictationState.Recording
        or DictationState.Stopping
        or DictationState.Transcribing
        or DictationState.Refining
        or DictationState.Inserting;

    public bool CanTransition(DictationState next) =>
        AllowedTransitions.TryGetValue(State, out var allowed) && allowed.Contains(next);

    public void Transition(DictationState next)
    {
        if (!CanTransition(next))
        {
            throw new InvalidTransitionException(State, next);
        }
        State = next;
    }
}
