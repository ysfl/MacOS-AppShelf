import SwiftUI

/// Application entry point. The store is shared by the window so scanning and edits
/// update the sidebar and the app grid from the same source of truth.
@main
struct AppShelfApp: App {
    @StateObject private var store = LauncherStore()

    var body: some Scene {
        WindowGroup {
            ContentView(store: store)
        }
        // Keep the window large enough for the sidebar and the adaptive app grid.
        .defaultSize(width: 1100, height: 720)
        .windowResizability(.contentMinSize)
        .commands {
            CommandGroup(after: .newItem) {
                Button("刷新应用列表") {
                    store.reload()
                }
                .keyboardShortcut("r", modifiers: [.command, .option])
            }
        }
    }
}
