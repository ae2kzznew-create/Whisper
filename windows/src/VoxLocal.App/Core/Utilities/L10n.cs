using System.Globalization;
using System.Text;
using System.Text.RegularExpressions;

namespace VoxLocal.Core.Utilities;

/// <summary>
/// Localization lookup with an in-app language override. Defaults to
/// Russian; the user can switch to English or follow the system language.
/// Reads the original Apple .strings tables from embedded resources, so the
/// macOS localization files are reused verbatim.
/// </summary>
public static partial class L10n
{
    public enum Language
    {
        System,
        Russian,
        English,
    }

    /// <summary>Set once at startup and whenever the user changes the setting.</summary>
    public static Language CurrentLanguage { get; private set; } = Language.Russian;

    private static Dictionary<string, string> _table = new();
    private static readonly object Lock = new();

    public static void SetLanguage(Language lang)
    {
        lock (Lock)
        {
            CurrentLanguage = lang;
            var code = lang switch
            {
                Language.Russian => "ru",
                Language.English => "en",
                _ => CultureInfo.CurrentUICulture.TwoLetterISOLanguageName == "ru" ? "ru" : "en",
            };
            _table = LoadTable(code);
        }
    }

    public static string T(string key)
    {
        lock (Lock)
        {
            if (_table.Count == 0)
            {
                _table = LoadTable("ru");
            }
            return _table.TryGetValue(key, out var value) ? value : key;
        }
    }

    public static string T(string key, params object[] args) =>
        string.Format(CultureInfo.CurrentCulture, T(key), args);

    private static Dictionary<string, string> LoadTable(string code)
    {
        // Resources\ru\Localizable.strings, Resources\en\Localizable.strings
        // are embedded into the assembly by the .csproj below.
        var assembly = typeof(L10n).Assembly;
        using var stream = assembly.GetManifestResourceStream($"VoxLocal.Core.Resources.{code}.Localizable.strings")
            ?? throw new InvalidOperationException($"missing string table: {code}");
        using var reader = new StreamReader(stream, Encoding.UTF8);
        return Parse(reader.ReadToEnd());
    }

    /// <summary>Parses the Apple .strings format: "key" = "value"; (comments ignored).</summary>
    internal static Dictionary<string, string> Parse(string text)
    {
        var table = new Dictionary<string, string>();
        foreach (Match m in EntryRegex().Matches(text))
        {
            var key = Unescape(m.Groups[1].Value);
            var value = ConvertFormat(Unescape(m.Groups[2].Value));
            table[key] = value;
        }
        return table;
    }

    private static string Unescape(string s) => s
        .Replace("\\\"", "\"")
        .Replace("\\n", "\n")
        .Replace("\\\\", "\\");

    /// <summary>%@ / %d / %.1f … → {0}, {1}, … so string.Format can be used.</summary>
    private static string ConvertFormat(string value)
    {
        var index = 0;
        return FormatSpecifierRegex().Replace(value, _ => "{" + index++ + "}");
    }

    [GeneratedRegex("\"((?:[^\"\\\\]|\\\\.)*)\"\\s*=\\s*\"((?:[^\"\\\\]|\\\\.)*)\"\\s*;")]
    private static partial Regex EntryRegex();

    [GeneratedRegex(@"%(?:\d+\$)?(?:\.\d+)?[@dDuUxXoOfeEgGcCsSp]")]
    private static partial Regex FormatSpecifierRegex();
}
