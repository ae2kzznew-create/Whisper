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
    private const int BarCount = 12;

    private readonly DictationController _dictation;
    private readonly Rectangle[] _bars = new Rectangle[BarCount];

    private static readonly Brush DimBrush = new SolidColorBrush(Color.FromArgb(0x26, 0xFF, 0xFF, 0xFF));
    private static readonly Brush GreenBrush = Brushes.MediumSeaGreen;
    private static readonly Brush OrangeBrush = Brushes.Orange;

    public OverlayWindow(DictationController dictation)
    {
        InitializeComponent();
        _dictation = dictation;

        for (var i = 0; i < BarCount; i++)
        {
            var bar = new Rectangle { RadiusX = 1, RadiusY = 1, Margin = new Thickness(1, 0, 1, 0), Fill = DimBrush };
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

        var (glyph, brush) = state switch
        {
            DictationState.Recording => ("\uE720", Brushes.IndianRed),           // mic.fill
            DictationState.Stopping or DictationState.Transcribing
                => ("\uE895", (Brush)Brushes.LightGray),                          // spinner
            DictationState.Refining => ("\uE945", Brushes.MediumPurple),         // wand.and.stars
            DictationState.Inserting => ("\uE70F", Brushes.CornflowerBlue),      // text.insert
            DictationState.Completed => ("\uE73E", Brushes.MediumSeaGreen),      // checkmark
            DictationState.Cancelled => ("\uE711", Brushes.Gray),                // xmark
            DictationState.Error => ("\uE7BA", Brushes.Orange),                  // warning
            _ => ("\uE720", Brushes.Gray),                                       // mic
        };
        StateGlyph.Text = glyph;
        StateGlyph.Foreground = brush;

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
        // Same thresholds as the SwiftUI LevelMeter: bar i lights up when
        // level > i/12; the top 20% turns orange.
        for (var i = 0; i < BarCount; i++)
        {
            var threshold = (float)i / BarCount;
            _bars[i].Fill = level > threshold
                ? (threshold > 0.8f ? OrangeBrush : GreenBrush)
                : DimBrush;
        }
    }

    private static string StateKey(DictationState state)
    {
        var name = state.ToString();
        return char.ToLowerInvariant(name[0]) + name[1..];
    }

    private static class NativeMethods
    {
        [DllImport("user32.dll")]
        public static extern int GetWindowLong(IntPtr hWnd, int nIndex);

        [DllImport("user32.dll")]
        public static extern int SetWindowLong(IntPtr hWnd, int nIndex, int dwNewValue);
    }
}
