import Foundation

/// A local snapshot of an application bundle shown in the launcher.
/// The normalized bundle path is the stable identity used by groups and SwiftUI.
///
/// `Sendable` because discovery now runs off the main actor and hands the finished array
/// back across that boundary.
public struct AppItem: Identifiable, Hashable, Sendable, RankedApp {
    public let id: String
    public let name: String
    public let path: String
    public let bundleIdentifier: String?
    /// Raw `ShelfCategory` value; translated only at display time.
    public let category: String
    public var isRunning: Bool
    /// Precomputed pinyin and initials so typing in the search fields stays instant.
    public let searchTokens: SearchTokens

    /// `aliases` carries names the app is known by but does not display, such as
    /// localized bundle names and the on-disk file name.
    public init(name: String,
                path: String,
                bundleIdentifier: String?,
                category: String,
                isRunning: Bool = false,
                aliases: [String] = []) {
        let normalizedPath = ShelfPath.normalize(path)
        self.id = normalizedPath
        self.name = name
        self.path = normalizedPath
        self.bundleIdentifier = bundleIdentifier
        self.category = category
        self.isRunning = isRunning
        self.searchTokens = SearchTokens(
            name: name,
            aliases: aliases,
            extras: [bundleIdentifier ?? "", category]
        )
    }

    public var displayName: String { name }

    /// Identity is the bundle path alone: two scans of the same bundle must compare equal
    /// even when one of them caught the app mid-launch.
    public static func == (lhs: AppItem, rhs: AppItem) -> Bool { lhs.id == rhs.id }

    public func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

/// A user-defined collection of application bundle paths.
/// Only paths are persisted; the bundle metadata is rebuilt during a scan.
public struct AppGroup: Identifiable, Codable, Hashable, Sendable {
    public let id: UUID
    public var name: String
    public var symbol: String
    public var colorHex: String
    public var appPaths: [String]

    public init(id: UUID = UUID(), name: String, symbol: String, colorHex: String, appPaths: [String] = []) {
        self.id = id
        self.name = name
        self.symbol = symbol
        self.colorHex = colorHex
        self.appPaths = appPaths
    }

    /// Paths normalized for comparison, in the order the user arranged them.
    public var normalizedPaths: [String] { appPaths.map(ShelfPath.normalize) }
}

/// The built-in views and user groups that can be selected in the sidebar.
public enum ShelfSelection: Hashable, Sendable {
    case all
    case running
    case ungrouped
    case hidden
    case group(UUID)
}

/// Starter groups shown on a first launch.
public enum DefaultGroups {
    public static let all: [AppGroup] = [
        AppGroup(name: ShelfCategory.common.rawValue, symbol: "star.fill", colorHex: "#F59E0B"),
        AppGroup(name: ShelfCategory.development.rawValue, symbol: "hammer.fill", colorHex: "#2F80ED"),
        AppGroup(name: ShelfCategory.communication.rawValue, symbol: "bubble.left.and.bubble.right.fill", colorHex: "#16A085"),
        AppGroup(name: ShelfCategory.creative.rawValue, symbol: "wand.and.stars", colorHex: "#D14D72"),
        AppGroup(name: ShelfCategory.everyday.rawValue, symbol: "house.fill", colorHex: "#7C5CFC"),
        AppGroup(name: ShelfCategory.utility.rawValue, symbol: "wrench.and.screwdriver.fill", colorHex: "#64748B")
    ]

    /// A fresh copy with new identities, so two stores never share a group UUID.
    public static func make() -> [AppGroup] {
        all.map { AppGroup(name: $0.name, symbol: $0.symbol, colorHex: $0.colorHex) }
    }
}
