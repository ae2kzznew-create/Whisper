import Foundation

/// A known downloadable ggml Whisper model. Sizes are approximate and shown
/// to the user before any download starts.
public struct WhisperModelInfo: Identifiable, Hashable, Sendable {
    public let name: String
    public let approxMB: Int
    public let multilingual: Bool

    public var id: String { name }
    public var fileName: String { "ggml-\(name).bin" }

    /// Official upstream source — the same Hugging Face repository used by
    /// whisper.cpp's own `download-ggml-model.sh`.
    public var downloadURL: URL {
        URL(string: "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/\(fileName)")!
    }

    public var sizeLabel: String {
        approxMB >= 1000
            ? String(format: "%.1f GB", Double(approxMB) / 1000)
            : "\(approxMB) MB"
    }
}

public enum WhisperModelCatalog {
    public static let models: [WhisperModelInfo] = [
        WhisperModelInfo(name: "tiny", approxMB: 78, multilingual: true),
        WhisperModelInfo(name: "tiny.en", approxMB: 78, multilingual: false),
        WhisperModelInfo(name: "base", approxMB: 148, multilingual: true),
        WhisperModelInfo(name: "base.en", approxMB: 148, multilingual: false),
        WhisperModelInfo(name: "small", approxMB: 488, multilingual: true),
        WhisperModelInfo(name: "small.en", approxMB: 488, multilingual: false),
        WhisperModelInfo(name: "medium", approxMB: 1530, multilingual: true),
        WhisperModelInfo(name: "large-v3", approxMB: 3100, multilingual: true),
        WhisperModelInfo(name: "large-v3-turbo", approxMB: 1620, multilingual: true),
    ]

    public static let defaultModelName = "base"

    public static func info(for name: String) -> WhisperModelInfo? {
        models.first { $0.name == name }
    }
}
