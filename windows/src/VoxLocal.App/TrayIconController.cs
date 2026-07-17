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
    private readonly Action _openHistory;
    private readonly Action _exit;

    public TrayIconController(
        DictationController dictation,
        ModelManager modelManager,
        Action openSettings,
        Action openHistory,
        Action exit)
    {
        _dictation = dictation;
        _modelManager = modelManager;
        _openSettings = openSettings;
        _openHistory = openHistory;
        _exit = exit;

        _icon = new NotifyIcon
        {
            Visible = true,
            ContextMenuStrip = new ContextMenuStrip(),
        };
        // Rebuild on every open so labels follow state and language changes
        // (menuNeedsUpdate analogue).
        _icon.ContextMenuStrip.Opening += (_, _) => RebuildMenu();
        // Wispr-Flow-style quick access: double-click opens the history.
        _icon.DoubleClick += (_, _) => _openHistory();
        UpdateIcon(DictationState.Idle);

        _dictation.StateChanged += UpdateIcon;
    }

    private void UpdateIcon(DictationState state)
    {
        // SF Symbols mic / mic.fill / waveform / mic.slash → own .ico assets
        // embedded in the executable (or drawn in code when assets are absent).
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
        menu.Items.Add(new ToolStripMenuItem(L10n.T("menu.history"), null, (_, _) => _openHistory()));
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

/// <summary>
/// Loads embedded .ico resources (cached). When the optional .ico assets were
/// not bundled into the build, modern colorful glyphs are drawn in code
/// (GDI+): a gradient badge with a white symbol, matching the Voice2kzz brand.
/// </summary>
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
        using var stream = assembly.GetManifestResourceStream($"VoxLocal.App.Icons.{name}");
        var icon = stream is not null ? new System.Drawing.Icon(stream) : Draw(name);
        Cache[name] = icon;
        return icon;
    }

    /// <summary>Colorful stand-ins for mic / mic.fill / waveform / mic.slash:
    /// a round gradient badge with a white glyph on top.</summary>
    private static System.Drawing.Icon Draw(string name)
    {
        const int size = 32;
        using var bitmap = new System.Drawing.Bitmap(size, size);
        using (var g = System.Drawing.Graphics.FromImage(bitmap))
        {
            g.SmoothingMode = System.Drawing.Drawing2D.SmoothingMode.AntiAlias;
            g.Clear(System.Drawing.Color.Transparent);

            // Brand gradients: purple→pink (idle), red→orange (recording),
            // blue→violet (busy), gray (error).
            System.Drawing.Color c1, c2;
            if (name.StartsWith("mic-fill", StringComparison.OrdinalIgnoreCase))
            {
                c1 = System.Drawing.Color.FromArgb(255, 69, 90);
                c2 = System.Drawing.Color.FromArgb(255, 138, 76);
            }
            else if (name.StartsWith("waveform", StringComparison.OrdinalIgnoreCase))
            {
                c1 = System.Drawing.Color.FromArgb(64, 156, 255);
                c2 = System.Drawing.Color.FromArgb(94, 92, 230);
            }
            else if (name.StartsWith("mic-slash", StringComparison.OrdinalIgnoreCase))
            {
                c1 = System.Drawing.Color.FromArgb(126, 126, 134);
                c2 = System.Drawing.Color.FromArgb(84, 84, 94);
            }
            else
            {
                c1 = System.Drawing.Color.FromArgb(168, 85, 247);
                c2 = System.Drawing.Color.FromArgb(236, 72, 153);
            }

            using (var badge = new System.Drawing.Drawing2D.LinearGradientBrush(
                new System.Drawing.Rectangle(0, 0, size, size), c1, c2, 45f))
            {
                g.FillEllipse(badge, 1, 1, size - 2, size - 2);
            }

            var white = System.Drawing.Color.White;
            using var pen = new System.Drawing.Pen(white, 2f)
            {
                StartCap = System.Drawing.Drawing2D.LineCap.Round,
                EndCap = System.Drawing.Drawing2D.LineCap.Round,
            };
            using var brush = new System.Drawing.SolidBrush(white);

            if (name.StartsWith("waveform", StringComparison.OrdinalIgnoreCase))
            {
                // Vertical bars of varying height (SF Symbols "waveform").
                int[] heights = { 8, 14, 18, 10, 14, 6 };
                for (var i = 0; i < heights.Length; i++)
                {
                    var x = 7f + i * 3.4f;
                    var h = heights[i];
                    g.FillRectangle(brush, x, (size - h) / 2f, 2.2f, h);
                }
            }
            else
            {
                // Microphone: capsule + cradle + stem + base.
                using (var capsule = RoundedRect(13, 7, 6, 10, 3))
                {
                    if (name.StartsWith("mic-fill", StringComparison.OrdinalIgnoreCase))
                    {
                        g.FillPath(brush, capsule);
                    }
                    else
                    {
                        g.DrawPath(pen, capsule);
                    }
                }
                g.DrawArc(pen, 10, 11, 12, 10, 0, 180);
                g.DrawLine(pen, 16, 21, 16, 24);
                g.DrawLine(pen, 12, 25, 20, 25);

                if (name.StartsWith("mic-slash", StringComparison.OrdinalIgnoreCase))
                {
                    g.DrawLine(pen, 9, 8, 23, 25);
                }
            }
        }

        var handle = bitmap.GetHicon();
        try
        {
            using var native = System.Drawing.Icon.FromHandle(handle);
            // Clone detaches the icon from the unmanaged handle so it can be destroyed.
            return (System.Drawing.Icon)native.Clone();
        }
        finally
        {
            _ = DestroyIcon(handle);
        }
    }

    private static System.Drawing.Drawing2D.GraphicsPath RoundedRect(int x, int y, int width, int height, int radius)
    {
        var d = radius * 2;
        var path = new System.Drawing.Drawing2D.GraphicsPath();
        path.AddArc(x, y, d, d, 180, 90);
        path.AddArc(x + width - d, y, d, d, 270, 90);
        path.AddArc(x + width - d, y + height - d, d, d, 0, 90);
        path.AddArc(x, y + height - d, d, d, 90, 90);
        path.CloseFigure();
        return path;
    }

    [System.Runtime.InteropServices.DllImport("user32.dll", SetLastError = true)]
    private static extern bool DestroyIcon(IntPtr handle);
}
