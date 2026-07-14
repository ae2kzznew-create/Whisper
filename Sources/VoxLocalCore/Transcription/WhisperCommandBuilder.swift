import Foundation

/// Pure construction of whisper-cli argument lists (unit-tested).
public enum WhisperCommandBuilder {
    /// - Parameters:
    ///   - outputBase: path *without extension*; whisper-cli writes
    ///     `<outputBase>.json` because of `-oj`.
    public static func arguments(
        modelPath: String,
        audioPath: String,
        language: String,
        threads: Int,
        outputBase: String
    ) -> [String] {
        let clampedThreads = max(1, min(threads, 16))
        return [
            "-m", modelPath,
            "-f", audioPath,
            "-l", language,
            "-t", String(clampedThreads),
            "-oj",              // JSON output for robust parsing
            "-of", outputBase,  // output file base path
            "-np",              // no runtime prints on stdout
        ]
    }
}
