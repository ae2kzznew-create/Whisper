import Foundation

/// Applies optional refinement with all fallback guarantees: any provider
/// failure, timeout, cancellation of the provider call, or an implausible
/// result returns the raw transcript unchanged (with a local log warning).
public struct RefinementPipeline: Sendable {
    public struct Outcome: Equatable, Sendable {
        public let text: String
        /// True when the raw transcript was used (refinement skipped/failed).
        public let usedFallback: Bool
        public let fallbackReason: String?
    }

    private let provider: TextRefinementProvider

    public init(provider: TextRefinementProvider) {
        self.provider = provider
    }

    public func refine(_ transcript: String, context: RefinementContext) async -> Outcome {
        if context.preset == .rawTranscript {
            return Outcome(text: transcript, usedFallback: false, fallbackReason: nil)
        }
        do {
            let refined = try await provider.refine(transcript, context: context)
            switch RefinementSafeguard.validate(original: transcript, refined: refined) {
            case .accepted(let text):
                Log.shared.info("refinement accepted (\(transcript.count) → \(text.count) chars)")
                return Outcome(text: text, usedFallback: false, fallbackReason: nil)
            case .rejected(let reason):
                Log.shared.info("refinement rejected, using raw transcript: \(reason)")
                return Outcome(text: transcript, usedFallback: true, fallbackReason: reason)
            }
        } catch is CancellationError {
            Log.shared.info("refinement cancelled, using raw transcript")
            return Outcome(text: transcript, usedFallback: true, fallbackReason: "cancelled")
        } catch RefinementError.timeout {
            Log.shared.info("refinement timed out, using raw transcript")
            return Outcome(text: transcript, usedFallback: true, fallbackReason: "timeout")
        } catch {
            Log.shared.info("refinement failed, using raw transcript: \(error)")
            return Outcome(text: transcript, usedFallback: true, fallbackReason: String(describing: error))
        }
    }
}
