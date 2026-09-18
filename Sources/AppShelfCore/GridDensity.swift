import Foundation

/// Tile-grid density, offered as a user preference.
///
/// Each case owns one `GridMetricsSpec`, and both the SwiftUI `GridItem` array and the
/// slide geometry are derived from it, so a density change cannot desynchronise the two.
public enum GridDensity: String, CaseIterable, Codable, Sendable {
    case compact
    case standard
    case spacious

    public static let defaultDensity: GridDensity = .standard

    public var spec: GridMetricsSpec {
        switch self {
        case .compact: GridMetricsSpec(minimum: 112, maximum: 142, columnSpacing: 10, rowSpacing: 12)
        case .standard: .standard
        case .spacious: GridMetricsSpec(minimum: 168, maximum: 214, columnSpacing: 18, rowSpacing: 20)
        }
    }

    /// Shortest card height, so a denser grid does not clip the two-line name.
    public var minimumRowHeight: Double {
        switch self {
        case .compact: 132
        case .standard: 158
        case .spacious: 186
        }
    }

    /// Settings label; the raw value doubles as the translation key.
    public var titleKey: String {
        switch self {
        case .compact: return "紧凑"
        case .standard: return "标准"
        case .spacious: return "宽松"
        }
    }

    /// Icon edge in points.
    public var iconSide: Double {
        switch self {
        case .compact: 62
        case .standard: 84
        case .spacious: 104
        }
    }
}

/// Launch counts and recency, as a pure ranking input.
///
/// Kept free of storage so the ordering it produces is testable; the app target owns the
/// persisted numbers and feeds them in.
public enum UsageRanking {
    /// Orders two items by "how often", then by "how recently", then by name.
    /// Used for the empty-query list, where there is no score to rank on.
    public static func sorted<Item: RankedApp>(_ items: [Item],
                                               counts: (Item) -> Int,
                                               lastUsed: (Item) -> Date?) -> [Item] {
        items.sorted { lhs, rhs in
            if lhs.isRunning != rhs.isRunning { return lhs.isRunning }
            let lhsCount = counts(lhs), rhsCount = counts(rhs)
            if lhsCount != rhsCount { return lhsCount > rhsCount }
            switch (lastUsed(lhs), lastUsed(rhs)) {
            case let (a?, b?): if a != b { return a > b }
            case (_?, nil): return true
            case (nil, _?): return false
            case (nil, nil): break
            }
            return lhs.displayName.localizedCaseInsensitiveCompare(rhs.displayName) == .orderedAscending
        }
    }
}
