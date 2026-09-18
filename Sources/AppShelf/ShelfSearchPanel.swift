import AppKit
import Combine
import SwiftUI
import UniformTypeIdentifiers

import AppShelfCore

/// Shared width of the floating panel, used by both the window and its content view.
let spotlightPanelWidth: CGFloat = 660

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
