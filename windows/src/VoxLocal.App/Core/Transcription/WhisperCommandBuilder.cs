namespace VoxLocal.Core.Transcription;

/// <summary>Pure construction of whisper-cli argument lists (unit-tested).</summary>
public static class WhisperCommandBuilder
{
    /// <param name="outputBase">Path *without extension*; whisper-cli writes
    /// &lt;outputBase&gt;.json because of -oj.</param>
    public static IReadOnlyList<string> Arguments(
        string modelPath,
        string audioPath,
        string language,
        int threads,
        string outputBase)
    {
        var clampedThreads = Math.Clamp(threads, 1, 16);
        return new[]
        {
            "-m", modelPath,
            "-f", audioPath,
            "-l", language,
            "-t", clampedThreads.ToString(),
            "-oj",              // JSON output for robust parsing
            "-of", outputBase,  // output file base path
            "-np",              // no runtime prints on stdout
        };
    }
}
