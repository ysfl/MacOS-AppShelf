import Foundation
import Testing

@testable import AppShelfCore

/// Every drag-and-drop bug this project has had was index arithmetic.
///
/// The two that cost the most: a landing slot that drifted by one tile, and "in front of
/// the next tile" being a no-op once the two were already neighbours, which forced the
/// user to overshoot a whole tile before anything moved.
struct ShelfOrderingTests {

    // MARK: move(before:) / move(after:)

    @Test("移动到目标之前，原位置被腾出")
    func moveBefore() {
        #expect(ShelfOrdering.move(["d"], before: "b", in: ["a", "b", "c", "d"]) == ["a", "d", "b", "c"])
        #expect(ShelfOrdering.move(["a"], before: "c", in: ["a", "b", "c", "d"]) == ["b", "a", "c", "d"])
    }

    @Test("新应用落到目标之前即完成归组")
    func moveBeforeFilesNewcomer() {
        #expect(ShelfOrdering.move(["x"], before: "c", in: ["a", "b", "c"]) == ["a", "b", "x", "c"])
    }

    @Test("目标不存在时追加到末尾，而不是丢弃")
    func missingTargetAppends() {
        #expect(ShelfOrdering.move(["x"], before: "zzz", in: ["a", "b"]) == ["a", "b", "x"])
    }

    @Test("拖到自己身上是空操作")
    func movingOntoItselfIsANoOp() {
        #expect(ShelfOrdering.move(["b"], before: "b", in: ["a", "b", "c"]) == ["a", "b", "c"])
    }

    @Test("向右移动落在经过的那个应用之后")
    func moveAfterLandsBehindThePassedTile() {
        #expect(ShelfOrdering.move(["a"], after: "c", in: ["a", "b", "c"]) == ["b", "c", "a"])
        #expect(ShelfOrdering.move(["c"], after: "a", in: ["a", "b", "c"]) == ["a", "c", "b"])
    }

    @Test("相邻时 before 是空操作，after 才真正交换")
    func adjacentSwapNeedsAfter() {
        // a b c: dragging a onto "in front of b" must not be a no-op once they are
        // already neighbours — that was the "have to overshoot a tile" bug.
        let before = ShelfOrdering.move(["a"], before: "b", in: ["a", "b", "c"])
        #expect(before == ["a", "b", "c"])
        let after = ShelfOrdering.move(["a"], after: "b", in: ["a", "b", "c"])
        #expect(after == ["b", "a", "c"])
    }

    @Test("一次拖动多个应用按给定顺序落在目标之前")
    func multipleDraggedItems() {
        #expect(ShelfOrdering.move(["d", "b"], before: "c", in: ["a", "b", "c", "d"]) == ["a", "d", "b", "c"])
    }

    // MARK: placement

    @Test("指针在起点右侧时落在该应用之后")
    func placementRightIsAfter() {
        let placement = ShelfOrdering.placement(order: ["a", "b", "c", "d"],
                                                source: 0, hovered: 2, picked: "a")
        #expect(placement == ShelfOrdering.Placement(edge: .after, target: "c"))
    }

    @Test("指针在起点左侧时落在该应用之前")
    func placementLeftIsBefore() {
        let placement = ShelfOrdering.placement(order: ["a", "b", "c", "d"],
                                                source: 3, hovered: 1, picked: "d")
        #expect(placement == ShelfOrdering.Placement(edge: .before, target: "b"))
    }

    @Test("没有移动、起点不符或索引越界都判为跨组归位")
    func placementRefusals() {
        let order = ["a", "b", "c"]
        #expect(ShelfOrdering.placement(order: order, source: 1, hovered: 1, picked: "b") == nil)
        #expect(ShelfOrdering.placement(order: order, source: 0, hovered: 1, picked: "zzz") == nil)
        #expect(ShelfOrdering.placement(order: order, source: 0, hovered: 9, picked: "a") == nil)
        #expect(ShelfOrdering.placement(order: [], source: 0, hovered: 1, picked: "a") == nil)
    }

    // MARK: group reordering

    @Test("分组重排序按移动方向修正插入点")
    func groupReorder() {
        let ids = ["g1", "g2", "g3"]
        #expect(ShelfOrdering.reorder(ids, moving: "g1", before: "g3") == ["g2", "g1", "g3"])
        #expect(ShelfOrdering.reorder(ids, moving: "g3", before: "g1") == ["g3", "g1", "g2"])
        #expect(ShelfOrdering.reorder(ids, moving: "g2", before: "g1") == ["g2", "g1", "g3"])
    }

    @Test("重排序对未知或自身目标保持原样")
    func groupReorderRefusals() {
        let ids = ["g1", "g2"]
        #expect(ShelfOrdering.reorder(ids, moving: "g1", before: "g1") == ids)
        #expect(ShelfOrdering.reorder(ids, moving: "nope", before: "g1") == ids)
        #expect(ShelfOrdering.reorder(ids, moving: "g1", before: "nope") == ids)
    }
}

/// Which neighbour slides, and how far.
struct ShelfReflowTests {

    @Test("起点与指针之间的每个格子让位一格")
    func tilesBetweenSlide() {
        // Carried from 0 towards 3: tiles 1,2,3 shift left one slot, tile 0 does not.
        #expect(ShelfReflow.targetIndex(index: 0, source: 0, hovered: 3) == nil)
        #expect(ShelfReflow.targetIndex(index: 1, source: 0, hovered: 3) == 0)
        #expect(ShelfReflow.targetIndex(index: 2, source: 0, hovered: 3) == 1)
        #expect(ShelfReflow.targetIndex(index: 3, source: 0, hovered: 3) == 2)
        #expect(ShelfReflow.targetIndex(index: 4, source: 0, hovered: 3) == nil)
    }

    @Test("反向拖动时格子向右让位")
    func tilesSlideRightWhenCarriedLeft() {
        #expect(ShelfReflow.targetIndex(index: 0, source: 3, hovered: 0) == 1)
        #expect(ShelfReflow.targetIndex(index: 2, source: 3, hovered: 0) == 3)
        #expect(ShelfReflow.targetIndex(index: 3, source: 3, hovered: 0) == nil)
    }

    @Test("指针回到起点时没有格子移动")
    func noSlideWhenHoveringSource() {
        #expect(ShelfReflow.targetIndex(index: 1, source: 1, hovered: 1) == nil)
    }

    @Test("跨行位移拆成列差与行差")
    func slotDeltaWrapsRows() {
        #expect(ShelfReflow.slotDelta(from: 0, to: 1, columns: 2) == (columns: 1, rows: 0))
        #expect(ShelfReflow.slotDelta(from: 1, to: 2, columns: 2) == (columns: -1, rows: 1))
        #expect(ShelfReflow.slotDelta(from: 0, to: 4, columns: 2) == (columns: 0, rows: 2))
    }

    @Test("列数为 0 时按 1 处理而不是崩溃")
    func zeroColumnsIsSafe() {
        #expect(ShelfReflow.slotDelta(from: 0, to: 3, columns: 0) == (columns: 0, rows: 3))
    }
}

/// The adaptive grid the slide distances are measured against.
struct GridGeometryTests {

    private let spec = GridMetricsSpec.standard

    @Test("宽度决定列数，剩余空间在 min/max 之间摊平")
    func columnFitting() {
        let measured = spec.measure(width: 1000, height: 332, count: 12)
        #expect(measured?.columns == 6)
        #expect(measured?.columnStep == 169)
        #expect(measured?.rowStep == 174)
    }

    @Test("列宽被夹在 maximum 以内，所以列数随宽度增长")
    func columnWidthIsClamped() {
        // A very wide window gets more columns rather than absurdly wide ones.
        let measured = spec.measure(width: 4000, height: 200, count: 1)
        #expect((measured?.columns ?? 0) > 20)
        #expect((measured?.columnStep ?? 0) <= GridMetricsSpec.standard.maximum
                + GridMetricsSpec.standard.columnSpacing + 0.001)
        #expect((measured?.columnStep ?? 0) >= GridMetricsSpec.standard.minimum
                + GridMetricsSpec.standard.columnSpacing - 0.001)
    }

    @Test("零宽或空列表返回 nil，让调用方保留上一次的有效测量")
    func refusesDegenerateMeasurements() {
        #expect(spec.measure(width: 0, height: 300, count: 5) == nil)
        #expect(spec.measure(width: 500, height: 300, count: 0) == nil)
        #expect(spec.measure(width: -1, height: 300, count: 5) == nil)
    }

    @Test("行数向上取整，最后一行为空也不会算出负行高")
    func rowCountRoundsUp() {
        // 5 items in 2 columns is 3 rows, so row height must divide by 3.
        let measured = spec.measure(width: 300, height: 3 * 158 + 2 * 16, count: 5)
        #expect(measured?.columns == 2)
        #expect(measured?.rowStep == 174)
    }

    @Test("极矮的容器退回到行距而不是 0")
    func tinyHeightFallsBack() {
        let measured = spec.measure(width: 300, height: 1, count: 50)
        #expect(measured?.rowStep == 16)
    }
}
