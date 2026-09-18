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
