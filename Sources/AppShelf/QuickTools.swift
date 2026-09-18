import AppKit
import Foundation

import AppShelfCore

/// One entry in the quick tool row: either a built-in utility or an app the user added.
enum QuickToolItem: Identifiable, Hashable {
    case builtin(QuickTool)
    case custom(CustomQuickTool)

    var id: String {
        switch self {
        case .builtin(let tool): return QuickToolID(tool.rawValue).rawValue
        case .custom(let tool): return QuickToolID(tool.id).rawValue
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

    @Published private(set) var enabledIDs: [String]
    @Published private(set) var customTools: [CustomQuickTool]

    /// Tools removed by dragging, kept so the row can offer them back without a trip
    /// through Settings.
    private static var builtinIDs: [String] {
        QuickTool.allCases.map { QuickToolID($0.rawValue).rawValue }
    }

    private init() {
        let defaults = UserDefaults.standard
        if let saved = defaults.array(forKey: ShelfDefaults.quickToolsEnabled) as? [String] {
            // Keep unknown ids out, but make sure newly added built-ins still appear.
            let known = Set(Self.builtinIDs)
            let filtered = saved.filter { known.contains($0) || QuickToolID(parsing: $0)?.isCustom == true }
            let missing = Self.builtinIDs.filter { !filtered.contains($0) }
            enabledIDs = filtered + missing
        } else {
            enabledIDs = Self.builtinIDs
        }

        if let data = defaults.data(forKey: ShelfDefaults.quickToolsCustom),
           let saved = try? JSONDecoder().decode([CustomQuickTool].self, from: data) {
            customTools = saved
        } else {
            customTools = []
        }
    }

    /// Visible tools in the user's order.
    var items: [QuickToolItem] { enabledIDs.compactMap { resolve($0) } }

    /// Everything that can be switched on, built-ins first.
    var allItems: [QuickToolItem] {
        QuickTool.allCases.map { QuickToolItem.builtin($0) } + customTools.map { QuickToolItem.custom($0) }
    }

    func isEnabled(_ id: String) -> Bool { enabledIDs.contains(id) }

    func setEnabled(_ id: String, isEnabled: Bool) {
        if isEnabled {
            guard !enabledIDs.contains(id) else { return }
            enabledIDs.append(id)
        } else {
            enabledIDs.removeAll { $0 == id }
        }
        persist()
    }

    /// Moves a visible tool one slot up or down.
    func move(_ id: String, by delta: Int) {
        guard let current = enabledIDs.firstIndex(of: id) else { return }
        let target = current + delta
        guard enabledIDs.indices.contains(target) else { return }
        enabledIDs.swapAt(current, target)
        persist()
    }

    func addCustom(name: String, path: String) {
        let normalized = ShelfPath.normalize(path)
        guard !customTools.contains(where: { $0.path == normalized }) else { return }
        let tool = CustomQuickTool(name: name, path: normalized)
        customTools.append(tool)
        enabledIDs.append(QuickToolID(tool.id).rawValue)
        persist()
    }

    /// Removes a tool from the row. Built-ins are only hidden; user-added tools are deleted.
    ///
    /// Returns the deleted entry so the caller can offer it back: drag-out used to destroy
    /// a custom tool with no confirmation and no way back.
    @discardableResult
    func remove(_ id: String) -> CustomQuickTool? {
        guard let tool = customTool(for: id) else {
            setEnabled(id, isEnabled: false)
            return nil
        }
        removeCustom(id: tool.id)
        return tool
    }

    func customTool(for id: String) -> CustomQuickTool? {
        guard case .custom(let uuid)? = QuickToolID(parsing: id) else { return nil }
        return customTools.first { $0.id == uuid }
    }

    func removeCustom(id: UUID) {
        customTools.removeAll { $0.id == id }
        enabledIDs.removeAll { $0 == QuickToolID(id).rawValue }
        persist()
    }

    func restoreCustom(_ tool: CustomQuickTool) {
        guard !customTools.contains(where: { $0.id == tool.id }) else { return }
        customTools.append(tool)
        let id = QuickToolID(tool.id).rawValue
        if !enabledIDs.contains(id) { enabledIDs.append(id) }
        persist()
    }

    /// Replaces both lists at once, used by undo and by import.
    func restore(enabledIDs: [String], custom: [CustomQuickTool]) {
        let known = Set(custom.map { QuickToolID($0.id).rawValue })
        let builtins = Set(Self.builtinIDs)
        self.enabledIDs = enabledIDs.filter { builtins.contains($0) || known.contains($0) }
        self.customTools = custom
        persist()
    }

    func resolve(_ id: String) -> QuickToolItem? {
        guard let parsed = QuickToolID(parsing: id) else { return nil }
        switch parsed {
        case .builtin(let rawValue):
            guard let tool = QuickTool(rawValue: rawValue) else { return nil }
            return .builtin(tool)
        case .custom(let uuid):
            guard let tool = customTools.first(where: { $0.id == uuid }) else { return nil }
            return .custom(tool)
        }
    }

    private func persist() {
        let defaults = UserDefaults.standard
        defaults.set(enabledIDs, forKey: ShelfDefaults.quickToolsEnabled)
        guard let data = try? JSONEncoder().encode(customTools) else { return }
        defaults.set(data, forKey: ShelfDefaults.quickToolsCustom)
    }
}
