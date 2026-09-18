import AppKit
import Combine
import SwiftUI

/// Wires AppKit entry points that SwiftUI does not expose: the Dock menu, the menu bar
/// icon, and the global hotkey that opens the Spotlight-style search panel.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let searchController = SpotlightController()
    private var searchPanel: SpotlightPanel?
    private var statusItem: NSStatusItem?
    private var store: LauncherStore?
    private var cancellables: Set<AnyCancellable> = []

    /// Called once the main window exists so the delegate can read the same store.
    func attach(store: LauncherStore) {
        self.store = store
        searchController.attach(store: store)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        Appearance.shared.apply()
        let panel = SpotlightPanel(controller: searchController)
        searchController.onRequestClose = { [weak self] in
            self?.searchPanel?.dismiss()
        }
        searchPanel = panel

        HotKeyCenter.shared.onTrigger = { [weak self] in
            self?.toggleSearchPanel()
        }
        registerHotKey()

        HotKeyStore.shared.$shortcut
            .sink { [weak self] _ in self?.registerHotKey() }
            .store(in: &cancellables)

        HotKeyStore.shared.$showsStatusItem
            .sink { [weak self] _ in self?.updateStatusItem() }
            .store(in: &cancellables)

        updateStatusItem()
        installDragSafetyNets()
    }

    // MARK: - Drag state safety nets

    /// Nothing about a drag is guaranteed to report back: it can be cancelled with Esc,
    /// released over empty space, or triggered by a stray few pixels of movement and then
    /// abandoned. Any of those used to leave every delete strip and outline stuck on
    /// screen. These watch for the events that mean "the drag is definitely over".
    private func installDragSafetyNets() {
        NSEvent.addLocalMonitorForEvents(matching: .leftMouseUp) { event in
            DispatchQueue.main.async { DragActivity.shared.endAfterRelease() }
            return event
        }

        // During a real drag the session owns the input, so a wheel event reaching the
        // window means no drag is in flight — which is exactly the stuck case.
        NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { event in
            if DragActivity.shared.isActive {
                DispatchQueue.main.async { DragActivity.shared.end() }
            }
            return event
        }

        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            // 53 is Escape.
            guard event.keyCode == 53 else { return event }
            DispatchQueue.main.async { self?.handleEscape() }
            return event
        }
    }

    /// Escape leaves whatever the user is in the middle of, most specific first.
    private func handleEscape() {
        // The floating search panel dismisses itself.
        if searchPanel?.isVisible == true { return }

        if let store, !store.query.isEmpty {
            store.query = ""
            return
        }

        // Otherwise abandon a drag that is still being reported as active.
        DragActivity.shared.end()
    }

    // MARK: - Dock menu

    /// Right-clicking the Dock icon lists the groups so an app shelf can be opened directly.
    func applicationDockMenu(_ sender: NSApplication) -> NSMenu? {
        let menu = NSMenu()
        let l = L10n.shared

        let search = NSMenuItem(title: l.t("聚焦搜索"), action: #selector(showSearchPanel(_:)), keyEquivalent: "")
        search.target = self
        search.image = symbol("magnifyingglass")
        menu.addItem(search)

        let open = NSMenuItem(title: l.t("打开应用架"), action: #selector(openMainWindow(_:)), keyEquivalent: "")
        open.target = self
        open.image = symbol("square.grid.3x3.fill")
        menu.addItem(open)

        if let store, !store.groups.isEmpty {
            menu.addItem(.separator())
            for group in store.groups {
                let item = NSMenuItem(
                    title: "\(group.name) · \(store.count(for: .group(group.id)))",
                    action: #selector(revealGroup(_:)),
                    keyEquivalent: ""
                )
                item.target = self
                item.representedObject = group.id.uuidString
                item.image = symbol(group.symbol)
                menu.addItem(item)
            }
        }

        menu.addItem(.separator())

        let refresh = NSMenuItem(title: l.t("刷新应用列表"), action: #selector(refreshApps(_:)), keyEquivalent: "")
        refresh.target = self
        refresh.image = symbol("arrow.clockwise")
        menu.addItem(refresh)

        let settings = NSMenuItem(title: l.t("设置…"), action: #selector(openSettings(_:)), keyEquivalent: ",")
        settings.target = self
        settings.image = symbol("gearshape")
        menu.addItem(settings)

        return menu
    }

    // MARK: - Menu bar

    private func updateStatusItem() {
        guard HotKeyStore.shared.showsStatusItem else {
            if let statusItem {
                NSStatusBar.system.removeStatusItem(statusItem)
                self.statusItem = nil
            }
            return
        }

        guard statusItem == nil else { return }

        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        let l = L10n.shared
        if let button = item.button {
            button.image = symbol("square.grid.3x3.fill")
            button.image?.isTemplate = true
            button.toolTip = l.t("应用架")
        }

        let menu = NSMenu()
        let shortcut = HotKeyStore.shared.shortcut
        let search = NSMenuItem(
            title: shortcut.isEnabled ? "\(l.t("聚焦搜索")) (\(shortcut.display))" : l.t("聚焦搜索"),
            action: #selector(showSearchPanel(_:)),
            keyEquivalent: ""
        )
        search.target = self
        menu.addItem(search)

        let open = NSMenuItem(title: l.t("打开应用架"), action: #selector(openMainWindow(_:)), keyEquivalent: "")
        open.target = self
        menu.addItem(open)

        let settings = NSMenuItem(title: l.t("设置…"), action: #selector(openSettings(_:)), keyEquivalent: ",")
        settings.target = self
        menu.addItem(settings)

        menu.addItem(.separator())

        let quit = NSMenuItem(title: l.t("退出应用架"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quit)

        item.menu = menu
        statusItem = item
    }

    // MARK: - Actions

    @objc private func showSearchPanel(_ sender: Any?) {
        toggleSearchPanel()
    }

    @objc private func openMainWindow(_ sender: Any?) {
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func revealGroup(_ sender: NSMenuItem) {
        guard let identifier = sender.representedObject as? String,
              let id = UUID(uuidString: identifier) else { return }
        store?.selection = .group(id)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func refreshApps(_ sender: Any?) {
        store?.reload()
    }

    @objc private func openSettings(_ sender: Any?) {
        SettingsWindowController.shared.showWindow()
    }

    // MARK: - Helpers

    func toggleSearchPanel() {
        searchPanel?.toggle()
    }

    private func registerHotKey() {
        let registered = HotKeyCenter.shared.register(HotKeyStore.shared.shortcut)
        HotKeyStore.shared.registrationFailed = !registered
    }

    private func symbol(_ name: String) -> NSImage? {
        NSImage(systemSymbolName: name, accessibilityDescription: nil)
    }
}
