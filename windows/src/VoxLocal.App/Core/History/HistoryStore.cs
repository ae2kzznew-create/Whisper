using System.Text.Json;
using VoxLocal.Core.Utilities;

namespace VoxLocal.Core.History;

/// <summary>One saved dictation result.</summary>
public sealed record HistoryEntry(DateTime TimestampUtc, string Text);

/// <summary>
/// Wispr-Flow-style dictation history: the most recent results are kept
/// locally in %APPDATA%\VoxLocal\history.json so the user can recover the
/// text even when insertion into the target app failed. The file never
/// leaves the machine and can be cleared from the history window.
/// </summary>
public sealed class HistoryStore
{
    public const int MaxEntries = 50;

    private readonly object _lock = new();
    private readonly string _path;
    private readonly List<HistoryEntry> _entries;

    /// <summary>Raised after Add/Clear. May fire on any thread.</summary>
    public event Action? Changed;

    public HistoryStore(string? path = null)
    {
        _path = path ?? Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData),
            "VoxLocal", "history.json");
        _entries = Load(_path);
    }

    public IReadOnlyList<HistoryEntry> Entries
    {
        get
        {
            lock (_lock)
            {
                return _entries.ToList();
            }
        }
    }

    public void Add(string text)
    {
        if (string.IsNullOrWhiteSpace(text))
        {
            return;
        }
        lock (_lock)
        {
            _entries.Insert(0, new HistoryEntry(DateTime.UtcNow, text));
            if (_entries.Count > MaxEntries)
            {
                _entries.RemoveRange(MaxEntries, _entries.Count - MaxEntries);
            }
            Save();
        }
        Changed?.Invoke();
    }

    public void Clear()
    {
        lock (_lock)
        {
            _entries.Clear();
            try
            {
                File.Delete(_path);
            }
            catch (Exception e)
            {
                Log.Shared.Error($"history clear failed: {e.Message}");
            }
        }
        Changed?.Invoke();
    }

    private static List<HistoryEntry> Load(string path)
    {
        try
        {
            if (!File.Exists(path))
            {
                return new List<HistoryEntry>();
            }
            var entries = JsonSerializer.Deserialize<List<HistoryEntry>>(File.ReadAllText(path));
            return entries ?? new List<HistoryEntry>();
        }
        catch (Exception e)
        {
            Log.Shared.Error($"history load failed: {e.Message}");
            return new List<HistoryEntry>();
        }
    }

    private void Save()
    {
        try
        {
            Directory.CreateDirectory(Path.GetDirectoryName(_path)!);
            File.WriteAllText(_path, JsonSerializer.Serialize(_entries));
        }
        catch (Exception e)
        {
            Log.Shared.Error($"history save failed: {e.Message}");
        }
    }
}
