using NAudio.CoreAudioApi;
using NAudio.Wave;
using NAudio.Wave.SampleProviders;
using System.Runtime.InteropServices;
using VoxLocal.Core.Models;
using VoxLocal.Core.Utilities;

namespace VoxLocal.Core.Audio;

public sealed record RecordingResult(string AudioPath, TimeSpan Duration, float PeakLevel);

/// <summary>
/// Captures microphone audio with WASAPI (NAudio), converts it to
/// 16 kHz mono PCM16 on the fly and writes a temporary WAV file suitable
/// for whisper.cpp. The temporary file lives only for the duration of one
/// dictation session; callers must delete it via the returned path (the
/// DictationController does) and Cancel() deletes it immediately.
/// </summary>
public sealed class AudioRecorder
{
    public Action<float>? LevelHandler { get; set; }
    /// <summary>Called when the input device disappears mid-recording.</summary>
    public Action? DeviceInterruptionHandler { get; set; }

    // _lock guards writer/pipeline/peak: OnDataAvailable runs on the WASAPI
    // capture thread while Start/Stop/Cancel run on the UI thread.
    private readonly object _lock = new();
    private WasapiCapture? _capture;
    private BufferedWaveProvider? _sourceBuffer;
    private IWaveProvider? _pcm16Pipeline;
    private WavWriter? _writer;
    private float _peak;
    private bool _stopping;
    private readonly byte[] _drainBuffer = new byte[16000 * 2]; // 1 s of PCM16 mono

    public bool IsRecording { get; private set; }

    public void Start(string? deviceId)
    {
        if (IsRecording)
        {
            throw new VoxLocalException(new VoxLocalError.RecordingFailed("already recording"));
        }
        lock (_lock) { _peak = 0; }

        WasapiCapture capture;
        try
        {
            var device = deviceId is null ? null : AudioDeviceFinder.Find(deviceId);
            capture = device is null ? new WasapiCapture() : new WasapiCapture(device);
        }
        catch (Exception)
        {
            throw new VoxLocalException(new VoxLocalError.MicrophoneUnavailable());
        }

        var format = capture.WaveFormat;
        if (format.SampleRate <= 0 || format.Channels <= 0)
        {
            capture.Dispose();
            throw new VoxLocalException(new VoxLocalError.MicrophoneUnavailable());
        }

        var tempPath = Path.Combine(Path.GetTempPath(), $"voxlocal-{Guid.NewGuid()}.wav");
        var writer = new WavWriter(tempPath, 16000);

        // Conversion pipeline: source buffer → mono → resample to 16 kHz → PCM16.
        var sourceBuffer = new BufferedWaveProvider(format)
        {
            DiscardOnBufferOverflow = true,
            ReadFully = false,
        };
        ISampleProvider samples = sourceBuffer.ToSampleProvider();
        if (format.Channels > 1)
        {
            // Take channel 0; microphones are effectively mono sources.
            samples = new MultiplexingSampleProvider(new[] { samples }, 1);
        }
        var resampled = new WdlResamplingSampleProvider(samples, 16000);
        var pcm16 = resampled.ToWaveProvider16();

        capture.DataAvailable += OnDataAvailable;
        capture.RecordingStopped += OnRecordingStopped;

        lock (_lock)
        {
            _capture = capture;
            _sourceBuffer = sourceBuffer;
            _pcm16Pipeline = pcm16;
            _writer = writer;
            _stopping = false;
        }

        try
        {
            capture.StartRecording();
        }
        catch (Exception ex)
        {
            CleanupCapture();
            lock (_lock)
            {
                _writer = null;
                _sourceBuffer = null;
                _pcm16Pipeline = null;
            }
            writer.CancelAndDelete();
            throw new VoxLocalException(new VoxLocalError.RecordingFailed(ex.Message));
        }
        IsRecording = true;
        Log.Shared.Info($"recording started (input: {format.SampleRate} Hz, {format.Channels} ch)");
    }

    private void OnDataAvailable(object? sender, WaveInEventArgs e)
    {
        // Entire body under the lock: Stop()/Cancel() null out the writer and
        // pipeline under the same lock, so no append can race Complete().
        lock (_lock)
        {
            if (_writer is null || _sourceBuffer is null || _pcm16Pipeline is null || _capture is null)
            {
                return;
            }

            // Level metering on the raw input buffer.
            var level = ComputeLevel(e.Buffer, e.BytesRecorded, _capture.WaveFormat);
            _peak = Math.Max(_peak, level);
            if (LevelHandler is { } handler)
            {
                System.Windows.Application.Current?.Dispatcher.BeginInvoke(() => handler(level));
            }

            _sourceBuffer.AddSamples(e.Buffer, 0, e.BytesRecorded);

            // Drain everything currently convertible into the WAV file.
            int read;
            while ((read = _pcm16Pipeline.Read(_drainBuffer, 0, _drainBuffer.Length)) > 0)
            {
                _writer.Append(_drainBuffer.AsSpan(0, read));
            }
        }
    }

    /// <summary>
    /// Perceptual meter level: sampled RMS mapped through a decibel curve
    /// (-50 dB … -8 dB → 0 … 1). Normal conversational speech lands around
    /// the middle of the meter instead of barely lighting two bars — the old
    /// linear "RMS × 18" heuristic required shouting to move the meter.
    /// </summary>
    private static float ComputeLevel(byte[] buffer, int bytes, WaveFormat format)
    {
        var step = 16 * format.Channels; // sample every 16th frame; enough for a meter
        float rms;
        if (format.Encoding == WaveFormatEncoding.IeeeFloat && bytes >= 4)
        {
            var floats = MemoryMarshal.Cast<byte, float>(buffer.AsSpan(0, bytes));
            float sum = 0;
            var counted = 0;
            for (var i = 0; i < floats.Length; i += step)
            {
                sum += floats[i] * floats[i];
                counted++;
            }
            rms = MathF.Sqrt(sum / Math.Max(1, counted));
        }
        else if (format.Encoding == WaveFormatEncoding.Pcm && format.BitsPerSample == 16 && bytes >= 2)
        {
            var shorts = MemoryMarshal.Cast<byte, short>(buffer.AsSpan(0, bytes));
            float sum = 0;
            var counted = 0;
            for (var i = 0; i < shorts.Length; i += step)
            {
                var v = shorts[i] / 32768f;
                sum += v * v;
                counted++;
            }
            rms = MathF.Sqrt(sum / Math.Max(1, counted));
        }
        else
        {
            return 0;
        }

        if (rms <= 0.0001f)
        {
            return 0;
        }
        var db = 20f * MathF.Log10(rms);
        return Math.Clamp((db + 50f) / 42f, 0f, 1f);
    }

    private void OnRecordingStopped(object? sender, StoppedEventArgs e)
    {
        if (e.Exception is not null && IsRecording && !_stopping)
        {
            Log.Shared.Info("audio capture stopped unexpectedly mid-recording (device change/disconnect)");
            DeviceInterruptionHandler?.Invoke();
        }
    }

    /// <summary>
    /// Stops the capture, finalizes the WAV and returns it. Throws
    /// EmptyRecording (and deletes the file) when almost nothing was
    /// captured — e.g. a too-short press or a dead microphone.
    /// </summary>
    public RecordingResult Stop()
    {
        if (!IsRecording)
        {
            throw new VoxLocalException(new VoxLocalError.RecordingFailed("not recording"));
        }
        lock (_lock) { _stopping = true; }
        CleanupCapture();
        IsRecording = false;

        WavWriter? writer;
        float capturedPeak;
        lock (_lock)
        {
            writer = _writer;
            _writer = null;
            _sourceBuffer = null;
            _pcm16Pipeline = null;
            capturedPeak = _peak;
        }
        if (writer is null)
        {
            throw new VoxLocalException(new VoxLocalError.RecordingFailed("not recording"));
        }

        var duration = writer.Duration;
        // Below ~0.35 s or near-silence there is nothing Whisper can use.
        if (duration.TotalSeconds < 0.35 || capturedPeak < 0.005f)
        {
            writer.CancelAndDelete();
            Log.Shared.Info($"recording rejected as empty (duration {duration.TotalSeconds:F2}s, peak {capturedPeak:F3})");
            throw new VoxLocalException(new VoxLocalError.EmptyRecording());
        }
        writer.Complete();
        Log.Shared.Info($"recording stopped ({duration.TotalSeconds:F2}s)");
        return new RecordingResult(writer.Path, duration, capturedPeak);
    }

    /// <summary>Stops immediately and deletes the temporary audio.</summary>
    public void Cancel()
    {
        WavWriter? writer;
        lock (_lock)
        {
            _stopping = true;
            writer = _writer;
            _writer = null;
            _sourceBuffer = null;
            _pcm16Pipeline = null;
        }
        if (!IsRecording && writer is null) return;
        CleanupCapture();
        IsRecording = false;
        writer?.CancelAndDelete();
        Log.Shared.Info("recording cancelled; temp audio deleted");
    }

    private void CleanupCapture()
    {
        WasapiCapture? capture;
        lock (_lock)
        {
            capture = _capture;
            _capture = null;
        }
        if (capture is null) return;
        capture.DataAvailable -= OnDataAvailable;
        capture.RecordingStopped -= OnRecordingStopped;
        try { capture.StopRecording(); } catch { /* not started */ }
        capture.Dispose();
    }
}

/// <summary>WASAPI device lookups for input-device selection in Settings.</summary>
public static class AudioDeviceFinder
{
    public sealed record Device(string Id, string Name);

    public static IReadOnlyList<Device> InputDevices()
    {
        using var enumerator = new MMDeviceEnumerator();
        var devices = new List<Device>();
        foreach (var device in enumerator.EnumerateAudioEndPoints(DataFlow.Capture, DeviceState.Active))
        {
            using (device)
            {
                devices.Add(new Device(device.ID, device.FriendlyName));
            }
        }
        return devices;
    }

    internal static MMDevice? Find(string id)
    {
        using var enumerator = new MMDeviceEnumerator();
        try
        {
            var device = enumerator.GetDevice(id);
            return device is { State: DeviceState.Active } ? device : null;
        }
        catch
        {
            return null;
        }
    }
}
