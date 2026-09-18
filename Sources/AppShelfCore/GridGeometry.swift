import Foundation

/// Geometry of an adaptive tile grid, mirroring `GridItem(.adaptive(minimum:maximum:))`.
///
/// A tile is slid by exactly one slot during a drag, which needs the real column step and
/// row step. Those were previously hand-written in two places and kept in sync by a
/// comment warning; now the view layer feeds its own constants in here, so there is one
/// definition of the grid.
public struct GridGeometry: Equatable, Sendable {
    public let columns: Int
    /// Distance between two neighbouring column origins (column width + spacing).
    public let columnStep: Double
    /// Distance between two neighbouring row origins (row height + spacing).
    public let rowStep: Double

    public init(columns: Int, columnStep: Double, rowStep: Double) {
        self.columns = columns
        self.columnStep = columnStep
        self.rowStep = rowStep
    }

    public static let fallback = GridGeometry(columns: 1, columnStep: 150, rowStep: 174)

    /// Fits `count` tiles into `width` x `height`.
    ///
    /// Returns `nil` for a zero-sized or empty grid, which lets the caller keep its last
    /// known-good measurement instead of collapsing every slide to zero.
    public static func measure(width: Double, height: Double, count: Int,
                               minimum: Double, maximum: Double,
                               columnSpacing: Double, rowSpacing: Double) -> GridGeometry? {
        guard width > 0, count > 0 else { return nil }

        let fitted = Int((width + columnSpacing) / (minimum + columnSpacing))
        let columns = max(1, fitted)
        let rawColumnWidth = (width - columnSpacing * Double(columns - 1)) / Double(columns)
        let columnWidth = min(max(rawColumnWidth, minimum), maximum)

        let rows = max(1, Int((Double(count) / Double(columns)).rounded(.up)))
        let rowHeight = (height - rowSpacing * Double(rows - 1)) / Double(rows)

        return GridGeometry(columns: columns,
                            columnStep: columnWidth + columnSpacing,
                            rowStep: rowHeight > 0 ? rowHeight + rowSpacing : rowSpacing)
    }
}

/// The single source of truth for the app grid's spacing.
///
/// Both the SwiftUI `GridItem` array and `GridGeometry.measure` read these, so a slide can
/// no longer land off-target because one of the two was edited.
public struct GridMetricsSpec: Equatable, Sendable {
    public let minimum: Double
    public let maximum: Double
    public let columnSpacing: Double
    public let rowSpacing: Double

    public init(minimum: Double, maximum: Double, columnSpacing: Double, rowSpacing: Double) {
        self.minimum = minimum
        self.maximum = maximum
        self.columnSpacing = columnSpacing
        self.rowSpacing = rowSpacing
    }

    /// Comfortable default: Launchpad-like tiles that reflow with the window width.
    public static let standard = GridMetricsSpec(minimum: 136, maximum: 176, columnSpacing: 14, rowSpacing: 16)

    public func measure(width: Double, height: Double, count: Int) -> GridGeometry? {
        GridGeometry.measure(width: width, height: height, count: count,
                             minimum: minimum, maximum: maximum,
                             columnSpacing: columnSpacing, rowSpacing: rowSpacing)
    }
}
