import AppKit
import SwiftUI

import AppShelfCore

/// Shared colors for the launcher shell and its controls.
///
/// Every stroke that has to survive both appearances reads a system semantic color rather
/// than a fixed black or white: `AppShelfPalette.border` used to be `Color.black.opacity(0.08)`,
/// which is invisible on a dark canvas, while the search panel's `Color.white.opacity(0.2)`
/// was invisible on a light one.
enum AppShelfPalette {
    static let sidebar = Color(nsColor: .underPageBackgroundColor)
    static let canvas = Color(nsColor: .windowBackgroundColor)
    static let panel = Color(nsColor: .controlBackgroundColor)

    /// Hairline separating a control from the surface it sits on. Legible in both appearances.
    static let border = Color(nsColor: .separatorColor)

    static let accent = Color(red: 0.12, green: 0.42, blue: 0.86)
    static let success = Color(red: 0.12, green: 0.60, blue: 0.42)
    /// The remove-from-group affordance. Text on a filled danger surface stays white in both
    /// appearances because the fill is opaque red, not a tint.
    static let danger = Color.red

    /// Fill behind a control that currently has keyboard focus.
    static let focusRing = accent.opacity(0.55)
    /// Fill behind the block a drop is about to land in.
    static let dropTargetFill = accent.opacity(0.13)
    /// Outline drawn on every tile while a drag is in flight.
    static let dragOutline = Color(nsColor: .separatorColor)
    /// Edge of a floating panel. The search panel used a fixed white stroke, which vanished
    /// on a light desktop just as the fixed black one vanished on a dark one.
    static let panelEdge = Color.primary.opacity(0.16)
}

/// The one definition of the app grid.
///
/// The `GridItem` array and the geometry used to slide a tile both come from here, so the
/// column step can no longer disagree with what the grid actually laid out.
enum ShelfGrid {
    static let spec = GridMetricsSpec.standard

    static var columns: [GridItem] {
        [GridItem(.adaptive(minimum: CGFloat(spec.minimum), maximum: CGFloat(spec.maximum)),
                  spacing: CGFloat(spec.columnSpacing))]
    }

    static var rowSpacing: CGFloat { CGFloat(spec.rowSpacing) }
    static var columnSpacing: CGFloat { CGFloat(spec.columnSpacing) }

    /// Shortest measure of the grid rows, so `GridGeometry` never divides by a zero height.
    static let minimumRowHeight: CGFloat = 158
}

extension Color {
    /// Decode the six- or eight-digit hex strings used by persisted group colors.
    init(hex: String) {
        let sanitized = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var value: UInt64 = 0
        Scanner(string: sanitized).scanHexInt64(&value)

        let red: Double
        let green: Double
        let blue: Double

        switch sanitized.count {
        case 6:
            red = Double((value >> 16) & 0xFF) / 255
            green = Double((value >> 8) & 0xFF) / 255
            blue = Double(value & 0xFF) / 255
        case 8:
            red = Double((value >> 24) & 0xFF) / 255
            green = Double((value >> 16) & 0xFF) / 255
            blue = Double((value >> 8) & 0xFF) / 255
        default:
            red = 0.35
            green = 0.40
            blue = 0.48
        }

        self.init(red: red, green: green, blue: blue)
    }

    /// Convert the system color picker value to the hex representation persisted by AppGroup.
    var appShelfHex: String {
        let nsColor = NSColor(self).usingColorSpace(.deviceRGB) ?? NSColor.gray
        let red = max(0, min(255, Int(round(nsColor.redComponent * 255))))
        let green = max(0, min(255, Int(round(nsColor.greenComponent * 255))))
        let blue = max(0, min(255, Int(round(nsColor.blueComponent * 255))))
        return String(format: "#%02X%02X%02X", red, green, blue)
    }
}

extension AppGroup {
    /// The group's tint, decoded from the hex string the picker persists.
    var color: Color { Color(hex: colorHex) }
}
