using System.Runtime.InteropServices;
using System.Windows.Interop;
using System.Windows.Threading;
using VoxLocal.Core.Utilities;

namespace VoxLocal.Core.Hotkeys;

public sealed class HotkeyConflictException : Exception
{
    public KeyCombo Combo { get; }

    public HotkeyConflictException(KeyCombo combo)
        : base($"hotkey conflict: {combo.DisplayString}")
    {
        Combo = combo;
    }
}

public sealed class HotkeyRegistrationException : Exception
{
    public int Win32Error { get; }

    public HotkeyRegistrationException(int win32Error)
        : base($"hotkey registration failed (Win32 {win32Error})")
    {
        Win32Error = win32Error;
    }
}

/// <summary>
/// System-wide hotkeys via Win32 RegisterHotKey on a hidden message-only
/// window. Key-down comes from WM_HOTKEY; key-up (needed for press-and-hold)
/// is detected by polling GetAsyncKeyState, because RegisterHotKey has no
/// release event. No special permissions are required. An additional Escape
/// hotkey is registered only while a dictation session is active, so Escape
/// behaves normally the rest of the time.
/// </summary>
public sealed class HotkeyManager : IDisposable
{
    public Action? OnMainKeyDown { get; set; }
    public Action? OnMainKeyUp { get; set; }
    public Action? OnEscape { get; set; }

    private const int WmHotkey = 0x0312;
    private const int MainHotkeyId = 1;
    private const int EscapeHotkeyId = 2;
    private const int ProbeHotkeyId = 3;
    private const uint VkEscape = 0x1B;
    private const uint ModNoRepeat = 0x4000;
    private const int ErrorHotkeyAlreadyRegistered = 1409;

    private HwndSource? _source;
    private bool _mainRegistered;
    private bool _escapeRegistered;
    private DispatcherTimer? _releaseTimer;

    public KeyCombo? RegisteredCombo { get; private set; }

    [DllImport("user32.dll", SetLastError = true)]
    private static extern bool RegisterHotKey(IntPtr hWnd, int id, uint fsModifiers, uint vk);

    [DllImport("user32.dll", SetLastError = true)]
    private static extern bool UnregisterHotKey(IntPtr hWnd, int id);

    [DllImport("user32.dll")]
    private static extern short GetAsyncKeyState(int vKey);

    private IntPtr EnsureWindow()
    {
        if (_source is null)
        {
            // Hidden message-only window that owns all hotkey registrations.
            var parameters = new HwndSourceParameters("VoxLocalHotkeys")
            {
                Width = 0,
                Height = 0,
                WindowStyle = 0,
                ExtendedWindowStyle = 0,
                ParentWindow = new IntPtr(-3), // HWND_MESSAGE
            };
            _source = new HwndSource(parameters);
            _source.AddHook(WndProc);
        }
        return _source.Handle;
    }

    private IntPtr WndProc(IntPtr hwnd, int msg, IntPtr wParam, IntPtr lParam, ref bool handled)
    {
        if (msg != WmHotkey)
        {
            return IntPtr.Zero;
        }
        switch (wParam.ToInt32())
        {
            case MainHotkeyId:
                handled = true;
                OnMainKeyDown?.Invoke();
                StartReleaseWatcher();
                break;
            case EscapeHotkeyId:
                handled = true;
                OnEscape?.Invoke();
                break;
        }
        return IntPtr.Zero;
    }

    /// <summary>
    /// RegisterHotKey has no key-released event (unlike Carbon). For
    /// press-and-hold mode the physical key state is polled until the key
    /// goes up, then OnMainKeyUp fires once.
    /// </summary>
    private void StartReleaseWatcher()
    {
        if (RegisteredCombo is not { } combo || _releaseTimer is not null)
        {
            return;
        }
        _releaseTimer = new DispatcherTimer(DispatcherPriority.Input)
        {
            Interval = TimeSpan.FromMilliseconds(30),
        };
        _releaseTimer.Tick += (_, _) =>
        {
            if ((GetAsyncKeyState((int)combo.KeyCode) & 0x8000) == 0)
            {
                _releaseTimer?.Stop();
                _releaseTimer = null;
                OnMainKeyUp?.Invoke();
            }
        };
        _releaseTimer.Start();
    }

    /// <summary>
    /// Registers the main dictation shortcut. Throws HotkeyConflictException
    /// when the system rejects the combo (already taken by another app).
    /// The new combo is probed *before* the old one is removed, so a failed
    /// change keeps the previously working shortcut alive.
    /// </summary>
    public void RegisterMainHotkey(KeyCombo combo)
    {
        var hwnd = EnsureWindow();
        if (!RegisterHotKey(hwnd, ProbeHotkeyId, combo.Modifiers | ModNoRepeat, combo.KeyCode))
        {
            var error = Marshal.GetLastWin32Error();
            Log.Shared.Error($"hotkey registration failed (Win32 {error}) for {combo.DisplayString}");
            if (error == ErrorHotkeyAlreadyRegistered)
            {
                throw new HotkeyConflictException(combo);
            }
            throw new HotkeyRegistrationException(error);
        }
        UnregisterHotKey(hwnd, ProbeHotkeyId);
        UnregisterMainHotkey();
        if (!RegisterHotKey(hwnd, MainHotkeyId, combo.Modifiers | ModNoRepeat, combo.KeyCode))
        {
            throw new HotkeyRegistrationException(Marshal.GetLastWin32Error());
        }
        _mainRegistered = true;
        RegisteredCombo = combo;
        Log.Shared.Info($"hotkey registered: {combo.DisplayString}");
    }

    public void UnregisterMainHotkey()
    {
        if (_mainRegistered && _source is not null)
        {
            UnregisterHotKey(_source.Handle, MainHotkeyId);
            _mainRegistered = false;
            RegisteredCombo = null;
        }
    }

    /// <summary>Escape is captured system-wide only while dictation is in flight.</summary>
    public void RegisterEscape()
    {
        var hwnd = EnsureWindow();
        if (_escapeRegistered)
        {
            return;
        }
        if (RegisterHotKey(hwnd, EscapeHotkeyId, ModNoRepeat, VkEscape))
        {
            _escapeRegistered = true;
        }
        else
        {
            // Not fatal: cancellation stays available from the tray menu.
            Log.Shared.Info($"escape hotkey unavailable (Win32 {Marshal.GetLastWin32Error()})");
        }
    }

    public void UnregisterEscape()
    {
        if (_escapeRegistered && _source is not null)
        {
            UnregisterHotKey(_source.Handle, EscapeHotkeyId);
            _escapeRegistered = false;
        }
    }

    public void Dispose()
    {
        UnregisterMainHotkey();
        UnregisterEscape();
        _releaseTimer?.Stop();
        _releaseTimer = null;
        if (_source is not null)
        {
            _source.RemoveHook(WndProc);
            _source.Dispose();
            _source = null;
        }
    }
}
