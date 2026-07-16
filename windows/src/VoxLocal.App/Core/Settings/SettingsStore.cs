using System.ComponentModel;
using System.Runtime.CompilerServices;
using System.Text.Json;
using System.Text.Json.Serialization;
using VoxLocal.Core.Hotkeys;
using VoxLocal.Core.Insertion;
using VoxLocal.Core.Refinement;
using VoxLocal.Core.Utilities;

namespace VoxLocal.Core.Settings;

public enum HotkeyMode
{
    /// <summary>Record while the shortcut is held; stop on release.</summary>
    PressAndHold,
    /// <summary>First press starts, second press stops.</summary>
    Toggle,
}

public enum SpokenLanguage
{
    Auto,
    Russian,
    English,
}

public static class SpokenLanguageExtensions
{
    /// <summary>Value passed to whisper-cli -l.</summary>
    public static string WhisperCode(this SpokenLanguage language) => language switch
    {
        SpokenLanguage.Russian => "ru",
        SpokenLanguage.English => "en",
        _ => "auto",
    };
}

/// <summary>
/// All persisted user settings. UserDefaults on macOS → a JSON file at
/// %APPDATA%\VoxLocal\settings.json on Windows (path injectable for tests).
/// Every property change writes through immediately, like didSet did.
/// </summary>
public sealed class SettingsStore : INotifyPropertyChanged
{
    public const string DefaultOllamaEndpoint = "http://127.0.0.1:11434";

    /// <summary>Serialized shape of the settings file.</summary>
    private sealed class Data
    {
        public uint HotkeyKeyCode { get; set; } = KeyCombo.Default.KeyCode;
        public uint HotkeyModifiers { get; set; } = KeyCombo.Default.Modifiers;
        public HotkeyMode HotkeyMode { get; set; } = HotkeyMode.PressAndHold;
        public string? InputDeviceId { get; set; }
        public string WhisperModel { get; set; } = "base";
        public SpokenLanguage SpokenLanguage { get; set; } = SpokenLanguage.Auto;
        public int WhisperThreads { get; set; } = Math.Min(8, Math.Max(2, Environment.ProcessorCount / 2));
        public bool RemoveArtifacts { get; set; } = true;
        public bool RefinementEnabled { get; set; }
        public string OllamaEndpoint { get; set; } = DefaultOllamaEndpoint;
        public string OllamaModel { get; set; } = "";
        public RefinementPreset RefinementPreset { get; set; } = RefinementPreset.CleanDictation;
        public string CustomInstruction { get; set; } = "";
        public double RefinementTimeout { get; set; } = 20.0;
        public InsertionMode InsertionMode { get; set; } = InsertionMode.Auto;
        public bool LaunchAtLogin { get; set; }
        public L10n.Language InterfaceLanguage { get; set; } = L10n.Language.Russian;
        public LogLevel LogLevel { get; set; } = LogLevel.Info;
        public bool OnboardingCompleted { get; set; }
    }

    private static readonly JsonSerializerOptions JsonOptions = new()
    {
        WriteIndented = true,
        Converters = { new JsonStringEnumConverter(JsonNamingPolicy.CamelCase) },
    };

    private readonly string _path;
    private readonly Data _data;

    public event PropertyChangedEventHandler? PropertyChanged;

    public SettingsStore(string? path = null)
    {
        _path = path ?? System.IO.Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData),
            "VoxLocal", "settings.json");
        _data = Load(_path);
        // Re-apply side effects for values loaded from disk.
        L10n.SetLanguage(_data.InterfaceLanguage);
        Log.Shared.Level = _data.LogLevel;
    }

    private static Data Load(string path)
    {
        try
        {
            if (File.Exists(path))
            {
                return JsonSerializer.Deserialize<Data>(File.ReadAllText(path), JsonOptions) ?? new Data();
            }
        }
        catch (Exception e) when (e is IOException or JsonException)
        {
            Log.Shared.Error($"settings load failed, using defaults: {e.Message}");
        }
        return new Data();
    }

    /// <summary>Write-through persistence: atomic temp-file + move.</summary>
    private void Save()
    {
        try
        {
            Directory.CreateDirectory(System.IO.Path.GetDirectoryName(_path)!);
            var tmp = _path + ".tmp";
            File.WriteAllText(tmp, JsonSerializer.Serialize(_data, JsonOptions));
            File.Move(tmp, _path, overwrite: true);
        }
        catch (IOException e)
        {
            Log.Shared.Error($"settings save failed: {e.Message}");
        }
    }

    private void SaveAndNotify([CallerMemberName] string? name = null)
    {
        Save();
        PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(name));
    }

    public uint HotkeyKeyCode
    {
        get => _data.HotkeyKeyCode;
        set { _data.HotkeyKeyCode = value; SaveAndNotify(); }
    }

    public uint HotkeyModifiers
    {
        get => _data.HotkeyModifiers;
        set { _data.HotkeyModifiers = value; SaveAndNotify(); }
    }

    /// <summary>Convenience accessor pairing key code + modifiers.</summary>
    public KeyCombo Hotkey
    {
        get => new(HotkeyKeyCode, HotkeyModifiers);
        set
        {
            _data.HotkeyKeyCode = value.KeyCode;
            _data.HotkeyModifiers = value.Modifiers;
            SaveAndNotify();
        }
    }

    public HotkeyMode HotkeyMode
    {
        get => _data.HotkeyMode;
        set { _data.HotkeyMode = value; SaveAndNotify(); }
    }

    /// <summary>MMDevice ID of the selected input device (null = system default).</summary>
    public string? InputDeviceId
    {
        get => _data.InputDeviceId;
        set { _data.InputDeviceId = value; SaveAndNotify(); }
    }

    public string WhisperModel
    {
        get => _data.WhisperModel;
        set { _data.WhisperModel = value; SaveAndNotify(); }
    }

    public SpokenLanguage SpokenLanguage
    {
        get => _data.SpokenLanguage;
        set { _data.SpokenLanguage = value; SaveAndNotify(); }
    }

    public int WhisperThreads
    {
        get => _data.WhisperThreads;
        set { _data.WhisperThreads = value; SaveAndNotify(); }
    }

    public bool RemoveArtifacts
    {
        get => _data.RemoveArtifacts;
        set { _data.RemoveArtifacts = value; SaveAndNotify(); }
    }

    public bool RefinementEnabled
    {
        get => _data.RefinementEnabled;
        set { _data.RefinementEnabled = value; SaveAndNotify(); }
    }

    public string OllamaEndpoint
    {
        get => _data.OllamaEndpoint;
        set { _data.OllamaEndpoint = value; SaveAndNotify(); }
    }

    public string OllamaModel
    {
        get => _data.OllamaModel;
        set { _data.OllamaModel = value; SaveAndNotify(); }
    }

    public RefinementPreset RefinementPreset
    {
        get => _data.RefinementPreset;
        set { _data.RefinementPreset = value; SaveAndNotify(); }
    }

    public string CustomInstruction
    {
        get => _data.CustomInstruction;
        set { _data.CustomInstruction = value; SaveAndNotify(); }
    }

    public double RefinementTimeout
    {
        get => _data.RefinementTimeout;
        set { _data.RefinementTimeout = value; SaveAndNotify(); }
    }

    public InsertionMode InsertionMode
    {
        get => _data.InsertionMode;
        set { _data.InsertionMode = value; SaveAndNotify(); }
    }

    /// <summary>Persisted flag; applying it (HKCU Run key) happens in the App module.</summary>
    public bool LaunchAtLogin
    {
        get => _data.LaunchAtLogin;
        set { _data.LaunchAtLogin = value; SaveAndNotify(); }
    }

    public L10n.Language InterfaceLanguage
    {
        get => _data.InterfaceLanguage;
        set
        {
            _data.InterfaceLanguage = value;
            L10n.SetLanguage(value);
            SaveAndNotify();
        }
    }

    public LogLevel LogLevel
    {
        get => _data.LogLevel;
        set
        {
            _data.LogLevel = value;
            Log.Shared.Level = value;
            SaveAndNotify();
        }
    }

    public bool OnboardingCompleted
    {
        get => _data.OnboardingCompleted;
        set { _data.OnboardingCompleted = value; SaveAndNotify(); }
    }

    public void ResetOnboarding() => OnboardingCompleted = false;
}
