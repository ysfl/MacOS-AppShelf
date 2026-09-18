import Foundation
import SwiftUI
import Combine

/// Localization manager.
///
/// Translations live in one JSON file per language. Each file maps a stable key
/// (the Chinese source string) to the translated value, so the app stays fully
/// usable in Chinese even before a language file exists. Bundled defaults ship
/// inside the app; an external folder can add or override languages at runtime,
/// which is how users contribute a new locale without recompiling.
final class L10n: ObservableObject {
    static let shared = L10n()

    /// Selected language code. "system" follows the OS setting.
    @Published var language: String {
        didSet {
            UserDefaults.standard.set(language, forKey: "AppShelf.language")
            objectWillChange.send()
        }
    }

    /// Folder scanned for external per-language JSON files at launch and on demand.
    /// Drop a `<code>.json` (e.g. `ja.json`) here to add a language.
    let defaultLoadPath: URL

    private var bundled: [String: [String: String]] = [:]
    private var external: [String: [String: String]] = [:]

    private init() {
        self.defaultLoadPath = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("AppShelf/Localization", isDirectory: true)
        self.language = UserDefaults.standard.string(forKey: "AppShelf.language") ?? "system"
        loadBundled()
        reloadExternal()
    }

    // MARK: - Loading

    private func loadBundled() {
        bundled.removeAll()
        guard let urls = Bundle.main.urls(forResourcesWithExtension: "json",
                                          subdirectory: "Localization") else { return }
        for url in urls {
            let code = url.deletingPathExtension().lastPathComponent
            if let dict = loadFile(url) { bundled[code] = dict }
        }
    }

    /// Re-scan the external folder. Call after dropping a new file in.
    func reloadExternal() {
        external.removeAll()
        let fm = FileManager.default
        guard fm.fileExists(atPath: defaultLoadPath.path) else { return }
        guard let urls = try? fm.contentsOfDirectory(at: defaultLoadPath,
                                                     includingPropertiesForKeys: nil) else { return }
        for url in urls where url.pathExtension.lowercased() == "json" {
            let code = url.deletingPathExtension().lastPathComponent
            if let dict = loadFile(url) { external[code] = dict }
        }
    }

    private func loadFile(_ url: URL) -> [String: String]? {
        guard let data = try? Data(contentsOf: url),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: String] else {
            return nil
        }
        return obj
    }

    // MARK: - Lookup

    private var effectiveLanguage: String {
        if language == "system" {
            let pref = Locale.preferredLanguages.first ?? "en"
            let lower = pref.lowercased()
            if lower.hasPrefix("zh") { return "zh-Hans" }
            if lower.hasPrefix("en") { return "en" }
            return pref
        }
        return language
    }

    /// Languages the UI can switch to: system, plus every language that has a table.
    var availableLanguages: [String] {
        var set = Set<String>()
        set.formUnion(bundled.keys)
        set.formUnion(external.keys)
        set.insert("system")
        let ordered = ["system", "zh-Hans", "en"]
        let extra = set.subtracting(ordered).sorted()
        return ordered.filter { set.contains($0) } + extra
    }

    /// Translate `key`. `args` replaces `{placeholder}` tokens with values.
    func t(_ key: String, args: [String: String] = [:]) -> String {
        let table: [String: String]? = external[effectiveLanguage] ?? bundled[effectiveLanguage]
        var value = table?[key] ?? bundled["en"]?[key] ?? key
        for (k, v) in args { value = value.replacingOccurrences(of: "{\(k)}", with: v) }
        return value
    }

    /// Human-readable label for a language code, shown in the switch menu.
    func displayName(for code: String) -> String {
        switch code {
        case "system": return t("language.system")
        case "zh-Hans": return "中文"
        case "en": return "English"
        default: return code
        }
    }
}

/// A text label that re-renders when the language changes, so the switch is instant.
struct L10nText: View {
    @ObservedObject private var l10n = L10n.shared
    let key: String
    let args: [String: String]

    init(_ key: String, args: [String: String] = [:]) {
        self.key = key
        self.args = args
    }

    var body: some View {
        Text(l10n.t(key, args: args))
    }
}
