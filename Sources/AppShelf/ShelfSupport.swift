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

extension View {
    /// Applies `transform` only when `condition` holds, without forcing both branches
    /// into one type.
    @ViewBuilder func when<Content: View>(_ condition: Bool, _ transform: (Self) -> Content) -> some View {
        if condition { transform(self) } else { self }
    }
}

/// Reports the grid's own size without taking part in layout.
struct GridSizeKey: PreferenceKey {
    static let defaultValue: CGSize = .zero
    static func reduce(value: inout CGSize, nextValue: () -> CGSize) {
        let next = nextValue()
        if next != .zero { value = next }
    }
}
