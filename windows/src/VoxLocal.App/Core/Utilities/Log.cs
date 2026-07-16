using System.Collections.Concurrent;
using System.Text;

namespace VoxLocal.Core.Utilities;

public enum LogLevel
{
    Off = 0,
    Error = 1,
    Info = 2,
    Debug = 3,
}

/// <summary>
/// Bounded local file logger. Privacy rules enforced by convention at every
/// call site: no raw audio, no transcript contents, no clipboard contents —
/// only lengths, states and redacted paths. Rotates at maxBytes, keeping
/// one previous generation, so total disk use stays bounded.
/// The serial DispatchQueue is replaced by one background worker thread.
/// </summary>
public sealed class Log : IDisposable
{
    public static Log Shared { get; } = new();

    public LogLevel Level { get; set; } = LogLevel.Info;
    public string Directory { get; }
    public string FilePath { get; }

    private readonly long _maxBytes;
    private readonly BlockingCollection<string> _queue = new();
    private readonly Thread _worker;
    private readonly ManualResetEventSlim _drained = new(true);

    public Log(string? directory = null, long maxBytes = 1_000_000)
    {
        _maxBytes = maxBytes;
        Directory = directory ?? Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
            "VoxLocal", "Logs");
        FilePath = Path.Combine(Directory, "voxlocal.log");
        System.IO.Directory.CreateDirectory(Directory);
        _worker = new Thread(Drain) { IsBackground = true, Name = "voxlocal.log" };
        _worker.Start();
    }

    public void Error(string message) => Write(LogLevel.Error, message);
    public void Info(string message) => Write(LogLevel.Info, message);
    public void Debug(string message) => Write(LogLevel.Debug, message);

    private void Write(LogLevel level, string message)
    {
        if (Level == LogLevel.Off || Level < level)
        {
            return;
        }
        var label = level.ToString().ToUpperInvariant();
        var line = $"{DateTime.Now:yyyy-MM-dd HH:mm:ss.fff} [{label}] {message}";
        _drained.Reset();
        _queue.Add(line);
    }

    private void Drain()
    {
        foreach (var line in _queue.GetConsumingEnumerable())
        {
            try
            {
                RotateIfNeeded();
                File.AppendAllText(FilePath, line + Environment.NewLine, Encoding.UTF8);
            }
            catch (IOException)
            {
                // logging must never crash the app
            }
            if (_queue.Count == 0)
            {
                _drained.Set();
            }
        }
    }

    private void RotateIfNeeded()
    {
        var info = new FileInfo(FilePath);
        if (!info.Exists || info.Length <= _maxBytes)
        {
            return;
        }
        var previous = Path.Combine(Directory, "voxlocal.log.1");
        File.Delete(previous);
        File.Move(FilePath, previous);
    }

    /// <summary>Flushes pending writes (queue.sync analogue); used by tests.</summary>
    public void Sync() => _drained.Wait(TimeSpan.FromSeconds(5));

    public void Dispose()
    {
        _queue.CompleteAdding();
        _worker.Join(TimeSpan.FromSeconds(2));
    }
}
