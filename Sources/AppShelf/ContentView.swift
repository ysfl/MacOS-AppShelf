import AppKit
import SwiftUI
import UniformTypeIdentifiers

import AppShelfCore

// MARK: - Main window
/// The main window. Sheets and alerts are kept here so child views only emit user intent.
struct ContentView: View {
    @ObservedObject var store: LauncherStore
    @ObservedObject private var quickTools = QuickToolStore.shared
    /// Observed so a density change in Settings re-renders the grid and re-measures slides.
    @ObservedObject private var layout = LayoutPreferences.shared

    @FocusState private var isSearchFocused: Bool
    // Highlight state is kept outside the view so drag hovers do not rebuild the grid.
    private let highlight = DragHighlight.shared
    @State private var isShowingNewGroup = false
    @State private var groupBeingEdited: AppGroup?
    @State private var groupPendingDeletion: AppGroup?
    @State private var urlsToAdd: [URL] = []
    @State private var isShowingAddSheet = false
    @State private var appToMove: AppItem?
    /// Refresh walks the whole file system, so it asks before starting.
    @State private var showRefreshConfirm = false
    /// Card the keyboard has selected, by bundle path so it survives section boundaries.
    @State private var focusedPath: String?

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
        // The window title follows the in-app language, not just the system one, so
        // switching to English renames the title bar immediately.
        .navigationTitle(L10n.shared.t("应用架"))
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
        .alert(L10n.shared.t("删除分组？"), isPresented: Binding(
            get: { groupPendingDeletion != nil },
            set: { if !$0 { groupPendingDeletion = nil } }
        )) {
            Button(L10n.shared.t("删除"), role: .destructive) {
                if let group = groupPendingDeletion {
                    store.deleteGroup(id: group.id)
                }
                groupPendingDeletion = nil
            }
            Button(L10n.shared.t("取消"), role: .cancel) {
                groupPendingDeletion = nil
            }
        } message: {
            L10nText("分组中的应用不会被卸载，只会移除这个分组。")
        }
        .alert(L10n.shared.t("操作失败"), isPresented: Binding(
            get: { store.errorMessage != nil },
            set: { if !$0 { store.errorMessage = nil } }
        )) {
            Button(L10n.shared.t("好"), role: .cancel) {
                store.errorMessage = nil
            }
        } message: {
            Text(store.errorMessage ?? L10n.shared.t("请稍后重试。"))
        }
        // Menu commands reach the window's own focus state through this token.
        .onReceive(FocusRouter.shared.$searchFocusToken) { _ in
            isSearchFocused = true
        }
    }

    private var mainContent: some View {
        // The header and the search row stay fixed while the grid scrolls.
        VStack(alignment: .leading, spacing: 0) {
            header

            searchBar

            Divider()

            ScrollViewReader { scroller in
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
                                onAddApp: chooseApps,
                                onRevealAll: store.hidden.isEmpty ? nil : { store.revealAllHidden() }
                            )
                        } else {
                            appGrid
                        }
                    }
                    .padding(.horizontal, 28)
                    .padding(.vertical, 24)
                    .frame(maxWidth: .infinity, minHeight: 320, alignment: .topLeading)
                    // Dropping a quick tool anywhere in the content area removes it.
                    .dropDestination(for: ShelfDragItem.self) { items, _ in
                        removeQuickTools(items)
                    }
                }
                // An arrow-key selection has to stay on screen, or the highlight walks out
                // of sight and the list looks frozen.
                .onChange(of: focusedPath) { _, path in
                    guard let path else { return }
                    withAnimation(ShelfMotion.fade) {
                        scroller.scrollTo(path, anchor: .center)
                    }
                }
            }

            footer
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onAppear { focusSearchField() }
        // Every page change hands the keyboard back to the search field.
        .onChange(of: store.selection, initial: false) { _, _ in
            // A drag cannot survive a page change, so drop any leftover state here too:
            // otherwise the strips and outlines reappear on the new page.
            DragActivity.shared.end()
            focusedPath = nil
            focusSearchField()
        }
        // Same for the search field itself: leaving a query can strand a drag started
        // over the old results.
        .onChange(of: store.query, initial: false) { _, _ in
            DragActivity.shared.end()
            // Start the highlight on the best match so Return opens it immediately.
            focusedPath = currentOrder.first
        }
        .onChange(of: store.apps.count, initial: false) { _, _ in
            if let focusedPath, !currentOrder.contains(focusedPath) { self.focusedPath = nil }
        }
    }

    /// A full-width search row under the title so there is room for longer queries.
    private var searchBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)

            TextField(L10n.shared.t("搜索应用，支持拼音首字母，如 wx / vsc"), text: $store.query)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .focused($isSearchFocused)
                .accessibilityLabel(L10n.shared.t("搜索应用，支持拼音首字母，如 wx / vsc"))
                // The search field keeps keyboard focus by design, so grid navigation has to
                // be driven from here. Up and down walk the results; left and right are left
                // to the caret, which is what Spotlight does too.
                .onKeyPress(.upArrow) {
                    moveFocus(by: -GridMetrics.shared.columns)
                    return .handled
                }
                .onKeyPress(.downArrow) {
                    moveFocus(by: GridMetrics.shared.columns)
                    return .handled
                }
                .onKeyPress(.return) {
                    openFocused()
                    return .handled
                }
                .onKeyPress(.escape) {
                    guard focusedPath != nil, store.query.isEmpty else { return .ignored }
                    focusedPath = nil
                    return .handled
                }

            if !store.query.isEmpty {
                Button {
                    store.query = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(L10n.shared.t("清除搜索"))
                .help(L10n.shared.t("清除搜索"))
            }
        }
        .padding(.horizontal, 12)
        .frame(height: 36)
        .background(AppShelfPalette.panel, in: RoundedRectangle(cornerRadius: 9))
        .overlay {
            RoundedRectangle(cornerRadius: 9)
                .stroke(isSearchFocused ? AppShelfPalette.focusRing : AppShelfPalette.border, lineWidth: 1)
        }
        .padding(.horizontal, 28)
        .padding(.bottom, 16)
        .accessibilityElement(children: .contain)
    }

    private func focusSearchField() {
        // A short delay lets the page finish swapping before focus is claimed.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            isSearchFocused = true
        }
    }

    // MARK: Keyboard selection

    /// The cards in the order they are drawn, so the arrow keys have something to walk.
    private var currentOrder: [String] {
        let sections = appSections
        if !sections.isEmpty { return sections.flatMap(\.apps).map(\.path) }
        return store.filteredApps.map(\.path)
    }

    private func moveFocus(by delta: Int) {
        let order = currentOrder
        guard !order.isEmpty else { return }
        guard let current = focusedPath.flatMap({ order.firstIndex(of: $0) }) else {
            focusedPath = order.first
            return
        }
        // Clamped rather than wrapped: in a grid, jumping to the far end of a 135-app list
        // on one keypress reads as a glitch, not as a cycle.
        let next = min(max(current + delta, 0), order.count - 1)
        focusedPath = order[next]
    }

    private func openFocused() {
        let order = currentOrder
        guard !order.isEmpty else { return }
        let path = focusedPath ?? order[0]
        guard let app = store.apps.first(where: { $0.path == path }) else { return }
        store.launch(app)
    }

    private var header: some View {
        HStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 9) {
                    Image(systemName: store.selectedSymbol)
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(AppShelfPalette.accent)
                        .frame(width: 23)
                        .accessibilityHidden(true)

                    Text(store.selectedTitle)
                        .font(.system(size: 24, weight: .semibold, design: .rounded))
                        .foregroundStyle(.primary)
                }

                Text(L10n.shared.t("apps_count",
                      args: ["count": "\(store.filteredCount)", "running": "\(store.count(for: .running))"]))
                    .font(.shelfBody)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 18)

            Toggle(isOn: $store.runningOnly) {
                Label {
                    L10nText("运行中")
                } icon: {
                    Image(systemName: "bolt.fill")
                }
                .font(.shelfBody)
            }
            .toggleStyle(.checkbox)
            .help(L10n.shared.t("只显示正在运行的应用"))

            // A full discovery pass walks the file system, so it is confirmed first.
            Button {
                showRefreshConfirm = true
            } label: {
                Image(systemName: store.isScanning ? "hourglass" : "arrow.clockwise")
                    .font(.shelfSectionTitle)
            }
            .buttonStyle(.bordered)
            .controlSize(.large)
            .disabled(store.isScanning)
            .accessibilityLabel(L10n.shared.t("刷新应用列表"))
            .help(L10n.shared.t("刷新应用列表"))
            .alert(L10n.shared.t("refresh.title"), isPresented: $showRefreshConfirm) {
                Button(L10n.shared.t("刷新应用列表")) { store.reload() }
                Button(L10n.shared.t("取消"), role: .cancel) { }
            } message: {
                Text(L10n.shared.t("refresh.message"))
            }

            Button(action: chooseApps) {
                Label {
                    L10nText("添加应用")
                } icon: {
                    Image(systemName: "plus")
                }
                .font(.shelfLabel)
            }
            .buttonStyle(.borderedProminent)
            .tint(AppShelfPalette.accent)
            .controlSize(.large)

            // Appearance switch: follow the OS, or force light / dark.
            Menu {
                ForEach(AppearanceMode.allCases, id: \.self) { mode in
                    Button {
                        Appearance.shared.mode = mode
                    } label: {
                        HStack {
                            Image(systemName: mode.symbol)
                            L10nText(mode.titleKey)
                            if Appearance.shared.mode == mode {
                                Image(systemName: "checkmark")
                            }
                        }
                    }
                }
            } label: {
                Image(systemName: Appearance.shared.mode.symbol)
                    .font(.shelfSectionTitle)
                    .accessibilityLabel(L10n.shared.t("appearance"))
            }
            // `accessibilityLabel` on the Menu itself makes `.borderlessButton` lay its
            // indicator out at the far edge of the space it is offered, which tore the
            // header apart. Labelling the image and pinning the size keeps it a tile.
            .menuStyle(.borderlessButton)
            .menuIndicator(.visible)
            .fixedSize()
            .buttonStyle(.bordered)
            .controlSize(.large)
            .help(L10n.shared.t("appearance"))

            // Language switch: pick a bundled or external language.
            Menu {
                ForEach(L10n.shared.availableLanguages, id: \.self) { code in
                    Button {
                        L10n.shared.language = code
                    } label: {
                        HStack {
                            if code == "system" {
                                L10nText("language.system")
                            } else {
                                Text(L10n.shared.displayName(for: code))
                            }
                            if L10n.shared.language == code {
                                Image(systemName: "checkmark")
                            }
                        }
                    }
                }
            } label: {
                Image(systemName: "globe")
                    .font(.shelfSectionTitle)
                    .accessibilityLabel(L10n.shared.t("language"))
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.visible)
            .fixedSize()
            .buttonStyle(.bordered)
            .controlSize(.large)
            .help(L10n.shared.t("language"))

            Button(action: { SettingsWindowController.shared.showWindow() }) {
                Image(systemName: "gearshape")
                    .font(.shelfSectionTitle)
            }
            .buttonStyle(.bordered)
            .controlSize(.large)
            .accessibilityLabel(L10n.shared.t("设置"))
            .help(L10n.shared.t("设置"))
        }
        .padding(.horizontal, 28)
        .padding(.vertical, 20)
    }

    private var appGrid: some View {
        let membership = store.groupMembership()
        let apps = store.filteredApps
        let hiddenSelection = store.selection == .hidden

        // Adaptive columns use the available window width without changing tile sizes.
        return LazyVGrid(columns: ShelfGrid.columns, alignment: .leading,
                         spacing: ShelfGrid.rowSpacing) {
            ForEach(Array(apps.enumerated()), id: \.element.id) { index, app in
                appCard(app, index: index, sectionGroupID: nil,
                        removableGroups: membership[app.path] ?? [],
                        isHiddenApp: hiddenSelection)
                    .id(app.path)
            }
        }
    }

    /// All Apps is laid out as one block per group, in the order the user arranged them.
    /// While a group is being dragged every block is outlined, and the one under the
    /// cursor is filled, so the drop target is obvious without reading any hint text.
    private var sectionedApps: some View {
        let membership = store.groupMembership()
        let sections = appSections

        return VStack(alignment: .leading, spacing: 18) {
            ForEach(sections) { section in
                sectionBlock(section, membership: membership)
            }
        }
    }

    @ViewBuilder
    private func sectionBlock(_ section: AppSection, membership: [String: [AppGroup]]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionHeader(section)

            LazyVGrid(columns: ShelfGrid.columns, alignment: .leading,
                      spacing: ShelfGrid.rowSpacing) {
                ForEach(Array(section.apps.enumerated()), id: \.element.id) { index, app in
                    appCard(app, index: index, sectionGroupID: section.groupID,
                            removableGroups: membership[app.path] ?? [])
                        .id(app.path)
                }
            }
            // Measures the block so a tile can be slid by exactly one slot. Sits in the
            // background so it never influences layout.
            .background(
                GeometryReader { proxy in
                    Color.clear.preference(key: GridSizeKey.self, value: proxy.size)
                }
            )
            .onPreferenceChange(GridSizeKey.self) { size in
                GridMetrics.shared.update(width: size.width, height: size.height, count: section.apps.count)
            }

            // Sits below the cards (outside the grid) so it never overlaps a tile, and only
            // exists while a drag is in flight so it costs no space when idle.
            if let groupID = section.groupID {
                RemoveFromGroupStrip(
                    groupID: groupID,
                    onRemove: { paths in
                        store.recordUndoPoint()
                        paths.forEach { store.removeApp($0, from: groupID) }
                        // The card reappears in the ungrouped block, so that is where the
                        // landing animation belongs — not in the block it just left.
                        if let path = paths.first {
                            DropAnimator.shared.playGrid(groupID: nil, path: path)
                        }
                        highlight.endDrag()
                    },
                    onMoveGroup: { dragged in
                        store.moveGroup(dragged, before: groupID)
                        // Without this the strip stayed up until the release fallback
                        // happened to close it 0.35 s later.
                        highlight.endDrag()
                    }
                )
            }

        }
        .padding(10)
        // Only this small view watches the drag state, so highlighting a
        // section never rebuilds the cards inside it.
        .background { SectionDropHighlight(groupID: section.groupID) }
        // The whole block accepts drops: group reordering and filing an app into
        // this group both work anywhere inside it, not only on the heading.
        .dropDestination(for: ShelfDragItem.self) { items, _ in
            guard let groupID = section.groupID else { return false }

            if let dragged = items.first(where: { $0.kind == .group })?.groupID {
                store.moveGroup(dragged, before: groupID)
                highlight.endDrag()
                return true
            }

            let paths = items.filter(\.isAppPath).map(\.value)
            guard !paths.isEmpty else { return false }
            store.addApps(paths, to: groupID)
            if let path = paths.first {
                DropAnimator.shared.playGrid(groupID: groupID, path: path)
            }
            highlight.endDrag()
            return true
        } isTargeted: { isTargeted in
            highlight.setGroupHover(isTargeted ? section.groupID : nil)
            highlight.setHover(isTargeted)
        }
        // An application bundle dragged in from Finder files itself into this group.
        .dropDestination(for: URL.self) { urls, _ in
            guard let groupID = section.groupID else { return false }
            let bundles = urls.filter { ShelfPath.isApplicationBundle($0.path) }
            guard !bundles.isEmpty else { return false }
            store.recordUndoPoint()
            store.addApps(bundles, to: groupID)
            return true
        }
    }

    /// The short hint next to a section heading, kept separate for the same reason.
    private struct SectionDropHint: View {
        @ObservedObject private var highlight = DragHighlight.shared
        @ObservedObject private var activity = DragActivity.shared
        let groupID: UUID?

        var body: some View {
            Text(isTarget ? L10n.shared.t("放到这里") : L10n.shared.t("拖动标题或卡片可调整顺序"))
                .font(.shelfMicro)
                .foregroundStyle(isTarget ? AppShelfPalette.accent : Color.secondary.opacity(0.7))
        }

        private var isTarget: Bool {
            activity.isActive && groupID == highlight.sectionTargetID
        }
    }

    /// The dashed outline every block shows while a drag is in flight, and the filled
    /// outline of the block under the cursor.
    private struct SectionDropHighlight: View {
        @ObservedObject private var highlight = DragHighlight.shared
        /// Driven by "a drag is happening" rather than by which block is hovered: that
        /// flips constantly and made every block's outline blink while the pointer moved.
        @ObservedObject private var activity = DragActivity.shared
        let groupID: UUID?

        var body: some View {
            RoundedRectangle(cornerRadius: 12)
                .fill(fill)
                .strokeBorder(
                    stroke,
                    style: isTarget
                        ? StrokeStyle(lineWidth: 2)
                        : StrokeStyle(lineWidth: 1, dash: [5, 4])
                )
        }

        private var isTarget: Bool {
            // Gated on the drag still running: the marker is only cleared when a drag
            // ends, so without this a drag released on empty space would leave one block
            // accented indefinitely.
            activity.isActive && groupID != nil && highlight.sectionTargetID == groupID
        }

        private var fill: Color {
            if isTarget { return AppShelfPalette.dropTargetFill }
            return activity.isActive ? Color.primary.opacity(0.05) : Color.clear
        }

        private var stroke: Color {
            if isTarget { return AppShelfPalette.accent }
            return activity.isActive ? AppShelfPalette.accent.opacity(0.35) : Color.clear
        }
    }

    /// Section headings are themselves draggable, so groups can be reordered here too.
    @ViewBuilder
    private func sectionHeader(_ section: AppSection) -> some View {
        let heading = HStack(spacing: 8) {
            Image(systemName: section.symbol)
                .font(.shelfLabel)
                .foregroundStyle(section.tint)
                .frame(width: 16)
                .accessibilityHidden(true)

            Text(section.title)
                .font(.shelfSectionTitle)
                .foregroundStyle(.primary)

            Text("\(section.apps.count)")
                .font(.shelfCount)
                .foregroundStyle(.tertiary)

            Spacer(minLength: 0)

            if section.groupID != nil {
                SectionDropHint(groupID: section.groupID)
            }
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())

        if let groupID = section.groupID {
            heading
                .accessibilityElement(children: .combine)
                .accessibilityLabel(L10n.shared.t("分组") + " " + section.title)
                .draggable(ShelfDragItem.group(groupID)) {
                    GroupDragPreview(
                        title: section.title,
                        symbol: section.symbol,
                        tint: section.tint,
                        apps: section.apps
                    )
                }
        } else {
            heading
        }
    }

    /// One card plus its drag behaviour. `sectionGroupID` enables drag-to-reorder
    /// inside that group; it stays nil for search results, which are ranked instead.
    ///
    /// Cards outside a section carry no drop target at all: hundreds of registered
    /// drop targets slow every mouse move during a drag.
    @ViewBuilder
    private func appCard(_ app: AppItem,
                         index: Int,
                         sectionGroupID: UUID?,
                         removableGroups: [AppGroup],
                         isHiddenApp: Bool = false) -> some View {
        let card = AppCard(
            app: app,
            showsCategory: sectionGroupID == nil,
            removableGroups: removableGroups,
            isFocused: focusedPath == app.path,
            isHiddenApp: isHiddenApp,
            onOpen: { store.launch(app) },
            onMove: { appToMove = app },
            onRemoveFromGroup: { group in
                store.recordUndoPoint()
                store.removeApp(app, from: group.id)
                DropAnimator.shared.play(groupID: group.id)
            },
            onRemoveAllGroups: {
                store.recordUndoPoint()
                removableGroups.forEach { store.removeApp(app, from: $0.id) }
            },
            onHide: { store.hideApp(app) },
            onReveal: { store.revealApp(app) },
            onShowInFinder: { store.openInFinder(app) },
            onShowPackageContents: { store.showPackageContents(app) },
            onCopyBundleID: { store.copyBundleIdentifier(app) },
            onQuit: app.isRunning ? { store.terminate(app) } : nil,
            onForceQuit: app.isRunning ? { store.terminate(app, force: true) } : nil,
            index: index,
            sectionGroupID: sectionGroupID
        )
        // The bundle path is the drag payload: dropping on a sidebar group files the app,
        // dropping on another card inside a section reorders it.
        //
        // Search results and the hidden list are not draggable: results are ranked, so there
        // is no stable position to reorder, and starting a drag there and abandoning it was
        // the most reliable way to leave the whole grid stuck showing drag affordances.
        .when(store.query.isEmpty && !isHiddenApp) { view in
            view.draggable(ShelfDragItem.app(app.path)) {
                // The whole card follows the cursor, so there is no icon drifting away
                // from the tile it belongs to.
                AppCardTile(app: app, showsCategory: sectionGroupID == nil, width: 152)
                    .background(AppShelfPalette.panel, in: RoundedRectangle(cornerRadius: 12))
                    .overlay {
                        RoundedRectangle(cornerRadius: 12)
                            .strokeBorder(AppShelfPalette.dragOutline, lineWidth: 1)
                    }
                    // The preview is only built once the drag actually starts, so this is
                    // the earliest reliable "this app is the one being carried" signal, and
                    // it records which block it came from.
                    .onAppear { highlight.beginAppDrag(path: app.path, from: sectionGroupID) }
            }
        }

        if let sectionGroupID {
            card
                .dropDestination(for: ShelfDragItem.self) { items, _ in
                    if items.contains(where: { $0.kind == .quickTool }) {
                        return removeQuickTools(items)
                    }

                    // Dropping another group on a card reorders that group ahead of this one.
                    if let groupID = items.first(where: { $0.kind == .group })?.groupID {
                        store.moveGroup(groupID, before: sectionGroupID)
                        highlight.endDrag()
                        return true
                    }

                    // Dropping an app here reorders it, or files it into this group from outside.
                    let paths = items.filter(\.isAppPath).map(\.value)
                    guard !paths.isEmpty else { return false }
                    // The whole gesture only previewed the slide with transforms; this is
                    // the one write that makes it real.
                    commitOrder(for: paths, hovered: app, in: sectionGroupID)
                    if let path = paths.first {
                        DropAnimator.shared.playGrid(groupID: sectionGroupID, path: path)
                    }
                    highlight.endDrag()
                    return true
                } isTargeted: { isTargeted in
                    highlight.setHover(isTargeted)
                    // A tile is inside the block too: without this, the outline of the
                    // section blinked off every time the pointer crossed a tile.
                    highlight.setGroupHover(isTargeted ? sectionGroupID : nil)
                    guard isTargeted else { return }
                    let activity = DragActivity.shared
                    // Only a reorder inside this block slides anything. When the tile
                    // under the cursor is the one being carried, it is a reorder; when it
                    // is any other tile, the app came from outside and is just filed here.
                    if app.path == activity.sourcePath {
                        if DragReflow.shared.sourceIndex == nil {
                            DragReflow.shared.begin(groupID: sectionGroupID, sourceIndex: index)
                        }
                    } else if activity.sourcePath == nil {
                        // Fallback: no drag-start signal arrived, so the first tile to
                        // report itself is assumed to be the one picked up.
                        highlight.beginAppDrag(path: app.path, from: sectionGroupID)
                        DragReflow.shared.begin(groupID: sectionGroupID, sourceIndex: index)
                    }
                    // Only records which slot the pointer is over. Nothing is reordered
                    // yet, so the indices used for the slide cannot drift mid-gesture.
                    DragReflow.shared.hover(index, groupID: sectionGroupID)
                }
                // Finder bundles dropped on a tile join this group.
                .dropDestination(for: URL.self) { urls, _ in
                    let bundles = urls.filter { ShelfPath.isApplicationBundle($0.path) }
                    guard !bundles.isEmpty else { return false }
                    store.recordUndoPoint()
                    store.addApps(bundles, to: sectionGroupID)
                    return true
                }
        } else {
            card
        }
    }

    /// Takes any quick tools out of the row. Returns true when that is what this drop was
    /// about, so the caller stops rather than falling through as an app drop.
    private func removeQuickTools(_ items: [ShelfDragItem]) -> Bool {
        let removed = items.filter { $0.kind == .quickTool }
        guard !removed.isEmpty else { return false }
        store.recordUndoPoint()
        removed.forEach { quickTools.remove($0.value) }
        store.note(L10n.shared.t("已从快捷工具移除"))
        return true
    }

    /// Writes the arrangement the slide has been previewing, once, on drop.
    ///
    /// `ShelfOrdering` owns the arithmetic; this only assembles its inputs from the live
    /// drag state and hands the resulting placement to the store.
    private func commitOrder(for paths: [String], hovered: AppItem, in groupID: UUID) {
        // Must be the same list the slide indices came from: the grid shows the
        // running-only subset when that filter is on, and mixing the two is what made
        // the landing slot drift a tile.
        let ordered = store.orderedApps(in: groupID)
        let list = store.runningOnly ? ordered.filter(\.isRunning) : ordered
        let order = list.map(\.path)

        let activity = DragActivity.shared
        let placement: ShelfOrdering.Placement?
        if DragReflow.shared.groupID == groupID,
           let source = DragReflow.shared.sourceIndex,
           let hoveredIndex = DragReflow.shared.hoveredIndex,
           let picked = activity.sourcePath {
            placement = ShelfOrdering.placement(order: order, source: source,
                                                hovered: hoveredIndex, picked: picked)
        } else {
            placement = nil
        }

        // `nil` means this was not a same-group reorder, so the app is simply filed where
        // it was dropped.
        store.applyOrder(paths,
                         placement: placement ?? ShelfOrdering.Placement(edge: .before,
                                                                        target: hovered.path),
                         in: groupID)
    }

    /// Sections are only used when no search text is active; searching ranks across everything.
    private var appSections: [AppSection] {
        guard !store.isLoading else { return [] }
        guard store.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return [] }

        func visible(_ apps: [AppItem]) -> [AppItem] {
            store.runningOnly ? apps.filter(\.isRunning) : apps
        }

        switch store.selection {
        case .running, .ungrouped, .hidden:
            return []
        case .group(let id):
            let apps = visible(store.orderedApps(in: id))
            guard !apps.isEmpty, let group = store.groups.first(where: { $0.id == id }) else { return [] }
            return [AppSection(id: id.uuidString,
                               title: store.title(for: group),
                               symbol: group.symbol,
                               tint: group.color,
                               groupID: id,
                               apps: apps)]
        case .all:
            var sections: [AppSection] = store.groups.compactMap { group in
                let apps = visible(store.orderedApps(in: group.id))
                guard !apps.isEmpty else { return nil }
                return AppSection(
                    id: group.id.uuidString,
                    title: store.title(for: group),
                    symbol: group.symbol,
                    tint: group.color,
                    groupID: group.id,
                    apps: apps
                )
            }
            let ungrouped = visible(store.ungroupedApps())
            if !ungrouped.isEmpty {
                sections.append(
                    AppSection(id: "ungrouped", title: L10n.shared.t("未分组"), symbol: "tray",
                               tint: .secondary, groupID: nil, apps: ungrouped)
                )
            }
            return sections
        }
    }

    private var quickToolsSection: some View {
        QuickToolsRow { tool in
            store.launch(tool)
        } onAdded: { message in
            store.note(message)
        }
    }

    /// The footer is its own view so the refresh timestamp updating every few seconds
    /// does not invalidate the whole page.
    private struct StatusFooter: View {
        @ObservedObject var store: LauncherStore

        var body: some View {
            HStack(spacing: 8) {
                Circle()
                    .fill(store.isLoading ? Color.orange : AppShelfPalette.success)
                    .frame(width: 7, height: 7)
                    .accessibilityHidden(true)

                Text(store.isLoading ? L10n.shared.t("正在扫描应用…")
                                      : L10n.shared.t("apps_scanned", args: ["count": "\(store.visibleApps.count)"]))
                    .font(.shelfNote)
                    .foregroundStyle(.secondary)

                Text("·")
                    .foregroundStyle(.tertiary)

                Text(L10n.shared.t("updated_at", args: ["time": store.lastUpdated.formatted(date: .omitted, time: .shortened)]))
                    .font(.shelfMeta)
                    .foregroundStyle(.tertiary)

                if let message = store.statusMessage {
                    Text("·")
                        .foregroundStyle(.tertiary)
                    Text(message)
                        .font(.shelfNote)
                        .foregroundStyle(AppShelfPalette.accent)
                }

                Spacer()

                if store.canUndo {
                    Button {
                        store.undo()
                    } label: {
                        Label(L10n.shared.t("撤销"), systemImage: "arrow.uturn.backward")
                            .font(.shelfNote)
                    }
                    .buttonStyle(.borderless)
                    .accessibilityLabel(L10n.shared.t("撤销上一步分组或排序操作"))
                    .help(L10n.shared.t("撤销上一步分组或排序操作"))
                }

                L10nText("应用架")
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 28)
            .padding(.vertical, 10)
            .background(AppShelfPalette.sidebar.opacity(0.58))
            .accessibilityElement(children: .contain)
        }
    }

    private var footer: some View {
        StatusFooter(store: store)
    }

    private var shouldShowQuickTools: Bool {
        store.selection == .all
            && store.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !store.runningOnly
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
        panel.title = L10n.shared.t("添加应用")
        panel.message = L10n.shared.t("选择一个或多个 .app 文件")
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
