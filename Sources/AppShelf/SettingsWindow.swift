import AppKit
import SwiftUI
import UniformTypeIdentifiers

import AppShelfCore

/// The settings window, identifiable so the delegate can exclude it when it looks for the
/// shelf window.
final class SettingsWindow: NSWindow {}

/// Owns the settings window.
///
/// The window is created directly with AppKit so the same entry point works from the
/// toolbar, the Dock menu, and the menu bar icon, instead of relying on a private action.
final class SettingsWindowController: NSWindowController {
    static let shared = SettingsWindowController()

    private init() {
        let hosting = NSHostingView(rootView: SettingsView())
        // Resizable and scrollable: the panel used to be a fixed 430x760 box with no
        // ScrollView, so a long quick-tool list was clipped with no way to reach it.
        let window = SettingsWindow(
            contentRect: NSRect(x: 0, y: 0, width: 460, height: 560),
            styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = L10n.shared.t("设置")
        window.contentView = hosting
        window.contentMinSize = NSSize(width: 400, height: 420)
        window.isReleasedWhenClosed = false
        window.center()
        super.init(window: window)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("SettingsWindowController is only created programmatically")
    }

    func showWindow() {
        NSApp.activate(ignoringOtherApps: true)
        window?.title = L10n.shared.t("设置")
        window?.makeKeyAndOrderFront(nil)
    }
}
