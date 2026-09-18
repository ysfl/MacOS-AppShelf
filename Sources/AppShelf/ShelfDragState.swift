import AppKit
import SwiftUI
import UniformTypeIdentifiers

import AppShelfCore

// MARK: - Drag state
/// Live state of an in-group drag: which slot was picked up, and which slot the pointer
/// is over.
///
/// The data is deliberately untouched until the drop. That keeps every index stable for
/// the whole gesture — reordering as we went made the indices move under the calculation,
/// which is what caused the "sometimes it takes two tiles" behaviour.
@MainActor
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
@MainActor
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
@MainActor
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
@MainActor
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
@MainActor
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
struct GroupDragPreview: View {
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
                    .font(.shelfCount)
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
                            .font(.shelfNote)
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
struct AppSection: Identifiable {
    let id: String
    let title: String
    let symbol: String
    let tint: Color
    let groupID: UUID?
    let apps: [AppItem]
}
