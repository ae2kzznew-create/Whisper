import Foundation

/// Lifecycle states of one dictation session.
public enum DictationState: String, CaseIterable, Sendable, Equatable {
    case idle
    case preparing
    case recording
    case stopping
    case transcribing
    case refining
    case inserting
    case completed
    case cancelled
    case error
}

public struct InvalidTransitionError: Error, Equatable, CustomStringConvertible {
    public let from: DictationState
    public let to: DictationState
    public var description: String { "invalid dictation transition \(from.rawValue) → \(to.rawValue)" }
}

/// Explicit state machine for the dictation lifecycle. Rejects transitions
/// that are not part of the documented graph, which prevents overlapping
/// sessions and out-of-order pipeline steps.
public struct DictationStateMachine: Sendable {
    public private(set) var state: DictationState

    public static let allowedTransitions: [DictationState: Set<DictationState>] = [
        .idle: [.preparing],
        .preparing: [.recording, .cancelled, .error],
        .recording: [.stopping, .cancelled, .error],
        .stopping: [.transcribing, .cancelled, .error],
        .transcribing: [.refining, .inserting, .cancelled, .error],
        .refining: [.inserting, .cancelled, .error],
        .inserting: [.completed, .cancelled, .error],
        .completed: [.idle],
        .cancelled: [.idle],
        .error: [.idle],
    ]

    public init(state: DictationState = .idle) {
        self.state = state
    }

    /// True while a session is in flight (a new session must not start).
    public var isActive: Bool {
        state != .idle
    }

    /// True while the session can still be cancelled by the user.
    public var isCancellable: Bool {
        switch state {
        case .preparing, .recording, .stopping, .transcribing, .refining, .inserting:
            return true
        default:
            return false
        }
    }

    public func canTransition(to next: DictationState) -> Bool {
        Self.allowedTransitions[state]?.contains(next) ?? false
    }

    public mutating func transition(to next: DictationState) throws {
        guard canTransition(to: next) else {
            throw InvalidTransitionError(from: state, to: next)
        }
        state = next
    }
}
