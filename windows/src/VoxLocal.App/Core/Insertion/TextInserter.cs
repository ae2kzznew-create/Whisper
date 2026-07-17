using System.Runtime.InteropServices;
using System.Text;
using System.Windows.Automation;
using VoxLocal.Core.Utilities;

namespace VoxLocal.Core.Insertion;

public abstract record InsertionOutcome
{
    public sealed record InsertedViaAutomation : InsertionOutcome;
    public sealed record PastedViaClipboard : InsertionOutcome;
    /// <summary>Text was typed in with synthetic Unicode key events (used for
    /// terminals and apps that reject Ctrl+V).</summary>
    public sealed record TypedViaKeyboard : InsertionOutcome;
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
/// Inserts the final text at the caret of the application that owned the
/// foreground window when dictation started (falling back to the current
/// foreground window when that one is gone).
/// Strategy chain — each step falls through to the next:
///   1. UI Automation ValuePattern — only for empty simple fields.
///   2. Synthetic Ctrl+V with clipboard save/restore — the common path.
///   3. Synthetic Unicode typing (KEYEVENTF_UNICODE) — terminals/consoles
///      and apps that reject paste; works virtually everywhere a caret is.
///   4. Plain clipboard as the last resort.
/// Hard limits imposed by Windows itself (not fixable from user space):
///   - password fields are never auto-typed (by design);
///   - windows of elevated ("run as administrator") processes do not accept
///     synthetic input from a non-elevated process (UIPI) — those fall back
///     to the clipboard with an explanatory message.
/// Must run on the UI (STA) thread.
/// </summary>
public sealed class TextInserter
{
    private readonly IClipboard _clipboard;

    public TextInserter(IClipboard? clipboard = null)
    {
        _clipboard = clipboard ?? new SystemClipboard();
    }

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

        // If the original target window is gone, insert wherever the caret
        // is now instead of giving up immediately.
        if (targetWindow == IntPtr.Zero || !IsWindow(targetWindow))
        {
            targetWindow = GetForegroundWindow();
            if (targetWindow == IntPtr.Zero)
            {
                _clipboard.WriteString(text);
                Log.Shared.Info("insertion: target window gone, left text on clipboard");
                return new InsertionOutcome.ClipboardOnly("insert.reason.targetGone");
            }
            Log.Shared.Info("insertion: original target gone, using current foreground window");
        }

        // Bring the original target back to front if focus moved during
        // transcription. AttachThreadInput bypasses the foreground-lock
        // protection that otherwise makes SetForegroundWindow a no-op.
        if (!await ActivateAsync(targetWindow, cancellationToken).ConfigureAwait(true))
        {
            if (cancellationToken.IsCancellationRequested)
            {
                return new InsertionOutcome.ClipboardOnly("insert.reason.targetGone");
            }
            _clipboard.WriteString(text);
            Log.Shared.Info("insertion: could not re-activate target, left text on clipboard");
            return new InsertionOutcome.ClipboardOnly("insert.reason.targetGone");
        }

        // UIPI: an elevated target silently swallows both Ctrl+V and typed
        // input from a non-elevated sender. Tell the user instead of failing
        // silently.
        if (IsWindowElevatedAboveUs(targetWindow))
        {
            _clipboard.WriteString(text);
            Log.Shared.Info("insertion: target is elevated (UIPI), left text on clipboard");
            return new InsertionOutcome.ClipboardOnly("insert.reason.elevated");
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

        // Terminals/consoles: Ctrl+V is unreliable (often bound to something
        // else or ignored) — type the text directly instead.
        var isTerminal = IsTerminalWindow(targetWindow);
        if (!isTerminal
            && await PasteWithClipboardRestoreAsync(text, cancellationToken).ConfigureAwait(true))
        {
            Log.Shared.Info($"insertion: via simulated paste (chars: {text.Length})");
            return new InsertionOutcome.PastedViaClipboard();
        }

        if (cancellationToken.IsCancellationRequested)
        {
            return new InsertionOutcome.ClipboardOnly("insert.reason.pasteFailed");
        }

        if (TypeUnicode(text))
        {
            Log.Shared.Info($"insertion: via synthetic typing (terminal: {isTerminal}, chars: {text.Length})");
            return new InsertionOutcome.TypedViaKeyboard();
        }

        _clipboard.WriteString(text);
        Log.Shared.Info("insertion: all methods failed, left text on clipboard");
        return new InsertionOutcome.ClipboardOnly("insert.reason.pasteFailed");
    }

    // ---- Window activation ----

    private static async Task<bool> ActivateAsync(IntPtr hWnd, CancellationToken cancellationToken)
    {
        if (GetForegroundWindow() == hWnd)
        {
            return true;
        }
        if (IsIconic(hWnd))
        {
            ShowWindow(hWnd, SwRestore);
        }
        for (var attempt = 0; attempt < 3; attempt++)
        {
            ForceForeground(hWnd);
            for (var i = 0; i < 5; i++)
            {
                if (GetForegroundWindow() == hWnd)
                {
                    return true;
                }
                await Task.Delay(100, CancellationToken.None).ConfigureAwait(true);
                if (cancellationToken.IsCancellationRequested)
                {
                    return false;
                }
            }
        }
        return GetForegroundWindow() == hWnd;
    }

    /// <summary>
    /// SetForegroundWindow is heavily restricted: only the process that owns
    /// the current foreground window may hand focus over. Temporarily joining
    /// the input queues of our thread, the current foreground thread and the
    /// target thread lifts that restriction (a documented, widely used
    /// technique).
    /// </summary>
    private static void ForceForeground(IntPtr hWnd)
    {
        var foreground = GetForegroundWindow();
        var ourThread = GetCurrentThreadId();
        var foregroundThread = foreground != IntPtr.Zero
            ? GetWindowThreadProcessId(foreground, out _)
            : 0;
        var targetThread = GetWindowThreadProcessId(hWnd, out _);

        var attachedForeground = foregroundThread != 0 && foregroundThread != ourThread
            && AttachThreadInput(ourThread, foregroundThread, true);
        var attachedTarget = targetThread != 0 && targetThread != ourThread
            && AttachThreadInput(ourThread, targetThread, true);
        try
        {
            BringWindowToTop(hWnd);
            SetForegroundWindow(hWnd);
        }
        finally
        {
            if (attachedForeground)
            {
                AttachThreadInput(ourThread, foregroundThread, false);
            }
            if (attachedTarget)
            {
                AttachThreadInput(ourThread, targetThread, false);
            }
        }
    }

    // ---- Elevation (UIPI) detection ----

    private static bool IsWindowElevatedAboveUs(IntPtr hWnd)
    {
        try
        {
            if (IsCurrentProcessElevated())
            {
                return false; // we are elevated ourselves — UIPI does not block us
            }
            GetWindowThreadProcessId(hWnd, out var pid);
            if (pid == 0)
            {
                return false;
            }
            var process = OpenProcess(ProcessQueryLimitedInformation, false, pid);
            if (process == IntPtr.Zero)
            {
                return true; // cannot even query — almost certainly higher integrity
            }
            try
            {
                if (!OpenProcessToken(process, TokenQuery, out var token))
                {
                    return true;
                }
                try
                {
                    return IsTokenElevated(token);
                }
                finally
                {
                    CloseHandle(token);
                }
            }
            finally
            {
                CloseHandle(process);
            }
        }
        catch (Exception e)
        {
            Log.Shared.Debug($"elevation check failed: {e.Message}");
            return false;
        }
    }

    private static bool IsCurrentProcessElevated()
    {
        if (!OpenProcessToken(GetCurrentProcess(), TokenQuery, out var token))
        {
            return false;
        }
        try
        {
            return IsTokenElevated(token);
        }
        finally
        {
            CloseHandle(token);
        }
    }

    private static bool IsTokenElevated(IntPtr token) =>
        GetTokenInformation(token, TokenElevationClass, out var elevated, sizeof(uint), out _)
        && elevated != 0;

    // ---- Terminal detection ----

    private static readonly string[] TerminalClasses =
    {
        "ConsoleWindowClass",            // classic conhost (cmd, PowerShell)
        "CASCADIA_HOSTING_WINDOW_CLASS", // Windows Terminal
        "VirtualConsoleClass",           // ConEmu / Cmder
        "mintty",                        // Git Bash / Cygwin / MSYS2
    };

    private static bool IsTerminalWindow(IntPtr hWnd)
    {
        var buffer = new StringBuilder(256);
        if (GetClassName(hWnd, buffer, buffer.Capacity) == 0)
        {
            return false;
        }
        var className = buffer.ToString();
        foreach (var terminal in TerminalClasses)
        {
            if (string.Equals(className, terminal, StringComparison.Ordinal))
            {
                return true;
            }
        }
        return false;
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
        catch (Exception e) when (e is ElementNotAvailableException or InvalidOperationException or COMException)
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
        catch (Exception e) when (e is ElementNotAvailableException or InvalidOperationException or COMException)
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

    // ---- Synthetic input plumbing ----

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
    private const uint KeyEventFUnicode = 0x0004;
    private const ushort VkControl = 0x11;
    private const ushort VkV = 0x56;
    private const ushort VkReturn = 0x0D;
    private const int SwRestore = 9;
    private const uint ProcessQueryLimitedInformation = 0x1000;
    private const uint TokenQuery = 0x0008;
    private const int TokenElevationClass = 20;

    private static INPUT Key(ushort vk, bool up) => new()
    {
        type = InputKeyboard,
        u = new InputUnion
        {
            ki = new KEYBDINPUT { wVk = vk, dwFlags = up ? KeyEventFKeyUp : 0 },
        },
    };

    private static INPUT UnicodeKey(char ch, bool up) => new()
    {
        type = InputKeyboard,
        u = new InputUnion
        {
            ki = new KEYBDINPUT
            {
                wVk = 0,
                wScan = ch,
                dwFlags = KeyEventFUnicode | (up ? KeyEventFKeyUp : 0u),
            },
        },
    };

    /// <summary>CGEvent Cmd+V on macOS → SendInput Ctrl+V on Windows.</summary>
    private static bool PostCtrlV()
    {
        var inputs = new[]
        {
            Key(VkControl, up: false),
            Key(VkV, up: false),
            Key(VkV, up: true),
            Key(VkControl, up: true),
        };
        return SendInput((uint)inputs.Length, inputs, Marshal.SizeOf<INPUT>()) == inputs.Length;
    }

    /// <summary>
    /// Types the text with KEYEVENTF_UNICODE key events — layout-independent
    /// and accepted by virtually every app, including consoles. Newlines are
    /// sent as real Enter presses so multi-line dictations work in chats and
    /// editors alike.
    /// </summary>
    private static bool TypeUnicode(string text)
    {
        var inputs = new List<INPUT>(text.Length * 2);
        foreach (var ch in text)
        {
            if (ch == '\r')
            {
                continue;
            }
            if (ch == '\n')
            {
                inputs.Add(Key(VkReturn, up: false));
                inputs.Add(Key(VkReturn, up: true));
                continue;
            }
            inputs.Add(UnicodeKey(ch, up: false));
            inputs.Add(UnicodeKey(ch, up: true));
        }
        if (inputs.Count == 0)
        {
            return true;
        }
        // Send in modest chunks so long dictations do not overflow the
        // system input queue.
        const int chunkSize = 64;
        for (var offset = 0; offset < inputs.Count; offset += chunkSize)
        {
            var count = Math.Min(chunkSize, inputs.Count - offset);
            var chunk = inputs.GetRange(offset, count).ToArray();
            if (SendInput((uint)chunk.Length, chunk, Marshal.SizeOf<INPUT>()) != chunk.Length)
            {
                return false;
            }
        }
        return true;
    }

    // ---- Native methods ----

    [DllImport("user32.dll")]
    private static extern IntPtr GetForegroundWindow();

    [DllImport("user32.dll")]
    private static extern bool SetForegroundWindow(IntPtr hWnd);

    [DllImport("user32.dll")]
    private static extern bool IsWindow(IntPtr hWnd);

    [DllImport("user32.dll")]
    private static extern bool IsIconic(IntPtr hWnd);

    [DllImport("user32.dll")]
    private static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);

    [DllImport("user32.dll")]
    private static extern bool BringWindowToTop(IntPtr hWnd);

    [DllImport("user32.dll")]
    private static extern bool AttachThreadInput(uint idAttach, uint idAttachTo, bool fAttach);

    [DllImport("user32.dll")]
    private static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint lpdwProcessId);

    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    private static extern int GetClassName(IntPtr hWnd, StringBuilder lpClassName, int nMaxCount);

    [DllImport("user32.dll", SetLastError = true)]
    private static extern uint SendInput(uint nInputs, INPUT[] pInputs, int cbSize);

    [DllImport("kernel32.dll")]
    private static extern uint GetCurrentThreadId();

    [DllImport("kernel32.dll")]
    private static extern IntPtr GetCurrentProcess();

    [DllImport("kernel32.dll")]
    private static extern IntPtr OpenProcess(uint dwDesiredAccess, bool bInheritHandle, uint dwProcessId);

    [DllImport("kernel32.dll")]
    private static extern bool CloseHandle(IntPtr hObject);

    [DllImport("advapi32.dll", SetLastError = true)]
    private static extern bool OpenProcessToken(IntPtr processHandle, uint desiredAccess, out IntPtr tokenHandle);

    [DllImport("advapi32.dll")]
    private static extern bool GetTokenInformation(IntPtr tokenHandle, int tokenInformationClass, out uint tokenInformation, uint tokenInformationLength, out uint returnLength);
}
