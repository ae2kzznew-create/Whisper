using System.Runtime.InteropServices;
using System.Windows.Automation;
using VoxLocal.Core.Utilities;

namespace VoxLocal.Core.Insertion;

public abstract record InsertionOutcome
{
    public sealed record InsertedViaAutomation : InsertionOutcome;
    public sealed record PastedViaClipboard : InsertionOutcome;
    /// <summary>Text left on the clipboard; the user pastes manually. The key
    /// explains why (localized message shown in the overlay/menu).</summary>
    public sealed record ClipboardOnly(string ReasonKey) : InsertionOutcome;
}

public enum InsertionMode
{
    Auto,
    ClipboardOnly,
}

/// <summary>
/// Inserts the final text into the application that owned the foreground
/// window when dictation started. Strategy: UI Automation first, synthetic
/// Ctrl+V with clipboard save/restore second, plain clipboard as the last
/// resort. Unlike macOS, no user-granted permission is required. Must run
/// on the UI (STA) thread.
/// </summary>
public sealed class TextInserter
{
    private readonly IClipboard _clipboard;

    public TextInserter(IClipboard? clipboard = null)
    {
        _clipboard = clipboard ?? new SystemClipboard();
    }

    [DllImport("user32.dll")]
    private static extern IntPtr GetForegroundWindow();

    [DllImport("user32.dll")]
    private static extern bool SetForegroundWindow(IntPtr hWnd);

    [DllImport("user32.dll")]
    private static extern bool IsWindow(IntPtr hWnd);

    public async Task<InsertionOutcome> InsertAsync(
        string text,
        IntPtr targetWindow,
        InsertionMode mode,
        CancellationToken cancellationToken = default)
    {
        // A cancelled session must produce no side effects at all — no
        // clipboard writes, no synthetic keystrokes. The caller discards
        // the outcome after cancellation.
        if (cancellationToken.IsCancellationRequested)
        {
            return new InsertionOutcome.ClipboardOnly("insert.reason.pasteFailed");
        }
        if (mode == InsertionMode.ClipboardOnly)
        {
            _clipboard.WriteString(text);
            Log.Shared.Info($"insertion: clipboard-only mode (chars: {text.Length})");
            return new InsertionOutcome.ClipboardOnly("insert.reason.clipboardMode");
        }

        if (targetWindow == IntPtr.Zero || !IsWindow(targetWindow))
        {
            _clipboard.WriteString(text);
            Log.Shared.Info("insertion: target window gone, left text on clipboard");
            return new InsertionOutcome.ClipboardOnly("insert.reason.targetGone");
        }

        // Bring the original target back to front if focus moved during
        // transcription.
        if (GetForegroundWindow() != targetWindow)
        {
            SetForegroundWindow(targetWindow);
            for (var i = 0; i < 10; i++)
            {
                await Task.Delay(100, CancellationToken.None).ConfigureAwait(true);
                if (cancellationToken.IsCancellationRequested)
                {
                    return new InsertionOutcome.ClipboardOnly("insert.reason.targetGone");
                }
                if (GetForegroundWindow() == targetWindow)
                {
                    break;
                }
            }
            if (GetForegroundWindow() != targetWindow)
            {
                _clipboard.WriteString(text);
                Log.Shared.Info("insertion: could not re-activate target, left text on clipboard");
                return new InsertionOutcome.ClipboardOnly("insert.reason.targetGone");
            }
        }

        switch (FocusedElementKind())
        {
            case FocusKind.SecureField:
                // Never auto-type into password fields.
                _clipboard.WriteString(text);
                Log.Shared.Info("insertion: password field detected, left text on clipboard");
                return new InsertionOutcome.ClipboardOnly("insert.reason.secureField");
            case FocusKind.Editable when TryInsertViaAutomation(text):
                Log.Shared.Info($"insertion: via UI Automation (chars: {text.Length})");
                return new InsertionOutcome.InsertedViaAutomation();
        }

        if (await PasteWithClipboardRestoreAsync(text, cancellationToken).ConfigureAwait(true))
        {
            Log.Shared.Info($"insertion: via simulated paste (chars: {text.Length})");
            return new InsertionOutcome.PastedViaClipboard();
        }

        if (cancellationToken.IsCancellationRequested)
        {
            return new InsertionOutcome.ClipboardOnly("insert.reason.pasteFailed");
        }
        _clipboard.WriteString(text);
        Log.Shared.Info("insertion: paste failed, left text on clipboard");
        return new InsertionOutcome.ClipboardOnly("insert.reason.pasteFailed");
    }

    // ---- UI Automation path (replaces the macOS Accessibility path) ----

    private enum FocusKind
    {
        Editable,
        SecureField,
        None,
    }

    private static FocusKind FocusedElementKind()
    {
        try
        {
            var focused = AutomationElement.FocusedElement;
            if (focused is null)
            {
                return FocusKind.None;
            }
            if ((bool)focused.GetCurrentPropertyValue(AutomationElement.IsPasswordProperty))
            {
                return FocusKind.SecureField;
            }
            return FocusKind.Editable;
        }
        catch (ElementNotAvailableException)
        {
            return FocusKind.None;
        }
    }

    /// <summary>
    /// The macOS version replaces AXSelectedText, which inserts at the caret.
    /// UI Automation has no exact equivalent: ValuePattern.SetValue replaces
    /// the whole field content, so it is only safe for empty simple fields.
    /// Anything richer falls through to synthetic paste, which preserves the
    /// caret-insertion semantics.
    /// </summary>
    private static bool TryInsertViaAutomation(string text)
    {
        try
        {
            var focused = AutomationElement.FocusedElement;
            if (focused is null)
            {
                return false;
            }
            if (focused.TryGetCurrentPattern(ValuePattern.Pattern, out var patternObj)
                && patternObj is ValuePattern value
                && !value.Current.IsReadOnly
                && string.IsNullOrEmpty(value.Current.Value))
            {
                value.SetValue(text);
                return true;
            }
            return false;
        }
        catch (Exception e) when (e is ElementNotAvailableException or InvalidOperationException)
        {
            return false;
        }
    }

    // ---- Clipboard + synthetic Ctrl+V path ----

    private async Task<bool> PasteWithClipboardRestoreAsync(string text, CancellationToken cancellationToken)
    {
        if (cancellationToken.IsCancellationRequested)
        {
            return false;
        }
        var previous = _clipboard.Snapshot();
        var hadPreviousContent = !previous.IsEmpty;
        var countAfterWrite = _clipboard.WriteString(text);

        if (!PostCtrlV())
        {
            return false;
        }

        // The target app needs time to consume the clipboard before the
        // restore. Deliberately NOT linked to the session's cancellation
        // token: a cancel arriving after Ctrl+V was sent must not collapse
        // this grace period and restore the clipboard too early (same
        // reasoning as the unstructured Task in the Swift version).
        await Task.Delay(450, CancellationToken.None).ConfigureAwait(true);
        if (ClipboardRestorePolicy.ShouldRestore(countAfterWrite, _clipboard.ChangeCount, hadPreviousContent))
        {
            _clipboard.Restore(previous);
            Log.Shared.Debug("clipboard restored after paste");
        }
        return true;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct KEYBDINPUT
    {
        public ushort wVk;
        public ushort wScan;
        public uint dwFlags;
        public uint time;
        public IntPtr dwExtraInfo;
    }

    [StructLayout(LayoutKind.Explicit)]
    private struct InputUnion
    {
        [FieldOffset(0)] public KEYBDINPUT ki;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct INPUT
    {
        public uint type;
        public InputUnion u;
    }

    private const uint InputKeyboard = 1;
    private const uint KeyEventFKeyUp = 0x0002;
    private const ushort VkControl = 0x11;
    private const ushort VkV = 0x56;

    [DllImport("user32.dll", SetLastError = true)]
    private static extern uint SendInput(uint nInputs, INPUT[] pInputs, int cbSize);

    /// <summary>CGEvent Cmd+V on macOS → SendInput Ctrl+V on Windows.</summary>
    private static bool PostCtrlV()
    {
        static INPUT Key(ushort vk, bool up) => new()
        {
            type = InputKeyboard,
            u = new InputUnion
            {
                ki = new KEYBDINPUT { wVk = vk, dwFlags = up ? KeyEventFKeyUp : 0 },
            },
        };
        var inputs = new[]
        {
            Key(VkControl, up: false),
            Key(VkV, up: false),
            Key(VkV, up: true),
            Key(VkControl, up: true),
        };
        return SendInput((uint)inputs.Length, inputs, Marshal.SizeOf<INPUT>()) == inputs.Length;
    }
}
