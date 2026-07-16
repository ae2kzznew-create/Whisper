using VoxLocal.Core.Models;

namespace VoxLocal.App;

/// <summary>
/// Floating dictation indicator. A borderless, non-activating, topmost
/// window keeps keyboard focus in the user's current application — the
/// NSPanel(.nonactivatingPanel) analogue.
/// </summary>
public sealed class OverlayWindowController
{
    private OverlayWindow? _window;
    private readonly DictationController _dictation;

    public OverlayWindowController(DictationController dictation)
    {
        _dictation = dictation;
        dictation.StateChanged += Handle;
    }

    private void Handle(DictationState state)
    {
        switch (state)
        {
            case DictationState.Idle:
                Hide();
                break;
            default:
                // completed/cancelled/error stay briefly; the controller
                // resets to idle which hides the overlay.
                Show();
                break;
        }
    }

    public void Show()
    {
        _window ??= new OverlayWindow(_dictation);
        if (!_window.IsVisible)
        {
            _window.PositionBottomCenter();
            // ShowActivated=false + WS_EX_NOACTIVATE: the target app keeps
            // focus (orderFrontRegardless analogue).
            _window.Show();
        }
    }

    public void Hide() => _window?.Hide();
}
