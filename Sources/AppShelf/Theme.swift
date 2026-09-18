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
/// The `GridItem` array, the slide geometry and the card metrics all read the same
/// density, so a change in Settings moves the whole grid together instead of desynchronising
/// the layout from the transform that slides tiles during a drag.
@MainActor
enum ShelfGrid {
    private static var preferences: LayoutPreferences { .shared }

    static var spec: GridMetricsSpec { preferences.density.spec }
    static var columns: [GridItem] { preferences.columns }
    static var rowSpacing: CGFloat { preferences.rowSpacing }
    static var columnSpacing: CGFloat { preferences.columnSpacing }
    static var minimumRowHeight: CGFloat { preferences.minimumRowHeight }
    static var iconSide: CGFloat { preferences.iconSide }
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

/// Named text roles for the styles that repeat often enough to be a system.
///
/// The grid still carries one-off sizes where a specific optical result was chosen
/// (a 31 pt empty-state glyph, a 9 pt arrow). Those are deliberate, not drift. What this
/// exists to stop is *new* ad-hoc sizes creeping in for roles that already have a name,
/// which `Scripts/gates/gates.py` enforces as a ratchet: the count of un-named
/// `.font(.system(size:` call sites may go down, never up.
extension Font {
    /// Sidebar and card metadata: counts, timestamps, quiet labels.
    static let shelfMeta = Font.system(size: 11)
    /// Small headings and control titles.
    static let shelfLabel = Font.system(size: 12, weight: .semibold)
    /// Default running text in lists and panels.
    static let shelfCaption = Font.system(size: 12)
    /// Group and section headings.
    static let shelfSectionTitle = Font.system(size: 14, weight: .semibold)
    /// Rows that need a touch more emphasis than `shelfCaption`.
    static let shelfBody = Font.system(size: 12, weight: .medium)
    /// Secondary notes under a heading.
    static let shelfNote = Font.system(size: 11, weight: .medium)
    /// Buttons and toolbar titles.
    static let shelfControlTitle = Font.system(size: 13, weight: .semibold)
    /// The smallest readable tier: badges, hints under icons.
    static let shelfMicro = Font.system(size: 10)
    /// Numerals that must stay column-aligned as values change.
    static let shelfCount = Font.system(size: 11, weight: .medium, design: .monospaced)
    /// Sheet and panel headings.
    static let shelfSheetTitle = Font.system(size: 20, weight: .semibold, design: .rounded)
}
