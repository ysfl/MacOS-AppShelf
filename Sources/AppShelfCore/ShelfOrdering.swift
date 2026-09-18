import Foundation

/// Index math behind reordering apps and groups.
///
/// Extracted from `LauncherStore` because every drag-and-drop bug this project has had
/// lived here: the landing slot drifting a tile, and "in front of the next tile" being a
/// no-op once the two were already neighbours. The store now only persists what these
/// functions return.
public enum ShelfOrdering {
    /// Which side of `target` the dragged items land on.
    public enum Edge: String, Equatable, Sendable {
        case before
        case after
    }

    /// A resolved drop destination: put the payload next to an existing entry.
    public struct Placement: Equatable, Sendable {
        public let edge: Edge
        public let target: String

        public init(edge: Edge, target: String) {
            self.edge = edge
            self.target = target
        }
    }

    /// Moves `dragged` so they sit immediately before `target`.
    ///
    /// An unknown `dragged` is inserted rather than skipped, which is what files an app
    /// into a group it was not part of. An unknown `target` appends to the tail.
    public static func move(_ dragged: [String], before target: String, in order: [String]) -> [String] {
        relocate(dragged, before: target, after: target, in: order)
    }

    /// Moves `dragged` so they sit immediately behind `target`.
    public static func move(_ dragged: [String], after target: String, in order: [String]) -> [String] {
        relocate(dragged, before: target, after: target, in: order, insertAfter: true)
    }

    private static func relocate(_ dragged: [String], before: String, after: String,
                                 in order: [String], insertAfter: Bool = false) -> [String] {
        var list = order
        for item in dragged {
            guard item != after else { continue }
            list.removeAll { $0 == item }
            let anchor = insertAfter ? after : before
            if let index = list.firstIndex(of: anchor) {
                list.insert(item, at: insertAfter ? index + 1 : index)
            } else {
                list.append(item)
            }
        }
        return list
    }

    /// Where the carried tile ends up once the pointer is released.
    ///
    /// `nil` means "this was never a same-group reorder" — the pointer came from outside,
    /// nothing moved, or the indices no longer describe the list the slide ran against.
    /// Callers then file the payload where it was dropped.
    public static func placement(order: [String], source: Int, hovered: Int, picked: String) -> Placement? {
        guard source != hovered,
              order.indices.contains(source), order.indices.contains(hovered),
              order[source] == picked else { return nil }
        // Carried right means landing *behind* the tile it passed; carrying left means
        // landing in front of it. Using "before" both ways is what forced the overshoot.
        return Placement(edge: hovered > source ? .after : .before, target: order[hovered])
    }

    /// Reorders identifiers, used when a sidebar row or a section heading is dragged.
    ///
    /// Removing the dragged entry shifts every later index down by one, so the insertion
    /// point has to be corrected for the direction of travel.
    public static func reorder(_ ids: [String], moving id: String, before target: String) -> [String] {
        guard id != target,
              let from = ids.firstIndex(of: id),
              let to = ids.firstIndex(of: target) else { return ids }
        var list = ids
        list.remove(at: from)
        list.insert(ids[from], at: from < to ? to - 1 : to)
        return list
    }
}

/// Which tile slides out of the way, and by how far.
///
/// The grid is never relaid out mid-drag: neighbours are moved with a transform, so the
/// indices used for the calculation stay valid for the whole gesture.
public enum ShelfReflow {
    /// The slot `index` should visually occupy while the pointer is at `hovered`,
    /// or `nil` when this tile is not between the pick-up and the pointer.
    public static func targetIndex(index: Int, source: Int, hovered: Int) -> Int? {
        if hovered > source {
            guard index > source, index <= hovered else { return nil }
            return index - 1
        }
        if hovered < source {
            guard index >= hovered, index < source else { return nil }
            return index + 1
        }
        return nil
    }

    /// Grid-space distance between two flat indices.
    public static func slotDelta(from: Int, to: Int, columns: Int) -> (columns: Int, rows: Int) {
        let columns = max(1, columns)
        return (to % columns - from % columns, to / columns - from / columns)
    }
}
