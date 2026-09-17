import AppKit
import SwiftUI

/// Captures a key combination while the settings window is key.
final class ShortcutRecorderCoordinator {
    private var monitor: Any?

    /// Starts recording. `onResult` receives `nil` when the user cancels with Escape.
    func start(onResult: @escaping (HotKey?) -> Void) {
        stop()
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { event in
            if Int(event.keyCode) == 53 {
                DispatchQueue.main.async { onResult(nil) }
                return nil
            }
            // A bare letter would be indistinguishable from normal typing, so require a modifier.
            let modifiers = event.modifierFlags.intersection([.command, .option, .control, .shift])
            guard !modifiers.isEmpty else { return nil }
            let shortcut = HotKey(event: event)
            DispatchQueue.main.async { onResult(shortcut) }
            return nil
        }
    }

    func stop() {
        if let monitor {
            NSEvent.removeMonitor(monitor)
            self.monitor = nil
        }
    }
}

/// A button that records a global shortcut when pressed.
struct ShortcutRecorderView: View {
    @Binding var shortcut: HotKey

    @State private var isRecording = false
    @State private var message: String?
    @State private var coordinator = ShortcutRecorderCoordinator()

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Button {
                    toggleRecording()
                } label: {
                    Text(isRecording ? "按下组合键…" : shortcut.display)
                        .font(.system(size: 13, weight: .semibold, design: .rounded))
                        .frame(minWidth: 108)
                }
                .controlSize(.large)

                Button("恢复默认") {
                    coordinator.stop()
                    isRecording = false
                    shortcut = HotKey.fallback
                    message = nil
                }
                .disabled(shortcut == HotKey.fallback)

                if shortcut.isEnabled {
                    Button("清除") {
                        coordinator.stop()
                        isRecording = false
                        shortcut = HotKey.disabled
                        message = "已停用全局快捷键"
                    }
                }
            }

            if let message {
                Text(message)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            } else if isRecording {
                Text("请按住 ⌘ / ⌥ / ⌃ / ⇧ 中的至少一个，esc 取消")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
        }
        .onDisappear { coordinator.stop() }
    }

    private func toggleRecording() {
        if isRecording {
            coordinator.stop()
            isRecording = false
            return
        }

        isRecording = true
        message = nil
        coordinator.start { result in
            isRecording = false
            if let result {
                shortcut = result
                message = nil
            } else {
                message = "已取消"
            }
        }
    }
}

/// Owns the settings window.
///
/// The window is created directly with AppKit so the same entry point works from the
/// toolbar, the Dock menu, and the menu bar icon, instead of relying on a private action.
final class SettingsWindowController: NSWindowController {
    static let shared = SettingsWindowController()

    private init() {
        let view = SettingsView()
        let hosting = NSHostingView(rootView: view)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 430, height: 470),
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "设置"
        window.contentView = hosting
        window.setContentSize(NSSize(width: 430, height: 640))
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
        window?.makeKeyAndOrderFront(nil)
    }
}

/// Preferences for the search panel, the menu bar icon, and cached usage data.
struct SettingsView: View {
    @ObservedObject private var hotKeys = HotKeyStore.shared
    @ObservedObject private var quickTools = QuickToolStore.shared

    /// Built-ins and user tools that are currently hidden from the sidebar.
    private var hiddenTools: [QuickToolItem] {
        quickTools.allItems.filter { !quickTools.isEnabled($0.id) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 3) {
                Text("设置")
                    .font(.system(size: 22, weight: .semibold, design: .rounded))
                Text("快捷键、菜单栏图标和应用占用统计")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }

            GroupBox {
                VStack(alignment: .leading, spacing: 10) {
                    Text("聚焦搜索快捷键")
                        .font(.system(size: 12, weight: .semibold))
                    ShortcutRecorderView(shortcut: $hotKeys.shortcut)
                    Text("按下这个组合键会在任何应用中唤出搜索框，输入后回车即可打开应用。")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                    if hotKeys.registrationFailed {
                        Text("系统没有接受这个组合键，可能被其他应用占用了，换一个试试。")
                            .font(.system(size: 11))
                            .foregroundStyle(Color.red)
                    }
                }
                .padding(6)
            } label: {
                Text("快捷键")
            }

            GroupBox {
                VStack(alignment: .leading, spacing: 10) {
                    Toggle("显示菜单栏图标", isOn: $hotKeys.showsStatusItem)
                        .font(.system(size: 12, weight: .semibold))
                    Text("菜单栏图标可以打开搜索框、应用架窗口和本设置面板。")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                .padding(6)
            } label: {
                Text("菜单栏")
            }

            GroupBox {
                VStack(alignment: .leading, spacing: 10) {
                    // Visible tools follow the stored order; the arrows move one slot.
                    ForEach(quickTools.items) { item in
                        HStack(spacing: 8) {
                            Image(systemName: item.symbol ?? "app.dashed")
                                .font(.system(size: 12, weight: .medium))
                                .foregroundStyle(.secondary)
                                .frame(width: 16)

                            Text(item.title)
                                .font(.system(size: 12))
                                .lineLimit(1)

                            Spacer(minLength: 0)

                            Button {
                                quickTools.move(item.id, by: -1)
                            } label: {
                                Image(systemName: "arrow.up")
                            }
                            .buttonStyle(.borderless)
                            .disabled(quickTools.items.first?.id == item.id)

                            Button {
                                quickTools.move(item.id, by: 1)
                            } label: {
                                Image(systemName: "arrow.down")
                            }
                            .buttonStyle(.borderless)
                            .disabled(quickTools.items.last?.id == item.id)

                            Button {
                                quickTools.setEnabled(item.id, isEnabled: false)
                            } label: {
                                Image(systemName: "minus.circle")
                            }
                            .buttonStyle(.borderless)
                            .help("隐藏")
                        }
                    }

                    if quickTools.items.isEmpty {
                        Text("还没有显示任何快捷工具")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }

                    Divider()

                    VStack(alignment: .leading, spacing: 6) {
                        Text("添加或隐藏")
                            .font(.system(size: 12, weight: .semibold))

                        ForEach(hiddenTools) { item in
                            HStack(spacing: 8) {
                                Text(item.title)
                                    .font(.system(size: 12))
                                    .lineLimit(1)
                                Spacer(minLength: 0)
                                Button("显示") {
                                    quickTools.setEnabled(item.id, isEnabled: true)
                                }
                                .buttonStyle(.borderless)
                                if item.isCustom {
                                    Button {
                                        if case .custom(let tool) = item {
                                            quickTools.removeCustom(id: tool.id)
                                        }
                                    } label: {
                                        Image(systemName: "trash")
                                    }
                                    .buttonStyle(.borderless)
                                    .help("删除")
                                }
                            }
                        }

                        Button("添加应用为快捷工具…", action: addQuickToolApp)
                    }

                    Text("快捷工具显示在侧边栏和“全部应用”顶部；可以把常用应用加进来。")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                .padding(6)
            } label: {
                Text("快捷工具")
            }

            GroupBox {
                VStack(alignment: .leading, spacing: 10) {
                    Button("重新计算磁盘占用") {
                        AppMetrics.shared.recalculate()
                    }
                    Text("占用量在后台测量并缓存。更新或卸载应用后可以重新计算一次。")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                .padding(6)
            } label: {
                Text("应用占用")
            }

            Spacer(minLength: 0)
        }
        .padding(22)
        .frame(width: 430, height: 640)
    }

    /// Picks a bundle to pin as a quick tool, the same way apps are added to a group.
    private func addQuickToolApp() {
        let panel = NSOpenPanel()
        panel.title = "添加快捷工具"
        panel.message = "选择一个 .app"
        panel.allowedContentTypes = [.applicationBundle]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.resolvesAliases = true

        guard panel.runModal() == .OK, let url = panel.url else { return }
        let name = (Bundle(url: url)?.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
            ?? url.deletingPathExtension().lastPathComponent
        quickTools.addCustom(name: name, path: url.standardizedFileURL.path)
    }
}
