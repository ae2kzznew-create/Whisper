using System.ComponentModel;
using System.Runtime.InteropServices;
using System.Windows;
using System.Windows.Controls.Primitives;
using System.Windows.Interop;
using System.Windows.Media;
using System.Windows.Shapes;
using VoxLocal.Core.Models;
using VoxLocal.Core.Utilities;

namespace VoxLocal.App;

public partial class OverlayWindow : Window
{
    private const int GwlExstyle = -20;
    private const int WsExNoactivate = 0x08000000;
    private const int WsExToolwindow = 0x00000080;
    private const int BarCount = 14;

    private readonly DictationController _dictation;
    private readonly Rectangle[] _bars = new Rectangle[BarCount];

    private static readonly Brush DimBrush = MakeFrozen(Color.FromArgb(0x24, 0xFF, 0xFF, 0xFF));
    // Purple→pink brand gradient across the meter bars.
    private static readonly Brush[] LitBrushes = CreateLitBrushes();

    // Gradient chips behind the state glyph (brand look per state).
    private static readonly Brush RecordingChip = Chip(0xFF, 0x45, 0x5A, 0xFF, 0x8A, 0x4C);
    private static readonly Brush BusyChip = Chip(0x40, 0x9C, 0xFF, 0x5E, 0x5C, 0xE6);
    private static readonly Brush RefiningChip = Chip(0xA8, 0x55, 0xF7, 0xEC, 0x48, 0x98);
    private static readonly Brush InsertingChip = Chip(0x2D, 0xD4, 0xBF, 0x38, 0xBD, 0xF8);
    private static readonly Brush DoneChip = Chip(0x34, 0xD3, 0x99, 0x10, 0xB9, 0x81);
    private static readonly Brush ErrorChip = Chip(0xF9, 0x73, 0x16, 0xEF, 0x44, 0x44);
    private static readonly Brush IdleChip = Chip(0x6B, 0x67, 0x7E, 0x4A, 0x47, 0x58);

    public OverlayWindow(DictationController dictation)
    {
        InitializeComponent();
        _dictation = dictation;

        for (var i = 0; i < BarCount; i++)
        {
            var bar = new Rectangle
            {
                RadiusX = 2,
                RadiusY = 2,
                Margin = new Thickness(1.2, 0, 1.2, 0),
                Fill = DimBrush,
            };
            _bars[i] = bar;
            LevelMeter.Children.Add(bar);
        }

        // Never steal focus from the dictation target.
        SourceInitialized += (_, _) =>
        {
            var handle = new WindowInteropHelper(this).Handle;
            var style = NativeMethods.GetWindowLong(handle, GwlExstyle);
            NativeMethods.SetWindowLong(handle, GwlExstyle, style | WsExNoactivate | WsExToolwindow);
        };
        // isMovableByWindowBackground analogue.
        MouseLeftButtonDown += (_, _) => DragMove();

        _dictation.PropertyChanged += OnDictationChanged;
        Render();
    }

    public void PositionBottomCenter()
    {
        // NSScreen.visibleFrame → WorkArea; same 96 px offset from the bottom.
        var area = SystemParameters.WorkArea;
        Left = area.Left + (area.Width - Width) / 2;
        Top = area.Bottom - 72 - 96;
    }

    private void OnDictationChanged(object? sender, PropertyChangedEventArgs e)
    {
        if (e.PropertyName == nameof(DictationController.MicLevel))
        {
            RenderLevel(_dictation.MicLevel);
        }
        else
        {
            Render();
        }
    }

    private void Render()
    {
        var state = _dictation.State;
        TitleText.Text = L10n.T($"state.{StateKey(state)}");

        var (glyph, chip) = state switch
        {
            DictationState.Recording => ("\uE720", RecordingChip),               // mic.fill
            DictationState.Stopping or DictationState.Transcribing
                => ("\uE895", BusyChip),                                          // spinner
            DictationState.Refining => ("\uE945", RefiningChip),                 // wand.and.stars
            DictationState.Inserting => ("\uE70F", InsertingChip),               // text.insert
            DictationState.Completed => ("\uE73E", DoneChip),                    // checkmark
            DictationState.Cancelled => ("\uE711", IdleChip),                    // xmark
            DictationState.Error => ("\uE7BA", ErrorChip),                       // warning
            _ => ("\uE720", IdleChip),                                           // mic
        };
        StateGlyph.Text = glyph;
        GlyphChip.Background = chip;

        var recording = state == DictationState.Recording;
        LevelMeter.Visibility = recording ? Visibility.Visible : Visibility.Collapsed;

        var subtitle = _dictation.StatusMessage.Length > 0
            ? _dictation.StatusMessage
            : state is DictationState.Recording or DictationState.Transcribing or DictationState.Refining
                ? L10n.T("overlay.esc")
                : "";
        SubtitleText.Text = subtitle;
        SubtitleText.Visibility = !recording && subtitle.Length > 0 ? Visibility.Visible : Visibility.Collapsed;
    }

    private void RenderLevel(float level)
    {
        // Bar i lights up when level > i/14; lit bars use the purple→pink
        // brand gradient instead of the old green/orange traffic lights.
        for (var i = 0; i < BarCount; i++)
        {
            var threshold = (float)i / BarCount;
            _bars[i].Fill = level > threshold ? LitBrushes[i] : DimBrush;
        }
    }

    private static string StateKey(DictationState state)
    {
        var name = state.ToString();
        return char.ToLowerInvariant(name[0]) + name[1..];
    }

    private static Brush MakeFrozen(Color color)
    {
        var brush = new SolidColorBrush(color);
        brush.Freeze();
        return brush;
    }

    private static Brush Chip(byte r1, byte g1, byte b1, byte r2, byte g2, byte b2)
    {
        var brush = new LinearGradientBrush(
            Color.FromRgb(r1, g1, b1), Color.FromRgb(r2, g2, b2), 45);
        brush.Freeze();
        return brush;
    }

    private static Brush[] CreateLitBrushes()
    {
        var brushes = new Brush[BarCount];
        for (var i = 0; i < BarCount; i++)
        {
            var t = (float)i / (BarCount - 1);
            byte Lerp(byte a, byte b) => (byte)(a + (b - a) * t);
            brushes[i] = MakeFrozen(Color.FromRgb(Lerp(0xA8, 0xEC), Lerp(0x55, 0x48), Lerp(0xF7, 0x98)));
        }
        return brushes;
    }

    private static class NativeMethods
    {
        [DllImport("user32.dll")]
        public static extern int GetWindowLong(IntPtr hWnd, int nIndex);

        [DllImport("user32.dll")]
        public static extern int SetWindowLong(IntPtr hWnd, int nIndex, int dwNewValue);
    }
}
