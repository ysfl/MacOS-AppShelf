import AppKit
import Combine
import Foundation
import SwiftUI

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

// MARK: - Undo

/// A restorable point in the user's own arrangement.
///
/// Snapshot rather than inverse-operation: grouping, ordering, hiding and quick tools all
/// cross-cut the same few lists, and restoring a whole snapshot is the only undo that
/// stays correct as those models evolve.
struct ShelfSnapshot: Equatable {
    var groups: [AppGroup]
    var hidden: HiddenAppList
    var quickToolEnabledIDs: [String]
    var customQuickTools: [CustomQuickTool]
}

// MARK: - Store

/// Owns the discovered app snapshots and the user-editable group state for the window.
@MainActor
final class LauncherStore: ObservableObject {
    /// Every discovered app, including hidden ones.
    @Published private(set) var apps: [AppItem] = [] {
        didSet {
            // Lookups happen once per scan rather than once per card per redraw.
            appLookup = Dictionary(uniqueKeysWithValues: apps.map { ($0.path, $0) })
        }
    }
    @Published private(set) var groups: [AppGroup] = []
    @Published private(set) var hidden = HiddenAppList()
    @Published var selection: ShelfSelection = .all
    @Published var query = ""
    @Published var runningOnly = false
    @Published private(set) var isLoading = true
    /// When the file system was last scanned. Deliberately *not* bumped by the periodic
    /// running-state tick: publishing it every few seconds invalidated the whole page,
    /// which rebuilt every card for a timestamp that had not meaningfully changed.
    @Published private(set) var lastUpdated = Date()
    @Published var errorMessage: String?
    /// Short-lived feedback shown in the footer, e.g. after an app is dropped onto a group.
    @Published var statusMessage: String?
    /// Set while a scan is running so a repeated Refresh cannot queue a second one.
    @Published private(set) var isScanning = false

    /// True when there is something to undo.
    @Published private(set) var canUndo = false

    /// Disk and memory usage for the cards.
    let metrics = AppMetrics.shared

    private var appLookup: [String: AppItem] = [:]
    private var statusClearTask: Task<Void, Never>?
    private var loadedPersistedState = false
    private var scanTask: Task<Void, Never>?
    private var undoStack: [ShelfSnapshot] = []
    private let undoLimit = 25

    init() {
        loadState()
        reload()
    }

    // MARK: Derived views

    /// Apps the user has not hidden. Everything the grid can show derives from this.
    var visibleApps: [AppItem] { hidden.filtering(apps) }

    var selectedGroup: AppGroup? {
        guard case let .group(id) = selection else { return nil }
        return groups.first { $0.id == id }
    }

    /// Group names are translated through the same table as everything else: a built-in
    /// group's name *is* its Chinese key, so 开发 reads as "Development" in English while a
    /// user-typed name like "AI 工具" has no entry and is shown as written.
    func title(for group: AppGroup) -> String { L10n.shared.t(group.name) }

    var selectedTitle: String {
        switch selection {
        case .all: return L10n.shared.t("全部应用")
        case .running: return L10n.shared.t("正在运行")
        case .ungrouped: return L10n.shared.t("未分组")
        case .hidden: return L10n.shared.t("已隐藏")
        case .group(let id):
            guard let group = groups.first(where: { $0.id == id }) else { return L10n.shared.t("分组") }
            return title(for: group)
        }
    }

    var selectedSymbol: String {
        switch selection {
        case .all: return "square.grid.2x2.fill"
        case .running: return "bolt.fill"
        case .ungrouped: return "tray"
        case .hidden: return "eye.slash.fill"
        case .group(let id): return groups.first { $0.id == id }?.symbol ?? "folder"
        }
    }

    /// Same filtering as `filteredApps` without the sort, for counts in the header.
    var filteredCount: Int { applyingFilters().count }

    var filteredApps: [AppItem] { applyingFilters() }

    private func applyingFilters() -> [AppItem] {
        var result: [AppItem]
        // Apply the sidebar selection first, then the text and running-state filters.
        switch selection {
        case .all:
            result = visibleApps
        case .running:
            result = visibleApps.filter(\.isRunning)
        case .ungrouped:
            let grouped = MembershipIndex.groupedPaths(groups: groups)
            result = visibleApps.filter { !grouped.contains($0.path) }
        case .hidden:
            return hiddenAppsInOrder()
        case .group(let id):
            let paths = Set(groups.first { $0.id == id }?.normalizedPaths ?? [])
            result = visibleApps.filter { paths.contains($0.path) }
        }

        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedQuery.isEmpty {
            // While searching, relevance order wins over the running-first order below,
            // so the best match for "wx" stays at the top even when another app is running.
            let ranked = SearchMatcher.ranked(result, query: trimmedQuery, limit: Int.max)
            if runningOnly && selection != .running { return ranked.filter(\.isRunning) }
            return ranked
        }

        if runningOnly && selection != .running {
            result = result.filter(\.isRunning)
        }

        return result.sorted { lhs, rhs in
            if lhs.isRunning != rhs.isRunning { return lhs.isRunning }
            return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
        }
    }

    private func hiddenAppsInOrder() -> [AppItem] {
        apps.filter { hidden.contains($0.path) }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// Ranked search across every visible app.
    func searchResults(for query: String, limit: Int = 40) -> [AppItem] {
        SearchMatcher.ranked(visibleApps, query: query, limit: limit)
    }

    /// Shows a short confirmation in the footer and clears it a few seconds later.
    func note(_ message: String) {
        statusMessage = message
        statusClearTask?.cancel()
        statusClearTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            guard !Task.isCancelled else { return }
            self?.statusMessage = nil
        }
    }

    /// Return the sidebar count without applying the search field.
    func count(for selection: ShelfSelection) -> Int {
        switch selection {
        case .all: return visibleApps.count
        case .running: return visibleApps.filter(\.isRunning).count
        case .ungrouped:
            let grouped = MembershipIndex.groupedPaths(groups: groups)
            return visibleApps.filter { !grouped.contains($0.path) }.count
        case .hidden: return hidden.count
        case .group(let id):
            let paths = Set(groups.first { $0.id == id }?.normalizedPaths ?? [])
            return visibleApps.filter { paths.contains($0.path) }.count
        }
    }

    // MARK: Scanning

    /// Re-scan bundle locations and then merge the current running state.
    ///
    /// Discovery walks three directory trees and opens every `Info.plist` it finds, which
    /// measured ~160 ms for 135 apps. It used to run inline, so `isLoading` never got a
    /// RunLoop turn and the loading state could not be seen; now it is published first and
    /// the walk happens off the main actor.
    func reload() {
        guard !isScanning else { return }
        isScanning = true
        isLoading = true

        // Saved paths are passed back into discovery so manually added apps survive a refresh.
        let savedPaths = groups.flatMap(\.appPaths)
        let restoreDefaults = !loadedPersistedState

        scanTask = Task { [weak self] in
            let discovered = await Task.detached(priority: .userInitiated) {
                AppDiscoveryService.discover(additionalPaths: savedPaths)
            }.value

            guard let self, !Task.isCancelled else { return }
            self.applyScan(discovered, seedingDefaults: restoreDefaults)
        }
    }

    private func applyScan(_ discovered: [AppItem], seedingDefaults: Bool) {
        defer { isScanning = false; isLoading = false }

        var discovered = discovered

        if seedingDefaults {
            // Bootstrap defaults only once. Existing UserDefaults must remain user-owned.
            groups = DefaultGroups.make()
            assignInitialGroups(for: discovered)
            loadedPersistedState = true
            persistState()
        }

        let running = runningProcesses()
        discovered = discovered.map { app in
            var updated = app
            updated.isRunning = running.paths.contains(app.path)
            return updated
        }

        apps = discovered
        lastUpdated = Date()

        // Usage data is read in the background so the grid stays responsive. Disk size is
        // requested per tile as it appears; memory is already on the utility queue, so
        // neither blocks this pile-up of redraws.
        metrics.register(discovered)
        metrics.updateMemory(forAppPaths: Array(running.paths))
    }

    /// Refresh only process state so a timer does not repeatedly walk the file system.
    func refreshRunningState() {
        guard !isScanning else { return }
        let running = runningProcesses()
        let updated = apps.map { app -> AppItem in
            var item = app
            item.isRunning = running.paths.contains(app.path)
            return item
        }

        // Publishing a new array every tick would rebuild every card, so the grid is only
        // invalidated when something actually changed.
        let didChange = zip(apps, updated).contains { $0.isRunning != $1.isRunning }
        if didChange { apps = updated }

        metrics.updateMemory(forAppPaths: Array(running.paths))
    }

    // MARK: Launching

    /// Ask Launch Services to open a discovered bundle.
    @discardableResult
    func launch(_ app: AppItem) -> Bool {
        let success = NSWorkspace.shared.open(URL(fileURLWithPath: app.path))
        if !success {
            errorMessage = L10n.shared.t("cannot_open", args: ["name": app.name])
        } else {
            refreshRunningState()
        }
        return success
    }

    /// Launch a built-in utility by identifier, with a path fallback for system apps.
    @discardableResult
    func launch(_ tool: QuickTool) -> Bool {
        // Bundle identifiers handle localized app names. The known paths cover system layouts
        // where Launch Services cannot resolve the identifier yet.
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: tool.bundleIdentifier) {
            let success = NSWorkspace.shared.open(url)
            if !success { errorMessage = L10n.shared.t("cannot_open", args: ["name": tool.title]) }
            return success
        }

        for path in tool.fallbackPaths where FileManager.default.fileExists(atPath: path) {
            let success = NSWorkspace.shared.open(URL(fileURLWithPath: path))
            if !success { errorMessage = L10n.shared.t("cannot_open", args: ["name": tool.title]) }
            return success
        }

        errorMessage = L10n.shared.t("not_found", args: ["name": tool.title])
        return false
    }

    /// Opens a quick tool entry, which is either a built-in utility or a user-picked app.
    @discardableResult
    func launch(_ tool: QuickToolItem) -> Bool {
        if case .builtin(let builtin) = tool { return launch(builtin) }

        guard let path = tool.path else { return false }
        let success = NSWorkspace.shared.open(URL(fileURLWithPath: path))
        if !success {
            errorMessage = L10n.shared.t("cannot_open", args: ["name": tool.title])
        } else {
            refreshRunningState()
        }
        return success
    }

    /// Quits a running app. `force` is the equivalent of `kill -9` and skips the
    /// app's own save and confirm steps.
    @discardableResult
    func terminate(_ app: AppItem, force: Bool = false) -> Bool {
        guard let running = NSWorkspace.shared.runningApplications.first(where: {
            $0.bundleURL?.standardizedFileURL.path == app.path
        }) else {
            errorMessage = L10n.shared.t("not_running", args: ["name": app.name])
            return false
        }

        let stopped = force ? running.forceTerminate() : running.terminate()
        if stopped {
            refreshRunningState()
            note(force ? L10n.shared.t("force_quit_app", args: ["name": app.name])
                       : L10n.shared.t("quit_app", args: ["name": app.name]))
        } else {
            errorMessage = L10n.shared.t("cannot_quit", args: ["name": app.name])
        }
        return stopped
    }

    /// Reveal the bundle in Finder without changing its location.
    func openInFinder(_ app: AppItem) {
        NSWorkspace.shared.selectFile(app.path, inFileViewerRootedAtPath: "")
    }

    func showPackageContents(_ app: AppItem) {
        NSWorkspace.shared.open(URL(fileURLWithPath: app.path).appendingPathComponent("Contents"))
    }

    func copyBundleIdentifier(_ app: AppItem) {
        guard let identifier = app.bundleIdentifier else {
            errorMessage = L10n.shared.t("no_bundle_id", args: ["name": app.name])
            return
        }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(identifier, forType: .string)
        note(L10n.shared.t("copied_bundle_id", args: ["id": identifier]))
    }

    // MARK: Groups

    /// Append a new group and select it so the user can add apps immediately.
    func createGroup(name: String, symbol: String, colorHex: String) {
        let cleanedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanedName.isEmpty else { return }
        willChangeArrangement()
        let group = AppGroup(name: cleanedName, symbol: symbol, colorHex: colorHex)
        groups.append(group)
        selection = .group(group.id)
        persistState()
    }

    func renameGroup(id: UUID, name: String, symbol: String, colorHex: String) {
        guard let index = groups.firstIndex(where: { $0.id == id }) else { return }
        let cleanedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanedName.isEmpty else { return }
        willChangeArrangement()
        groups[index].name = cleanedName
        groups[index].symbol = symbol
        groups[index].colorHex = colorHex
        persistState()
    }

    /// Delete only the grouping metadata; application bundles remain untouched.
    func deleteGroup(id: UUID) {
        guard groups.count > 1, let index = groups.firstIndex(where: { $0.id == id }) else { return }
        willChangeArrangement()
        groups.remove(at: index)
        if selection == .group(id) { selection = .all }
        persistState()
    }

    /// Reorders groups, used when a sidebar row or an All Apps section header is dragged.
    func moveGroup(_ id: UUID, before targetID: UUID) {
        let reordered = ShelfOrdering.reorder(groups.map(\.id).map(\.uuidString),
                                              moving: id.uuidString,
                                              before: targetID.uuidString)
        guard reordered != groups.map(\.id).map(\.uuidString) else { return }
        willChangeArrangement()
        let lookup = Dictionary(uniqueKeysWithValues: groups.map { ($0.id.uuidString, $0) })
        groups = reordered.compactMap { lookup[$0] }
        persistState()
    }

    // MARK: Membership

    /// Import selected bundles and attach their normalized paths to one group.
    func addApps(_ urls: [URL], to groupID: UUID) {
        guard let groupIndex = groups.firstIndex(where: { $0.id == groupID }) else { return }
        willChangeArrangement()

        for url in urls {
            guard let item = AppDiscoveryService.item(for: url) else { continue }
            if !apps.contains(where: { $0.path == item.path }) { apps.append(item) }
            if !groups[groupIndex].appPaths.contains(where: { ShelfPath.normalize($0) == item.path }) {
                groups[groupIndex].appPaths.append(item.path)
            }
            hidden.reveal(item.path)
        }

        sortAppsByName()
        metrics.register(apps)
        persistState()
    }

    /// Add an existing card to another group without removing its current membership.
    func addApp(_ app: AppItem, to groupID: UUID) {
        guard let groupIndex = groups.firstIndex(where: { $0.id == groupID }) else { return }
        guard !groups[groupIndex].appPaths.contains(where: { ShelfPath.normalize($0) == app.path }) else { return }
        willChangeArrangement()
        groups[groupIndex].appPaths.append(app.path)
        persistState()
    }

    /// Remove a path from one group; the app remains available in All Apps.
    func removeApp(_ path: String, from groupID: UUID) {
        guard let groupIndex = groups.firstIndex(where: { $0.id == groupID }) else { return }
        let before = groups[groupIndex].appPaths.count
        let target = ShelfPath.normalize(path)
        let removed = groups[groupIndex].appPaths.filter { ShelfPath.normalize($0) == target }
        guard !removed.isEmpty else { return }
        willChangeArrangement()
        groups[groupIndex].appPaths.removeAll { ShelfPath.normalize($0) == target }
        guard groups[groupIndex].appPaths.count != before else { return }
        persistState()
        note(L10n.shared.t("removed_from_group", args: ["name": title(for: groups[groupIndex])]))
    }

    func removeApp(_ app: AppItem, from groupID: UUID) {
        removeApp(app.path, from: groupID)
    }

    /// Every group this app currently belongs to, used by the card's context menu.
    func groupMembership() -> [String: [AppGroup]] { MembershipIndex.build(groups: groups) }

    /// Apps of one group in the order the user arranged them.
    func orderedApps(in groupID: UUID) -> [AppItem] {
        groups.first { $0.id == groupID }?.normalizedPaths.compactMap { appLookup[$0] } ?? []
    }

    /// Apps that are not part of any group.
    func ungroupedApps() -> [AppItem] {
        MembershipIndex.ungrouped(visibleApps, groups: groups)
    }

    /// Adds bundle paths dropped onto a group. Anything that is not an existing `.app`
    /// bundle is ignored, so dropped text cannot create broken entries.
    func addApps(_ paths: [String], to groupID: UUID) {
        guard let groupIndex = groups.firstIndex(where: { $0.id == groupID }) else { return }
        var addedCount = 0
        var pending: [AppItem] = []

        for path in paths {
            let url = URL(fileURLWithPath: path)
            guard ShelfPath.isApplicationBundle(path), FileManager.default.fileExists(atPath: path),
                  let item = AppDiscoveryService.item(for: url) else { continue }
            if !apps.contains(where: { $0.path == item.path }) { pending.append(item) }
            if !groups[groupIndex].appPaths.contains(where: { ShelfPath.normalize($0) == item.path }) {
                addedCount += 1
            }
        }

        guard addedCount > 0 else { return }
        willChangeArrangement()

        for item in pending where !apps.contains(where: { $0.path == item.path }) {
            apps.append(item)
            hidden.reveal(item.path)
        }
        for path in paths {
            let normalized = ShelfPath.normalize(path)
            guard ShelfPath.isApplicationBundle(normalized),
                  !groups[groupIndex].appPaths.contains(where: { ShelfPath.normalize($0) == normalized }) else { continue }
            groups[groupIndex].appPaths.append(normalized)
        }

        sortAppsByName()
        metrics.register(apps)
        persistState()
        note(L10n.shared.t("added_to_group", args: ["count": "\(addedCount)", "name": title(for: groups[groupIndex])]))
    }

    /// Replaces a group's order in one step.
    ///
    /// The index math lives in `ShelfOrdering`; this only decides whether anything changed,
    /// records the undo point, and writes once.
    func applyOrder(_ dragged: [String], placement: ShelfOrdering.Placement, in groupID: UUID) {
        guard let index = groups.firstIndex(where: { $0.id == groupID }) else { return }
        let draggedPaths = dragged.map(ShelfPath.normalize)
        let target = ShelfPath.normalize(placement.target)
        let current = groups[index].normalizedPaths

        let next: [String]
        switch placement.edge {
        case .before: next = ShelfOrdering.move(draggedPaths, before: target, in: current)
        case .after: next = ShelfOrdering.move(draggedPaths, after: target, in: current)
        }
        guard next != current else { return }

        willChangeArrangement()
        groups[index].appPaths = next
        persistState()
    }

    // MARK: Hiding

    /// Takes an app off the shelf without touching the bundle.
    func hideApp(_ app: AppItem) {
        guard hidden.hide(app.path) else { return }
        willChangeArrangement()
        persistHidden()
        note(L10n.shared.t("hidden_app", args: ["name": app.name]))
    }

    func revealApp(_ app: AppItem) {
        guard hidden.reveal(app.path) else { return }
        willChangeArrangement()
        persistHidden()
        note(L10n.shared.t("revealed_app", args: ["name": app.name]))
    }

    /// Brings every hidden app back at once, from the empty state of the hidden view.
    func revealAllHidden() {
        let count = hidden.count
        guard count > 0 else { return }
        willChangeArrangement()
        hidden.revealAll()
        if selection == .hidden { selection = .all }
        persistHidden()
        note(L10n.shared.t("revealed_all", args: ["count": "\(count)"]))
    }

    // MARK: Undo

    /// Opens an undo point for a change made outside the store, such as a quick tool
    /// removal. Callers must invoke this immediately before mutating.
    func recordUndoPoint() { willChangeArrangement() }

    /// Records the current arrangement before a change the user may want back.
    private func willChangeArrangement() {
        undoStack.append(currentSnapshot())
        if undoStack.count > undoLimit { undoStack.removeFirst(undoStack.count - undoLimit) }
        canUndo = true
    }

    func undo() {
        guard let previous = undoStack.popLast() else { return }
        applySnapshot(previous)
        canUndo = !undoStack.isEmpty
        note(L10n.shared.t("已撤销"))
    }

    private func currentSnapshot() -> ShelfSnapshot {
        ShelfSnapshot(groups: groups,
                      hidden: hidden,
                      quickToolEnabledIDs: QuickToolStore.shared.enabledIDs,
                      customQuickTools: QuickToolStore.shared.customTools)
    }

    private func applySnapshot(_ snapshot: ShelfSnapshot) {
        groups = snapshot.groups
        hidden = snapshot.hidden
        if selection == .hidden, hidden.isEmpty { selection = .all }
        QuickToolStore.shared.restore(enabledIDs: snapshot.quickToolEnabledIDs,
                                     custom: snapshot.customQuickTools)
        persistState()
        persistHidden()
    }

    // MARK: Persistence

    /// Writes group state immediately. Drop handlers call this once the arrangement is final.
    func persistGroups() { persistState() }

    private func loadState() {
        let defaults = UserDefaults.standard
        if let data = defaults.data(forKey: ShelfDefaults.groupState),
           let saved = try? JSONDecoder().decode([AppGroup].self, from: data),
           !saved.isEmpty {
            groups = saved
            loadedPersistedState = true
        } else {
            groups = DefaultGroups.make()
        }

        if let data = defaults.data(forKey: ShelfDefaults.hiddenApps),
           let saved = try? JSONDecoder().decode([String].self, from: data) {
            hidden = HiddenAppList(paths: saved)
        }
    }

    /// Encode only the small, user-editable group model; bundle metadata is never persisted.
    private func persistState() {
        guard let data = try? JSONEncoder().encode(groups) else { return }
        UserDefaults.standard.set(data, forKey: ShelfDefaults.groupState)
    }

    private func persistHidden() {
        guard let data = try? JSONEncoder().encode(Array(hidden.paths).sorted()) else { return }
        UserDefaults.standard.set(data, forKey: ShelfDefaults.hiddenApps)
    }

    private func assignInitialGroups(for discovered: [AppItem]) {
        // This is a one-time convenience pass, not a permanent categorization rule.
        for app in discovered {
            guard let target = AppCategorizer.seedGroup(for: app.name, bundleIdentifier: app.bundleIdentifier),
                  let index = groups.firstIndex(where: { $0.name == target.rawValue }) else { continue }
            groups[index].appPaths.append(app.path)
        }
    }

    private func sortAppsByName() {
        apps.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// Bundle paths paired with pids, so card footers can show both size and memory.
    func runningProcesses() -> (paths: Set<String>, processes: [(path: String, pid: Int32)]) {
        var paths: Set<String> = []
        var processes: [(path: String, pid: Int32)] = []

        for application in NSWorkspace.shared.runningApplications {
            guard let bundleURL = application.bundleURL else { continue }
            let path = bundleURL.standardizedFileURL.path
            paths.insert(path)
            processes.append((path, application.processIdentifier))
        }

        return (paths, processes)
    }
}

// MARK: - Export / import

extension LauncherStore {
    /// Everything the user arranged, as a portable payload.
    func exportSnapshot() -> ShelfExport {
        ShelfExport(groups: groups,
                    hiddenApps: Array(hidden.paths).sorted(),
                    preferences: .init(language: L10n.shared.language,
                                       appearance: Appearance.shared.mode.rawValue,
                                       showsStatusItem: HotKeyStore.shared.showsStatusItem,
                                       hotKey: HotKeyStore.shared.shortcut),
                    quickTools: .init(enabledIDs: QuickToolStore.shared.enabledIDs,
                                       custom: QuickToolStore.shared.customTools))
    }

    /// Applies an import, reporting what had to be dropped. Returns false when refused.
    @discardableResult
    func applyImport(_ export: ShelfExport) -> Bool {
        let result = ShelfImport.validate(export)
        switch result.report {
        case .unsupportedVersion(let found, let supported):
            errorMessage = L10n.shared.t("import_version_too_new",
                                         args: ["found": "\(found)", "supported": "\(supported)"])
            return false
        case .appliedWithWarnings(let warnings):
            note(L10n.shared.t("import_partial", args: ["count": "\(warnings.count)"]))
        case .valid:
            break
        }

        guard let cleaned = result.cleaned else { return false }

        willChangeArrangement()
        groups = cleaned.groups
        hidden = HiddenAppList(paths: cleaned.hiddenApps)
        if selection == .hidden, hidden.isEmpty { selection = .all }
        L10n.shared.language = cleaned.preferences.language
        Appearance.shared.mode = AppearanceMode(rawValue: cleaned.preferences.appearance) ?? .system
        HotKeyStore.shared.showsStatusItem = cleaned.preferences.showsStatusItem
        HotKeyStore.shared.shortcut = cleaned.preferences.hotKey ?? .fallback
        QuickToolStore.shared.restore(enabledIDs: cleaned.quickTools.enabledIDs,
                                     custom: cleaned.quickTools.custom)
        persistState()
        persistHidden()
        return true
    }
}
