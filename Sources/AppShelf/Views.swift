import AppKit
import SwiftUI
import UniformTypeIdentifiers

import AppShelfCore

extension UTType {
    /// One in-app drag type for every draggable thing in the window.
    ///
    /// A view can only reliably carry a single drop destination, so app cards, group
    /// rows, and quick tools all share this type and are told apart by `kind`.
    static let appShelfDragItem = UTType(exportedAs: "local.dan.AppShelf.drag")
}

// MARK: - Drag state

/// Live state of an in-group drag: which slot was picked up, and which slot the pointer
/// is over.
///
/// The data is deliberately untouched until the drop. That keeps every index stable for
/// the whole gesture — reordering as we went made the indices move under the calculation,
/// which is what caused the "sometimes it takes two tiles" behaviour.
final class DragReflow: ObservableObject {
    static let shared = DragReflow()

    @Published private(set) var groupID: UUID?
    @Published private(set) var sourceIndex: Int?
    @Published private(set) var hoveredIndex: Int?

    func begin(groupID: UUID, sourceIndex: Int) {
        self.groupID = groupID
        self.sourceIndex = sourceIndex
        self.hoveredIndex = sourceIndex
    }

    /// Only the group the drag started in slides; hovering another block files the app
    /// there on drop and must not disturb this block.
    func hover(_ index: Int, groupID: UUID) {
        guard self.groupID == groupID else { return }
        guard hoveredIndex != index else { return }
        hoveredIndex = index
    }

    func clear() {
        groupID = nil
        sourceIndex = nil
        hoveredIndex = nil
    }
}

/// Whether a drag is in progress at all, and which app is being carried.
///
/// Deliberately separate from the highlight object: that one publishes on every pointer
/// move, so subscribing every tile to it would repaint the whole grid while dragging.
/// This one only changes twice per drag, so tiles can safely watch it to draw their
/// outline and fade themselves out of the grid.
final class DragActivity: ObservableObject {
    static let shared = DragActivity()

    @Published private(set) var isActive = false
    @Published private(set) var sourcePath: String?
    /// The block the carried app was picked up from. An app can sit in several groups and
    /// then shows one card per group; without this, carrying it blanked *every* one of its
    /// cards at once instead of only the one under the cursor.
    @Published private(set) var sourceGroupID: UUID?

    private var endWork: DispatchWorkItem?
    private var safetyWork: DispatchWorkItem?

    func begin() {
        endWork?.cancel()
        endWork = nil
        if !isActive { isActive = true }
        scheduleSafetyNet()
    }

    func begin(path: String, groupID: UUID?) {
        begin()
        sourcePath = path
        sourceGroupID = groupID
    }

    /// Last-resort reset. A drag that is cancelled with Esc, released over empty space, or
    /// never started properly never reaches a drop handler, and the delete strips and
    /// outlines would otherwise stay on screen until the app was restarted.
    private func scheduleSafetyNet() {
        safetyWork?.cancel()
        let work = DispatchWorkItem { self.end() }
        safetyWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 12, execute: work)
    }

    /// Called from a mouse release: if no drop handler has run by the time this fires,
    /// the drag was abandoned and the state has to go.
    func endAfterRelease() {
        endWork?.cancel()
        let work = DispatchWorkItem { self.end() }
        endWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35, execute: work)
    }

    /// Called as soon as a drop has been handled.
    func end() {
        endWork?.cancel()
        endWork = nil
        safetyWork?.cancel()
        safetyWork = nil
        isActive = false
        sourcePath = nil
        sourceGroupID = nil
        DragReflow.shared.clear()
    }

    /// Leaving one target often just means entering another, so the flag only clears
    /// after a pause with nothing hovered.
    func scheduleEnd() {
        endWork?.cancel()
        let work = DispatchWorkItem {
            self.isActive = false
            self.sourcePath = nil
            self.sourceGroupID = nil
            // A drag abandoned outside any target never reaches a drop handler, so the
            // held tile has to be released here or it would stay faded.
            DragReflow.shared.clear()
        }
        endWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.9, execute: work)
    }
}

/// Where a drag is currently hovering.
///
/// This lives in its own object instead of the content view on purpose: only the small
/// highlight views observe it, so moving the cursor during a drag repaints a few
/// outlines rather than rebuilding every card in the window.
final class DragHighlight: ObservableObject {
    static let shared = DragHighlight()

    @Published var sectionTargetID: UUID?
    @Published var sidebarGroupID: UUID?

    /// Records which app the user picked up, and from which block. The drag always begins
    /// under that tile, so the first tile to report itself is the one being carried.
    func beginAppDrag(path: String, from groupID: UUID?) {
        guard DragActivity.shared.sourcePath == nil else { return }
        DragActivity.shared.begin(path: path, groupID: groupID)
    }

    /// Marks the block the cursor is inside.
    ///
    /// Deliberately never cleared on leave. Only the container used to report this, so
    /// crossing the gap between two tiles — where the tile's own drop target takes over
    /// — dropped it to nil and the outline blinked on every single move. Clearing on
    /// leave is also order-dependent: a "left tile A" can arrive after "entered tile B"
    /// and undo it. Entering another block simply moves the marker, and the drag ending
    /// clears it.
    func setGroupHover(_ id: UUID?) {
        guard let id else { return }
        sectionTargetID = id
    }

    /// Called by every drop destination while the cursor is over it.
    func setHover(_ isTargeted: Bool) {
        if isTargeted {
            DragActivity.shared.begin()
        } else {
            DragActivity.shared.scheduleEnd()
        }
    }

    /// Called once a drop has been handled, so the strips retract immediately.
    func endDrag() {
        DragActivity.shared.end()
        clear()
    }

    func clear() {
        sectionTargetID = nil
        sidebarGroupID = nil
    }
}

/// Geometry of the app grid, needed to slide a tile by exactly one slot.
///
/// The numbers come from `ShelfGrid`, which is the same source the `GridItem` array is
/// built from, so a slide can no longer disagree with what the grid actually laid out.
final class GridMetrics: ObservableObject {
    static let shared = GridMetrics()

    @Published private(set) var columnStep: CGFloat = CGFloat(GridGeometry.fallback.columnStep)
    @Published private(set) var rowStep: CGFloat = CGFloat(GridGeometry.fallback.rowStep)
    @Published private(set) var columns: Int = GridGeometry.fallback.columns

    /// Ignores a zero-sized measurement rather than collapsing every slide to zero.
    func update(width: CGFloat, height: CGFloat, count: Int) {
        guard let measured = ShelfGrid.spec.measure(width: Double(width),
                                                    height: Double(height),
                                                    count: count) else { return }
        if columns != measured.columns { columns = measured.columns }
        // Half a point of tolerance: sub-pixel layout jitter should not republish.
        if abs(columnStep - CGFloat(measured.columnStep)) > 0.5 { columnStep = CGFloat(measured.columnStep) }
        if abs(rowStep - CGFloat(measured.rowStep)) > 0.5 { rowStep = CGFloat(measured.rowStep) }
    }
}

/// Plays a short "the app went into this group" animation at the drop destination.
///
/// Without it a card simply vanishes from its old section the moment the mouse is
/// released, which reads as a glitch rather than as a move.
final class DropAnimator: ObservableObject {
    static let shared = DropAnimator()

    /// Bumped on every drop so the destination can replay the animation.
    @Published private(set) var token = 0
    /// `nil` when the landing block is the ungrouped one, which has no identity of its own.
    @Published private(set) var groupID: UUID?
    /// Icon shown shrinking into a sidebar row; `nil` means pulse the row itself.
    @Published private(set) var path: String?
    /// Card that should pop into place inside the grid.
    @Published private(set) var landedPath: String?
    /// Where the drop happened. The two destinations animate differently on purpose: the
    /// grid pops the card in where it now sits, the sidebar swallows the icon.
    @Published private(set) var isSidebarTarget = false

    /// An app dropped inside the page: it appears where it now belongs.
    /// `groupID` is nil for the ungrouped block.
    func playGrid(groupID: UUID?, path: String) {
        isSidebarTarget = false
        self.groupID = groupID
        self.path = nil
        landedPath = path
        token += 1
    }

    /// An app dropped on a sidebar group: the icon shrinks into that row.
    func playSidebar(groupID: UUID, path: String) {
        isSidebarTarget = true
        self.groupID = groupID
        self.path = path
        landedPath = nil
        token += 1
    }

    /// A generic pulse on a sidebar row, used when there is no icon to shrink.
    func play(groupID: UUID) {
        isSidebarTarget = true
        self.groupID = groupID
        path = nil
        landedPath = nil
        token += 1
    }

    /// Clears the animation only if it is still the one `token` started.
    ///
    /// Two drops inside one animation window used to have the first one's timer tear down
    /// the second one's animation halfway through.
    func finish(token: Int) {
        guard token == self.token else { return }
        groupID = nil
        path = nil
        landedPath = nil
    }
}

private extension View {
    /// Applies `transform` only when `condition` holds, without forcing both branches
    /// into one type.
    @ViewBuilder func when<Content: View>(_ condition: Bool, _ transform: (Self) -> Content) -> some View {
        if condition { transform(self) } else { self }
    }
}

/// Reports the grid's own size without taking part in layout.
private struct GridSizeKey: PreferenceKey {
    static var defaultValue: CGSize = .zero
    static func reduce(value: inout CGSize, nextValue: () -> CGSize) {
        let next = nextValue()
        if next != .zero { value = next }
    }
}

/// Animation presets that step aside when the user asked macOS to reduce motion.
///
/// The drag affordances stay — they carry information — but the springs collapse to a
/// near-instant transition instead of throwing tiles across the grid. SwiftUI has no
/// `reduceMotion` environment key on macOS, so this reads the same system setting AppKit
/// exposes; it changes rarely, which makes reading it per render cheap enough.
enum ShelfMotion {
    private static var reduceMotion: Bool {
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }

    static var slide: Animation {
        reduceMotion ? .linear(duration: 0.08) : .interactiveSpring(response: 0.26, dampingFraction: 0.86)
    }

    static var pop: Animation {
        reduceMotion ? .linear(duration: 0.12) : .spring(response: 0.3, dampingFraction: 0.62)
    }

    static var fade: Animation {
        reduceMotion ? .linear(duration: 0.08) : .easeOut(duration: 0.16)
    }

    /// Duration of the sidebar drop pulse, shortened under reduce motion.
    static var pulseDuration: Double { reduceMotion ? 0.12 : 0.38 }
    static var pulseAnimation: Animation {
        reduceMotion ? .linear(duration: 0.1) : .easeOut(duration: 0.34)
    }
}

// MARK: - Drag payload

/// What is being dragged: an app card, a group, or a quick tool tile.
struct ShelfDragItem: Codable, Transferable {
    enum Kind: String, Codable {
        case app
        case group
        case quickTool
    }

    let kind: Kind
    let value: String

    static var transferRepresentation: some TransferRepresentation {
        CodableRepresentation(contentType: .appShelfDragItem)
    }

    static func app(_ path: String) -> ShelfDragItem {
        ShelfDragItem(kind: .app, value: path)
    }

    static func group(_ id: UUID) -> ShelfDragItem {
        ShelfDragItem(kind: .group, value: id.uuidString)
    }

    static func quickTool(_ id: String) -> ShelfDragItem {
        ShelfDragItem(kind: .quickTool, value: id)
    }

    var groupID: UUID? {
        guard kind == .group else { return nil }
        return UUID(uuidString: value)
    }

    var isAppPath: Bool {
        kind == .app && ShelfPath.isApplicationBundle(value)
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
        .background(AppShelfPalette.canvas.opacity(0.96), in: RoundedRectangle(cornerRadius: 10))
        .overlay {
            RoundedRectangle(cornerRadius: 10)
                .stroke(tint.opacity(0.65), lineWidth: 1.5)
        }
        .accessibilityHidden(true)
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

// MARK: - Main window

/// The main window. Sheets and alerts are kept here so child views only emit user intent.
struct ContentView: View {
    @ObservedObject var store: LauncherStore
    @ObservedObject private var quickTools = QuickToolStore.shared

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
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 18)

            Toggle(isOn: $store.runningOnly) {
                Label {
                    L10nText("运行中")
                } icon: {
                    Image(systemName: "bolt.fill")
                }
                .font(.system(size: 12, weight: .medium))
            }
            .toggleStyle(.checkbox)
            .help(L10n.shared.t("只显示正在运行的应用"))

            // A full discovery pass walks the file system, so it is confirmed first.
            Button {
                showRefreshConfirm = true
            } label: {
                Image(systemName: store.isScanning ? "hourglass" : "arrow.clockwise")
                    .font(.system(size: 14, weight: .semibold))
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
                .font(.system(size: 12, weight: .semibold))
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
                    .font(.system(size: 14, weight: .semibold))
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
                    .font(.system(size: 14, weight: .semibold))
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
                    .font(.system(size: 14, weight: .semibold))
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
                .font(.system(size: 10))
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
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(section.tint)
                .frame(width: 16)
                .accessibilityHidden(true)

            Text(section.title)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.primary)

            Text("\(section.apps.count)")
                .font(.system(size: 11, weight: .medium, design: .monospaced))
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
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)

                Text("·")
                    .foregroundStyle(.tertiary)

                Text(L10n.shared.t("updated_at", args: ["time": store.lastUpdated.formatted(date: .omitted, time: .shortened)]))
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

                if store.canUndo {
                    Button {
                        store.undo()
                    } label: {
                        Label(L10n.shared.t("撤销"), systemImage: "arrow.uturn.backward")
                            .font(.system(size: 11, weight: .medium))
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

// MARK: - Sidebar

/// The draggable group list in the sidebar, split out so the sidebar body stays small.
private struct SidebarGroups: View {
    @EnvironmentObject private var store: LauncherStore
    @ObservedObject private var highlight = DragHighlight.shared

    let onNewGroup: () -> Void
    let onEditGroup: (AppGroup) -> Void
    let onDeleteGroup: (AppGroup) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                SidebarSectionLabel(L10n.shared.t("分组"))
                Spacer()
                Button(action: onNewGroup) {
                    Image(systemName: "plus")
                        .font(.system(size: 11, weight: .bold))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .accessibilityLabel(L10n.shared.t("新建分组"))
                .help(L10n.shared.t("新建分组"))
            }

            ForEach(store.groups) { group in
                SidebarRow(
                    title: store.title(for: group),
                    symbol: group.symbol,
                    tint: group.color,
                    count: store.count(for: .group(group.id)),
                    isSelected: store.selection == .group(group.id),
                    isDropTarget: highlight.sidebarGroupID == group.id
                ) {
                    store.selection = .group(group.id)
                }
                .contextMenu {
                    Button(L10n.shared.t("编辑分组"), systemImage: "pencil") {
                        onEditGroup(group)
                    }
                    Button(L10n.shared.t("删除分组"), systemImage: "trash", role: .destructive) {
                        onDeleteGroup(group)
                    }
                }
                // The whole group travels with the cursor, cards included.
                .draggable(ShelfDragItem.group(group.id)) {
                    GroupDragPreview(
                        title: store.title(for: group),
                        symbol: group.symbol,
                        tint: group.color,
                        apps: Array(store.orderedApps(in: group.id).prefix(6))
                    )
                }
                // One drop target for the whole row: another group reorders,
                // an app card is filed into this group.
                .dropDestination(for: ShelfDragItem.self) { items, _ in
                    if let dragged = items.first(where: { $0.kind == .group })?.groupID {
                        store.moveGroup(dragged, before: group.id)
                        highlight.endDrag()
                        return true
                    }

                    let paths = items.filter(\.isAppPath).map(\.value)
                    guard !paths.isEmpty else { return false }
                    store.addApps(paths, to: group.id)
                    if let path = paths.first {
                        DropAnimator.shared.playSidebar(groupID: group.id, path: path)
                    }
                    highlight.endDrag()
                    return true
                } isTargeted: { isTargeted in
                    highlight.sidebarGroupID = isTargeted ? group.id : nil
                    highlight.setHover(isTargeted)
                }
                // Finder bundles dropped on the row join this group.
                .dropDestination(for: URL.self) { urls, _ in
                    let bundles = urls.filter { ShelfPath.isApplicationBundle($0.path) }
                    guard !bundles.isEmpty else { return false }
                    store.recordUndoPoint()
                    store.addApps(bundles, to: group.id)
                    return true
                }
                // The dropped app shrinks into the row instead of simply vanishing.
                .overlay { DropPulse(groupID: group.id) }
            }
        }
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
                        SidebarSectionLabel(L10n.shared.t("我的应用"))
                        SidebarRow(
                            title: L10n.shared.t("全部应用"),
                            symbol: "square.grid.2x2.fill",
                            tint: AppShelfPalette.accent,
                            count: store.count(for: .all),
                            isSelected: store.selection == .all
                        ) {
                            store.selection = .all
                        }
                        SidebarRow(
                            title: L10n.shared.t("正在运行"),
                            symbol: "bolt.fill",
                            tint: AppShelfPalette.success,
                            count: store.count(for: .running),
                            isSelected: store.selection == .running
                        ) {
                            store.selection = .running
                        }
                        SidebarRow(
                            title: L10n.shared.t("未分组"),
                            symbol: "tray",
                            tint: .secondary,
                            count: store.count(for: .ungrouped),
                            isSelected: store.selection == .ungrouped
                        ) {
                            store.selection = .ungrouped
                        }
                        // Only offered once there is something to show.
                        if !store.hidden.isEmpty {
                            SidebarRow(
                                title: L10n.shared.t("已隐藏"),
                                symbol: "eye.slash.fill",
                                tint: .secondary,
                                count: store.count(for: .hidden),
                                isSelected: store.selection == .hidden
                            ) {
                                store.selection = .hidden
                            }
                        }
                    }

                    SidebarGroups(
                        onNewGroup: onNewGroup,
                        onEditGroup: onEditGroup,
                        onDeleteGroup: onDeleteGroup
                    )
                    .environmentObject(store)

                    VStack(alignment: .leading, spacing: 5) {
                        SidebarSectionLabel(L10n.shared.t("快捷工具"))
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
                L10nText("自动扫描")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                L10nText("/Applications · 系统应用 · ~/Applications")
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
            .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 1) {
                L10nText("应用架")
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
                    .accessibilityHidden(true)

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
        .accessibilityLabel(title)
        .accessibilityValue("\(count)")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
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
                    .accessibilityHidden(true)
                Text(tool.title)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
                Spacer()
                Image(systemName: "arrow.up.right")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.tertiary)
                    .accessibilityHidden(true)
            }
            .padding(.horizontal, 10)
            .frame(height: 30)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(tool.title)
        .accessibilityHint(L10n.shared.t("打开"))
        .help(L10n.shared.t("打开") + " \(tool.title)")
        .draggable(ShelfDragItem.quickTool(tool.id)) {
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

// MARK: - Cards

/// A red strip at the foot of a group block. Dropping an app here takes it out of
/// the group instead of filing it in, so grouping can be undone by dragging alone.
private struct RemoveFromGroupStrip: View {
    @ObservedObject private var activity = DragActivity.shared

    let groupID: UUID
    let onRemove: ([String]) -> Void
    let onMoveGroup: (UUID) -> Void

    @State private var isTargeted = false
    @State private var targetedWork: DispatchWorkItem?
    private let debounceDelay = 0.22
    /// Tall enough to drop into casually. Only shown while a drag is in progress, so
    /// it never occupies space (or overlaps a card) when idle.
    private let stripHeight: CGFloat = 64

    var body: some View {
        // Visible for the whole drag; only the fill follows the cursor.
        let isVisible = activity.isActive || isTargeted

        VStack(spacing: 0) {
            if isVisible {
                HStack(spacing: 8) {
                    Image(systemName: "trash")
                        .font(.system(size: 14, weight: .semibold))
                        .accessibilityHidden(true)
                    L10nText("拖到这里，从该分组移除")
                        .font(.system(size: 13, weight: .semibold))
                }
                .foregroundStyle(isTargeted ? Color.white : AppShelfPalette.danger)
                .frame(maxWidth: .infinity)
                .frame(height: stripHeight)
                .background(
                    isTargeted ? AppShelfPalette.danger.opacity(0.9) : AppShelfPalette.danger.opacity(0.12),
                    in: RoundedRectangle(cornerRadius: 12)
                )
                .overlay {
                    RoundedRectangle(cornerRadius: 12)
                        .strokeBorder(
                            AppShelfPalette.danger.opacity(isTargeted ? 1 : 0.5),
                            style: StrokeStyle(lineWidth: 1.5, dash: [5, 4])
                        )
                }
            }
        }
        .animation(ShelfMotion.fade, value: isVisible)
        .allowsHitTesting(isVisible)
        .dropDestination(for: ShelfDragItem.self) { items, _ in
            if let dragged = items.first(where: { $0.kind == .group })?.groupID {
                onMoveGroup(dragged)
                return true
            }

            let paths = items.filter(\.isAppPath).map(\.value)
            guard !paths.isEmpty else { return false }
            onRemove(paths)
            return true
        } isTargeted: { isTargeted in
            setTargeted(isTargeted)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(L10n.shared.t("拖到这里，从该分组移除"))
    }

    /// Debounced so a cursor sitting on the edge cannot flip the strip on and off.
    private func setTargeted(_ value: Bool) {
        DragHighlight.shared.setHover(value)
        if value {
            targetedWork?.cancel()
            withAnimation(ShelfMotion.fade) { isTargeted = true }
            return
        }

        targetedWork?.cancel()
        let work = DispatchWorkItem {
            withAnimation(ShelfMotion.fade) { self.isTargeted = false }
        }
        targetedWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + debounceDelay, execute: work)
    }
}

/// Shrinking ghost of the dropped app, shown on the sidebar group that received it.
private struct DropPulse: View {
    @ObservedObject private var animator = DropAnimator.shared
    let groupID: UUID

    @State private var scale: CGFloat = 1
    @State private var opacity: Double = 0

    var body: some View {
        ZStack {
            if animator.isSidebarTarget, animator.groupID == groupID {
                Group {
                    if let path = animator.path {
                        Image(nsImage: IconCache.shared.image(for: path))
                            .resizable()
                            .interpolation(.high)
                    } else {
                        RoundedRectangle(cornerRadius: 10)
                            .fill(AppShelfPalette.accent.opacity(0.35))
                    }
                }
                .frame(width: 62, height: 62)
                .scaleEffect(scale)
                .opacity(opacity)
                .shadow(color: .black.opacity(0.18), radius: 8, y: 3)
                .onAppear(perform: play)
                .onChange(of: animator.token, initial: false) { _, _ in play() }
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private func play() {
        let token = animator.token
        scale = 1.1
        opacity = 1
        withAnimation(ShelfMotion.pulseAnimation) {
            scale = 0.22
            opacity = 0
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + ShelfMotion.pulseDuration) {
            animator.finish(token: token)
        }
    }
}

/// Category, disk usage, and memory share one small line. The category is only
/// repeated when the tile is not already sitting inside that group's section.
///
/// File scope rather than nested in `AppCard`: the drag preview is a separate view
/// and has to render the same footer.
private struct AppUsageLine: View {
    /// Watches only this app's numbers, so another app's measurement landing
    /// never repaints this tile during a scroll.
    @ObservedObject private var stat: AppStat
    let app: AppItem
    let showsCategory: Bool

    init(app: AppItem, showsCategory: Bool) {
        self.app = app
        self.showsCategory = showsCategory
        _stat = ObservedObject(wrappedValue: AppMetrics.shared.stat(for: app.path))
    }

    var body: some View {
        HStack(spacing: 4) {
            if showsCategory {
                Text(L10n.shared.t(app.category))
                    .foregroundStyle(.secondary)
                Text("·")
                    .foregroundStyle(.tertiary)
            }

            Text(stat.sizeText)
                .foregroundStyle(.secondary)

            if app.isRunning {
                Text("·")
                    .foregroundStyle(.tertiary)
                Text(stat.memoryText)
                    .foregroundStyle(AppShelfPalette.success)
            }
        }
        .font(.system(size: 10.5, weight: .medium, design: .rounded))
        .lineLimit(1)
        .accessibilityHidden(true)
        .help(L10n.shared.t("应用占用 = 应用本体 + 该应用在 Library 中的数据；内存为运行中全部进程之和"))
    }
}

/// The face of a tile: icon, name, and the usage line.
///
/// The grid and the drag preview both render this, so what follows the cursor is the
/// whole card the user picked up rather than a bare icon drifting away from its tile.
struct AppCardTile: View {
    let app: AppItem
    let showsCategory: Bool
    /// nil fills the grid column; the drag preview passes a concrete width because a
    /// preview cannot be laid out against an infinite one.
    var width: CGFloat? = nil

    @ViewBuilder
    var body: some View {
        let tile = VStack(spacing: 9) {
            ZStack(alignment: .topTrailing) {
                AppIconView(path: app.path)
                    .frame(width: 84, height: 84)
                    .accessibilityHidden(true)

                if app.isRunning {
                    Circle()
                        .fill(AppShelfPalette.success)
                        .frame(width: 11, height: 11)
                        .overlay {
                            Circle()
                                .strokeBorder(AppShelfPalette.canvas, lineWidth: 2)
                        }
                        .offset(x: 2, y: -2)
                        .accessibilityHidden(true)
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

            // Only this line watches usage data, so a memory refresh does not redraw
            // the icon or the rest of the tile.
            AppUsageLine(app: app, showsCategory: showsCategory)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 14)
        .frame(minHeight: ShelfGrid.minimumRowHeight, alignment: .top)

        if let width {
            tile.frame(width: width, alignment: .top)
        } else {
            tile.frame(maxWidth: .infinity, alignment: .top)
        }
    }
}

private struct AppCard: View {
    let app: AppItem
    /// False inside a group section, where the heading already says the category.
    let showsCategory: Bool
    /// Groups this app belongs to, offered in the menu so grouping can be undone.
    let removableGroups: [AppGroup]
    /// Selected by the keyboard: the arrow keys have to show what they moved on to.
    let isFocused: Bool
    /// Shown from the hidden list, so the offer flips to 显示此应用.
    let isHiddenApp: Bool
    let onOpen: () -> Void
    let onMove: () -> Void
    let onRemoveFromGroup: (AppGroup) -> Void
    let onRemoveAllGroups: () -> Void
    let onHide: () -> Void
    let onReveal: () -> Void
    let onShowInFinder: () -> Void
    let onShowPackageContents: () -> Void
    let onCopyBundleID: () -> Void
    let onQuit: (() -> Void)?
    let onForceQuit: (() -> Void)?

    @ObservedObject private var animator = DropAnimator.shared
    /// Only the drag on/off flag, never the highlight object: that one changes on
    /// every pointer move and would repaint the whole grid mid-drag.
    @ObservedObject private var activity = DragActivity.shared
    /// Watched to slide out of the way. Cheap here: it only changes a transform.
    @ObservedObject private var reflow = DragReflow.shared
    @ObservedObject private var grid = GridMetrics.shared
    @State private var isHovering = false
    @State private var popScale: CGFloat = 1
    @State private var popOpacity: Double = 1
    /// Position in its block, and the block it belongs to. Needed to work out whether
    /// this tile has to make room, and in which direction.
    let index: Int
    let sectionGroupID: UUID?

    /// True once this exact tile is the one being carried.
    ///
    /// Requires `reflow.sourceIndex` to be set: until then the tile still has to accept
    /// the hit that tells the grid which app was picked up. It also has to be in the block
    /// the drag started from — an app that sits in three groups shows three cards, and
    /// carrying one used to blank all three.
    private var isCarriedAway: Bool {
        activity.sourcePath == app.path
            && reflow.sourceIndex != nil
            && activity.sourceGroupID == sectionGroupID
    }

    /// How far this tile slides while the dragged tile is carried past it.
    private var slideOffset: CGSize {
        guard let sectionGroupID,
              reflow.groupID == sectionGroupID,
              let source = reflow.sourceIndex,
              let hovered = reflow.hoveredIndex,
              let target = ShelfReflow.targetIndex(index: index, source: source, hovered: hovered)
        else { return .zero }

        let delta = ShelfReflow.slotDelta(from: index, to: target, columns: grid.columns)
        return CGSize(width: CGFloat(delta.columns) * grid.columnStep,
                      height: CGFloat(delta.rows) * grid.rowStep)
    }

    var body: some View {
        Button(action: onOpen) {
            cardContent
        }
        .buttonStyle(.plain)
        // Pure transform: no relayout, which is what makes the motion continuous.
        .offset(slideOffset)
        .animation(ShelfMotion.slide, value: reflow.hoveredIndex)
        // The carried card leaves its slot; without this the fade is a hard cut.
        .animation(ShelfMotion.fade, value: isCarriedAway)
        .onHover { isHovering = $0 }
        // Disk usage is only measured once the tile is actually on screen, so scrolling
        // through hundreds of apps never queues work for apps nobody looked at.
        .onAppear { AppMetrics.shared.requestSizeIfNeeded(for: app) }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(app.name)
        .accessibilityValue(accessibilityDetails)
        .accessibilityHint(L10n.shared.t("打开"))
        .accessibilityAddTraits(.isButton)
        .contextMenu {
            Button(L10n.shared.t("打开"), systemImage: "arrow.up.right") { onOpen() }
            Button(L10n.shared.t("加入其他分组"), systemImage: "folder.badge.plus") { onMove() }

            if !removableGroups.isEmpty {
                Divider()
                Menu(L10n.shared.t("取消分组")) {
                    ForEach(removableGroups) { group in
                        Button(L10n.shared.t("removed_from_group", args: ["name": group.name]), systemImage: "minus.circle") {
                            onRemoveFromGroup(group)
                        }
                    }
                    if removableGroups.count > 1 {
                        Divider()
                        Button(L10n.shared.t("移出全部分组"), systemImage: "xmark.circle", role: .destructive) {
                            onRemoveAllGroups()
                        }
                    }
                }
            }

            if let onQuit {
                Divider()
                Button(L10n.shared.t("退出应用"), systemImage: "xmark.circle") { onQuit() }
                if let onForceQuit {
                    Button(L10n.shared.t("强制结束"), systemImage: "exclamationmark.octagon", role: .destructive) { onForceQuit() }
                }
            }

            Divider()
            Button(L10n.shared.t("在 Finder 中显示"), systemImage: "folder") { onShowInFinder() }
            Button(L10n.shared.t("显示包内容"), systemImage: "doc.on.doc") { onShowPackageContents() }
            Button(L10n.shared.t("拷贝 Bundle ID"), systemImage: "doc.on.clipboard") { onCopyBundleID() }

            Divider()
            if isHiddenApp {
                Button(L10n.shared.t("显示此应用"), systemImage: "eye") { onReveal() }
            } else {
                Button(L10n.shared.t("隐藏此应用"), systemImage: "eye.slash") { onHide() }
            }
        }
        .help(L10n.shared.t("打开") + " \(app.name)")
    }

    private var accessibilityDetails: String {
        var parts = [L10n.shared.t(app.category)]
        if app.isRunning { parts.append(L10n.shared.t("运行中")) }
        return parts.joined(separator: " · ")
    }

    /// Outline round the tile while dragging. A system separator is used rather than a
    /// fixed black stroke, which would vanish in dark mode.
    private var dragOutline: some View {
        RoundedRectangle(cornerRadius: 12)
            .strokeBorder(AppShelfPalette.dragOutline, lineWidth: 1)
    }

    /// Launchpad-style tile: a large icon, a centred name, and one quiet info line.
    private var cardContent: some View {
        AppCardTile(app: app, showsCategory: showsCategory)
            .background(cardBackground)
        .contentShape(RoundedRectangle(cornerRadius: 12))
        // Every tile shows its bounds while dragging, so where an icon will land is
        // obvious before releasing it.
        .overlay {
            if activity.isActive { dragOutline }
            if isFocused {
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(AppShelfPalette.accent, lineWidth: 2)
            }
        }
        // No animated shadow or scale on hover: animating those on two hundred tiles at
        // once is what made hovering and dragging feel heavy.
        .scaleEffect(isHovering ? 1.015 : 1)
        // An app dropped inside the page pops up where its card now sits.
        .scaleEffect(popScale)
        // The card is under the cursor, so the slot it came from is left empty — the
        // gap itself is what shows where it will land.
        .opacity(popOpacity * (isCarriedAway ? 0 : 1))
        // It must stop taking hits too: the neighbour sliding into this slot sits under
        // the same point, and if the invisible tile won, hovering the gap would read as
        // "hovering the source" and snap every tile back.
        .allowsHitTesting(!isCarriedAway)
        .onChange(of: animator.token, initial: false) { _, token in
            // Matched on the block too, so a card of the same app sitting in another
            // group does not pop as well.
            guard animator.landedPath == app.path,
                  animator.groupID == sectionGroupID else { return }
            popIn(token: token)
        }
    }

    private func popIn(token: Int) {
        popScale = 0.55
        popOpacity = 0.2
        withAnimation(ShelfMotion.pop) {
            popScale = 1
            popOpacity = 1
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            animator.finish(token: token)
        }
    }

    /// No permanent outline: the tile only gains a soft rounded surface while hovered,
    /// so the grid stays clean and the icon and name carry the layout.
    private var cardBackground: some View {
        RoundedRectangle(cornerRadius: 12)
            .fill(isHovering || isFocused ? AppShelfPalette.panel : Color.clear)
    }
}

/// Caches app icons. `NSWorkspace.icon(forFile:)` goes through Launch Services, and
/// calling it for every card on every redraw is what made dragging feel sluggish.
final class IconCache {
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
struct AppIconView: View {
    let path: String

    var body: some View {
        Image(nsImage: IconCache.shared.image(for: path))
            .resizable()
            .interpolation(.high)
            .aspectRatio(contentMode: .fit)
    }
}

// MARK: - Quick tools

/// The quick tool row at the top of All Apps.
/// Its own view so the drop highlight does not invalidate the whole page.
private struct QuickToolsRow: View {
    @ObservedObject private var quickTools = QuickToolStore.shared
    @State private var isTargeted = false

    let onLaunch: (QuickToolItem) -> Void
    let onAdded: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                L10nText("快捷工具")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Text(isTargeted ? L10n.shared.t("松手即可添加") : L10n.shared.t("拖应用进来添加，拖出去移除"))
                    .font(.system(size: 11))
                    .foregroundStyle(isTargeted ? AppShelfPalette.accent : Color.secondary.opacity(0.7))
            }

            // A grid instead of a single row so any number of tools stays inside the window.
            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 150, maximum: 230), spacing: 10)],
                alignment: .leading,
                spacing: 10
            ) {
                ForEach(quickTools.items) { tool in
                    QuickToolTile(tool: tool) {
                        onLaunch(tool)
                    }
                }
            }
        }
        .padding(8)
        .background {
            RoundedRectangle(cornerRadius: 10)
                .stroke(
                    isTargeted ? AppShelfPalette.accent : Color.clear,
                    style: StrokeStyle(lineWidth: 1.5, dash: [5, 4])
                )
        }
        // Dropping an app card here pins it as a quick tool.
        .dropDestination(for: ShelfDragItem.self) { items, _ in
            pin(items.filter(\.isAppPath).map(\.value))
        } isTargeted: { isTargeted in
            self.isTargeted = isTargeted
        }
        // Bundles dragged in from Finder can be pinned the same way.
        .dropDestination(for: URL.self) { urls, _ in
            pin(urls.filter { ShelfPath.isApplicationBundle($0.path) }.map(\.path))
        }
    }

    private func pin(_ paths: [String]) -> Bool {
        let bundles = paths.filter { ShelfPath.isApplicationBundle($0) }
        guard !bundles.isEmpty else { return false }
        for path in bundles {
            let url = URL(fileURLWithPath: path)
            let name = AppDiscoveryService.item(for: url)?.name
                ?? url.deletingPathExtension().lastPathComponent
            quickTools.addCustom(name: name, path: path)
        }
        onAdded(L10n.shared.t("已加入快捷工具"))
        return true
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
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 2) {
                    Text(tool.title)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.primary)
                    L10nText("打开")
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                }

                Spacer(minLength: 4)
                Image(systemName: "arrow.up.right")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.tertiary)
                    .accessibilityHidden(true)
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
        .accessibilityLabel(tool.title)
        .accessibilityHint(L10n.shared.t("拖应用进来添加，拖出去移除"))
        .help(L10n.shared.t("打开") + " \(tool.title)")
        // Drag the tile out of the row to remove it.
        .draggable(ShelfDragItem.quickTool(tool.id)) {
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

// MARK: - States

/// Placeholder shown while the file-system scan is in progress.
private struct LoadingState: View {
    var body: some View {
        VStack(spacing: 12) {
            ProgressView()
                .controlSize(.small)
            L10nText("正在读取应用…")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, minHeight: 280)
    }
}

/// Shared empty state, worded for whichever view is actually empty.
private struct EmptyState: View {
    let query: String
    let selection: ShelfSelection
    let onClearSearch: () -> Void
    let onAddApp: () -> Void
    let onRevealAll: (() -> Void)?

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: symbolName)
                .font(.system(size: 31, weight: .light))
                .foregroundStyle(.tertiary)
                .frame(width: 66, height: 66)
                .background(AppShelfPalette.panel, in: RoundedRectangle(cornerRadius: 16))
                .accessibilityHidden(true)

            Text(headline)
                .font(.system(size: 16, weight: .semibold))

            Text(subheadline)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)

            HStack(spacing: 8) {
                if !query.isEmpty {
                    Button(L10n.shared.t("清除搜索"), action: onClearSearch)
                        .buttonStyle(.bordered)
                }
                if selection == .hidden, let onRevealAll {
                    Button(L10n.shared.t("全部显示"), action: onRevealAll)
                        .buttonStyle(.borderedProminent)
                        .tint(AppShelfPalette.accent)
                }
                if selection != .running && selection != .hidden && selection != .ungrouped {
                    Button(action: onAddApp) {
                        Label(L10n.shared.t("添加应用"), systemImage: "plus")
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(AppShelfPalette.accent)
                }
            }
            .padding(.top, 3)
        }
        .frame(maxWidth: .infinity, minHeight: 300)
    }

    private var symbolName: String {
        if !query.isEmpty { return "magnifyingglass" }
        switch selection {
        case .running: return "bolt.slash"
        case .hidden: return "eye.slash"
        case .ungrouped: return "checkmark.seal"
        default: return "square.grid.2x2"
        }
    }

    private var headline: String {
        if !query.isEmpty { return L10n.shared.t("没有匹配的应用") }
        switch selection {
        case .running: return L10n.shared.t("没有正在运行的应用")
        case .hidden: return L10n.shared.t("没有隐藏的应用")
        case .ungrouped: return L10n.shared.t("所有应用都已分组")
        default: return L10n.shared.t("这个分组还没有应用")
        }
    }

    private var subheadline: String {
        if !query.isEmpty { return L10n.shared.t("换个关键词试试。") }
        switch selection {
        case .running: return L10n.shared.t("启动任意应用后即可看到。")
        case .hidden: return L10n.shared.t("隐藏的应用不会出现在列表和搜索结果里。")
        case .ungrouped: return L10n.shared.t("每个应用都至少在一个分组里。")
        default: return L10n.shared.t("可以添加一个 .app，或切换到其他分组。")
        }
    }
}

// MARK: - Sheets

/// Create or edit one group without exposing persistence details to the form.
struct GroupEditorSheet: View {
    @Environment(\.dismiss) private var dismiss

    private let existing: AppGroup?
    private let onSave: (String, String, String) -> Void

    @State private var name: String
    @State private var selectedSymbol: String
    @State private var color: Color
    @State private var symbolFilter = ""

    private let symbols = GroupSymbolCatalog.available
    private let columns = 8

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
                    Text(existing == nil ? L10n.shared.t("新建分组") : L10n.shared.t("编辑分组"))
                        .font(.system(size: 20, weight: .semibold, design: .rounded))
                    L10nText("给分组一个容易辨认的名称和图标")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }

            VStack(alignment: .leading, spacing: 8) {
                L10nText("名称")
                    .font(.system(size: 12, weight: .semibold))
                TextField(L10n.shared.t("例如：项目、影音、常用"), text: $name)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityLabel(L10n.shared.t("名称"))
            }

            VStack(alignment: .leading, spacing: 9) {
                L10nText("图标")
                    .font(.system(size: 12, weight: .semibold))

                // The catalogue is long enough that a fixed grid without a filter was
                // unusable once the wanted symbol was not among the first fifteen.
                TextField(L10n.shared.t("搜索图标"), text: $symbolFilter)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 12))
                    .accessibilityLabel(L10n.shared.t("搜索图标"))

                ScrollView {
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: columns),
                              spacing: 8) {
                        ForEach(shownSymbols, id: \.self) { symbol in
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
                                            .stroke(selectedSymbol == symbol ? color.opacity(0.55) : AppShelfPalette.border,
                                                    lineWidth: 1)
                                    }
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(symbol)
                            .accessibilityAddTraits(selectedSymbol == symbol ? .isSelected : [])
                        }
                    }
                    .padding(2)
                }
                .frame(height: 132)
            }

            ColorPicker(L10n.shared.t("颜色"), selection: $color, supportsOpacity: false)
                .font(.system(size: 12, weight: .semibold))

            HStack {
                Spacer()
                Button(L10n.shared.t("取消"), role: .cancel) { dismiss() }
                Button(existing == nil ? L10n.shared.t("创建") : L10n.shared.t("保存")) {
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

    private var shownSymbols: [String] {
        let query = symbolFilter.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !query.isEmpty else { return symbols }
        // The chosen symbol stays visible while filtering, so the selection never vanishes.
        let matches = symbols.filter { $0.lowercased().contains(query) }
        if matches.isEmpty { return [selectedSymbol] }
        return matches.contains(selectedSymbol) ? matches : [selectedSymbol] + matches
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
                L10nText("添加到应用架")
                    .font(.system(size: 20, weight: .semibold, design: .rounded))
                Text(L10n.shared.t("已选择 个应用", args: ["count": "\(urls.count)"]))
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }

            ScrollView {
                VStack(alignment: .leading, spacing: 7) {
                    ForEach(urls, id: \.path) { url in
                        HStack(spacing: 9) {
                            Image(nsImage: IconCache.shared.image(for: url.path))
                                .resizable()
                                .frame(width: 28, height: 28)
                                .accessibilityHidden(true)
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

            Picker(L10n.shared.t("目标分组"), selection: $selectedGroupID) {
                ForEach(groups) { group in
                    Label(group.name, systemImage: group.symbol)
                        .tag(group.id)
                }
            }
            .pickerStyle(.menu)

            HStack {
                Spacer()
                Button(L10n.shared.t("取消"), role: .cancel) { dismiss() }
                Button {
                    onAdd(urls, selectedGroupID)
                    dismiss()
                } label: {
                    Label(L10n.shared.t("加入分组"), systemImage: "plus")
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
                Image(nsImage: IconCache.shared.image(for: app.path))
                    .resizable()
                    .frame(width: 44, height: 44)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 3) {
                    L10nText("加入其他分组")
                        .font(.system(size: 18, weight: .semibold, design: .rounded))
                    Text(app.name)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            Picker(L10n.shared.t("目标分组"), selection: $selectedGroupID) {
                ForEach(groups) { group in
                    Label(group.name, systemImage: group.symbol)
                        .tag(Optional(group.id))
                }
            }
            .pickerStyle(.menu)

            HStack {
                Spacer()
                Button(L10n.shared.t("取消"), role: .cancel) { dismiss() }
                Button(L10n.shared.t("加入")) {
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
