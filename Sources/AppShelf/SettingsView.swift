import AppKit
import SwiftUI
import UniformTypeIdentifiers

import AppShelfCore

/// Captures a key combination while the settings window is key.
@MainActor
final class ShortcutRecorderCoordinator {
    private var monitor: Any?

    /// Starts recording. `onResult` receives `nil` when the user cancels with Escape.
    ///
    /// The monitor hands us a `@Sendable` closure on an arbitrary thread and `NSEvent` is
    /// not `Sendable`, so the event is reduced to plain values before the hop instead of
    /// being carried across it. The callback is promised back on the main actor.
    func start(onResult: @escaping @MainActor @Sendable (HotKey?) -> Void) {
        stop()
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { event in
            let keyCode = event.keyCode
            let modifiers = event.modifierFlags.intersection([.command, .option, .control, .shift])
            let characters = event.charactersIgnoringModifiers ?? ""
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    if Int(keyCode) == 53 {
                        onResult(nil)
                        return
                    }
                    // A bare letter would be indistinguishable from normal typing, so require a modifier.
                    guard !modifiers.isEmpty else { return }
                    onResult(HotKey(keyCode: keyCode, cocoaModifiers: modifiers, characters: characters))
                }
            }
            // Every key press is consumed while recording; the recorder owns the keyboard.
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
                    Text(displayText)
                        .font(.system(size: 13, weight: .semibold, design: .rounded))
                        .frame(minWidth: 108)
                }
                .controlSize(.large)
                .accessibilityLabel(L10n.shared.t("聚焦搜索快捷键"))

                Button(L10n.shared.t("恢复默认")) {
                    stopRecording()
                    shortcut = .fallback
                    message = nil
                }
                .disabled(shortcut == HotKey.fallback)

                if shortcut.isEnabled {
                    Button(L10n.shared.t("清除")) {
                        stopRecording()
                        shortcut = .disabled
                        message = L10n.shared.t("已停用全局快捷键")
                    }
                }
            }

            if let message {
                Text(message)
                    .font(.shelfMeta)
                    .foregroundStyle(.secondary)
            } else if isRecording {
                Text(L10n.shared.t("请按住 ⌘ / ⌥ / ⌃ / ⇧ 中的至少一个，esc 取消"))
                    .font(.shelfMeta)
                    .foregroundStyle(.secondary)
            }
        }
        .onDisappear { coordinator.stop() }
    }

    /// A disabled shortcut has no stored label: the settings panel used to persist whatever
    /// language was active when it was cleared, which then showed up in the wrong language.
    private var displayText: String {
        if isRecording { return L10n.shared.t("按下组合键…") }
        return shortcut.isEnabled ? shortcut.display : L10n.shared.t("未设置")
    }

    @MainActor private func stopRecording() {
        coordinator.stop()
        isRecording = false
    }

    @MainActor private func toggleRecording() {
        if isRecording {
            stopRecording()
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
                message = L10n.shared.t("已取消")
            }
        }
    }
}

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

/// Preferences for the search panel, the menu bar icon, and cached usage data.
struct SettingsView: View {
    @ObservedObject private var hotKeys = HotKeyStore.shared
    @ObservedObject private var quickTools = QuickToolStore.shared
    @ObservedObject private var metrics = AppMetrics.shared
    @ObservedObject private var l10n = L10n.shared

    /// Polled while a recalculation is running so the panel can show it winding down.
    private let progressTimer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    @State private var importReport: String?

    /// Export and import act on the same store the window shows, reached through the
    /// delegate because the settings panel is a separate AppKit window.
    private var store: LauncherStore? { AppDelegate.shared?.shelfStore }

    /// Built-ins and user tools that are currently hidden from the sidebar.
    private var hiddenTools: [QuickToolItem] {
        quickTools.allItems.filter { !quickTools.isEnabled($0.id) }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                header

                shortcutBox
                statusBarBox
                quickToolsBox
                usageBox
                languageBox
                dataBox
            }
            .padding(22)
            .frame(maxWidth: 560, alignment: .leading)
        }
        .frame(minWidth: 400, minHeight: 420)
        .background(AppShelfPalette.canvas)
        .onReceive(progressTimer) { _ in
            // Repaints the pending-measurement line while a recalculation drains.
            if metrics.pendingMeasurements > 0 { objectWillChangeTick += 1 }
        }
    }

    @State private var objectWillChangeTick = 0

    private var header: some View {
        VStack(alignment: .leading, spacing: 3) {
            L10nText("设置")
                .font(.system(size: 22, weight: .semibold, design: .rounded))
            L10nText("快捷键、菜单栏图标和应用占用统计")
                .font(.shelfCaption)
                .foregroundStyle(.secondary)
        }
    }

    private var shortcutBox: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                L10nText("聚焦搜索快捷键")
                    .font(.shelfLabel)
                ShortcutRecorderView(shortcut: $hotKeys.shortcut)
                L10nText("按下这个组合键会在任何应用中唤出搜索框，输入后回车即可打开应用。")
                    .font(.shelfMeta)
                    .foregroundStyle(.secondary)
                if hotKeys.registrationFailed {
                    L10nText("系统没有接受这个组合键，可能被其他应用占用了，换一个试试。")
                        .font(.shelfMeta)
                        .foregroundStyle(AppShelfPalette.danger)
                }
            }
            .padding(6)
        } label: {
            L10nText("快捷键")
        }
    }

    private var statusBarBox: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                Toggle(L10n.shared.t("显示菜单栏图标"), isOn: $hotKeys.showsStatusItem)
                    .font(.shelfLabel)
                L10nText("菜单栏图标可以打开搜索框、应用架窗口和本设置面板。")
                    .font(.shelfMeta)
                    .foregroundStyle(.secondary)
            }
            .padding(6)
        } label: {
            L10nText("菜单栏")
        }
    }

    private var quickToolsBox: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                // Visible tools follow the stored order; the arrows move one slot.
                ForEach(quickTools.items) { item in
                    HStack(spacing: 8) {
                        toolGlyph(for: item)
                            .frame(width: 16)
                            .accessibilityHidden(true)

                        Text(item.title)
                            .font(.shelfCaption)
                            .lineLimit(1)

                        Spacer(minLength: 0)

                        Button {
                            quickTools.move(item.id, by: -1)
                        } label: {
                            Image(systemName: "arrow.up")
                        }
                        .buttonStyle(.borderless)
                        .disabled(quickTools.items.first?.id == item.id)
                        .accessibilityLabel(L10n.shared.t("上移"))

                        Button {
                            quickTools.move(item.id, by: 1)
                        } label: {
                            Image(systemName: "arrow.down")
                        }
                        .buttonStyle(.borderless)
                        .disabled(quickTools.items.last?.id == item.id)
                        .accessibilityLabel(L10n.shared.t("下移"))

                        Button {
                            quickTools.setEnabled(item.id, isEnabled: false)
                        } label: {
                            Image(systemName: "minus.circle")
                        }
                        .buttonStyle(.borderless)
                        .accessibilityLabel(L10n.shared.t("隐藏"))
                        .help(L10n.shared.t("隐藏"))
                    }
                }

                if quickTools.items.isEmpty {
                    L10nText("还没有显示任何快捷工具")
                        .font(.shelfMeta)
                        .foregroundStyle(.secondary)
                }

                Divider()

                VStack(alignment: .leading, spacing: 6) {
                    L10nText("添加或隐藏")
                        .font(.shelfLabel)

                    ForEach(hiddenTools) { item in
                        HStack(spacing: 8) {
                            Text(item.title)
                                .font(.shelfCaption)
                                .lineLimit(1)
                            Spacer(minLength: 0)
                            Button(L10n.shared.t("显示")) {
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
                                .accessibilityLabel(L10n.shared.t("删除"))
                                .help(L10n.shared.t("删除"))
                            }
                        }
                    }

                    Button(L10n.shared.t("添加应用为快捷工具…"), action: addQuickToolApp)
                }

                L10nText("快捷工具显示在侧边栏和“全部应用”顶部；可以把常用应用加进来。")
                    .font(.shelfMeta)
                    .foregroundStyle(.secondary)
            }
            .padding(6)
        } label: {
            L10nText("快捷工具")
        }
    }

    private var usageBox: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    Button(L10n.shared.t("重新计算磁盘占用")) {
                        AppMetrics.shared.recalculate()
                    }
                    if metrics.pendingMeasurements > 0 {
                        Button(L10n.shared.t("取消")) {
                            AppMetrics.shared.cancelRecalculation()
                        }
                        .buttonStyle(.bordered)
                    }
                }

                if metrics.pendingMeasurements > 0 {
                    L10nText("recalculate_progress",
                             args: ["count": "\(metrics.pendingMeasurements)"])
                        .font(.shelfMeta)
                        .foregroundStyle(.secondary)
                }

                L10nText("占用量在后台测量并缓存。更新或卸载应用后可以重新计算一次。")
                    .font(.shelfMeta)
                    .foregroundStyle(.secondary)
            }
            .padding(6)
        } label: {
            L10nText("应用占用")
        }
    }

    private var languageBox: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                Picker(selection: Binding(get: { Appearance.shared.mode },
                                          set: { Appearance.shared.mode = $0 })) {
                    ForEach(AppearanceMode.allCases, id: \.self) { mode in
                        L10nText(mode.titleKey)
                    }
                } label: {
                    L10nText("appearance")
                }
                .pickerStyle(.segmented)

                Picker(selection: $l10n.language) {
                    ForEach(l10n.availableLanguages, id: \.self) { code in
                        if code == "system" {
                            L10nText("language.system")
                        } else {
                            Text(l10n.displayName(for: code))
                        }
                    }
                } label: {
                    L10nText("language")
                }

                VStack(alignment: .leading, spacing: 3) {
                    Text(l10n.defaultLoadPath.path)
                        .font(.system(size: 10, design: .monospaced))
                        .textSelection(.enabled)
                        .foregroundStyle(.secondary)
                    L10nText("external_localization_hint")
                        .font(.shelfMeta)
                        .foregroundStyle(.secondary)
                }

                // The documented "add a language without recompiling" workflow used to need a
                // relaunch because the folder was only ever scanned during init.
                HStack(spacing: 8) {
                    Button(L10n.shared.t("重新载入语言")) {
                        l10n.reloadExternal()
                    }
                    Text(L10n.shared.t("external_language_count",
                                       args: ["count": "\(l10n.externalLanguageCount)"]))
                        .font(.shelfMeta)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(6)
        } label: {
            L10nText("language")
        }
    }

    private var dataBox: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    Button(L10n.shared.t("导出分组设置…"), action: exportState)
                    Button(L10n.shared.t("导入分组设置…"), action: importState)
                }
                if let importReport {
                    Text(importReport)
                        .font(.shelfMeta)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
                L10nText("data_scope_hint")
                    .font(.shelfMeta)
                    .foregroundStyle(.secondary)
            }
            .padding(6)
        } label: {
            L10nText("设置备份")
        }
    }

    @ViewBuilder
    private func toolGlyph(for item: QuickToolItem) -> some View {
        if let symbol = item.symbol {
            Image(systemName: symbol)
                .font(.shelfBody)
                .foregroundStyle(.secondary)
        } else if let path = item.path {
            Image(nsImage: IconCache.shared.image(for: path))
                .resizable()
                .interpolation(.high)
                .frame(width: 16, height: 16)
        } else {
            Image(systemName: "app.dashed")
                .font(.shelfBody)
                .foregroundStyle(.secondary)
        }
    }

    /// Picks a bundle to pin as a quick tool, the same way apps are added to a group.
    private func addQuickToolApp() {
        let panel = NSOpenPanel()
        panel.title = L10n.shared.t("添加快捷工具")
        panel.message = L10n.shared.t("选择一个 .app")
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

    // MARK: Export / import

    @MainActor
    private func exportState() {
        let panel = NSSavePanel()
        panel.title = L10n.shared.t("导出分组设置")
        panel.nameFieldStringValue = "AppShelf-\(AppVersion.string).json"
        panel.allowedContentTypes = [.json]

        guard panel.runModal() == .OK, let url = panel.url, let store else { return }
        let payload = ShelfImport.encode(store.exportSnapshot(), pretty: true)
        do {
            guard let payload else { throw ShelfExportError.encodingFailed }
            try payload.write(to: url, options: .atomic)
            importReport = L10n.shared.t("export_written", args: ["path": url.path])
        } catch {
            ShelfLog.transfer.error("Export to \(url.path, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
            importReport = L10n.shared.t("export_failed", args: ["reason": error.localizedDescription])
        }
    }

    @MainActor
    private func importState() {
        let panel = NSOpenPanel()
        panel.title = L10n.shared.t("导入分组设置")
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false

        guard let store, panel.runModal() == .OK, let url = panel.url else { return }
        let payload: ShelfExport?
        do {
            payload = ShelfImport.decode(try Data(contentsOf: url))
        } catch {
            ShelfLog.transfer.error("Import from \(url.lastPathComponent, privacy: .public) could not be read: \(error.localizedDescription, privacy: .public)")
            payload = nil
        }
        guard let payload else {
            ShelfLog.transfer.error("Import rejected: \(url.lastPathComponent, privacy: .public) is not a shelf backup.")
            importReport = L10n.shared.t("import_unreadable")
            return
        }

        importReport = store.applyImport(payload) ? L10n.shared.t("import_done") : L10n.shared.t("import_refused")
    }
}

enum ShelfExportError: Error {
    case encodingFailed
}
