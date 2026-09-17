import AppKit
import Combine
import Foundation
import SwiftUI

/// A local snapshot of an application bundle shown in the launcher.
/// The normalized bundle path is the stable identity used by groups and SwiftUI.
struct AppItem: Identifiable, Hashable {
    let id: String
    let name: String
    let path: String
    let bundleIdentifier: String?
    let category: String
    var isRunning: Bool
    /// Precomputed pinyin and initials so typing in the search fields stays instant.
    let searchTokens: SearchTokens

    /// `aliases` carries names the app is known by but does not display, such as
    /// localized bundle names and the on-disk file name.
    init(
        name: String,
        path: String,
        bundleIdentifier: String?,
        category: String,
        isRunning: Bool = false,
        aliases: [String] = []
    ) {
        let normalizedPath = URL(fileURLWithPath: path).standardizedFileURL.path
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

    static func == (lhs: AppItem, rhs: AppItem) -> Bool {
        lhs.id == rhs.id
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
}

/// A user-defined collection of application bundle paths.
/// Only paths are persisted; the bundle metadata is rebuilt during a scan.
struct AppGroup: Identifiable, Codable, Hashable {
    let id: UUID
    var name: String
    var symbol: String
    var colorHex: String
    var appPaths: [String]

    var color: Color {
        Color(hex: colorHex)
    }

    init(id: UUID = UUID(), name: String, symbol: String, colorHex: String, appPaths: [String] = []) {
        self.id = id
        self.name = name
        self.symbol = symbol
        self.colorHex = colorHex
        self.appPaths = appPaths
    }
}

/// The built-in views and user group that can be selected in the sidebar.
enum ShelfSelection: Hashable {
    case all
    case running
    case ungrouped
    case group(UUID)
}

/// Apple utilities that can be launched even when they are not in the app grid.
enum QuickTool: String, CaseIterable, Identifiable {
    case calculator
    case terminal
    case activityMonitor
    case screenshot
    case systemSettings

    var id: String { rawValue }

    var title: String {
        switch self {
        case .calculator: return "计算器"
        case .terminal: return "终端"
        case .activityMonitor: return "活动监视器"
        case .screenshot: return "截图"
        case .systemSettings: return "系统设置"
        }
    }

    var symbol: String {
        switch self {
        case .calculator: return "plus.forwardslash.minus"
        case .terminal: return "apple.terminal"
        case .activityMonitor: return "waveform.path.ecg"
        case .screenshot: return "rectangle.dashed.and.paperclip"
        case .systemSettings: return "gearshape"
        }
    }

    var bundleIdentifier: String {
        switch self {
        case .calculator: return "com.apple.calculator"
        case .terminal: return "com.apple.Terminal"
        case .activityMonitor: return "com.apple.ActivityMonitor"
        case .screenshot: return "com.apple.screenshot"
        case .systemSettings: return "com.apple.systempreferences"
        }
    }

    var fallbackApplicationName: String {
        switch self {
        case .calculator: return "Calculator"
        case .terminal: return "Terminal"
        case .activityMonitor: return "Activity Monitor"
        case .screenshot: return "Screenshot"
        case .systemSettings: return "System Settings"
        }
    }

    var fallbackPaths: [String] {
        switch self {
        case .calculator:
            return ["/System/Applications/Calculator.app"]
        case .terminal:
            return ["/System/Applications/Utilities/Terminal.app"]
        case .activityMonitor:
            return ["/System/Applications/Utilities/Activity Monitor.app"]
        case .screenshot:
            return [
                "/System/Applications/Utilities/Screenshot.app",
                "/System/Applications/Screenshot.app"
            ]
        case .systemSettings:
            return ["/System/Applications/System Settings.app"]
        }
    }
}

extension Color {
    /// Decode the six- or eight-digit hex strings used by persisted group colors.
    init(hex: String) {
        let sanitized = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var value: UInt64 = 0
        Scanner(string: sanitized).scanHexInt64(&value)

        let red: Double
        let green: Double
        let blue: Double

        switch sanitized.count {
        case 6:
            red = Double((value >> 16) & 0xFF) / 255
            green = Double((value >> 8) & 0xFF) / 255
            blue = Double(value & 0xFF) / 255
        case 8:
            red = Double((value >> 24) & 0xFF) / 255
            green = Double((value >> 16) & 0xFF) / 255
            blue = Double((value >> 8) & 0xFF) / 255
        default:
            red = 0.35
            green = 0.40
            blue = 0.48
        }

        self.init(red: red, green: green, blue: blue)
    }
}

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
            if url.pathExtension.caseInsensitiveCompare("app") == .orderedSame,
               FileManager.default.fileExists(atPath: url.path),
               let item = makeItem(url: url, seen: &seen, allowsBackgroundApp: true) {
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
        let category = category(for: displayName, bundleIdentifier: bundleIdentifier)

        // "WeChat" is filed as 微信 in its own zh-Hans resources and "Code" is really
        // Visual Studio Code on disk, so search has to know about those names too.
        var aliases = Self.localizedNames(in: normalized)
        let fileName = normalized.deletingPathExtension().lastPathComponent
        if fileName.caseInsensitiveCompare(displayName) != .orderedSame {
            aliases.append(fileName)
        }

        return AppItem(
            name: displayName,
            path: normalized.path,
            bundleIdentifier: bundleIdentifier,
            category: category,
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

    private static func category(for name: String, bundleIdentifier: String?) -> String {
        let normalizedName = name.lowercased()
        let normalizedIdentifier = (bundleIdentifier ?? "").lowercased()
        let text = "\(normalizedName) \(normalizedIdentifier)"
        let isCodeEditor = normalizedName == "code"
            || normalizedName.contains("visual studio code")
            || normalizedName.contains("codex")
            || normalizedName.contains("claude code")
            || normalizedIdentifier.contains("vscode")
            || normalizedIdentifier.contains("visualstudio")

        // Classification is deliberately keyword-based and conservative. Users can change
        // group membership, so a wrong initial category does not change app behavior.
        if isCodeEditor || containsAny(text, ["xcode", "android studio", "hbuilder", "dbeaver", "mqtt", "redis", "sequel", "fork", "docker", "terminal", "termius", "transmit", "postman", "charles", "reqable"]) {
            return "开发"
        }
        if containsAny(text, ["wechat", "qq", "telegram", "discord", "dingtalk", "lark", "slack", "meeting", "teams", "chatgpt", "claude", "doubao", "qianwen", "workbuddy"]) {
            return "沟通"
        }
        if containsAny(text, ["photoshop", "illustrator", "figma", "sketch", "keynote", "powerpoint", "premiere", "after effects", "pixelmator"]) {
            return "创作"
        }
        if containsAny(text, ["safari", "chrome", "firefox", "arc", "edge", "browser", "obsidian", "notion", "word", "excel", "numbers", "pages", "quark", "baidu", "netdisk"]) {
            return "日常"
        }
        if containsAny(text, ["calculator", "activity monitor", "screenshot", "system preferences", "system settings", "disk utility", "cleanmymac", "keka", "archive", "battery", "clash", "wireguard", "sunlogin", "utilities"]) {
            return "工具"
        }
        return "其他"
    }

    private static func containsAny(_ text: String, _ values: [String]) -> Bool {
        values.contains { text.contains($0) }
    }
}

/// Owns the discovered app snapshots and the user-editable group state for the window.
@MainActor
final class LauncherStore: ObservableObject {
    @Published private(set) var apps: [AppItem] = []
    @Published private(set) var groups: [AppGroup] = []
    @Published var selection: ShelfSelection = .all
    @Published var query = ""
    @Published var runningOnly = false
    @Published private(set) var isLoading = true
    @Published private(set) var lastUpdated = Date()
    @Published var errorMessage: String?
    /// Short-lived feedback shown in the footer, e.g. after an app is dropped onto a group.
    @Published var statusMessage: String?

    /// Disk and memory usage for the cards.
    let metrics = AppMetrics.shared

    /// The sidebar group that a drag is currently hovering over, used for highlight feedback.
    @Published var highlightedGroupID: UUID?

    private let stateKey = "AppShelf.state.v2"
    private var statusClearTask: Task<Void, Never>?
    private var loadedPersistedState = false

    init() {
        loadState()
        reload()
    }

    var selectedGroup: AppGroup? {
        guard case let .group(id) = selection else { return nil }
        return groups.first { $0.id == id }
    }

    var selectedTitle: String {
        switch selection {
        case .all: return "全部应用"
        case .running: return "正在运行"
        case .ungrouped: return "未分组"
        case .group(let id): return groups.first { $0.id == id }?.name ?? "分组"
        }
    }

    var selectedSymbol: String {
        switch selection {
        case .all: return "square.grid.2x2.fill"
        case .running: return "bolt.fill"
        case .ungrouped: return "tray"
        case .group(let id): return groups.first { $0.id == id }?.symbol ?? "folder"
        }
    }

    var filteredApps: [AppItem] {
        var result: [AppItem]
        // Apply the sidebar selection first, then the text and running-state filters.
        switch selection {
        case .all:
            result = apps
        case .running:
            result = apps.filter(\.isRunning)
        case .ungrouped:
            let groupedPaths = Set(groups.flatMap(\.appPaths).map(normalizePath))
            result = apps.filter { !groupedPaths.contains($0.path) }
        case .group(let id):
            let paths = Set(groups.first { $0.id == id }?.appPaths.map(normalizePath) ?? [])
            result = apps.filter { paths.contains($0.path) }
        }

        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedQuery.isEmpty {
            // While searching, relevance order wins over the running-first order below,
            // so the best match for "wx" stays at the top even when another app is running.
            let rankedIDs = searchResults(for: trimmedQuery, limit: Int.max).map(\.id)
            let visible = Dictionary(uniqueKeysWithValues: result.map { ($0.id, $0) })
            let ranked = rankedIDs.compactMap { visible[$0] }
            if runningOnly && selection != .running {
                return ranked.filter(\.isRunning)
            }
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

    /// Ranked search across every discovered app.
    /// Matches the name, the pinyin spelling, the initials, and loose subsequences.
    func searchResults(for query: String, limit: Int = 40) -> [AppItem] {
        let scored: [(AppItem, Int)] = apps.compactMap { app in
            guard let score = SearchMatcher.score(app.searchTokens, query: query) else { return nil }
            return (app, score)
        }

        let sorted = scored.sorted { lhs, rhs in
            if lhs.1 != rhs.1 { return lhs.1 > rhs.1 }
            if lhs.0.isRunning != rhs.0.isRunning { return lhs.0.isRunning }
            return lhs.0.name.localizedCaseInsensitiveCompare(rhs.0.name) == .orderedAscending
        }

        return Array(sorted.prefix(limit).map(\.0))
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
        case .all: return apps.count
        case .running: return apps.filter(\.isRunning).count
        case .ungrouped:
            let groupedPaths = Set(groups.flatMap(\.appPaths).map(normalizePath))
            return apps.filter { !groupedPaths.contains($0.path) }.count
        case .group(let id):
            let paths = Set(groups.first { $0.id == id }?.appPaths.map(normalizePath) ?? [])
            return apps.filter { paths.contains($0.path) }.count
        }
    }

    /// Re-scan bundle locations and then merge the current running state.
    func reload() {
        isLoading = true
        // Saved paths are passed back into discovery so manually added apps survive a refresh.
        let savedPaths = groups.flatMap(\.appPaths)
        var discovered = AppDiscoveryService.discover(additionalPaths: savedPaths)

        if !loadedPersistedState {
            // Bootstrap defaults only once. Existing UserDefaults must remain user-owned.
            groups = Self.defaultGroups()
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
        isLoading = false

        // Usage data is read in the background so the grid stays responsive.
        metrics.measure(paths: discovered.map(\.path))
        metrics.updateMemory(running.processes.filter { running.paths.contains($0.path) })
    }

    /// Refresh only process state so a five-second timer does not repeatedly walk the file system.
    func refreshRunningState() {
        let running = runningProcesses()
        apps = apps.map { app in
            var updated = app
            updated.isRunning = running.paths.contains(app.path)
            return updated
        }
        lastUpdated = Date()

        metrics.updateMemory(running.processes.filter { running.paths.contains($0.path) })
    }

    /// Ask Launch Services to open a discovered bundle.
    @discardableResult
    func launch(_ app: AppItem) -> Bool {
        let success = NSWorkspace.shared.open(URL(fileURLWithPath: app.path))
        if !success {
            errorMessage = "无法打开“\(app.name)”"
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
            if !success { errorMessage = "无法打开“\(tool.title)”" }
            return success
        }

        for path in tool.fallbackPaths where FileManager.default.fileExists(atPath: path) {
            let success = NSWorkspace.shared.open(URL(fileURLWithPath: path))
            if !success { errorMessage = "无法打开“\(tool.title)”" }
            return success
        }

        errorMessage = "找不到“\(tool.title)”"
        return false
    }

    /// Quits a running app. `force` is the equivalent of `kill -9` and skips the
    /// app's own save and confirm steps.
    @discardableResult
    func terminate(_ app: AppItem, force: Bool = false) -> Bool {
        guard let running = NSWorkspace.shared.runningApplications.first(where: {
            $0.bundleURL?.standardizedFileURL.path == app.path
        }) else {
            errorMessage = "“\(app.name)”现在没有在运行"
            return false
        }

        let stopped = force ? running.forceTerminate() : running.terminate()
        if stopped {
            refreshRunningState()
            note(force ? "已强制结束“\(app.name)”" : "已退出“\(app.name)”")
        } else {
            errorMessage = "无法结束“\(app.name)”"
        }
        return stopped
    }

    /// Opens a quick tool entry, which is either a built-in utility or a user-picked app.
    @discardableResult
    func launch(_ tool: QuickToolItem) -> Bool {
        if case .builtin(let builtin) = tool {
            return launch(builtin)
        }

        guard let path = tool.path else { return false }
        let success = NSWorkspace.shared.open(URL(fileURLWithPath: path))
        if !success {
            errorMessage = "无法打开“\(tool.title)”"
        } else {
            refreshRunningState()
        }
        return success
    }

    /// Reveal the bundle in Finder without changing its location.
    func openInFinder(_ app: AppItem) {
        NSWorkspace.shared.selectFile(app.path, inFileViewerRootedAtPath: "")
    }

    /// Append a new group and select it so the user can add apps immediately.
    func createGroup(name: String, symbol: String, colorHex: String) {
        let cleanedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanedName.isEmpty else { return }
        let group = AppGroup(name: cleanedName, symbol: symbol, colorHex: colorHex)
        groups.append(group)
        selection = .group(group.id)
        persistState()
    }

    /// Update group presentation while preserving its app paths.
    func renameGroup(id: UUID, name: String, symbol: String, colorHex: String) {
        guard let index = groups.firstIndex(where: { $0.id == id }) else { return }
        let cleanedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanedName.isEmpty else { return }
        groups[index].name = cleanedName
        groups[index].symbol = symbol
        groups[index].colorHex = colorHex
        persistState()
    }

    /// Delete only the grouping metadata; application bundles remain untouched.
    func deleteGroup(id: UUID) {
        guard groups.count > 1, let index = groups.firstIndex(where: { $0.id == id }) else { return }
        groups.remove(at: index)
        if selection == .group(id) { selection = .all }
        persistState()
    }

    /// Import selected bundles and attach their normalized paths to one group.
    func addApps(_ urls: [URL], to groupID: UUID) {
        guard let groupIndex = groups.firstIndex(where: { $0.id == groupID }) else { return }

        for url in urls {
            guard let item = AppDiscoveryService.item(for: url) else { continue }
            if !apps.contains(where: { $0.path == item.path }) {
                apps.append(item)
            }
            if !groups[groupIndex].appPaths.contains(where: { normalizePath($0) == item.path }) {
                groups[groupIndex].appPaths.append(item.path)
            }
        }

        apps.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        persistState()
    }

    /// Add an existing card to another group without removing its current membership.
    func addApp(_ app: AppItem, to groupID: UUID) {
        guard let groupIndex = groups.firstIndex(where: { $0.id == groupID }) else { return }
        if !groups[groupIndex].appPaths.contains(where: { normalizePath($0) == app.path }) {
            groups[groupIndex].appPaths.append(app.path)
            persistState()
        }
    }

    /// Remove a path from one group; the app remains available in All Apps.
    func removeApp(_ app: AppItem, from groupID: UUID) {
        guard let groupIndex = groups.firstIndex(where: { $0.id == groupID }) else { return }
        groups[groupIndex].appPaths.removeAll { normalizePath($0) == app.path }
        persistState()
    }

    /// Adds bundle paths dropped onto a sidebar group. Anything that is not an existing
    /// `.app` bundle is ignored, so dropped text cannot create broken entries.
    func addApps(_ paths: [String], to groupID: UUID) {
        guard let groupIndex = groups.firstIndex(where: { $0.id == groupID }) else { return }
        var addedCount = 0

        for path in paths {
            guard path.hasSuffix(".app"), FileManager.default.fileExists(atPath: path) else { continue }
            guard let item = AppDiscoveryService.item(for: URL(fileURLWithPath: path)) else { continue }

            if !apps.contains(where: { $0.path == item.path }) {
                apps.append(item)
            }
            if !groups[groupIndex].appPaths.contains(where: { normalizePath($0) == item.path }) {
                groups[groupIndex].appPaths.append(item.path)
                addedCount += 1
            }
        }

        guard addedCount > 0 else { return }

        apps.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        metrics.measure(paths: apps.map(\.path))
        persistState()
        note("已把 \(addedCount) 个应用加入“\(groups[groupIndex].name)”")
    }

    /// Apps of one group in the order the user arranged them.
    func orderedApps(in groupID: UUID) -> [AppItem] {
        let order = groups.first { $0.id == groupID }?.appPaths.map(normalizePath) ?? []
        let lookup = Dictionary(uniqueKeysWithValues: apps.map { ($0.path, $0) })
        return order.compactMap { lookup[$0] }
    }

    /// Apps that are not part of any group.
    func ungroupedApps() -> [AppItem] {
        let groupedPaths = Set(groups.flatMap(\.appPaths).map(normalizePath))
        return apps
            .filter { !groupedPaths.contains($0.path) }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// Drops dragged cards ahead of `target` inside one group, which both reorders
    /// existing members and files new ones at that position.
    func moveApps(_ draggedPaths: [String], before target: AppItem, in groupID: UUID) {
        guard let index = groups.firstIndex(where: { $0.id == groupID }) else { return }
        var list = groups[index].appPaths.map(normalizePath)
        var didChange = false

        for dragged in draggedPaths.map(normalizePath) {
            guard dragged != target.path else { continue }
            list.removeAll { $0 == dragged }
            if let targetIndex = list.firstIndex(of: target.path) {
                list.insert(dragged, at: targetIndex)
            } else {
                list.append(dragged)
            }
            didChange = true
        }

        guard didChange else { return }
        groups[index].appPaths = list
        persistState()
    }

    /// Restore groups from the current user's defaults, falling back to the built-in set.
    private func loadState() {
        guard let data = UserDefaults.standard.data(forKey: stateKey),
              let saved = try? JSONDecoder().decode([AppGroup].self, from: data),
              !saved.isEmpty else {
            groups = Self.defaultGroups()
            return
        }
        groups = saved
        loadedPersistedState = true
    }

    /// Encode only the small, user-editable group model; bundle metadata is never persisted.
    private func persistState() {
        guard let data = try? JSONEncoder().encode(groups) else { return }
        UserDefaults.standard.set(data, forKey: stateKey)
    }

    private func assignInitialGroups(for discovered: [AppItem]) {
        // This is a one-time convenience pass, not a permanent categorization rule.
        let commonNames = ["safari", "google chrome", "visual studio code", "xcode", "terminal", "chatgpt", "obsidian"]

        for app in discovered {
            let targetName: String?
            if commonNames.contains(where: { app.name.localizedCaseInsensitiveCompare($0) == .orderedSame }) {
                targetName = "常用"
            } else if ["开发", "沟通", "创作", "日常", "工具"].contains(app.category) {
                targetName = app.category
            } else {
                targetName = nil
            }

            guard let targetName,
                  let index = groups.firstIndex(where: { $0.name == targetName }) else { continue }
            groups[index].appPaths.append(app.path)
        }
    }

    /// Bundle paths paired with pids, so card footers can show both size and memory.
    private func runningProcesses() -> (paths: Set<String>, processes: [(path: String, pid: Int32)]) {
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

    private func normalizePath(_ path: String) -> String {
        URL(fileURLWithPath: path).standardizedFileURL.path
    }

    /// Starter groups shown on a first launch.
    private static func defaultGroups() -> [AppGroup] {
        [
            AppGroup(name: "常用", symbol: "star.fill", colorHex: "#F59E0B"),
            AppGroup(name: "开发", symbol: "hammer.fill", colorHex: "#2F80ED"),
            AppGroup(name: "沟通", symbol: "bubble.left.and.bubble.right.fill", colorHex: "#16A085"),
            AppGroup(name: "创作", symbol: "wand.and.stars", colorHex: "#D14D72"),
            AppGroup(name: "日常", symbol: "house.fill", colorHex: "#7C5CFC"),
            AppGroup(name: "工具", symbol: "wrench.and.screwdriver.fill", colorHex: "#64748B")
        ]
    }
}
