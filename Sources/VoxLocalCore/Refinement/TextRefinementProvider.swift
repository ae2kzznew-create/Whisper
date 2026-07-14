import Foundation

public enum RefinementPreset: String, CaseIterable, Sendable {
    /// No changes at all — refinement short-circuits.
    case rawTranscript
    /// Punctuation, capitalization, filler-word removal.
    case cleanDictation
    /// Same as clean, plus tightening of wordy phrases.
    case concise
    /// Clean plus a neutral business tone.
    case businessStyle
    /// Fix only obvious recognition errors; keep the spoken wording.
    case preserveSpokenWording
    /// User-supplied instruction appended to the strict base rules.
    case custom

    public var titleKey: String { "refine.preset.\(rawValue)" }
}

public struct RefinementContext: Sendable {
    /// BCP-47-ish language code detected or selected ("ru", "en", nil = unknown).
    public let language: String?
    public let preset: RefinementPreset
    public let customInstruction: String?
    public let timeout: TimeInterval

    public init(language: String?, preset: RefinementPreset, customInstruction: String? = nil, timeout: TimeInterval = 20) {
        self.language = language
        self.preset = preset
        self.customInstruction = customInstruction
        self.timeout = timeout
    }
}

public enum RefinementAvailability: Equatable, Sendable {
    case available
    case serverUnreachable(String)
    case modelMissing(available: [String])
}

public enum RefinementError: Error, Equatable {
    case unavailable(String)
    case timeout
    case invalidResponse(String)
    case nonLocalEndpoint(String)
}

public protocol TextRefinementProvider: Sendable {
    func refine(_ transcript: String, context: RefinementContext) async throws -> String
    func checkAvailability() async -> RefinementAvailability
}

/// Pass-through provider used when refinement is disabled.
public struct NoRefinementProvider: TextRefinementProvider {
    public init() {}

    public func refine(_ transcript: String, context: RefinementContext) async throws -> String {
        transcript
    }

    public func checkAvailability() async -> RefinementAvailability {
        .available
    }
}
