import Foundation

/// Localization lookup with an in-app language override. The app defaults to
/// Russian; the user can switch to English or follow the system language.
public enum L10n {
    public enum Language: String, CaseIterable, Sendable {
        case system
        case russian = "ru"
        case english = "en"
    }

    /// Set once at startup and whenever the user changes the setting.
    public private(set) static var language: Language = .russian

    private static var overrideBundle: Bundle?

    public static func setLanguage(_ lang: Language) {
        language = lang
        switch lang {
        case .system:
            overrideBundle = nil
        case .russian, .english:
            if let path = Bundle.module.path(forResource: lang.rawValue, ofType: "lproj"),
               let bundle = Bundle(path: path) {
                overrideBundle = bundle
            } else {
                overrideBundle = nil
            }
        }
    }

    public static func t(_ key: String) -> String {
        let bundle = overrideBundle ?? Bundle.module
        return bundle.localizedString(forKey: key, value: key, table: nil)
    }

    public static func t(_ key: String, _ args: CVarArg...) -> String {
        String(format: t(key), locale: Locale.current, arguments: args)
    }
}
