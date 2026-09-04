import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Shared colors for the launcher shell and its controls.
private enum AppShelfPalette {
    static let sidebar = Color(nsColor: .underPageBackgroundColor)
    static let canvas = Color(nsColor: .windowBackgroundColor)
    static let panel = Color(nsColor: .controlBackgroundColor)
    static let border = Color.black.opacity(0.08)
    static let accent = Color(red: 0.12, green: 0.42, blue: 0.86)
    static let success = Color(red: 0.12, green: 0.60, blue: 0.42)
}

/// The main window. Sheets and alerts are kept here so child views only emit user intent.
struct ContentView: View {
    @ObservedObject var store: LauncherStore

    @State private var isShowingNewGroup = false
    @State private var groupBeingEdited: AppGroup?
    @State private var groupPendingDeletion: AppGroup?
    @State private var urlsToAdd: [URL] = []
    @State private var isShowingAddSheet = false
    @State private var appToMove: AppItem?

    // Running state is cheap to refresh and should reflect apps launched outside AppShelf.
    private let refreshTimer = Timer.publish(every: 5, on: .main, in: .common).autoconnect()

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
        // The header stays fixed while the grid scrolls, which keeps search and filters visible.
        VStack(alignment: .leading, spacing: 0) {
            header

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    if shouldShowQuickTools {
                        quickTools
                    }

                    if store.isLoading {
                        LoadingState()
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
            }

            footer
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
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

            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.secondary)

                TextField("搜索应用", text: $store.query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                    .frame(width: 180)

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
            .padding(.horizontal, 11)
            .padding(.vertical, 8)
            .background(AppShelfPalette.panel, in: RoundedRectangle(cornerRadius: 9))
            .overlay {
                RoundedRectangle(cornerRadius: 9)
                    .stroke(AppShelfPalette.border, lineWidth: 1)
            }

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
        }
        .padding(.horizontal, 28)
        .padding(.vertical, 20)
    }

    private var appGrid: some View {
        // Adaptive columns use the available window width without changing card dimensions.
        LazyVGrid(
            columns: [GridItem(.adaptive(minimum: 172, maximum: 230), spacing: 14)],
            alignment: .leading,
            spacing: 14
        ) {
            ForEach(store.filteredApps) { app in
                AppCard(
                    app: app,
                    currentGroupID: currentGroupID,
                    onOpen: { store.launch(app) },
                    onMove: {
                        appToMove = app
                    },
                    onRemove: currentGroupID.map { groupID in
                        { store.removeApp(app, from: groupID) }
                    },
                    onShowInFinder: { store.openInFinder(app) }
                )
            }
        }
    }

    private var quickTools: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text("快捷工具")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Text("点击即可打开")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
            }

            HStack(spacing: 10) {
                ForEach(Array(QuickTool.allCases.prefix(4))) { tool in
                    QuickToolTile(tool: tool) {
                        store.launch(tool)
                    }
                }
            }
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
}

/// Navigation for built-in views, user groups, and the small utility list.
struct SidebarView: View {
    @ObservedObject var store: LauncherStore
    let onNewGroup: () -> Void
    let onEditGroup: (AppGroup) -> Void
    let onDeleteGroup: (AppGroup) -> Void
    let onLaunchTool: (QuickTool) -> Void

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
                                isSelected: store.selection == .group(group.id)
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
                        }
                    }

                    VStack(alignment: .leading, spacing: 5) {
                        SidebarSectionLabel("快捷工具")
                        ForEach(QuickTool.allCases) { tool in
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
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: symbol)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(isSelected ? tint : .secondary)
                    .frame(width: 18)

                Text(title)
                    .font(.system(size: 13, weight: isSelected ? .semibold : .medium))
                    .foregroundStyle(isSelected ? .primary : .secondary)
                    .lineLimit(1)

                Spacer(minLength: 4)

                Text("\(count)")
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundStyle(isSelected ? .secondary : .tertiary)
            }
            .padding(.horizontal, 10)
            .frame(height: 34)
            .background {
                if isSelected {
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color.white.opacity(0.78))
                        .shadow(color: .black.opacity(0.04), radius: 2, y: 1)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// A sidebar shortcut that delegates launching to the store owner.
private struct ToolRow: View {
    let tool: QuickTool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: tool.symbol)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
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
    }
}

/// A fixed-size app tile. Opening is the primary action; less common actions live in its menu.
private struct AppCard: View {
    let app: AppItem
    let currentGroupID: UUID?
    let onOpen: () -> Void
    let onMove: () -> Void
    let onRemove: (() -> Void)?
    let onShowInFinder: () -> Void

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
            Divider()
            Button("在 Finder 中显示", systemImage: "folder") { onShowInFinder() }
        }
        .help("打开\(app.name)")
    }

    private var cardContent: some View {
        VStack(alignment: .leading, spacing: 0) {
            cardTop
            Spacer(minLength: 12)
            Text(app.name)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.primary)
                .lineLimit(1)
                .truncationMode(.middle)
            cardFooter
        }
        .padding(15)
        .frame(maxWidth: .infinity, minHeight: 156, maxHeight: 156, alignment: .topLeading)
        .background(cardBackground)
        .overlay(cardBorder)
        .shadow(color: .black.opacity(isHovering ? 0.09 : 0.035), radius: isHovering ? 9 : 3, y: isHovering ? 4 : 1)
        .scaleEffect(isHovering ? 1.012 : 1)
    }

    private var cardTop: some View {
        HStack(alignment: .top) {
            AppIconView(path: app.path)
                .frame(width: 62, height: 62)

            Spacer(minLength: 8)

            if app.isRunning {
                HStack(spacing: 4) {
                    Circle()
                        .fill(AppShelfPalette.success)
                        .frame(width: 6, height: 6)
                    Text("运行中")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(AppShelfPalette.success)
                }
                .padding(.horizontal, 7)
                .padding(.vertical, 4)
                .background(AppShelfPalette.success.opacity(0.10), in: Capsule())
            }
        }
    }

    private var cardFooter: some View {
        HStack(spacing: 6) {
            Text(app.category)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
            Spacer()
            Image(systemName: isHovering ? "arrow.up.right.circle.fill" : "arrow.up.right")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(isHovering ? AppShelfPalette.accent : Color.secondary.opacity(0.48))
        }
        .padding(.top, 5)
    }

    private var cardBackground: some View {
        RoundedRectangle(cornerRadius: 8)
            .fill(AppShelfPalette.panel.opacity(isHovering ? 1 : 0.72))
    }

    private var cardBorder: some View {
        RoundedRectangle(cornerRadius: 8)
            .stroke(isHovering ? AppShelfPalette.accent.opacity(0.32) : AppShelfPalette.border, lineWidth: 1)
    }
}

/// Resolve the icon from the bundle path so third-party apps use their own artwork.
private struct AppIconView: View {
    let path: String

    var body: some View {
        Image(nsImage: NSWorkspace.shared.icon(forFile: path))
            .resizable()
            .interpolation(.high)
            .aspectRatio(contentMode: .fit)
            .shadow(color: .black.opacity(0.12), radius: 3, y: 2)
    }
}

/// A larger shortcut tile shown above the full app grid.
private struct QuickToolTile: View {
    let tool: QuickTool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: tool.symbol)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(AppShelfPalette.accent)
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
