import AppKit
import Foundation

/// A user-picked app that behaves like a built-in quick tool.
struct CustomQuickTool: Identifiable, Codable, Hashable {
    let id: UUID
    var name: String
    var path: String

    init(id: UUID = UUID(), name: String, path: String) {
        self.id = id
        self.name = name
        self.path = path
    }
}

/// One entry in the quick tool row: either a built-in utility or an app the user added.
enum QuickToolItem: Identifiable, Hashable {
    case builtin(QuickTool)
    case custom(CustomQuickTool)

    var id: String {
        switch self {
        case .builtin(let tool): return "builtin.\(tool.rawValue)"
        case .custom(let tool): return "custom.\(tool.id.uuidString)"
        }
    }

    var title: String {
        switch self {
        case .builtin(let tool): return tool.title
        case .custom(let tool): return tool.name
        }
    }

    /// Built-ins use an SF Symbol; custom tools fall back to their own app icon.
    var symbol: String? {
        switch self {
        case .builtin(let tool): return tool.symbol
        case .custom: return nil
        }
    }

    var path: String? {
        switch self {
        case .builtin: return nil
        case .custom(let tool): return tool.path
        }
    }

    var isCustom: Bool {
        if case .custom = self { return true }
        return false
    }
}

/// Persists which quick tools are visible, in which order, and which apps were added.
final class QuickToolStore: ObservableObject {
    static let shared = QuickToolStore()

    private enum Key {
        static let enabled = "AppShelf.quickTools.enabled.v1"
        static let custom = "AppShelf.quickTools.custom.v1"
    }

    @Published private(set) var enabledIDs: [String]
    @Published private(set) var customTools: [CustomQuickTool]

    private init() {
        let defaults = UserDefaults.standard
        if let saved = defaults.array(forKey: Key.enabled) as? [String] {
            // Keep unknown ids out, but make sure newly added built-ins still appear.
            let known = Set(Self.allBuiltinIDs)
            let filtered = saved.filter { known.contains($0) }
            let missing = QuickTool.allCases.map { "builtin.\($0.rawValue)" }.filter { !filtered.contains($0) }
            enabledIDs = filtered + missing
        } else {
            enabledIDs = QuickTool.allCases.map { "builtin.\($0.rawValue)" }
        }

        if let data = defaults.data(forKey: Key.custom),
           let saved = try? JSONDecoder().decode([CustomQuickTool].self, from: data) {
            customTools = saved
        } else {
            customTools = []
        }
    }

    private static var allBuiltinIDs: [String] {
        QuickTool.allCases.map { "builtin.\($0.rawValue)" }
    }

    /// Visible tools in the user's order.
    var items: [QuickToolItem] {
        enabledIDs.compactMap { resolve($0) }
    }

    /// Everything that can be switched on, built-ins first.
    var allItems: [QuickToolItem] {
        QuickTool.allCases.map { QuickToolItem.builtin($0) } + customTools.map { QuickToolItem.custom($0) }
    }

    func isEnabled(_ id: String) -> Bool {
        enabledIDs.contains(id)
    }

    func setEnabled(_ id: String, isEnabled: Bool) {
        if isEnabled {
            guard !enabledIDs.contains(id) else { return }
            enabledIDs.append(id)
        } else {
            enabledIDs.removeAll { $0 == id }
        }
        persistEnabled()
    }

    /// Moves a visible tool one slot up or down.
    func move(_ id: String, by delta: Int) {
        guard let current = enabledIDs.firstIndex(of: id) else { return }
        let target = current + delta
        guard enabledIDs.indices.contains(target) else { return }
        enabledIDs.swapAt(current, target)
        persistEnabled()
    }

    func addCustom(name: String, path: String) {
        guard !customTools.contains(where: { $0.path == path }) else { return }
        let tool = CustomQuickTool(name: name, path: path)
        customTools.append(tool)
        persistCustom()
        enabledIDs.append(tool.quickToolID)
        persistEnabled()
    }

    func removeCustom(id: UUID) {
        customTools.removeAll { $0.id == id }
        persistCustom()
        enabledIDs.removeAll { $0 == "custom.\(id.uuidString)" }
        persistEnabled()
    }

    func resolve(_ id: String) -> QuickToolItem? {
        if id.hasPrefix("builtin.") {
            let rawValue = String(id.dropFirst("builtin.".count))
            guard let tool = QuickTool(rawValue: rawValue) else { return nil }
            return .builtin(tool)
        }
        if id.hasPrefix("custom.") {
            let rawValue = String(id.dropFirst("custom.".count))
            guard let uuid = UUID(uuidString: rawValue),
                  let tool = customTools.first(where: { $0.id == uuid }) else { return nil }
            return .custom(tool)
        }
        return nil
    }

    private func persistEnabled() {
        UserDefaults.standard.set(enabledIDs, forKey: Key.enabled)
    }

    private func persistCustom() {
        guard let data = try? JSONEncoder().encode(customTools) else { return }
        UserDefaults.standard.set(data, forKey: Key.custom)
    }
}

private extension CustomQuickTool {
    var quickToolID: String { "custom.\(id.uuidString)" }
}
