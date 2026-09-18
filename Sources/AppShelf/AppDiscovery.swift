import AppKit
import SwiftUI
import UniformTypeIdentifiers

import AppShelfCore

// MARK: - Discovery
/// Finds launchable app bundles without modifying them.
/// System background agents are omitted from the automatic scan to keep the list useful.
enum AppDiscoveryService {
    private static let searchRoots: [URL] = {
        let home = FileManager.default.homeDirectoryForCurrentUser
        // These are the user-visible application locations. CoreServices is intentionally excluded:
        // it contains many helper processes that should not appear in a launcher.
        return [
            URL(fileURLWithPath: "/Applications"),
            home.appendingPathComponent("Applications", isDirectory: true),
            URL(fileURLWithPath: "/System/Applications")
        ]
    }()

    static func discover(additionalPaths: [String] = []) -> [AppItem] {
        var items: [AppItem] = []
        var seen = Set<String>()

        for root in searchRoots {
            for url in appURLs(in: root) {
                if let item = makeItem(url: url, seen: &seen, allowsBackgroundApp: false) {
                    items.append(item)
                }
            }
        }

        // A manually selected path is an explicit user choice, so keep it even when its
        // bundle declares itself as a background or menu-bar app.
        for path in additionalPaths {
            let url = URL(fileURLWithPath: path)
            guard ShelfPath.isApplicationBundle(url.path),
                  FileManager.default.fileExists(atPath: url.path) else { continue }
            if let item = makeItem(url: url, seen: &seen, allowsBackgroundApp: true) {
                items.append(item)
            }
        }

        return items.sorted { lhs, rhs in
                lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
            }
    }

    static func item(for url: URL) -> AppItem? {
        var seen = Set<String>()
        return makeItem(url: url, seen: &seen, allowsBackgroundApp: true)
    }

    private static func appURLs(in root: URL) -> [URL] {
        guard FileManager.default.fileExists(atPath: root.path) else { return [] }

        let keys: [URLResourceKey] = [.isDirectoryKey, .isPackageKey]
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        var results: [URL] = []
        for case let url as URL in enumerator {
            guard url.pathExtension.caseInsensitiveCompare("app") == .orderedSame else { continue }
            results.append(url)
            // An app bundle is a package. Do not descend into its embedded helper bundles.
            enumerator.skipDescendants()
        }
        ShelfLog.discovery.log("Scanned \(root.path, privacy: .public): \(results.count) bundles")
        return results
    }

    private static func makeItem(url: URL, seen: inout Set<String>, allowsBackgroundApp: Bool) -> AppItem? {
        let normalized = url.standardizedFileURL
        guard normalized.pathExtension.caseInsensitiveCompare("app") == .orderedSame,
              FileManager.default.fileExists(atPath: normalized.path) else {
            return nil
        }

        let bundle = Bundle(url: normalized)
        let displayName = (bundle?.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
            ?? (bundle?.object(forInfoDictionaryKey: "CFBundleName") as? String)
            ?? normalized.deletingPathExtension().lastPathComponent
        let bundleIdentifier = bundle?.bundleIdentifier
        let isBackgroundOnly = bundle?.object(forInfoDictionaryKey: "LSBackgroundOnly") as? Bool ?? false
        let isUIElement = bundle?.object(forInfoDictionaryKey: "LSUIElement") as? Bool ?? false
        guard allowsBackgroundApp || (!isBackgroundOnly && !isUIElement),
              seen.insert(normalized.path).inserted else { return nil }
        let category = AppCategorizer.category(name: displayName, bundleIdentifier: bundleIdentifier)

        // "WeChat" is filed as 微信 in its own zh-Hans resources and "Code" is really
        // Visual Studio Code on disk, so search has to know about those names too.
        var aliases = localizedNames(in: normalized)
        let fileName = normalized.deletingPathExtension().lastPathComponent
        if fileName.caseInsensitiveCompare(displayName) != .orderedSame {
            aliases.append(fileName)
        }

        return AppItem(
            name: displayName,
            path: normalized.path,
            bundleIdentifier: bundleIdentifier,
            category: category.rawValue,
            aliases: aliases
        )
    }

    /// Reads display names from the bundle's own `InfoPlist.strings` resources.
    /// Bundles such as WeChat only ship their Chinese name there.
    private static func localizedNames(in bundleURL: URL) -> [String] {
        let resources = bundleURL.appendingPathComponent("Contents/Resources")
        guard let entries = try? FileManager.default.contentsOfDirectory(atPath: resources.path) else {
            return []
        }

        var names: [String] = []
        for entry in entries where entry.hasSuffix(".lproj") {
            let stringsURL = resources
                .appendingPathComponent(entry)
                .appendingPathComponent("InfoPlist.strings")
            guard let dictionary = NSDictionary(contentsOf: stringsURL) else { continue }
            for key in ["CFBundleDisplayName", "CFBundleName"] {
                if let value = dictionary[key] as? String, !value.isEmpty {
                    names.append(value)
                }
            }
        }
        return names
    }
}
