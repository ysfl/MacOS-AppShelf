import Foundation

/// A portable snapshot of everything the user arranged by hand.
///
/// Grouping and ordering is the entire value of the shelf, and until now it lived in one
/// `UserDefaults` blob with no way out — a new Mac started from zero. The payload carries
/// bundle paths rather than bundle metadata on purpose: metadata is rebuilt by a scan, and
/// shipping it would let an old export overwrite a newer local state.
public struct ShelfExport: Codable, Equatable, Sendable {
    public static let currentVersion = 1

    public var version: Int
    public var exportedAt: Date
    public var groups: [AppGroup]
    public var hiddenApps: [String]
    public var preferences: Preferences
    public var quickTools: QuickTools

    public struct Preferences: Codable, Equatable, Sendable {
        public var language: String
        public var appearance: String
        public var showsStatusItem: Bool
        /// `nil` leaves the receiving app's shortcut untouched.
        public var hotKey: HotKey?

        public init(language: String, appearance: String, showsStatusItem: Bool, hotKey: HotKey?) {
            self.language = language
            self.appearance = appearance
            self.showsStatusItem = showsStatusItem
            self.hotKey = hotKey
        }
    }

    public struct QuickTools: Codable, Equatable, Sendable {
        public var enabledIDs: [String]
        public var custom: [CustomQuickTool]

        public init(enabledIDs: [String], custom: [CustomQuickTool]) {
            self.enabledIDs = enabledIDs
            self.custom = custom
        }
    }

    public init(version: Int = ShelfExport.currentVersion,
                exportedAt: Date = Date(),
                groups: [AppGroup],
                hiddenApps: [String],
                preferences: Preferences,
                quickTools: QuickTools) {
        self.version = version
        self.exportedAt = exportedAt
        self.groups = groups
        self.hiddenApps = hiddenApps
        self.preferences = preferences
        self.quickTools = quickTools
    }
}

/// Validation applied to an imported file before anything is overwritten.
public enum ShelfImportReport: Equatable, Sendable {
    /// Safe to apply as-is.
    case valid
    /// Newer than this build understands; the caller should refuse rather than truncate.
    case unsupportedVersion(Int, supported: Int)
    /// Applied, but with the listed entries dropped.
    case appliedWithWarnings([Warning])

    public enum Warning: Equatable, Sendable {
        case groupWithoutName
        case duplicateGroupID
        /// A quick tool id pointed at nothing we could resolve.
        case unresolvedQuickToolID(String)
    }
}

public enum ShelfImport {
    /// Checks an export payload and repairs what can be repaired without user input.
    ///
    /// Returns `nil` alongside a refusal report when the file cannot be applied at all.
    public static func validate(_ export: ShelfExport) -> (cleaned: ShelfExport?, report: ShelfImportReport) {
        guard export.version <= ShelfExport.currentVersion else {
            return (nil, .unsupportedVersion(export.version, supported: ShelfExport.currentVersion))
        }

        var warnings: [ShelfImportReport.Warning] = []
        var seenIDs = Set<UUID>()

        let groups = export.groups.compactMap { group -> AppGroup? in
            let name = group.name.trimmingCharacters(in: .whitespacesAndNewlines)
            if name.isEmpty {
                warnings.append(.groupWithoutName)
                return nil
            }
            if seenIDs.contains(group.id) {
                warnings.append(.duplicateGroupID)
                return nil
            }
            seenIDs.insert(group.id)
            var cleaned = group
            cleaned.name = name
            return cleaned
        }

        let resolved = export.quickTools.enabledIDs.filter { raw in
            if QuickToolID(parsing: raw) != nil { return true }
            warnings.append(.unresolvedQuickToolID(raw))
            return false
        }

        let hidden = export.hiddenApps.map(ShelfPath.normalize)
        let cleaned = ShelfExport(version: ShelfExport.currentVersion,
                                  exportedAt: export.exportedAt,
                                  groups: groups,
                                  hiddenApps: hidden,
                                  preferences: export.preferences,
                                  quickTools: .init(enabledIDs: resolved, custom: export.quickTools.custom))

        return (cleaned, warnings.isEmpty ? .valid : .appliedWithWarnings(warnings))
    }

    public static func encode(_ export: ShelfExport, pretty: Bool) -> Data? {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        if pretty { encoder.outputFormatting = [.prettyPrinted, .sortedKeys] }
        return try? encoder.encode(export)
    }

    public static func decode(_ data: Data) -> ShelfExport? {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(ShelfExport.self, from: data)
    }
}
