import Foundation

/// Bundle paths are the identity of an app throughout the shelf, so every comparison has
/// to go through the same normalization: `/Applications/../Applications/Foo.app//` and
/// `/Applications/Foo.app` are the same bundle.
public enum ShelfPath {
    public static func normalize(_ path: String) -> String {
        URL(fileURLWithPath: path).standardizedFileURL.path
    }

    /// True for a path that names an application bundle, case-insensitively.
    ///
    /// The old checks used `hasSuffix(".app")`, which silently dropped `.APP` bundles on
    /// case-sensitive volumes and matched a folder named `NotAnApp.bundle`.
    public static func isApplicationBundle(_ path: String) -> Bool {
        URL(fileURLWithPath: path).pathExtension.lowercased() == "app"
    }
}

/// Stable identifiers for the persisted state, kept together so a key rename cannot
/// leave an orphan behind in `UserDefaults`.
public enum ShelfDefaults {
    public static let groupState = "AppShelf.state.v2"
    public static let sizeCache = "AppShelf.sizeCache.v2"
    public static let hiddenApps = "AppShelf.hiddenApps.v1"
    public static let hotKey = "AppShelf.hotkey.v1"
    public static let statusItem = "AppShelf.statusItem.v1"
    public static let language = "AppShelf.language"
    public static let appearance = "AppShelf.appearance"
    public static let quickToolsEnabled = "AppShelf.quickTools.enabled.v1"
    public static let gridDensity = "AppShelf.gridDensity.v1"
    public static let usage = "AppShelf.usage.v1"
    public static let quickToolsCustom = "AppShelf.quickTools.custom.v1"
    /// Obsolete formats that must be removed on launch, never written again.
    public static let retired = ["AppShelf.sizeCache.v1"]
}
