import Foundation

/// Bundles the user does not want to see, addressed by normalized path.
///
/// Hiding is the missing counterpart to "remove from group": until now the only way to get
/// an app off the shelf was to never have it installed. The list survives a rescan, and an
/// app that is reinstalled at the same path stays hidden, which is what the user expects.
public struct HiddenAppList: Equatable, Codable, Sendable {
    public private(set) var paths: Set<String>

    public init(paths: [String] = []) {
        self.paths = Set(paths.map(ShelfPath.normalize))
    }

    public func contains(_ path: String) -> Bool { paths.contains(ShelfPath.normalize(path)) }
    public var isEmpty: Bool { paths.isEmpty }
    public var count: Int { paths.count }

    /// Returns false when the app was already hidden, so callers can skip a save.
    @discardableResult
    public mutating func hide(_ path: String) -> Bool { paths.insert(ShelfPath.normalize(path)).inserted }

    @discardableResult
    public mutating func reveal(_ path: String) -> Bool { paths.remove(ShelfPath.normalize(path)) != nil }

    public mutating func revealAll() { paths.removeAll() }

    public func filtering(_ apps: [AppItem]) -> [AppItem] {
        guard !paths.isEmpty else { return apps }
        return apps.filter { !paths.contains($0.path) }
    }
}

/// Which groups an app belongs to, inverted from the per-group path lists.
public enum MembershipIndex {
    public static func build(groups: [AppGroup]) -> [String: [AppGroup]] {
        var membership: [String: [AppGroup]] = [:]
        for group in groups {
            for path in group.appPaths {
                membership[ShelfPath.normalize(path), default: []].append(group)
            }
        }
        return membership
    }

    /// Paths that appear in at least one group.
    public static func groupedPaths(groups: [AppGroup]) -> Set<String> {
        Set(groups.flatMap { $0.appPaths.map(ShelfPath.normalize) })
    }

    public static func ungrouped(_ apps: [AppItem], groups: [AppGroup]) -> [AppItem] {
        let grouped = groupedPaths(groups: groups)
        return apps
            .filter { !grouped.contains($0.path) }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }
}
