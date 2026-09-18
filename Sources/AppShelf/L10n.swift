import Combine
import Foundation
import SwiftUI

import AppShelfCore

/// Localization manager.
///
/// Translations live in one JSON file per language. Each file maps a stable key
/// (the Chinese source string) to the translated value, so the app stays fully
/// usable in Chinese even before a language file exists. Bundled defaults ship
/// inside the app; an external folder can add or override languages at runtime,
/// which is how users contribute a new locale without recompiling.
///
/// Lookup and language resolution are delegated to `LocalizationResolver`, which is pure
/// and unit-tested; this class only owns the loaded tables and the change notification.
@MainActor
final class L10n: ObservableObject {
    static let shared = L10n()

    /// Selected language code. "system" follows the OS setting.
    ///
    /// `@Published` already emits `objectWillChange`; the previous `didSet` sent it a second
    /// time, which made every observer rebuild twice per switch.
    @Published var language: String {
        didSet {
            guard oldValue != language else { return }
            UserDefaults.standard.set(language, forKey: ShelfDefaults.language)
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
        self.language = UserDefaults.standard.string(forKey: ShelfDefaults.language) ?? "system"
        loadBundled()
        loadExternal()
    }

    // MARK: - Loading

    private func loadBundled() {
        bundled.removeAll()
        guard let urls = Bundle.main.urls(forResourcesWithExtension: "json",
                                          subdirectory: "Localization") else { return }
        for url in urls {
            let code = url.deletingPathExtension().lastPathComponent
            if let dict = Self.loadFile(url) { bundled[code] = dict }
        }
    }

    private func loadExternal() {
        external.removeAll()
        let fm = FileManager.default
        guard fm.fileExists(atPath: defaultLoadPath.path),
              let urls = try? fm.contentsOfDirectory(at: defaultLoadPath,
                                                    includingPropertiesForKeys: nil) else { return }
        for url in urls where url.pathExtension.lowercased() == "json" {
            let code = url.deletingPathExtension().lastPathComponent
            if let dict = Self.loadFile(url) { external[code] = dict }
        }
    }

    /// Re-reads the external folder so a dropped-in language file takes effect without a
    /// relaunch. Publishing the result is what lets the settings panel offer it at once.
    ///
    /// This used to run only during `init`, which meant the documented "add a language
    /// without recompiling" workflow still required restarting the app.
    func reloadExternal() {
        loadExternal()
        objectWillChange.send()
    }

    /// Number of languages found in the external folder, for the settings panel's feedback.
    var externalLanguageCount: Int { external.keys.count }

    /// A malformed language file is skipped rather than aborting the whole load, but the
    /// reason has to be findable: a silently missing translation is otherwise invisible.
    private static func loadFile(_ url: URL) -> [String: String]? {
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            ShelfLog.l10n.error("Cannot read \(url.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .public)")
            return nil
        }
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: String] else {
            ShelfLog.l10n.error("\(url.lastPathComponent, privacy: .public) is not a string-to-string JSON table; skipped.")
            return nil
        }
        return obj
    }

    // MARK: - Lookup

    var effectiveLanguage: String {
        LocalizationResolver.effectiveLanguage(selection: language,
                                               preferredLanguages: Locale.preferredLanguages)
    }

    /// Languages the UI can switch to: system, plus every language that has a table.
    var availableLanguages: [String] {
        LocalizationResolver.availableLanguages(bundled: bundled, external: external)
    }

    /// Translate `key`. `args` replaces `{placeholder}` tokens with values.
    func t(_ key: String, args: [String: String] = [:]) -> String {
        let language = effectiveLanguage
        let table = LocalizationResolver.table(bundled: bundled, external: external, language: language)
        let resolved = LocalizationResolver.resolve(key: key,
                                                    table: table,
                                                    englishFallback: bundled["en"] ?? [:])
        return LocalizationResolver.substitute(resolved, args: args)
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
