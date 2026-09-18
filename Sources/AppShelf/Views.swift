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
    /// One in-app drag type for every draggable thing in the window.
    ///
    /// A view can only reliably carry a single drop destination, so app cards, group
    /// rows, and quick tools all share this type and are told apart by `kind`.
    static let appShelfDragItem = UTType(exportedAs: "local.dan.AppShelf.drag")
}

/// Where a drag is currently hovering.
///
/// This lives in its own object instead of the content view on purpose: only the small
/// highlight views observe it, so moving the cursor during a drag repaints a few
/// outlines rather than rebuilding every card in the window.
/// Whether a drag is in progress at all.
///
/// Deliberately separate from `DragHighlight`: that object publishes on every pointer
/// move, so subscribing every tile to it would repaint the whole grid while dragging.
/// This one only changes twice per drag, so tiles can safely watch it to draw their
/// outline.
final class DragActivity: ObservableObject {
    static let shared = DragActivity()

    @Published private(set) var isActive = false
    /// The app being dragged. Tiles watch this to fade themselves out of the grid,
    /// since the card under the cursor is the one that should look solid.
    @Published private(set) var sourcePath: String?

    private var endWork: DispatchWorkItem?

    func begin() {
        endWork?.cancel()
        endWork = nil
        if !isActive { isActive = true }
    }

    func begin(path: String) {
        begin()
        sourcePath = path
    }

    /// Called as soon as a drop has been handled.
    func end() {
        endWork?.cancel()
        endWork = nil
        isActive = false
        sourcePath = nil
    }

    /// Leaving one target often just means entering another, so the flag only clears
    /// after a pause with nothing hovered.
    func scheduleEnd() {
        endWork?.cancel()
        let work = DispatchWorkItem {
            self.isActive = false
            // A drag abandoned outside any target never reaches a drop handler, so the
            // held tile has to be released here or it would stay faded.
            self.sourcePath = nil
        }
        endWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.9, execute: work)
    }
}

final class DragHighlight: ObservableObject {
    static let shared = DragHighlight()

    @Published var sectionTargetID: UUID?
    @Published var sidebarGroupID: UUID?
    @Published var quickToolTarget = false
    /// App being dragged, captured when the drag starts so tiles can make room for it.
    var sourcePath: String? { DragActivity.shared.sourcePath }
    /// Last tile the reflow ran against, so the same pair is never repeated.
    var lastReflowTarget: String?

    /// True for the whole drag, not just while a target is under the cursor.
    /// The remove strips stay visible for the entire drag so they cannot flicker
    /// when the cursor crosses their edge.
    var isDragging: Bool { DragActivity.shared.isActive }

    /// Records which app the user picked up. The drag always begins under that tile,
    /// so the first tile to report itself is the one being carried.
    func beginAppDrag(path: String) {
        guard DragActivity.shared.sourcePath == nil else { return }
        lastReflowTarget = nil
        DragActivity.shared.begin(path: path)
    }

    var isReordering: Bool {
        sectionTargetID != nil || sidebarGroupID != nil
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
        quickToolTarget = false
        // sourcePath lives on DragActivity so tiles can watch it; cleared there.
        lastReflowTarget = nil
    }
}

/// Plays a short "the app went into this group" animation at the drop destination.
///
/// Without it a card simply vanishes from its old section the moment the mouse is
/// released, which reads as a glitch rather than as a move.
final class DropAnimator: ObservableObject {
    static let shared = DropAnimator()

    /// Where the drop happened. The two destinations animate differently on purpose:
    /// the grid pops the card in where it now sits, the sidebar swallows the icon.
    enum Target {
        case grid
        case sidebar
    }

    /// Bumped on every drop so the destination can replay the animation.
    @Published var token = 0
    @Published var target: Target = .grid
    @Published var groupID: UUID?
    /// Icon shown shrinking into a sidebar row.
    @Published var path: String?
    /// Card that should pop into place inside the grid.
    @Published var landedPath: String?

    /// An app dropped inside the page: it appears where it now belongs.
    func playGrid(groupID: UUID, path: String) {
        target = .grid
        self.groupID = groupID
        self.path = nil
        landedPath = path
        token += 1
    }

    /// An app dropped on a sidebar group: the icon shrinks into that row.
    func playSidebar(groupID: UUID, path: String) {
        target = .sidebar
        self.groupID = groupID
        self.path = path
        landedPath = nil
        token += 1
    }

    func play(groupID: UUID) {
        target = .sidebar
        self.groupID = groupID
        path = nil
        landedPath = nil
        token += 1
    }

    func finish() {
        groupID = nil
        path = nil
        landedPath = nil
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
            if animator.target == .sidebar && animator.groupID == groupID {
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
    }

    private func play() {
        scale = 1.1
        opacity = 1
        withAnimation(.easeOut(duration: 0.34)) {
            scale = 0.22
            opacity = 0
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.38) {
            animator.finish()
        }
    }
}

/// What is being dragged: an app card, a group, or a quick tool tile.
private struct ShelfDragItem: Codable, Transferable {
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
        kind == .app && value.hasSuffix(".app")
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
                // Dropping a quick tool anywhere in the content area removes it.
                .dropDestination(for: ShelfDragItem.self) { items, _ in
                    let removed = items.filter { $0.kind == .quickTool }
                    guard !removed.isEmpty else { return false }
                    removed.forEach { quickTools.remove($0.value) }
                    store.note(L10n.shared.t("已从快捷工具移除"))
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

            TextField(L10n.shared.t("搜索应用，支持拼音首字母，如 wx / vsc"), text: $store.query)
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
                .help(L10n.shared.t("清除搜索"))
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
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 14, weight: .semibold))
            }
            .buttonStyle(.bordered)
            .controlSize(.large)
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
            }
            .menuStyle(.borderlessButton)
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
            }
            .menuStyle(.borderlessButton)
            .buttonStyle(.bordered)
            .controlSize(.large)
            .help(L10n.shared.t("language"))

            Button(action: openSystemSettings) {
                Image(systemName: "gearshape")
                    .font(.system(size: 14, weight: .semibold))
            }
            .buttonStyle(.bordered)
            .controlSize(.large)
            .help(L10n.shared.t("设置"))
        }
        .padding(.horizontal, 28)
        .padding(.vertical, 20)
    }

    private var appGrid: some View {
        let membership = store.groupMembership()

        // Adaptive columns use the available window width without changing tile sizes.
        return LazyVGrid(columns: appGridColumns, alignment: .leading, spacing: 16) {
            ForEach(store.filteredApps) { app in
                appCard(app, sectionGroupID: nil, removableGroups: membership[app.path] ?? [])
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
        let membership = store.groupMembership()

        return VStack(alignment: .leading, spacing: 18) {
            ForEach(appSections) { section in
                sectionBlock(section, membership: membership)
            }
        }
    }

    @ViewBuilder
    private func sectionBlock(_ section: AppSection, membership: [String: [AppGroup]]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionHeader(section)

            LazyVGrid(columns: appGridColumns, alignment: .leading, spacing: 16) {
                ForEach(section.apps) { app in
                    appCard(app, sectionGroupID: section.groupID, removableGroups: membership[app.path] ?? [])
                }
            }

            // Sits below the cards (outside the grid) and stays in the layout so it
            // never overlaps a tile. Its frame is reserved whether or not a drag is
            // active, so it does not push the section around when it appears mid-drag.
            if let groupID = section.groupID {
                RemoveFromGroupStrip(
                    groupID: groupID,
                    onRemove: { paths in
                        paths.forEach { store.removeApp($0, from: groupID) }
                        // The app reappears in the ungrouped section, so pop it in there.
                        if let path = paths.first {
                            DropAnimator.shared.playGrid(groupID: groupID, path: path)
                        }
                        highlight.endDrag()
                    },
                    onMoveGroup: { dragged in
                        store.moveGroup(dragged, before: groupID)
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
    }

    /// The short hint next to a section heading, kept separate for the same reason.
    private struct SectionDropHint: View {
        @ObservedObject private var highlight = DragHighlight.shared
        @ObservedObject private var activity = DragActivity.shared
        let groupID: UUID?

        var body: some View {
            Text(isTarget ? L10n.shared.t("放到这里") : L10n.shared.t("拖动标题或卡片可调整顺序"))
                .font(.system(size: 10))
                .foregroundStyle(
                    isTarget ? AppShelfPalette.accent : Color.secondary.opacity(0.7)
                )
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
            if isTarget { return AppShelfPalette.accent.opacity(0.13) }
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
                SectionDropHint(groupID: section.groupID)
            }
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())

        if let groupID = section.groupID {
            header
                .draggable(ShelfDragItem.group(groupID)) {
                    GroupDragPreview(
                        title: section.title,
                        symbol: section.symbol,
                        tint: section.tint,
                        apps: section.apps
                    )
                }
        } else {
            header
        }
    }

    /// One card plus its drag behaviour. `sectionGroupID` enables drag-to-reorder
    /// inside that group; it stays nil for search results, which are ranked instead.
    ///
    /// Cards outside a section carry no drop target at all: hundreds of registered
    /// drop targets slow every mouse move during a drag.
    @ViewBuilder
    private func appCard(_ app: AppItem, sectionGroupID: UUID?, removableGroups: [AppGroup]) -> some View {
        let card = AppCard(
            app: app,
            currentGroupID: currentGroupID,
            showsCategory: sectionGroupID == nil,
            removableGroups: removableGroups,
            onOpen: { store.launch(app) },
            onMove: {
                appToMove = app
            },
            onRemoveFromGroup: { group in
                store.removeApp(app, from: group.id)
                DropAnimator.shared.play(groupID: group.id)
            },
            onShowInFinder: { store.openInFinder(app) },
            onQuit: app.isRunning ? { store.terminate(app) } : nil,
            onForceQuit: app.isRunning ? { store.terminate(app, force: true) } : nil
        )
        // The bundle path is the drag payload: dropping on a sidebar group files the app,
        // dropping on another card inside a section reorders it.
        .draggable(ShelfDragItem.app(app.path)) {
            // The whole card follows the cursor, so there is no icon drifting away
            // from the tile it belongs to.
            AppCardTile(app: app, showsCategory: sectionGroupID == nil, width: 152)
                .background(AppShelfPalette.panel, in: RoundedRectangle(cornerRadius: 12))
                .overlay {
                    RoundedRectangle(cornerRadius: 12)
                        .strokeBorder(Color(nsColor: .separatorColor), lineWidth: 1)
                }
        }

        if let sectionGroupID {
            card
                .dropDestination(for: ShelfDragItem.self) { items, _ in
                    // A quick tool dropped anywhere outside its row is removed.
                    if let tool = items.first(where: { $0.kind == .quickTool }) {
                        quickTools.remove(tool.value)
                        store.note(L10n.shared.t("已从快捷工具移除"))
                        return true
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
                    store.moveApps(paths, before: app, in: sectionGroupID)
                    if let path = paths.first {
                        DropAnimator.shared.playGrid(groupID: sectionGroupID, path: path)
                    }
                    // The live reflow during hover skips persisting, so the final
                    // commit is written here.
                    store.persistGroups()
                    highlight.endDrag()
                    return true
                } isTargeted: { isTargeted in
                    highlight.setHover(isTargeted)
                    // A tile is inside the block too: without this, the outline of the
                    // section blinked off every time the pointer crossed a tile.
                    highlight.setGroupHover(isTargeted ? sectionGroupID : nil)
                    guard isTargeted else { return }
                    // The drag always begins under the tile being dragged, so the first
                    // tile to report itself is the one the user picked up. Remembering it
                    // lets the others shuffle out of the way as the pointer travels.
                    if highlight.sourcePath == nil { highlight.beginAppDrag(path: app.path) }
                    makeRoom(for: app, in: sectionGroupID)
                }
        } else {
            card
        }
    }

    /// Launchpad-style make-way: while an app is dragged inside its own group, the
    /// tiles it passes shuffle aside immediately, so the gap shows where it will land
    /// instead of only hinting at it after release.
    ///
    /// Only same-group drags reflow. Cross-group and outside apps are filed on drop,
    /// because their old position has no meaning in this section.
    private func makeRoom(for target: AppItem, in groupID: UUID) {
        guard let sourcePath = highlight.sourcePath, sourcePath != target.path else { return }
        // Resolved through the store so cached paths and normalized paths compare equal.
        let list = store.orderedApps(in: groupID)
        guard let from = list.firstIndex(where: { $0.path == sourcePath }) else { return }

        guard let to = list.firstIndex(where: { $0.path == target.path }), to != from else { return }
        // The same pair never runs twice in a row; the tile under the cursor reports
        // itself repeatedly while the pointer rests.
        if highlight.lastReflowTarget == target.path { return }

        highlight.lastReflowTarget = target.path
        // Dragging right lands the app *behind* the tile it passes: inserting in front
        // of that tile is a no-op once they are neighbours, and that no-op was what made
        // the gesture feel like it needed a whole extra tile of travel. Dragging left
        // still inserts in front, so one tile of travel always swaps a pair.
        withAnimation(.interactiveSpring(response: 0.24, dampingFraction: 0.82)) {
            if to > from {
                store.moveApps([sourcePath], after: target, in: groupID, persist: false)
            } else {
                store.moveApps([sourcePath], before: target, in: groupID, persist: false)
            }
        }
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
                    AppSection(id: "ungrouped", title: L10n.shared.t("未分组"), symbol: "tray", tint: .secondary, groupID: nil, apps: ungrouped)
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

                Text(store.isLoading ? L10n.shared.t("正在扫描应用…") : L10n.shared.t("apps_scanned", args: ["count": "\(store.apps.count)"]))
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

                L10nText("应用架")
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 28)
            .padding(.vertical, 10)
            .background(AppShelfPalette.sidebar.opacity(0.58))
        }
    }

    private var footer: some View {
        StatusFooter(store: store)
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

    private func openSystemSettings() {
        SettingsWindowController.shared.showWindow()
    }
}

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
                .help(L10n.shared.t("新建分组"))
            }

            ForEach(store.groups) { group in
                SidebarRow(
                    title: group.name,
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
                        title: group.name,
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

/// A compact app tile. Opening is the primary action; less common actions live in its menu.
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
        .help(L10n.shared.t("应用占用 = 应用本体 + 该应用在 Library 中的数据；内存为运行中全部进程之和"))
    }
}

/// The face of a tile: icon, name, and the usage line.
///
/// The grid and the drag preview both render this, so what follows the cursor is the
/// whole card the user picked up rather than a bare icon drifting away from its tile.
private struct AppCardTile: View {
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

            // Only this line watches usage data, so a memory refresh does not redraw
            // the icon or the rest of the tile.
            AppUsageLine(app: app, showsCategory: showsCategory)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 14)
        .frame(minHeight: 158, alignment: .top)

        if let width {
            tile.frame(width: width, alignment: .top)
        } else {
            tile.frame(maxWidth: .infinity, alignment: .top)
        }
    }
}

private struct AppCard: View {
    let app: AppItem
    let currentGroupID: UUID?
    /// False inside a group section, where the heading already says the category.
    let showsCategory: Bool
    /// Groups this app belongs to, offered in the menu so grouping can be undone.
    let removableGroups: [AppGroup]
    let onOpen: () -> Void
    let onMove: () -> Void
    let onRemoveFromGroup: (AppGroup) -> Void
    let onShowInFinder: () -> Void
    let onQuit: (() -> Void)?
    let onForceQuit: (() -> Void)?

    @ObservedObject private var animator = DropAnimator.shared
    /// Only the drag on/off flag, never the highlight object: that one changes on
    /// every pointer move and would repaint the whole grid mid-drag.
    @ObservedObject private var activity = DragActivity.shared
    @State private var isHovering = false
    @State private var popScale: CGFloat = 1
    @State private var popOpacity: Double = 1

    var body: some View {
        Button(action: onOpen) {
            cardContent
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        // Disk usage is only measured once the tile is actually on screen, so scrolling
        // through hundreds of apps never queues work for apps nobody looked at.
        .onAppear { AppMetrics.shared.requestSizeIfNeeded(for: app) }
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
                            removableGroups.forEach(onRemoveFromGroup)
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
        }
        .help(L10n.shared.t("打开") + " \(app.name)")
    }

    /// Accent round the tile while dragging, so every drop target reads as its own slot.
    /// A system separator is used rather than a fixed black stroke, which would vanish
    /// in dark mode.
    private var dragOutline: some View {
        RoundedRectangle(cornerRadius: 12)
            .strokeBorder(Color(nsColor: .separatorColor), lineWidth: 1)
    }

    /// Launchpad-style tile: a large icon, a centred name, and one quiet info line.
    private var cardContent: some View {
        AppCardTile(app: app, showsCategory: showsCategory)
            .background(hoverBackground)
        .contentShape(RoundedRectangle(cornerRadius: 12))
        // Every tile shows its bounds while dragging, so where an icon will land is
        // obvious before releasing it.
        .overlay { if activity.isActive { dragOutline } }
        // No animated shadow or scale: animating those on two hundred tiles at once is
        // what made hovering and dragging feel heavy.
        .scaleEffect(isHovering ? 1.015 : 1)
        // An app dropped inside the page pops up where its card now sits.
        .scaleEffect(popScale)
        // The card the user is carrying is the solid one under the cursor; the tile it
        // left behind marks the slot it will land in, so it fades rather than showing
        // a second copy of the same card.
        .opacity(popOpacity * (activity.sourcePath == app.path ? 0.32 : 1))
        .onChange(of: animator.token, initial: false) { _, _ in
            guard animator.target == .grid, animator.landedPath == app.path else { return }
            popIn()
        }
    }

    private func popIn() {
        popScale = 0.55
        popOpacity = 0.2
        withAnimation(.spring(response: 0.3, dampingFraction: 0.62)) {
            popScale = 1
            popOpacity = 1
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            animator.finish()
        }
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
private struct AppIconView: View {
    let path: String

    var body: some View {
        Image(nsImage: IconCache.shared.image(for: path))
            .resizable()
            .interpolation(.high)
            .aspectRatio(contentMode: .fit)
    }
}

/// A red strip at the foot of a group block. Dropping an app here takes it out of
/// the group instead of filing it in, so grouping can be undone by dragging alone.
private struct RemoveFromGroupStrip: View {
    @ObservedObject private var highlight = DragHighlight.shared
    /// The strip appears for the whole drag, and this flag changes only twice per drag.
    @ObservedObject private var activity = DragActivity.shared

    let groupID: UUID
    let onRemove: ([String]) -> Void
    let onMoveGroup: (UUID) -> Void

    @State private var isTargeted = false
    private let debounceDelay = 0.22
    /// Tall enough to drop into casually. Only shown while a drag is in progress, so
    /// it never occupies space (or overlaps a card) when idle.
    private let stripHeight: CGFloat = 64

    var body: some View {
        // Visible for the whole drag; only the fill follows the cursor. The frame is
        // always reserved (faint hint when idle) so there is no relayout mid-drag.
        let isVisible = activity.isActive || isTargeted

        VStack(spacing: 0) {
            if isVisible {
                HStack(spacing: 8) {
                    Image(systemName: "trash")
                        .font(.system(size: 14, weight: .semibold))
                    L10nText("拖到这里，从该分组移除")
                        .font(.system(size: 13, weight: .semibold))
                }
                .foregroundStyle(isTargeted ? Color.white : Color.red)
                .frame(maxWidth: .infinity)
                .frame(height: stripHeight)
                .background(
                    isTargeted ? Color.red.opacity(0.9) : Color.red.opacity(0.12),
                    in: RoundedRectangle(cornerRadius: 12)
                )
                .overlay {
                    RoundedRectangle(cornerRadius: 12)
                        .strokeBorder(
                            Color.red.opacity(isTargeted ? 1 : 0.5),
                            style: StrokeStyle(lineWidth: 1.5, dash: [5, 4])
                        )
                }
            }
        }
        .animation(.easeOut(duration: 0.12), value: isVisible)
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
    }

    /// Debounced so a cursor sitting on the edge cannot flip the strip on and off.
    private func setTargeted(_ value: Bool) {
        highlight.setHover(value)
        if value {
            targetedWork?.cancel()
            withAnimation(.easeOut(duration: 0.12)) { isTargeted = true }
            return
        }

        targetedWork?.cancel()
        let work = DispatchWorkItem {
            withAnimation(.easeOut(duration: 0.12)) { self.isTargeted = false }
        }
        targetedWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + debounceDelay, execute: work)
    }

    @State private var targetedWork: DispatchWorkItem?
}

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
            let paths = items.filter(\.isAppPath).map(\.value)
            guard !paths.isEmpty else { return false }
            for path in paths {
                let name = AppDiscoveryService.item(for: URL(fileURLWithPath: path))?.name
                    ?? URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent
                quickTools.addCustom(name: name, path: path)
            }
            onAdded(L10n.shared.t("已加入快捷工具"))
            return true
        } isTargeted: { isTargeted in
            self.isTargeted = isTargeted
        }
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
                    L10nText("打开")
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

            Text(query.isEmpty ? L10n.shared.t("这个分组还没有应用") : L10n.shared.t("没有匹配的应用"))
                .font(.system(size: 16, weight: .semibold))

            Text(query.isEmpty ? L10n.shared.t("可以添加一个 .app，或切换到其他分组。") : L10n.shared.t("换个关键词试试。"))
                .font(.system(size: 12))
                .foregroundStyle(.secondary)

            HStack(spacing: 8) {
                if !query.isEmpty {
                    Button(L10n.shared.t("清除搜索"), action: onClearSearch)
                        .buttonStyle(.bordered)
                }
                if selection != .running {
                    Button {
                        onAddApp()
                    } label: {
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
            }

            VStack(alignment: .leading, spacing: 9) {
                L10nText("图标")
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
                Image(nsImage: NSWorkspace.shared.icon(forFile: app.path))
                    .resizable()
                    .frame(width: 44, height: 44)
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
