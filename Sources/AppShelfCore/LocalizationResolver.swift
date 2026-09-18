import Foundation

/// Language selection and translation lookup, free of `UserDefaults` and bundles.
///
/// The lookup order is external file for the language, then the bundled file for the
/// language, then bundled English, then the key itself — which is always the Chinese
/// source string, so the app stays usable in Chinese even with no table at all.
public enum LocalizationResolver {
    public static let systemSelection = "system"
    public static let english = "en"
    public static let simplifiedChinese = "zh-Hans"

    /// Maps the user's choice plus the OS preference list onto a language code.
    public static func effectiveLanguage(selection: String, preferredLanguages: [String]) -> String {
        guard selection == systemSelection else { return selection }
        let preferred = preferredLanguages.first ?? english
        return canonicalCode(preferred) ?? preferred
    }

    /// Narrows a locale like `zh-Hant-TW` or `en-GB` down to a code we ship a table for.
    public static func canonicalCode(_ locale: String) -> String? {
        let lower = locale.lowercased()
        if lower.hasPrefix("zh") { return simplifiedChinese }
        if lower.hasPrefix("en") { return english }
        return nil
    }

    /// The table in force for one language.
    ///
    /// An external file overrides the bundled one *per key* rather than replacing it, so
    /// dropping in a partial `en.json` to fix two strings no longer loses the other 126.
    public static func table(bundled: [String: [String: String]],
                             external: [String: [String: String]],
                             language: String) -> [String: String] {
        var merged = bundled[language] ?? [:]
        for (key, value) in external[language] ?? [:] where !value.isEmpty {
            merged[key] = value
        }
        return merged
    }

    public static func resolve(key: String, table: [String: String], englishFallback: [String: String]) -> String {
        table[key] ?? englishFallback[key] ?? key
    }

    /// Replaces `{name}` tokens. Missing tokens are left as written, which is easier to
    /// spot in a translated file than a silently empty hole.
    public static func substitute(_ text: String, args: [String: String]) -> String {
        guard !args.isEmpty else { return text }
        var value = text
        for (name, replacement) in args {
            value = value.replacingOccurrences(of: "{\(name)}", with: replacement)
        }
        return value
    }

    /// Languages the UI can offer: the pinned ones that have a table, then anything else
    /// the user added, alphabetically.
    public static func availableLanguages(bundled: [String: [String: String]],
                                          external: [String: [String: String]]) -> [String] {
        var codes = Set(bundled.keys)
        codes.formUnion(external.keys)
        codes.insert(systemSelection)
        let pinned = [systemSelection, simplifiedChinese, english]
        return pinned.filter { codes.contains($0) } + codes.subtracting(pinned).sorted()
    }
}
