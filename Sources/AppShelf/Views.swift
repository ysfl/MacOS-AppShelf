import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Shared colors for the launcher shell and its controls.
enum AppShelfPalette {
    static let sidebar = Color(nsColor: .underPageBackgroundColor)
    static let canvas = Color(nsColor: .windowBackgroundColor)
    static let panel = Color(nsColor: .controlBackgroundColor)
    static let border = Color.black.opacity(0.08)
    static let accent = Color(red: 0.12, green: 0.42, blue: 0.86)
    static let success = Color(red: 0.12, green: 0.60, blue: 0.42)
}

extension UTType {
    /// In-app drag types. Declaring them separately keeps an app card (plain text),
    /// a group row, and a quick tool tile from being mistaken for one another.
    static let appShelfGroup = UTType(exportedAs: "local.dan.AppShelf.group")
    static let appShelfQuickTool = UTType(exportedAs: "local.dan.AppShelf.quicktool")
}

/// Payload of a dragged sidebar group or section heading.
private struct GroupDragPayload: Codable, Transferable {
    let id: UUID

    static var transferRepresentation: some TransferRepresentation {
        CodableRepresentation(contentType: .appShelfGroup)
    }
}

/// Payload of a dragged quick tool tile.
private struct QuickToolDragPayload: Codable, Transferable {
    let id: String

    static var transferRepresentation: some TransferRepresentation {
        CodableRepresentation(contentType: .appShelfQuickTool)
    }
}

/// App cards drag their bundle path as plain text; this filters real bundle paths out
/// from any other text that might be dropped onto the window.
private enum ShelfDragPayload {
    static func isAppPath(_ payload: String) -> Bool {
        payload.hasSuffix(".app")
    }
}

/// A dragged group travels with the cursor as a small card: its heading plus a few
/// of its icons, so the gesture looks like the whole group is being moved.
private struct GroupDragPreview: View {
    let title: String
    let symbol: String
    let tint: Color
    let apps: [AppItem]

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 6) {
                Image(systemName: symbol)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(tint)
                Text(title)
                    .font(.system(size: 12.5, weight: .semibold))
                Text("\(apps.count)")
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundStyle(.secondary)
            }

            if !apps.isEmpty {
                HStack(spacing: 5) {
                    ForEach(apps.prefix(6)) { app in
                        AppIconView(path: app.path)
                            .frame(width: 30, height: 30)
                    }
                    if apps.count > 6 {
                        Text("+\(apps.count - 6)")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .padding(10)
        .background(Color(nsColor: .windowBackgroundColor).opacity(0.96), in: RoundedRectangle(cornerRadius: 10))
        .overlay {
            RoundedRectangle(cornerRadius: 10)
                .stroke(tint.opacity(0.65), lineWidth: 1.5)
        }
    }
}

/// One block of cards shown under a group heading in the All Apps view.
private struct AppSection: Identifiable {
    let id: String
    let title: String
    let symbol: String
    let tint: Color
    let groupID: UUID?
    let apps: [AppItem]
}

/// The main window. Sheets and alerts are kept here so child views only emit user intent.
struct ContentView: View {
    @ObservedObject var store: LauncherStore
    @ObservedObject private var quickTools = QuickToolStore.shared

    @FocusState private var isSearchFocused: Bool
    @State private var isSectionDropTarget: UUID?
    @State private var isQuickToolDropTarget = false
    @State private var isShowingNewGroup = false
    @State private var groupBeingEdited: AppGroup?
    @State private var groupPendingDeletion: AppGroup?
    @State private var urlsToAdd: [URL] = []
    @State private var isShowingAddSheet = false
    @State private var appToMove: AppItem?

    // Running state and memory are cheap to refresh, and a short interval keeps the
    // memory readouts on the cards close to live.
    private let refreshTimer = Timer.publish(every: 3, on: .main, in: .common).autoconnect()

    var body: some View {
        HStack(spacing: 0) {
            SidebarView(
                store: store,
                onNewGroup: { isShowingNewGroup = true },
                onEditGroup: { groupBeingEdited = $0 },
                onDeleteGroup: { groupPendingDeletion = $0 },
                onLaunchTool: { store.launch($0) }
            )

            Divider()

            mainContent
        }
        .background(AppShelfPalette.canvas)
        .frame(minWidth: 980, minHeight: 620)
        .onReceive(refreshTimer) { _ in
            store.refreshRunningState()
        }
        .sheet(isPresented: $isShowingNewGroup) {
            GroupEditorSheet { name, symbol, colorHex in
                store.createGroup(name: name, symbol: symbol, colorHex: colorHex)
            }
        }
        .sheet(item: $groupBeingEdited) { group in
            GroupEditorSheet(existing: group) { name, symbol, colorHex in
                store.renameGroup(id: group.id, name: name, symbol: symbol, colorHex: colorHex)
            }
        }
        .sheet(isPresented: $isShowingAddSheet) {
            AddAppsSheet(
                urls: urlsToAdd,
                groups: store.groups,
                defaultGroupID: destinationGroupID
            ) { urls, groupID in
                store.addApps(urls, to: groupID)
            }
        }
        .sheet(item: $appToMove) { app in
            MoveAppSheet(app: app, groups: store.groups) { groupID in
                store.addApp(app, to: groupID)
            }
        }
        .alert("删除分组？", isPresented: Binding(
            get: { groupPendingDeletion != nil },
            set: { if !$0 { groupPendingDeletion = nil } }
        )) {
            Button("删除", role: .destructive) {
                if let group = groupPendingDeletion {
                    store.deleteGroup(id: group.id)
                }
                groupPendingDeletion = nil
            }
            Button("取消", role: .cancel) {
                groupPendingDeletion = nil
            }
        } message: {
            Text("分组中的应用不会被卸载，只会移除这个分组。")
        }
        .alert("操作失败", isPresented: Binding(
            get: { store.errorMessage != nil },
            set: { if !$0 { store.errorMessage = nil } }
        )) {
            Button("好", role: .cancel) {
                store.errorMessage = nil
            }
        } message: {
            Text(store.errorMessage ?? "请稍后重试。")
        }
    }

    private var mainContent: some View {
        // The header and the search row stay fixed while the grid scrolls.
        VStack(alignment: .leading, spacing: 0) {
            header

            searchBar

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    if shouldShowQuickTools {
                        quickToolsSection
                    }

                    if store.isLoading {
                        LoadingState()
                    } else if !appSections.isEmpty {
                        sectionedApps
                    } else if store.filteredApps.isEmpty {
                        EmptyState(
                            query: store.query,
                            selection: store.selection,
                            onClearSearch: { store.query = "" },
                            onAddApp: chooseApps
                        )
                    } else {
                        appGrid
                    }
                }
                .padding(.horizontal, 28)
                .padding(.vertical, 24)
                .frame(maxWidth: .infinity, minHeight: 320, alignment: .topLeading)
                // Dropping a quick tool here takes it out of the toolbar row.
                .dropDestination(for: QuickToolDragPayload.self) { items, _ in
                    guard !items.isEmpty else { return false }
                    items.forEach { quickTools.remove($0.id) }
                    store.note("已从快捷工具移除")
                    return true
                } isTargeted: { _ in }
            }

            footer
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onAppear { focusSearchField() }
        // Every page change hands the keyboard back to the search field.
        .onChange(of: store.selection, initial: false) { _, _ in
            focusSearchField()
        }
    }

    /// A full-width search row under the title so there is room for longer queries.
    private var searchBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.secondary)

            TextField("搜索应用，支持拼音首字母，如 wx / vsc", text: $store.query)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .focused($isSearchFocused)

            if !store.query.isEmpty {
                Button {
                    store.query = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
                .help("清除搜索")
            }
        }
        .padding(.horizontal, 12)
        .frame(height: 36)
        .background(AppShelfPalette.panel, in: RoundedRectangle(cornerRadius: 9))
        .overlay {
            RoundedRectangle(cornerRadius: 9)
                .stroke(isSearchFocused ? AppShelfPalette.accent.opacity(0.5) : AppShelfPalette.border, lineWidth: 1)
        }
        .padding(.horizontal, 28)
        .padding(.bottom, 16)
    }

    private func focusSearchField() {
        // A short delay lets the page finish swapping before focus is claimed.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            isSearchFocused = true
        }
    }

    private var header: some View {
        HStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 9) {
                    Image(systemName: store.selectedSymbol)
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(AppShelfPalette.accent)
                        .frame(width: 23)

                    Text(store.selectedTitle)
                        .font(.system(size: 24, weight: .semibold, design: .rounded))
                        .foregroundStyle(.primary)
                }

                Text("\(store.filteredApps.count) 个应用 · \(store.count(for: .running)) 个正在运行")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 18)

            Toggle(isOn: $store.runningOnly) {
                Label("运行中", systemImage: "bolt.fill")
                    .font(.system(size: 12, weight: .medium))
            }
            .toggleStyle(.checkbox)
            .help("只显示正在运行的应用")

            Button(action: store.reload) {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 14, weight: .semibold))
            }
            .buttonStyle(.bordered)
            .controlSize(.large)
            .help("刷新应用列表")

            Button(action: chooseApps) {
                Label("添加应用", systemImage: "plus")
                    .font(.system(size: 12, weight: .semibold))
            }
            .buttonStyle(.borderedProminent)
            .tint(AppShelfPalette.accent)
            .controlSize(.large)

            Button(action: openSystemSettings) {
                Image(systemName: "gearshape")
                    .font(.system(size: 14, weight: .semibold))
            }
            .buttonStyle(.bordered)
            .controlSize(.large)
            .help("设置")
        }
        .padding(.horizontal, 28)
        .padding(.vertical, 20)
    }

    private var appGrid: some View {
        // Adaptive columns use the available window width without changing tile sizes.
        LazyVGrid(columns: appGridColumns, alignment: .leading, spacing: 16) {
            ForEach(store.filteredApps) { app in
                appCard(app, sectionGroupID: nil)
            }
        }
    }

    private var appGridColumns: [GridItem] {
        [GridItem(.adaptive(minimum: 136, maximum: 176), spacing: 14)]
    }

    /// All Apps is laid out as one block per group, in the order the user arranged them.
    /// While a group is being dragged every block is outlined, and the one under the
    /// cursor is filled, so the drop target is obvious without reading any hint text.
    private var sectionedApps: some View {
        VStack(alignment: .leading, spacing: 18) {
            ForEach(appSections) { section in
                VStack(alignment: .leading, spacing: 10) {
                    sectionHeader(section)

                    LazyVGrid(columns: appGridColumns, alignment: .leading, spacing: 16) {
                        ForEach(section.apps) { app in
                            appCard(app, sectionGroupID: section.groupID)
                        }
                    }
                }
                .padding(10)
                .background {
                    RoundedRectangle(cornerRadius: 12)
                        .fill(sectionFill(for: section))
                        .strokeBorder(
                            sectionStroke(for: section),
                            style: isTargeted(section) ? StrokeStyle(lineWidth: 2) : StrokeStyle(lineWidth: 1, dash: [5, 4])
                        )
                }
                .animation(.easeOut(duration: 0.12), value: isSectionDropTarget)
            }
        }
    }

    private func isTargeted(_ section: AppSection) -> Bool {
        section.groupID == isSectionDropTarget
    }

    private func sectionFill(for section: AppSection) -> Color {
        if isTargeted(section) { return AppShelfPalette.accent.opacity(0.13) }
        return isGroupReordering ? Color.primary.opacity(0.05) : Color.clear
    }

    private func sectionStroke(for section: AppSection) -> Color {
        if isTargeted(section) { return AppShelfPalette.accent }
        return isGroupReordering ? AppShelfPalette.accent.opacity(0.35) : Color.clear
    }

    /// True while any group row or section heading is hovering over a drop target.
    private var isGroupReordering: Bool {
        isSectionDropTarget != nil || store.groupReorderTargetID != nil
    }


    /// Section headings are themselves draggable, so groups can be reordered here too.
    @ViewBuilder
    private func sectionHeader(_ section: AppSection) -> some View {
        let header = HStack(spacing: 8) {
            Image(systemName: section.symbol)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(section.tint)
                .frame(width: 16)

            Text(section.title)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.primary)

            Text("\(section.apps.count)")
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .foregroundStyle(.tertiary)

            Spacer(minLength: 0)

            if section.groupID != nil {
                Text(isSectionDropTarget == section.groupID ? "放到这里" : "拖动标题或卡片可调整顺序")
                    .font(.system(size: 10))
                    .foregroundStyle(isSectionDropTarget == section.groupID ? AppShelfPalette.accent : Color.secondary.opacity(0.7))
            }
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())

        if let groupID = section.groupID {
            header
                .draggable(GroupDragPayload(id: groupID)) {
                    GroupDragPreview(
                        title: section.title,
                        symbol: section.symbol,
                        tint: section.tint,
                        apps: section.apps
                    )
                }
                .dropDestination(for: GroupDragPayload.self) { items, _ in
                    guard let dragged = items.first?.id else { return false }
                    store.moveGroup(dragged, before: groupID)
                    return true
                } isTargeted: { isTargeted in
                    isSectionDropTarget = isTargeted ? groupID : nil
                }
        } else {
            header
        }
    }

    /// One card plus its drag behaviour. `sectionGroupID` enables drag-to-reorder
    /// inside that group; it stays nil for search results, which are ranked instead.
    private func appCard(_ app: AppItem, sectionGroupID: UUID?) -> some View {
        AppCard(
            app: app,
            currentGroupID: currentGroupID,
            showsCategory: sectionGroupID == nil,
            onOpen: { store.launch(app) },
            onMove: {
                appToMove = app
            },
            onRemove: currentGroupID.map { groupID in
                { store.removeApp(app, from: groupID) }
            },
            onShowInFinder: { store.openInFinder(app) },
            onQuit: app.isRunning ? { store.terminate(app) } : nil,
            onForceQuit: app.isRunning ? { store.terminate(app, force: true) } : nil
        )
        // The bundle path is the drag payload: dropping on a sidebar group files the app,
        // dropping on another card inside a section reorders it.
        .draggable(app.path) {
            AppIconView(path: app.path)
                .frame(width: 64, height: 64)
        }
        .dropDestination(for: String.self) { items, _ in
            guard let sectionGroupID else { return false }
            // Only other app cards reorder; quick tool payloads belong to the toolbar row.
            let paths = items.filter(ShelfDragPayload.isAppPath)
            guard !paths.isEmpty else { return false }
            store.moveApps(paths, before: app, in: sectionGroupID)
            return true
        } isTargeted: { _ in }
    }

    /// Sections are only used when no search text is active; searching ranks across everything.
    private var appSections: [AppSection] {
        guard !store.isLoading else { return [] }
        guard store.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return [] }

        func visible(_ apps: [AppItem]) -> [AppItem] {
            store.runningOnly ? apps.filter(\.isRunning) : apps
        }

        switch store.selection {
        case .running, .ungrouped:
            return []
        case .group(let id):
            let apps = visible(store.orderedApps(in: id))
            guard !apps.isEmpty, let group = store.groups.first(where: { $0.id == id }) else { return [] }
            return [AppSection(id: id.uuidString, title: group.name, symbol: group.symbol, tint: group.color, groupID: id, apps: apps)]
        case .all:
            var sections: [AppSection] = store.groups.compactMap { group in
                let apps = visible(store.orderedApps(in: group.id))
                guard !apps.isEmpty else { return nil }
                return AppSection(
                    id: group.id.uuidString,
                    title: group.name,
                    symbol: group.symbol,
                    tint: group.color,
                    groupID: group.id,
                    apps: apps
                )
            }
            let ungrouped = visible(store.ungroupedApps())
            if !ungrouped.isEmpty {
                sections.append(
                    AppSection(id: "ungrouped", title: "未分组", symbol: "tray", tint: .secondary, groupID: nil, apps: ungrouped)
                )
            }
            return sections
        }
    }

    private var quickToolsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text("快捷工具")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Text(isQuickToolDropTarget ? "松手即可添加" : "拖应用进来添加，拖出去移除")
                    .font(.system(size: 11))
                    .foregroundStyle(isQuickToolDropTarget ? AppShelfPalette.accent : Color.secondary.opacity(0.7))
            }

            // A grid instead of a single row so any number of tools stays inside the window.
            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 150, maximum: 230), spacing: 10)],
                alignment: .leading,
                spacing: 10
            ) {
                ForEach(quickTools.items) { tool in
                    QuickToolTile(tool: tool) {
                        store.launch(tool)
                    }
                }
            }
        }
        .padding(8)
        .background {
            RoundedRectangle(cornerRadius: 10)
                .stroke(
                    isQuickToolDropTarget ? AppShelfPalette.accent : Color.clear,
                    style: StrokeStyle(lineWidth: 1.5, dash: [5, 4])
                )
        }
        // Dropping an app card here pins it as a quick tool.
        .dropDestination(for: String.self) { items, _ in
            let paths = items.filter(ShelfDragPayload.isAppPath)
            guard !paths.isEmpty else { return false }
            for path in paths {
                let name = AppDiscoveryService.item(for: URL(fileURLWithPath: path))?.name
                    ?? URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent
                quickTools.addCustom(name: name, path: path)
            }
            store.note("已加入快捷工具")
            return true
        } isTargeted: { isTargeted in
            isQuickToolDropTarget = isTargeted
        }
    }

    private var footer: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(store.isLoading ? Color.orange : AppShelfPalette.success)
                .frame(width: 7, height: 7)

            Text(store.isLoading ? "正在扫描应用…" : "已扫描 \(store.apps.count) 个应用")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)

            Text("·")
                .foregroundStyle(.tertiary)

            Text("更新于 \(store.lastUpdated.formatted(date: .omitted, time: .shortened))")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)

            if let message = store.statusMessage {
                Text("·")
                    .foregroundStyle(.tertiary)
                Text(message)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(AppShelfPalette.accent)
            }

            Spacer()

            Text("应用架")
                .font(.system(size: 11, weight: .semibold, design: .rounded))
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 28)
        .padding(.vertical, 10)
        .background(AppShelfPalette.sidebar.opacity(0.58))
    }

    private var shouldShowQuickTools: Bool {
        store.selection == .all && store.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !store.runningOnly
    }

    private var currentGroupID: UUID? {
        if case let .group(id) = store.selection { return id }
        return nil
    }

    private var destinationGroupID: UUID {
        if let currentGroupID { return currentGroupID }
        return store.groups.first?.id ?? UUID()
    }

    private func chooseApps() {
        // The system picker is opened only after an explicit Add App action and never scans
        // arbitrary folders on its own.
        let panel = NSOpenPanel()
        panel.title = "添加应用"
        panel.message = "选择一个或多个 .app 文件"
        panel.allowedContentTypes = [.applicationBundle]
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.resolvesAliases = true

        guard panel.runModal() == .OK, !panel.urls.isEmpty else { return }
        urlsToAdd = panel.urls
        isShowingAddSheet = true
    }

    private func openSystemSettings() {
        SettingsWindowController.shared.showWindow()
    }
}

/// Navigation for built-in views, user groups, and the small utility list.
struct SidebarView: View {
    @ObservedObject var store: LauncherStore
    @ObservedObject private var quickTools = QuickToolStore.shared
    let onNewGroup: () -> Void
    let onEditGroup: (AppGroup) -> Void
    let onDeleteGroup: (AppGroup) -> Void
    let onLaunchTool: (QuickToolItem) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            brand

            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    VStack(alignment: .leading, spacing: 5) {
                        SidebarSectionLabel("我的应用")
                        SidebarRow(
                            title: "全部应用",
                            symbol: "square.grid.2x2.fill",
                            tint: AppShelfPalette.accent,
                            count: store.count(for: .all),
                            isSelected: store.selection == .all
                        ) {
                            store.selection = .all
                        }
                        SidebarRow(
                            title: "正在运行",
                            symbol: "bolt.fill",
                            tint: AppShelfPalette.success,
                            count: store.count(for: .running),
                            isSelected: store.selection == .running
                        ) {
                            store.selection = .running
                        }
                        SidebarRow(
                            title: "未分组",
                            symbol: "tray",
                            tint: .secondary,
                            count: store.count(for: .ungrouped),
                            isSelected: store.selection == .ungrouped
                        ) {
                            store.selection = .ungrouped
                        }
                    }

                    VStack(alignment: .leading, spacing: 5) {
                        HStack {
                            SidebarSectionLabel("分组")
                            Spacer()
                            Button(action: onNewGroup) {
                                Image(systemName: "plus")
                                    .font(.system(size: 11, weight: .bold))
                            }
                            .buttonStyle(.plain)
                            .foregroundStyle(.secondary)
                            .help("新建分组")
                        }

                        ForEach(store.groups) { group in
                            SidebarRow(
                                title: group.name,
                                symbol: group.symbol,
                                tint: group.color,
                                count: store.count(for: .group(group.id)),
                                isSelected: store.selection == .group(group.id),
                                isDropTarget: store.highlightedGroupID == group.id
                            ) {
                                store.selection = .group(group.id)
                            }
                            .contextMenu {
                                Button("编辑分组", systemImage: "pencil") {
                                    onEditGroup(group)
                                }
                                Button("删除分组", systemImage: "trash", role: .destructive) {
                                    onDeleteGroup(group)
                                }
                            }
                            // The row accepts two kinds of drop: an app card (files it here)
                            // or another group row (reorders the sidebar).
                            .draggable(GroupDragPayload(id: group.id)) { [store] in
                                // The whole group travels with the cursor, cards included.
                                GroupDragPreview(
                                    title: group.name,
                                    symbol: group.symbol,
                                    tint: group.color,
                                    apps: Array(store.orderedApps(in: group.id).prefix(6))
                                )
                            }
                            // Two drop targets on one row: an app card files the app here,
                            // another group row reorders the sidebar.
                            .dropDestination(for: GroupDragPayload.self) { items, _ in
                                guard let dragged = items.first?.id else { return false }
                                store.moveGroup(dragged, before: group.id)
                                return true
                            } isTargeted: { isTargeted in
                                store.groupReorderTargetID = isTargeted ? group.id : nil
                                if !isTargeted && store.highlightedGroupID == group.id {
                                    store.highlightedGroupID = nil
                                }
                            }
                            .dropDestination(for: String.self) { items, _ in
                                let paths = items.filter(ShelfDragPayload.isAppPath)
                                guard !paths.isEmpty else { return false }
                                store.addApps(paths, to: group.id)
                                return true
                            } isTargeted: { isTargeted in
                                store.highlightedGroupID = isTargeted ? group.id : nil
                            }
                        }
                    }

                    VStack(alignment: .leading, spacing: 5) {
                        SidebarSectionLabel("快捷工具")
                        ForEach(quickTools.items) { tool in
                            ToolRow(tool: tool) {
                                onLaunchTool(tool)
                            }
                        }
                    }
                }
                .padding(.horizontal, 14)
                .padding(.bottom, 18)
            }

            Divider()

            VStack(alignment: .leading, spacing: 5) {
                Text("自动扫描")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                Text("/Applications · 系统应用 · ~/Applications")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                    .lineLimit(2)
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 14)
        }
        .frame(width: 236)
        .background(AppShelfPalette.sidebar)
    }

    private var brand: some View {
        HStack(spacing: 11) {
            ZStack {
                RoundedRectangle(cornerRadius: 10)
                    .fill(AppShelfPalette.accent)
                Image(systemName: "square.grid.3x3.fill")
                    .font(.system(size: 17, weight: .bold))
                    .foregroundStyle(.white)
            }
            .frame(width: 34, height: 34)

            VStack(alignment: .leading, spacing: 1) {
                Text("应用架")
                    .font(.system(size: 16, weight: .bold, design: .rounded))
                Text("App Shelf")
                    .font(.system(size: 10, weight: .medium, design: .rounded))
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.horizontal, 18)
        .padding(.top, 21)
        .padding(.bottom, 20)
    }
}

/// Small all-caps labels separate the sidebar's navigation sections.
private struct SidebarSectionLabel: View {
    let title: String

    init(_ title: String) {
        self.title = title
    }

    var body: some View {
        Text(title)
            .font(.system(size: 10, weight: .bold))
            .foregroundStyle(.tertiary)
            .textCase(.uppercase)
            .padding(.horizontal, 10)
            .padding(.bottom, 2)
    }
}

/// A selectable sidebar row with a count that stays aligned as names change.
private struct SidebarRow: View {
    let title: String
    let symbol: String
    let tint: Color
    let count: Int
    let isSelected: Bool
    let isDropTarget: Bool
    let action: () -> Void

    init(
        title: String,
        symbol: String,
        tint: Color,
        count: Int,
        isSelected: Bool,
        isDropTarget: Bool = false,
        action: @escaping () -> Void
    ) {
        self.title = title
        self.symbol = symbol
        self.tint = tint
        self.count = count
        self.isSelected = isSelected
        self.isDropTarget = isDropTarget
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: symbol)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(isSelected ? tint : .secondary)
                    .frame(width: 18)

                Text(title)
                    .font(.system(size: 13, weight: isHighlighted ? .semibold : .medium))
                    .foregroundStyle(isHighlighted ? .primary : .secondary)
                    .lineLimit(1)

                Spacer(minLength: 4)

                Text("\(count)")
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundStyle(isHighlighted ? .primary : .tertiary)
            }
            .padding(.horizontal, 10)
            .frame(height: 34)
            .background { rowBackground }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var isHighlighted: Bool { isSelected || isDropTarget }

    /// Uses system background colors so the row stays readable in light and dark mode;
    /// a fixed white fill turned the label white-on-white once the Mac switched to dark.
    @ViewBuilder
    private var rowBackground: some View {
        if isHighlighted {
            RoundedRectangle(cornerRadius: 8)
                .fill(Color(nsColor: .windowBackgroundColor).opacity(isDropTarget ? 1 : 0.85))
                .overlay {
                    RoundedRectangle(cornerRadius: 8)
                        .fill(tint.opacity(isDropTarget ? 0.22 : 0))
                }
                .overlay {
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(isDropTarget ? tint : Color.clear, lineWidth: 2)
                }
                .shadow(color: .black.opacity(isSelected && !isDropTarget ? 0.05 : 0), radius: 2, y: 1)
        }
    }
}

/// A sidebar shortcut that delegates launching to the store owner.
private struct ToolRow: View {
    let tool: QuickToolItem
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                toolIcon
                    .frame(width: 18)
                Text(tool.title)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
                Spacer()
                Image(systemName: "arrow.up.right")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 10)
            .frame(height: 30)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("打开\(tool.title)")
        .draggable(QuickToolDragPayload(id: tool.id)) {
            Label(tool.title, systemImage: "square.dashed")
                .font(.system(size: 12, weight: .semibold))
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
        }
    }

    @ViewBuilder
    private var toolIcon: some View {
        if let symbol = tool.symbol {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
        } else if let path = tool.path {
            Image(nsImage: IconCache.shared.image(for: path))
                .resizable()
                .interpolation(.high)
        }
    }
}

/// A compact app tile. Opening is the primary action; less common actions live in its menu.
private struct AppCard: View {
    let app: AppItem
    let currentGroupID: UUID?
    /// False inside a group section, where the heading already says the category.
    let showsCategory: Bool
    let onOpen: () -> Void
    let onMove: () -> Void
    let onRemove: (() -> Void)?
    let onShowInFinder: () -> Void
    let onQuit: (() -> Void)?
    let onForceQuit: (() -> Void)?

    @ObservedObject private var metrics = AppMetrics.shared
    @State private var isHovering = false

    var body: some View {
        Button(action: onOpen) {
            cardContent
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .contextMenu {
            Button("打开", systemImage: "arrow.up.right") { onOpen() }
            Button("加入其他分组", systemImage: "folder.badge.plus") { onMove() }
            if let onRemove {
                Divider()
                Button("从当前分组移除", systemImage: "minus.circle", role: .destructive) { onRemove() }
            }
            if let onQuit {
                Divider()
                Button("退出应用", systemImage: "xmark.circle") { onQuit() }
                if let onForceQuit {
                    Button("强制结束", systemImage: "exclamationmark.octagon", role: .destructive) { onForceQuit() }
                }
            }
            Divider()
            Button("在 Finder 中显示", systemImage: "folder") { onShowInFinder() }
        }
        .help("打开\(app.name)")
    }

    /// Icon on the left, name and usage stacked beside it, so a card reads as one row
    /// instead of an icon floating over empty space.
    /// Launchpad-style tile: a large icon, a centred name, and one quiet info line.
    private var cardContent: some View {
        VStack(spacing: 9) {
            ZStack(alignment: .topTrailing) {
                AppIconView(path: app.path)
                    .frame(width: 84, height: 84)

                if app.isRunning {
                    Circle()
                        .fill(AppShelfPalette.success)
                        .frame(width: 11, height: 11)
                        .overlay {
                            Circle()
                                .strokeBorder(Color(nsColor: .windowBackgroundColor), lineWidth: 2)
                        }
                        .offset(x: 2, y: -2)
                }
            }

            Text(app.name)
                .font(.system(size: 12.5, weight: .medium))
                .foregroundStyle(.primary)
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .truncationMode(.tail)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity)

            infoLine
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 14)
        .frame(maxWidth: .infinity, minHeight: 158, alignment: .top)
        .background(hoverBackground)
        .contentShape(RoundedRectangle(cornerRadius: 12))
        // No animated shadow or scale: animating those on two hundred tiles at once is
        // what made hovering and dragging feel heavy.
        .scaleEffect(isHovering ? 1.015 : 1)
    }

    /// Category, disk usage, and memory share one small line. The category is only
    /// repeated when the tile is not already sitting inside that group's section.
    private var infoLine: some View {
        HStack(spacing: 4) {
            if showsCategory {
                Text(app.category)
                    .foregroundStyle(.secondary)
                Text("·")
                    .foregroundStyle(.tertiary)
            }

            Text(metrics.sizeText(for: app.path))
                .foregroundStyle(.secondary)

            if app.isRunning {
                Text("·")
                    .foregroundStyle(.tertiary)
                Text(metrics.memoryText(for: app.path))
                    .foregroundStyle(AppShelfPalette.success)
            }
        }
        .font(.system(size: 10.5, weight: .medium, design: .rounded))
        .lineLimit(1)
        .help("磁盘占用 = 应用本体 + 该应用在 Library 中的数据；内存为运行中全部进程之和")
    }

    /// No permanent outline: the tile only gains a soft rounded surface while hovered,
    /// so the grid stays clean and the icon and name carry the layout.
    private var hoverBackground: some View {
        RoundedRectangle(cornerRadius: 12)
            .fill(isHovering ? AppShelfPalette.panel : Color.clear)
    }
}

/// Caches app icons. `NSWorkspace.icon(forFile:)` goes through Launch Services, and
/// calling it for every card on every redraw is what made dragging feel sluggish.
private final class IconCache {
    static let shared = IconCache()

    private let cache = NSCache<NSString, NSImage>()

    private init() {
        cache.countLimit = 500
    }

    func image(for path: String) -> NSImage {
        let key = path as NSString
        if let cached = cache.object(forKey: key) { return cached }
        let image = NSWorkspace.shared.icon(forFile: path)
        cache.setObject(image, forKey: key)
        return image
    }
}

/// Resolve the icon from the bundle path so third-party apps use their own artwork.
private struct AppIconView: View {
    let path: String

    var body: some View {
        Image(nsImage: IconCache.shared.image(for: path))
            .resizable()
            .interpolation(.high)
            .aspectRatio(contentMode: .fit)
    }
}

/// A larger shortcut tile shown above the full app grid.
private struct QuickToolTile: View {
    let tool: QuickToolItem
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                toolIcon
                    .frame(width: 29, height: 29)
                    .background(AppShelfPalette.accent.opacity(0.10), in: RoundedRectangle(cornerRadius: 8))

                VStack(alignment: .leading, spacing: 2) {
                    Text(tool.title)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.primary)
                    Text("打开")
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                }

                Spacer(minLength: 4)
                Image(systemName: "arrow.up.right")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 11)
            .frame(maxWidth: .infinity, minHeight: 54, maxHeight: 54)
            .background(AppShelfPalette.panel.opacity(0.72), in: RoundedRectangle(cornerRadius: 8))
            .overlay {
                RoundedRectangle(cornerRadius: 8)
                    .stroke(AppShelfPalette.border, lineWidth: 1)
            }
        }
        .buttonStyle(.plain)
        .help("打开\(tool.title)")
        // Drag the tile out of the row to remove it.
        .draggable(QuickToolDragPayload(id: tool.id)) {
            Label(tool.title, systemImage: "square.dashed")
                .font(.system(size: 12, weight: .semibold))
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
        }
    }

    /// Built-in utilities keep their SF Symbol; user-added tools show their own icon.
    @ViewBuilder
    private var toolIcon: some View {
        if let symbol = tool.symbol {
            Image(systemName: symbol)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(AppShelfPalette.accent)
        } else if let path = tool.path {
            Image(nsImage: IconCache.shared.image(for: path))
                .resizable()
                .interpolation(.high)
        }
    }
}

/// Placeholder shown while the file-system scan is in progress.
private struct LoadingState: View {
    var body: some View {
        VStack(spacing: 12) {
            ProgressView()
                .controlSize(.small)
            Text("正在读取应用…")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, minHeight: 280)
    }
}

/// Shared empty state for an empty group and an unsuccessful search.
private struct EmptyState: View {
    let query: String
    let selection: ShelfSelection
    let onClearSearch: () -> Void
    let onAddApp: () -> Void

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: query.isEmpty ? "square.grid.2x2" : "magnifyingglass")
                .font(.system(size: 31, weight: .light))
                .foregroundStyle(.tertiary)
                .frame(width: 66, height: 66)
                .background(AppShelfPalette.panel, in: RoundedRectangle(cornerRadius: 16))

            Text(query.isEmpty ? "这个分组还没有应用" : "没有匹配的应用")
                .font(.system(size: 16, weight: .semibold))

            Text(query.isEmpty ? "可以添加一个 .app，或切换到其他分组。" : "换个关键词试试。")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)

            HStack(spacing: 8) {
                if !query.isEmpty {
                    Button("清除搜索", action: onClearSearch)
                        .buttonStyle(.bordered)
                }
                if selection != .running {
                    Button {
                        onAddApp()
                    } label: {
                        Label("添加应用", systemImage: "plus")
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(AppShelfPalette.accent)
                }
            }
            .padding(.top, 3)
        }
        .frame(maxWidth: .infinity, minHeight: 300)
    }
}

/// Create or edit one group without exposing persistence details to the form.
struct GroupEditorSheet: View {
    @Environment(\.dismiss) private var dismiss

    private let existing: AppGroup?
    private let onSave: (String, String, String) -> Void

    @State private var name: String
    @State private var selectedSymbol: String
    @State private var color: Color

    private let symbols = [
        "star.fill", "folder.fill", "hammer.fill", "bubble.left.fill", "wand.and.stars",
        "house.fill", "wrench.and.screwdriver.fill", "book.fill", "music.note", "gamecontroller.fill",
        "camera.fill", "doc.fill", "network", "globe", "heart.fill"
    ]

    init(existing: AppGroup? = nil, onSave: @escaping (String, String, String) -> Void) {
        self.existing = existing
        self.onSave = onSave
        _name = State(initialValue: existing?.name ?? "")
        _selectedSymbol = State(initialValue: existing?.symbol ?? "folder.fill")
        _color = State(initialValue: existing.map { Color(hex: $0.colorHex) } ?? AppShelfPalette.accent)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(existing == nil ? "新建分组" : "编辑分组")
                        .font(.system(size: 20, weight: .semibold, design: .rounded))
                    Text("给分组一个容易辨认的名称和图标")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("名称")
                    .font(.system(size: 12, weight: .semibold))
                TextField("例如：项目、影音、常用", text: $name)
                    .textFieldStyle(.roundedBorder)
            }

            VStack(alignment: .leading, spacing: 9) {
                Text("图标")
                    .font(.system(size: 12, weight: .semibold))
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 8), spacing: 8) {
                    ForEach(symbols, id: \.self) { symbol in
                        Button {
                            selectedSymbol = symbol
                        } label: {
                            Image(systemName: symbol)
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundStyle(selectedSymbol == symbol ? color : .secondary)
                                .frame(width: 31, height: 31)
                                .background {
                                    RoundedRectangle(cornerRadius: 7)
                                        .fill(selectedSymbol == symbol ? color.opacity(0.14) : AppShelfPalette.panel)
                                }
                                .overlay {
                                    RoundedRectangle(cornerRadius: 7)
                                        .stroke(selectedSymbol == symbol ? color.opacity(0.55) : AppShelfPalette.border, lineWidth: 1)
                                }
                        }
                        .buttonStyle(.plain)
                    }
                }
            }

            ColorPicker("颜色", selection: $color, supportsOpacity: false)
                .font(.system(size: 12, weight: .semibold))

            HStack {
                Spacer()
                Button("取消", role: .cancel) { dismiss() }
                Button(existing == nil ? "创建" : "保存") {
                    onSave(name, selectedSymbol, color.appShelfHex)
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .tint(AppShelfPalette.accent)
                .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(24)
        .frame(width: 430)
    }
}

/// Review selected app bundles and choose their destination group.
struct AddAppsSheet: View {
    @Environment(\.dismiss) private var dismiss

    let urls: [URL]
    let groups: [AppGroup]
    let defaultGroupID: UUID
    let onAdd: ([URL], UUID) -> Void

    @State private var selectedGroupID: UUID

    init(urls: [URL], groups: [AppGroup], defaultGroupID: UUID, onAdd: @escaping ([URL], UUID) -> Void) {
        self.urls = urls
        self.groups = groups
        self.defaultGroupID = defaultGroupID
        self.onAdd = onAdd
        _selectedGroupID = State(initialValue: defaultGroupID)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 4) {
                Text("添加到应用架")
                    .font(.system(size: 20, weight: .semibold, design: .rounded))
                Text("已选择 \(urls.count) 个应用")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }

            ScrollView {
                VStack(alignment: .leading, spacing: 7) {
                    ForEach(urls, id: \.path) { url in
                        HStack(spacing: 9) {
                            Image(nsImage: NSWorkspace.shared.icon(forFile: url.path))
                                .resizable()
                                .frame(width: 28, height: 28)
                            Text(url.deletingPathExtension().lastPathComponent)
                                .font(.system(size: 12, weight: .medium))
                                .lineLimit(1)
                            Spacer()
                        }
                        .padding(.horizontal, 9)
                        .padding(.vertical, 6)
                        .background(AppShelfPalette.panel.opacity(0.7), in: RoundedRectangle(cornerRadius: 8))
                    }
                }
            }
            .frame(maxHeight: 190)

            Picker("目标分组", selection: $selectedGroupID) {
                ForEach(groups) { group in
                    Label(group.name, systemImage: group.symbol)
                        .tag(group.id)
                }
            }
            .pickerStyle(.menu)

            HStack {
                Spacer()
                Button("取消", role: .cancel) { dismiss() }
                Button {
                    onAdd(urls, selectedGroupID)
                    dismiss()
                } label: {
                    Label("加入分组", systemImage: "plus")
                }
                .buttonStyle(.borderedProminent)
                .tint(AppShelfPalette.accent)
                .disabled(groups.isEmpty)
            }
        }
        .padding(24)
        .frame(width: 430)
    }
}

/// Choose another group for an existing app card.
struct MoveAppSheet: View {
    @Environment(\.dismiss) private var dismiss

    let app: AppItem
    let groups: [AppGroup]
    let onMove: (UUID) -> Void

    @State private var selectedGroupID: UUID?

    init(app: AppItem, groups: [AppGroup], onMove: @escaping (UUID) -> Void) {
        self.app = app
        self.groups = groups
        self.onMove = onMove
        _selectedGroupID = State(initialValue: groups.first?.id)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 12) {
                Image(nsImage: NSWorkspace.shared.icon(forFile: app.path))
                    .resizable()
                    .frame(width: 44, height: 44)
                VStack(alignment: .leading, spacing: 3) {
                    Text("加入其他分组")
                        .font(.system(size: 18, weight: .semibold, design: .rounded))
                    Text(app.name)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            Picker("目标分组", selection: $selectedGroupID) {
                ForEach(groups) { group in
                    Label(group.name, systemImage: group.symbol)
                        .tag(Optional(group.id))
                }
            }
            .pickerStyle(.menu)

            HStack {
                Spacer()
                Button("取消", role: .cancel) { dismiss() }
                Button("加入") {
                    if let selectedGroupID { onMove(selectedGroupID) }
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .tint(AppShelfPalette.accent)
                .disabled(selectedGroupID == nil)
            }
        }
        .padding(24)
        .frame(width: 380)
    }
}

private extension Color {
    /// Convert the system color picker value to the hex representation persisted by AppGroup.
    var appShelfHex: String {
        let nsColor = NSColor(self).usingColorSpace(.deviceRGB) ?? NSColor.gray
        let red = max(0, min(255, Int(round(nsColor.redComponent * 255))))
        let green = max(0, min(255, Int(round(nsColor.greenComponent * 255))))
        let blue = max(0, min(255, Int(round(nsColor.blueComponent * 255))))
        return String(format: "#%02X%02X%02X", red, green, blue)
    }
}
