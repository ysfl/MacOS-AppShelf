import AppKit
import SwiftUI
import UniformTypeIdentifiers

import AppShelfCore

/// Drives the floating search panel: filtering, keyboard navigation, and launching.
/// The panel shows only the search field and its results, never the full window.
@MainActor
final class SpotlightController: ObservableObject {
    @Published var query = "" {
        didSet { refresh() }
    }
    @Published var selectedIndex = 0
    @Published private(set) var results: [AppItem] = []

    /// The panel owns this closure so the controller never touches AppKit directly.
    var onRequestClose: (() -> Void)?

    private var store: LauncherStore?
    private static let resultLimit = 40

    func attach(store: LauncherStore) {
        self.store = store
        refresh()
    }

    var shortcutHint: String {
        let shortcut = HotKeyStore.shared.shortcut
        return shortcut.isEnabled ? shortcut.display : L10n.shared.t("未设置")
    }

    /// Resets the panel each time it is presented so it always opens on a clean query.
    func prepareForPresentation() {
        query = ""
        selectedIndex = 0
        refresh()
    }

    func refresh() {
        guard let store else {
            results = []
            return
        }

        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            // With an empty query the panel doubles as a quick switcher: what is running,
            // then what the user launches most, then most recently used, then alphabetical.
            let visible = store.hidden.filtering(store.apps)
            results = Array(UsageRanking.sorted(
                visible,
                counts: { UsageRecorder.shared.count(for: $0.path) },
                lastUsed: { UsageRecorder.shared.lastUsed(for: $0.path) }
            ).prefix(20))
        } else {
            results = Array(store.searchResults(for: trimmed, limit: Self.resultLimit))
        }

        if results.isEmpty {
            selectedIndex = 0
        } else {
            selectedIndex = min(max(selectedIndex, 0), results.count - 1)
        }
    }

    func move(by delta: Int) {
        guard !results.isEmpty else { return }
        selectedIndex = (selectedIndex + delta + results.count) % results.count
    }

    func select(_ index: Int) {
        guard results.indices.contains(index) else { return }
        selectedIndex = index
    }

    func openSelected() {
        guard results.indices.contains(selectedIndex) else { return }
        open(results[selectedIndex])
    }

    func open(_ app: AppItem) {
        store?.launch(app)
        onRequestClose?()
    }
}
