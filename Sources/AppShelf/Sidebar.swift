import AppKit
import SwiftUI
import UniformTypeIdentifiers

import AppShelfCore

// MARK: - Sidebar
/// The draggable group list in the sidebar, split out so the sidebar body stays small.
struct SidebarGroups: View {
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
                    .font(.shelfMicro)
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
struct SidebarSectionLabel: View {
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
struct SidebarRow: View {
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
                    .font(.shelfControlTitle)
                    .foregroundStyle(isSelected ? tint : .secondary)
                    .frame(width: 18)
                    .accessibilityHidden(true)

                Text(title)
                    .font(.system(size: 13, weight: isHighlighted ? .semibold : .medium))
                    .foregroundStyle(isHighlighted ? .primary : .secondary)
                    .lineLimit(1)

                Spacer(minLength: 4)

                Text("\(count)")
                    .font(.shelfCount)
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
struct ToolRow: View {
    let tool: QuickToolItem
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                toolIcon
                    .frame(width: 18)
                    .accessibilityHidden(true)
                Text(tool.title)
                    .font(.shelfBody)
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
                .font(.shelfLabel)
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
        }
    }

    @ViewBuilder
    private var toolIcon: some View {
        if let symbol = tool.symbol {
            Image(systemName: symbol)
                .font(.shelfBody)
                .foregroundStyle(.secondary)
        } else if let path = tool.path {
            Image(nsImage: IconCache.shared.image(for: path))
                .resizable()
                .interpolation(.high)
        }
    }
}
