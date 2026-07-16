using System.Runtime.InteropServices;
using System.Text;
using System.Text.Json.Serialization;

namespace VoxLocal.Core.Hotkeys;

/// <summary>A global shortcut: Win32 virtual-key code + RegisterHotKey modifier mask.</summary>
public sealed record KeyCombo(
    [property: JsonPropertyName("keyCode")] uint KeyCode,
    [property: JsonPropertyName("modifiers")] uint Modifiers)
{
    // RegisterHotKey modifier mask (MOD_*).
    public const uint ModAlt = 0x0001;
    public const uint ModControl = 0x0002;
    public const uint ModShift = 0x0004;
    public const uint ModWin = 0x0008;

    /// <summary>
    /// Default: Alt+Space (mirrors Option+Space on macOS). RegisterHotKey
    /// takes precedence over the window system menu; onboarding should offer
    /// Ctrl+Alt+Space as an alternative.
    /// </summary>
    public static readonly KeyCombo Default = new(0x20 /* VK_SPACE */, ModAlt);

    public static KeyCombo FromKeyEvent(uint virtualKey, bool ctrl, bool shift, bool alt, bool win)
    {
        uint mods = 0;
        if (ctrl) mods |= ModControl;
        if (shift) mods |= ModShift;
        if (alt) mods |= ModAlt;
        if (win) mods |= ModWin;
        return new KeyCombo(virtualKey, mods);
    }

    public string DisplayString
    {
        get
        {
            var parts = new StringBuilder();
            if ((Modifiers & ModControl) != 0) parts.Append("Ctrl+");
            if ((Modifiers & ModAlt) != 0) parts.Append("Alt+");
            if ((Modifiers & ModShift) != 0) parts.Append("Shift+");
            if ((Modifiers & ModWin) != 0) parts.Append("Win+");
            return parts.Append(KeyName(KeyCode)).ToString();
        }
    }

    private static readonly Dictionary<uint, string> SpecialKeyNames = new()
    {
        [0x20] = "Space", [0x0D] = "Enter", [0x09] = "Tab", [0x08] = "Backspace", [0x1B] = "Esc",
        [0x25] = "←", [0x27] = "→", [0x28] = "↓", [0x26] = "↑",
        [0x70] = "F1", [0x71] = "F2", [0x72] = "F3", [0x73] = "F4", [0x74] = "F5", [0x75] = "F6",
        [0x76] = "F7", [0x77] = "F8", [0x78] = "F9", [0x79] = "F10", [0x7A] = "F11", [0x7B] = "F12",
        [0x24] = "Home", [0x23] = "End", [0x21] = "PgUp", [0x22] = "PgDn", [0x2E] = "Del",
    };

    [DllImport("user32.dll")]
    private static extern uint MapVirtualKey(uint uCode, uint uMapType);

    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    private static extern int GetKeyNameTextW(int lParam, StringBuilder lpString, int nSize);

    public static string KeyName(uint keyCode)
    {
        if (SpecialKeyNames.TryGetValue(keyCode, out var special))
        {
            return special;
        }
        // Translate through the current keyboard layout.
        var scanCode = MapVirtualKey(keyCode, 0 /* MAPVK_VK_TO_VSC */);
        if (scanCode != 0)
        {
            var name = new StringBuilder(32);
            if (GetKeyNameTextW((int)(scanCode << 16), name, name.Capacity) > 0)
            {
                return name.ToString().ToUpperInvariant();
            }
        }
        return $"Key {keyCode}";
    }
}
