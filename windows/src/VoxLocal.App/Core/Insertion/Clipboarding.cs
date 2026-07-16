using System.Runtime.InteropServices;
using System.Windows;

namespace VoxLocal.Core.Insertion;

/// <summary>Snapshot of the clipboard: format name → data.</summary>
public sealed record ClipboardSnapshot(IReadOnlyDictionary<string, object> Formats)
{
    public bool IsEmpty => Formats.Count == 0;
}

/// <summary>
/// Abstraction over the Windows clipboard so save/restore logic is
/// unit-testable without touching the real system clipboard. ChangeCount
/// maps to Win32 GetClipboardSequenceNumber — the same "did anyone else
/// write?" signal as NSPasteboard.changeCount on macOS.
/// </summary>
public interface IClipboard
{
    uint ChangeCount { get; }
    ClipboardSnapshot Snapshot();
    /// <summary>Writes a plain string; returns the resulting ChangeCount.</summary>
    uint WriteString(string text);
    /// <summary>Restores previously snapshotted content; returns the resulting ChangeCount.</summary>
    uint Restore(ClipboardSnapshot snapshot);
}

public sealed class SystemClipboard : IClipboard
{
    [DllImport("user32.dll")]
    private static extern uint GetClipboardSequenceNumber();

    public uint ChangeCount => GetClipboardSequenceNumber();

    public ClipboardSnapshot Snapshot()
    {
        var formats = new Dictionary<string, object>();
        try
        {
            if (Clipboard.GetDataObject() is { } data)
            {
                foreach (var format in data.GetFormats(autoConvert: false))
                {
                    try
                    {
                        if (data.GetData(format, autoConvert: false) is { } value)
                        {
                            formats[format] = value;
                        }
                    }
                    catch (COMException)
                    {
                        // Skip formats the source app cannot render right now.
                    }
                }
            }
        }
        catch (COMException)
        {
            // Clipboard busy — treat as empty; restore will then be skipped.
        }
        return new ClipboardSnapshot(formats);
    }

    public uint WriteString(string text)
    {
        Clipboard.SetDataObject(new DataObject(DataFormats.UnicodeText, text), copy: true);
        return ChangeCount;
    }

    public uint Restore(ClipboardSnapshot snapshot)
    {
        if (snapshot.IsEmpty)
        {
            return ChangeCount;
        }
        var data = new DataObject();
        foreach (var (format, value) in snapshot.Formats)
        {
            data.SetData(format, value, autoConvert: false);
        }
        try
        {
            Clipboard.SetDataObject(data, copy: true);
        }
        catch (COMException)
        {
            // Best effort — same as the macOS version.
        }
        return ChangeCount;
    }
}

/// <summary>
/// Decides whether the previous clipboard contents may be restored after a
/// synthetic paste. Pure logic, unit-tested: restore only when nobody else
/// has written to the clipboard since our own write.
/// </summary>
public static class ClipboardRestorePolicy
{
    public static bool ShouldRestore(
        uint changeCountAfterOurWrite,
        uint currentChangeCount,
        bool hadPreviousContent) =>
        hadPreviousContent && currentChangeCount == changeCountAfterOurWrite;
}
