import AppKit
import SwiftUI
import UniformTypeIdentifiers

import AppShelfCore

// MARK: - Cards
/// A red strip at the foot of a group block. Dropping an app here takes it out of
/// the group instead of filing it in, so grouping can be undone by dragging alone.
struct RemoveFromGroupStrip: View {
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
                        .font(.shelfSectionTitle)
                        .accessibilityHidden(true)
                    L10nText("拖到这里，从该分组移除")
                        .font(.shelfControlTitle)
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
struct DropPulse: View {
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
struct AppUsageLine: View {
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
                    .frame(width: ShelfGrid.iconSide, height: ShelfGrid.iconSide)
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

struct AppCard: View {
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
@MainActor
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
