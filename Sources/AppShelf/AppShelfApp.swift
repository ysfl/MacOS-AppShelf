import SwiftUI

import AppShelfCore

/// Application entry point. The store is shared by the window so scanning and edits
/// update the sidebar and the app grid from the same source of truth.
@main
struct AppShelfApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var store = LauncherStore()
    @Environment(\.openWindow) private var openWindow

    var body: some Scene {
        // An explicit id so the delegate can reopen the shelf after the user closes it;
        // without a window on screen, `NSApp.activate` alone did nothing at all.
        WindowGroup(id: "main") {
            ContentView(store: store)
                .onAppear {
                    // The delegate needs the store for the Dock menu and the search panel.
                    appDelegate.attach(store: store)
                    appDelegate.setOpenMainWindowAction { openWindow(id: "main") }
                }
        }
        // Keep the window large enough for the sidebar and the adaptive app grid.
        .defaultSize(width: 1100, height: 720)
        .windowResizability(.contentMinSize)
        .commands {
            // A second main window would run its own refresh timer and share the six global
            // drag-state singletons, so a drag in one window lit up the other.
            CommandGroup(replacing: .newItem) {
                Button {
                    appDelegate.showMainWindow()
                } label: {
                    L10nText("打开应用架窗口")
                }
                .keyboardShortcut("0", modifiers: [.command])
            }

            CommandGroup(after: .textEditing) {
                Button {
                    FocusRouter.shared.focusSearch()
                } label: {
                    L10nText("搜索应用")
                }
                .keyboardShortcut("f", modifiers: [.command])
            }

            CommandGroup(after: .undoRedo) {
                Button {
                    store.undo()
                } label: {
                    L10nText("撤销")
                }
                .keyboardShortcut("z", modifiers: [.command])
                .disabled(!store.canUndo)
            }

            CommandGroup(after: .appSettings) {
                Button {
                    SettingsWindowController.shared.showWindow()
                } label: {
                    L10nText("设置…")
                }
                .keyboardShortcut(",", modifiers: [.command])
            }

            CommandMenu(L10n.shared.t("应用架")) {
                Button {
                    appDelegate.toggleSearchPanel()
                } label: {
                    L10nText("聚焦搜索")
                }
                .keyboardShortcut("k", modifiers: [.command])

                Button {
                    store.reload()
                } label: {
                    L10nText("刷新应用列表")
                }
                .keyboardShortcut("r", modifiers: [.command, .option])
                .disabled(store.isScanning)

                Divider()

                // ⌘1…⌘9 jump straight to a group, the one shortcut set a shelf really wants.
                ForEach(Array(store.groups.prefix(9).enumerated()), id: \.element.id) { offset, group in
                    Button {
                        store.selection = .group(group.id)
                        appDelegate.showMainWindow()
                    } label: {
                        L10nText(group.name)
                    }
                    .keyboardShortcut(KeyEquivalent(Character("\(offset + 1)")), modifiers: [.command])
                }
            }
        }
    }
}
