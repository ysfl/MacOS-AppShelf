import Foundation

/// A user-picked app that behaves like a built-in quick tool.
public struct CustomQuickTool: Identifiable, Codable, Hashable, Sendable {
    public let id: UUID
    public var name: String
    public var path: String

    public init(id: UUID = UUID(), name: String, path: String) {
        self.id = id
        self.name = name
        self.path = ShelfPath.normalize(path)
    }
}

/// Quick tools are addressed by a prefixed string id so built-ins and user-added apps can
/// share one ordered list. Parsing that prefix by hand in three places is how a malformed
/// id ends up silently deleting the wrong entry.
public enum QuickToolID: Equatable, Hashable, Sendable {
    case builtin(String)
    case custom(UUID)

    public static let builtinPrefix = "builtin."
    public static let customPrefix = "custom."

    public init?(parsing raw: String) {
        if raw.hasPrefix(QuickToolID.builtinPrefix) {
            let value = String(raw.dropFirst(QuickToolID.builtinPrefix.count))
            guard !value.isEmpty else { return nil }
            self = .builtin(value)
            return
        }
        if raw.hasPrefix(QuickToolID.customPrefix) {
            guard let uuid = UUID(uuidString: String(raw.dropFirst(QuickToolID.customPrefix.count))) else { return nil }
            self = .custom(uuid)
            return
        }
        return nil
    }

    public init(_ builtin: String) { self = .builtin(builtin) }
    public init(_ custom: UUID) { self = .custom(custom) }

    public var rawValue: String {
        switch self {
        case .builtin(let name): return QuickToolID.builtinPrefix + name
        case .custom(let uuid): return QuickToolID.customPrefix + uuid.uuidString
        }
    }

    public var isCustom: Bool {
        if case .custom = self { return true }
        return false
    }
}
