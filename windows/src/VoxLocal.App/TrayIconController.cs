using System.Diagnostics;
using System.Windows.Forms;
using VoxLocal.Core.Models;
using VoxLocal.Core.Transcription;
using VoxLocal.Core.Utilities;

namespace VoxLocal.App;

/// <summary>
/// Tray presence (NSStatusItem analogue): icon reflecting the dictation
/// state plus the command menu required by the product spec.
/// </summary>
public sealed class TrayIconController : IDisposable
{
    private readonly NotifyIcon _icon;
    private readonly DictationController _dictation;
    private readonly ModelManager _modelManager;
    private readonly Action _openSettings;
    private readonly Action _exit;

    public TrayIconController(
        DictationController dictation,
        ModelManager modelManager,
        Action openSettings,
        Action exit)
    {
        _dictation = dictation;
        _modelManager = modelManager;
        _openSettings = openSettings;
        _exit = exit;

        _icon = new NotifyIcon
        {
            Visible = true,
            ContextMenuStrip = new ContextMenuStrip(),
        };
        // Rebuild on every open so labels follow state and language changes
        // (menuNeedsUpdate analogue).
        _icon.ContextMenuStrip.Opening += (_, _) => RebuildMenu();
        UpdateIcon(DictationState.Idle);

        _dictation.StateChanged += UpdateIcon;
    }

    private void UpdateIcon(DictationState state)
    {
        // SF Symbols mic / mic.fill / waveform / mic.slash → own .ico assets
        // embedded in the executable.
        var resource = state switch
        {
            DictationState.Recording => "mic-fill.ico",
            DictationState.Transcribing or DictationState.Stopping
                or DictationState.Refining or DictationState.Inserting => "waveform.ico",
            DictationState.Error => "mic-slash.ico",
            _ => "mic.ico",
        };
        _icon.Icon = TrayIcons.Load(resource);
        _icon.Text = $"{L10n.T("app.name")} — {L10n.T($"state.{StateKey(state)}")}";
    }

    /// <summary>DictationState.RawTranscript-style keys: "state.recording" etc.</summary>
    private static string StateKey(DictationState state)
    {
        var name = state.ToString();
        return char.ToLowerInvariant(name[0]) + name[1..];
    }

    private void RebuildMenu()
    {
        var menu = _icon.ContextMenuStrip!;
        menu.Items.Clear();
        var state = _dictation.State;

        menu.Items.Add(new ToolStripMenuItem(
            L10n.T("menu.status", L10n.T($"state.{StateKey(state)}")))
        {
            Enabled = false,
        });
        if (_dictation.StatusMessage.Length > 0)
        {
            menu.Items.Add(new ToolStripMenuItem(_dictation.StatusMessage) { Enabled = false });
        }
        menu.Items.Add(new ToolStripSeparator());

        menu.Items.Add(new ToolStripMenuItem(L10n.T("menu.start"), null, (_, _) => _dictation.StartDictation())
        {
            Enabled = state == DictationState.Idle,
        });
        menu.Items.Add(new ToolStripMenuItem(L10n.T("menu.stop"), null, (_, _) => _dictation.StopAndProcess())
        {
            Enabled = state == DictationState.Recording,
        });
        var cancellable = state is DictationState.Preparing or DictationState.Recording
            or DictationState.Stopping or DictationState.Transcribing
            or DictationState.Refining or DictationState.Inserting;
        menu.Items.Add(new ToolStripMenuItem(L10n.T("menu.cancel"), null, (_, _) => _dictation.CancelDictation())
        {
            Enabled = cancellable,
        });

        menu.Items.Add(new ToolStripSeparator());
        menu.Items.Add(new ToolStripMenuItem(L10n.T("menu.settings"), null, (_, _) => _openSettings()));
        menu.Items.Add(new ToolStripMenuItem(L10n.T("menu.models"), null, (_, _) => OpenFolder(_modelManager.ModelsDirectory)));
        menu.Items.Add(new ToolStripMenuItem(L10n.T("menu.logs"), null, (_, _) => OpenFolder(Log.Shared.Directory)));
        menu.Items.Add(new ToolStripSeparator());
        menu.Items.Add(new ToolStripMenuItem(L10n.T("menu.quit"), null, (_, _) => _exit()));
    }

    /// <summary>NSWorkspace.shared.open(folder) → Explorer.</summary>
    private static void OpenFolder(string path) =>
        Process.Start(new ProcessStartInfo("explorer.exe", $"\"{path}\"") { UseShellExecute = true });

    public void Dispose()
    {
        _dictation.StateChanged -= UpdateIcon;
        _icon.Visible = false;
        _icon.Dispose();
    }
}

/// <summary>Loads embedded .ico resources (cached).</summary>
internal static class TrayIcons
{
    private static readonly Dictionary<string, System.Drawing.Icon> Cache = new();

    public static System.Drawing.Icon Load(string name)
    {
        if (Cache.TryGetValue(name, out var cached))
        {
            return cached;
        }
        var assembly = typeof(TrayIcons).Assembly;
        using var stream = assembly.GetManifestResourceStream($"VoxLocal.App.Icons.{name}")
            ?? throw new InvalidOperationException($"missing tray icon resource: {name}");
        var icon = new System.Drawing.Icon(stream);
        Cache[name] = icon;
        return icon;
    }
}
