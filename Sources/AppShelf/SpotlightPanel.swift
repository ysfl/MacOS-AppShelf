import AppKit
import Combine
import SwiftUI

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
            // With an empty query the panel doubles as a quick switcher: running apps first.
            results = Array(store.apps.sorted { lhs, rhs in
                if lhs.isRunning != rhs.isRunning { return lhs.isRunning }
                return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
            }.prefix(20))
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

/// Shared width of the floating panel, used by both the window and its content view.
private let spotlightPanelWidth: CGFloat = 660

extension Notification.Name {
    /// Posted every time the panel is presented so the text field can take focus again.
    static let spotlightPanelDidPresent = Notification.Name("AppShelf.spotlightPanelDidPresent")
}

/// A borderless, non-activating panel that floats above other apps.
/// It takes keyboard focus without bringing the rest of the app forward.
final class SpotlightPanel: NSPanel {
    private static let minimumHeight: CGFloat = 96
    private static let maximumHeight: CGFloat = 620

    private let controller: SpotlightController
    private weak var hostingView: NSHostingView<SpotlightView>?
    private var cancellables: Set<AnyCancellable> = []
    private var localMonitor: Any?
    private var globalMonitor: Any?
    private var previousApplication: NSRunningApplication?
    private var isDismissing = false

    init(controller: SpotlightController) {
        self.controller = controller
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: spotlightPanelWidth, height: 300),
            styleMask: [.nonactivatingPanel, .fullSizeContentView, .borderless],
            backing: .buffered,
            defer: false
        )

        isFloatingPanel = true
        level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.popUpMenuWindow)))
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        isMovableByWindowBackground = true
        titleVisibility = .hidden
        titlebarAppearsTransparent = true
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        animationBehavior = .utilityWindow

        let view = SpotlightView(controller: controller)
        let hosting = NSHostingView(rootView: view)
        hosting.frame = NSRect(x: 0, y: 0, width: spotlightPanelWidth, height: 300)
        contentView = hosting
        self.hostingView = hosting

        // Results change the natural height of the panel, so refit whenever they do.
        controller.$results
            .sink { [weak self] _ in
                DispatchQueue.main.async { self?.fitHeight() }
            }
            .store(in: &cancellables)
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    /// Centers the panel near the top of the screen, like Spotlight does.
    func present() {
        guard !isVisible else { return }
        isDismissing = false
        previousApplication = NSWorkspace.shared.frontmostApplication
        controller.prepareForPresentation()
        fitHeight()
        makeKeyAndOrderFront(nil)

        // A non-activating panel normally becomes key on its own. If it did not, fall back
        // to activating the app so the text field can still receive typing.
        if !isKeyWindow {
            NSApp.activate(ignoringOtherApps: true)
            makeKeyAndOrderFront(nil)
        }

        installMonitors()
        NotificationCenter.default.post(name: .spotlightPanelDidPresent, object: nil)
    }

    func dismiss() {
        guard isVisible, !isDismissing else { return }
        isDismissing = true
        removeMonitors()
        orderOut(nil)

        // Hand focus back to whatever the user was doing before the panel appeared.
        if let previousApplication,
           previousApplication != NSRunningApplication.current {
            previousApplication.activate(options: [])
        }
        previousApplication = nil
        isDismissing = false
    }

    func toggle() {
        if isVisible {
            dismiss()
        } else {
            present()
        }
    }

    override func resignKey() {
        super.resignKey()
        if isVisible && !isDismissing {
            dismiss()
        }
    }

    // MARK: - Sizing

    private func fitHeight() {
        guard let hostingView else { return }
        let width = spotlightPanelWidth
        hostingView.setFrameSize(NSSize(width: width, height: hostingView.frame.height))
        hostingView.layoutSubtreeIfNeeded()
        let natural = hostingView.fittingSize.height
        let height = min(max(natural, SpotlightPanel.minimumHeight), SpotlightPanel.maximumHeight)
        setContentSize(NSSize(width: width, height: height))
        reposition()
    }

    private func reposition() {
        guard let screen = NSScreen.main ?? NSScreen.screens.first else { return }
        let visible = screen.visibleFrame
        let originX = visible.midX - frame.width / 2
        let top = visible.maxY - visible.height * 0.22
        setFrameOrigin(NSPoint(x: originX, y: top - frame.height))
    }

    // MARK: - Events

    private func installMonitors() {
        guard localMonitor == nil else { return }

        localMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { [weak self] event in
            guard let self, self.isVisible, self.isKeyWindow else { return event }
            return self.handleKey(event) ? nil : event
        }

        // Clicking another application should close the panel instead of leaving it behind.
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            guard let self, self.isVisible else { return }
            DispatchQueue.main.async { self.dismiss() }
        }
    }

    private func removeMonitors() {
        if let localMonitor {
            NSEvent.removeMonitor(localMonitor)
            self.localMonitor = nil
        }
        if let globalMonitor {
            NSEvent.removeMonitor(globalMonitor)
            self.globalMonitor = nil
        }
    }

    /// Returns true when the event was consumed by the panel.
    private func handleKey(_ event: NSEvent) -> Bool {
        switch Int(event.keyCode) {
        case 125: // Down
            controller.move(by: 1)
            return true
        case 126: // Up
            controller.move(by: -1)
            return true
        case 48: // Tab
            controller.move(by: event.modifierFlags.contains(.shift) ? -1 : 1)
            return true
        case 36, 76: // Return, Enter
            controller.openSelected()
            return true
        case 53: // Escape
            dismiss()
            return true
        default:
            return false
        }
    }
}

/// The panel's content: one search field, a short result list, and a hint bar.
struct SpotlightView: View {
    @ObservedObject var controller: SpotlightController

    @FocusState private var isFieldFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            searchField
            if controller.results.isEmpty {
                noResults
            } else {
                resultsList
            }
            hintBar
        }
        .frame(width: spotlightPanelWidth)
        .background(
            RoundedRectangle(cornerRadius: 14)
                .fill(.regularMaterial)
        )
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .overlay {
            RoundedRectangle(cornerRadius: 14)
                .stroke(Color.white.opacity(0.20), lineWidth: 1)
        }
        .onAppear {
            focusField()
        }
        // The view is created once and reused, so refocus on every presentation.
        .onReceive(NotificationCenter.default.publisher(for: .spotlightPanelDidPresent)) { _ in
            focusField()
        }
    }

    private func focusField() {
        // Focus slightly after the panel becomes key so the field is ready to type.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            isFieldFocused = true
        }
    }

    private var searchField: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(.secondary)

            TextField(L10n.shared.t("搜索应用…"), text: $controller.query)
                .textFieldStyle(.plain)
                .font(.system(size: 18, weight: .regular))
                .focused($isFieldFocused)
                .onSubmit { controller.openSelected() }

            Text(controller.shortcutHint)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 7)
                .padding(.vertical, 3)
                .background(Color.primary.opacity(0.07), in: RoundedRectangle(cornerRadius: 5))
        }
        .padding(.horizontal, 16)
        .frame(height: 54)
    }

    private var resultsList: some View {
        ScrollView(.vertical, showsIndicators: false) {
            LazyVStack(spacing: 2) {
                ForEach(Array(controller.results.enumerated()), id: \.element.id) { index, app in
                    SpotlightRow(
                        app: app,
                        isSelected: index == controller.selectedIndex
                    ) {
                        controller.open(app)
                    }
                    .onHover { isHovering in
                        if isHovering { controller.select(index) }
                    }
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
        }
        .frame(maxHeight: 8 * SpotlightRow.rowHeight)
    }

    private var noResults: some View {
        VStack(spacing: 6) {
            L10nText("没有匹配的应用")
                .font(.system(size: 13, weight: .semibold))
            L10nText("试试应用名、拼音全拼或首字母，例如“wx”")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, minHeight: 76)
    }

    private var hintBar: some View {
        HStack(spacing: 14) {
            hint("↑↓", L10n.shared.t("选择"))
            hint("⏎", L10n.shared.t("打开"))
            hint("esc", L10n.shared.t("关闭"))
            Spacer()
            L10nText("应用架")
                .font(.system(size: 10, weight: .semibold, design: .rounded))
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 16)
        .frame(height: 30)
        .background(Color.primary.opacity(0.04))
    }

    private func hint(_ key: String, _ title: String) -> some View {
        HStack(spacing: 5) {
            Text(key)
                .font(.system(size: 10, weight: .semibold))
                .padding(.horizontal, 5)
                .padding(.vertical, 2)
                .background(Color.primary.opacity(0.08), in: RoundedRectangle(cornerRadius: 4))
            Text(title)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
        }
    }
}

/// One result row: icon, name, and a short subtitle with size and running state.
private struct SpotlightRow: View {
    static let rowHeight: CGFloat = 52

    let app: AppItem
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 11) {
                Image(nsImage: IconCache.shared.image(for: app.path))
                    .resizable()
                    .interpolation(.high)
                    .frame(width: 34, height: 34)

                VStack(alignment: .leading, spacing: 2) {
                    Text(app.name)
                        .font(.system(size: 13.5, weight: .semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)

                    HStack(spacing: 6) {
                        if app.isRunning {
                            Circle()
                                .fill(AppShelfPalette.success)
                                .frame(width: 5, height: 5)
                            L10nText("运行中")
                                .font(.system(size: 10.5, weight: .medium))
                                .foregroundStyle(AppShelfPalette.success)
                        }
                        Text(L10n.shared.t(app.category))
                            .font(.system(size: 10.5))
                            .foregroundStyle(.secondary)
                    }
                }

                Spacer(minLength: 8)

                if isSelected {
                    Image(systemName: "return")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 10)
            .frame(height: SpotlightRow.rowHeight)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                RoundedRectangle(cornerRadius: 8)
                    .fill(isSelected ? AppShelfPalette.accent.opacity(0.16) : Color.clear)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
