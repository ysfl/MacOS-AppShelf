import SwiftUI

@main
struct AppShelfApp: App {
    @StateObject private var store = LauncherStore()

    var body: some Scene {
        WindowGroup {
            ContentView(store: store)
        }
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
