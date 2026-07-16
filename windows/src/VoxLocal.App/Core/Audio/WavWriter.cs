using System.Runtime.InteropServices;

namespace VoxLocal.Core.Audio;

/// <summary>
/// Incrementally writes a mono 16-bit PCM WAV file (RIFF little-endian).
/// The header is finalized with correct chunk sizes on Complete().
/// </summary>
public sealed class WavWriter
{
    public string Path { get; }
    public uint SampleRate { get; }
    public ulong SamplesWritten { get; private set; }

    private readonly FileStream _stream;
    private const int HeaderSize = 44;

    public WavWriter(string path, uint sampleRate = 16000)
    {
        Path = path;
        SampleRate = sampleRate;
        _stream = new FileStream(path, FileMode.Create, FileAccess.Write, FileShare.None);
        // Placeholder header; sizes patched in Complete().
        _stream.Write(Header(sampleRate, 0));
    }

    public void Append(ReadOnlySpan<short> samples)
    {
        if (samples.IsEmpty) return;
        _stream.Write(MemoryMarshal.AsBytes(samples));
        SamplesWritten += (ulong)samples.Length;
    }

    /// <summary>Appends raw little-endian PCM16 bytes (must be an even count).</summary>
    public void Append(ReadOnlySpan<byte> pcm16Bytes)
    {
        if (pcm16Bytes.IsEmpty) return;
        _stream.Write(pcm16Bytes);
        SamplesWritten += (ulong)(pcm16Bytes.Length / 2);
    }

    public TimeSpan Duration => TimeSpan.FromSeconds((double)SamplesWritten / SampleRate);

    /// <summary>Patches RIFF/data chunk sizes and closes the file.</summary>
    public void Complete()
    {
        var dataBytes = (uint)Math.Min(SamplesWritten * 2, uint.MaxValue);
        _stream.Seek(0, SeekOrigin.Begin);
        _stream.Write(Header(SampleRate, dataBytes));
        _stream.Dispose();
    }

    public void CancelAndDelete()
    {
        try { _stream.Dispose(); } catch { /* already closed */ }
        try { File.Delete(Path); } catch { /* best effort */ }
    }

    internal static byte[] Header(uint sampleRate, uint dataBytes)
    {
        const ushort channels = 1;
        const ushort bitsPerSample = 16;
        var byteRate = sampleRate * channels * (bitsPerSample / 8);

        using var ms = new MemoryStream(HeaderSize);
        using var w = new BinaryWriter(ms); // BinaryWriter writes little-endian
        w.Write("RIFF"u8);
        w.Write(36 + dataBytes);
        w.Write("WAVE"u8);
        w.Write("fmt "u8);
        w.Write(16u);
        w.Write((ushort)1); // PCM
        w.Write(channels);
        w.Write(sampleRate);
        w.Write((uint)byteRate);
        w.Write((ushort)(channels * bitsPerSample / 8)); // block align
        w.Write(bitsPerSample);
        w.Write("data"u8);
        w.Write(dataBytes);
        w.Flush();
        return ms.ToArray();
    }
}
