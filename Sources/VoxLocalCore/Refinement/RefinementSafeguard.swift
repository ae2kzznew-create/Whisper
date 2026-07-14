import Foundation

/// Validates LLM-refined text against the original transcript. When the
/// result is empty, implausibly different or bloated, the pipeline falls
/// back to the raw transcript and records a local warning.
public enum RefinementSafeguard {
    public enum Verdict: Equatable, Sendable {
        case accepted(String)
        case rejected(reason: String)
    }

    /// Common LLM refusal/meta openings that indicate the model answered
    /// instead of editing.
    static let refusalMarkers: [String] = [
        "as an ai", "i'm sorry", "i am sorry", "i cannot", "i can't",
        "here is the corrected", "here's the corrected", "sure,", "sure!",
        "как ии", "как искусственный интеллект", "я не могу", "извините",
        "вот исправленный", "конечно,", "конечно!",
    ]

    public static func validate(original: String, refined: String) -> Verdict {
        let cleaned = refined.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else {
            return .rejected(reason: "empty refinement result")
        }

        let lowered = cleaned.lowercased()
        for marker in refusalMarkers where lowered.hasPrefix(marker) {
            return .rejected(reason: "looks like an LLM meta-response")
        }

        // Substantially longer output means invented content.
        let maxLength = max(Int(Double(original.count) * 1.6), original.count + 120)
        if cleaned.count > maxLength {
            return .rejected(reason: "refined text much longer than original (\(cleaned.count) vs \(original.count) chars)")
        }

        // Word-overlap sanity check for texts long enough to compare.
        let originalWords = significantWords(original)
        if originalWords.count >= 8 {
            let refinedWords = significantWords(cleaned)
            let overlap = jaccard(originalWords, refinedWords)
            if overlap < 0.2 {
                return .rejected(reason: String(format: "refined text too dissimilar (overlap %.2f)", overlap))
            }
        }

        return .accepted(cleaned)
    }

    static func significantWords(_ text: String) -> Set<String> {
        Set(
            text.lowercased()
                .components(separatedBy: CharacterSet.alphanumerics.inverted)
                .filter { $0.count >= 3 }
        )
    }

    static func jaccard(_ a: Set<String>, _ b: Set<String>) -> Double {
        guard !a.isEmpty || !b.isEmpty else { return 1 }
        let union = a.union(b).count
        guard union > 0 else { return 1 }
        return Double(a.intersection(b).count) / Double(union)
    }
}
