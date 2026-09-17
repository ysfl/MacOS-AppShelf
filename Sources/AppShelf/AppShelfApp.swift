import SwiftUI

/// Application entry point. The store is shared by the window so scanning and edits
/// update the sidebar and the app grid from the same source of truth.
@main
struct AppShelfApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var store = LauncherStore()

    var body: some Scene {
        WindowGroup {
            ContentView(store: store)
                .onAppear {
                    // The delegate needs the store for the Dock menu and the search panel.
                    appDelegate.attach(store: store)
                }
        }
        // Keep the window large enough for the sidebar and the adaptive app grid.
        .defaultSize(width: 1100, height: 720)
        .windowResizability(.contentMinSize)
        .commands {
            CommandGroup(after: .newItem) {
                Button("聚焦搜索") {
                    appDelegate.toggleSearchPanel()
                }
                .keyboardShortcut("k", modifiers: [.command])

                Button("刷新应用列表") {
                    store.reload()
                }
                .keyboardShortcut("r", modifiers: [.command, .option])
            }
        }

        Settings {
            SettingsView()
        }
    }
}
