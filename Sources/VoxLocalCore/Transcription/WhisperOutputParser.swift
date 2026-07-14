import Foundation

/// Parses whisper-cli JSON output (`-oj`) and optionally strips common
/// non-speech annotations that Whisper emits.
public enum WhisperOutputParser {
    public struct Output: Equatable, Sendable {
        public let text: String
        public let detectedLanguage: String?

        public init(text: String, detectedLanguage: String?) {
            self.text = text
            self.detectedLanguage = detectedLanguage
        }
    }

    private struct WhisperJSON: Decodable {
        struct Segment: Decodable { let text: String }
        struct ResultInfo: Decodable { let language: String? }
        let transcription: [Segment]?
        let result: ResultInfo?
    }

    public static func parse(jsonData: Data, removeArtifacts: Bool) throws -> Output {
        let decoded = try JSONDecoder().decode(WhisperJSON.self, from: jsonData)
        let joined = (decoded.transcription ?? [])
            .map(\.text)
            .joined()
        let cleaned = removeArtifacts ? stripArtifacts(from: joined) : joined
        let text = normalizeWhitespace(cleaned)
        return Output(text: text, detectedLanguage: decoded.result?.language)
    }

    // MARK: - Artifact removal

    /// Square-bracket annotations are never real dictation output.
    private static let bracketPattern = try! NSRegularExpression(pattern: #"\[[^\]\n]{0,60}\]"#)

    /// Parenthesised annotations are removed only when they match known
    /// noise markers, so real speech like "(so to speak)" survives.
    private static let knownParenMarkers: [String] = [
        "music", "applause", "laughter", "laughing", "typing", "silence",
        "inaudible", "noise", "coughing", "sighs", "sigh", "beep", "clicking",
        "музыка", "аплодисменты", "смех", "тишина", "шум", "неразборчиво",
        "вздох", "кашель", "щелчок",
    ]
    private static let parenPattern = try! NSRegularExpression(
        pattern: #"\((?:"# + knownParenMarkers.joined(separator: "|") + #")[^)\n]{0,20}\)"#,
        options: [.caseInsensitive])

    public static func stripArtifacts(from text: String) -> String {
        var result = text
        for regex in [bracketPattern, parenPattern] {
            let range = NSRange(result.startIndex..., in: result)
            result = regex.stringByReplacingMatches(in: result, range: range, withTemplate: " ")
        }
        result = result.replacingOccurrences(of: "♪", with: " ")
        return result
    }

    public static func normalizeWhitespace(_ text: String) -> String {
        let collapsed = text
            .components(separatedBy: .newlines)
            .map { $0.split(separator: " ", omittingEmptySubsequences: true).joined(separator: " ") }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
        return collapsed.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
