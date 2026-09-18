import AppKit
import Carbon.HIToolbox
import Foundation

/// A global shortcut for the Spotlight-style search panel.
/// `keyCode` is a virtual key code and `carbonModifiers` is a Carbon modifier mask.
struct HotKey: Codable, Equatable, Sendable {
    var keyCode: UInt32
    var carbonModifiers: UInt32
    var display: String

    /// Option-Space, the same space many launchers use and one Spotlight leaves free.
    static let fallback = HotKey(keyCode: UInt32(kVK_Space), carbonModifiers: UInt32(optionKey), display: "⌥Space")

    /// The recorder writes this when the user clears the shortcut.
    static let disabled = HotKey(keyCode: UInt32.max, carbonModifiers: 0, display: L10n.shared.t("未设置"))

    var isEnabled: Bool { keyCode != UInt32.max }
}

extension HotKey {
    init(event: NSEvent) {
        self.keyCode = UInt32(event.keyCode)
        self.carbonModifiers = Self.carbonFlags(from: event.modifierFlags)
        self.display = Self.displayString(
            modifiers: event.modifierFlags,
            keyCode: event.keyCode,
            characters: event.charactersIgnoringModifiers ?? ""
        )
    }

    /// Converts Cocoa modifier flags to the Carbon mask `RegisterEventHotKey` expects.
    static func carbonFlags(from flags: NSEvent.ModifierFlags) -> UInt32 {
        var carbon: UInt32 = 0
        if flags.contains(.command) { carbon |= UInt32(cmdKey) }
        if flags.contains(.shift) { carbon |= UInt32(shiftKey) }
        if flags.contains(.option) { carbon |= UInt32(optionKey) }
        if flags.contains(.control) { carbon |= UInt32(controlKey) }
        return carbon
    }

    /// Builds the visible combination, e.g. "⌥⇧A".
    static func displayString(modifiers: NSEvent.ModifierFlags, keyCode: UInt16, characters: String) -> String {
        var prefix = ""
        if modifiers.contains(.control) { prefix += "⌃" }
        if modifiers.contains(.option) { prefix += "⌥" }
        if modifiers.contains(.shift) { prefix += "⇧" }
        if modifiers.contains(.command) { prefix += "⌘" }
        return prefix + keyName(keyCode: keyCode, characters: characters)
    }

    static func keyName(keyCode: UInt16, characters: String) -> String {
        if let named = specialKeyNames[Int(keyCode)] { return named }
        let upper = characters.uppercased()
        return upper.isEmpty ? L10n.shared.t("key_code", args: ["n": "\(keyCode)"]) : upper
    }

    private static let specialKeyNames: [Int: String] = [
        36: "↩", 76: "⌤", 48: "⇥", 49: "Space", 51: "⌫", 53: "⎋", 117: "⌦",
        115: "↖", 119: "↘", 116: "⇞", 121: "⇟",
        123: "←", 124: "→", 125: "↓", 126: "↑",
        122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5", 97: "F6",
        98: "F7", 100: "F8", 101: "F9", 109: "F10", 103: "F11", 111: "F12"
    ]
}

/// Registers the hotkey with Carbon so the panel can be opened from any app.
final class HotKeyCenter {
    static let shared = HotKeyCenter()

    private let signature: OSType = 0x4150_5348 // 'APSH'
    private let identifier: UInt32 = 1

    private var reference: EventHotKeyRef?
    private var handler: EventHandlerRef?
    private var isHandlerInstalled = false

    /// Invoked on the main thread when the shortcut fires.
    var onTrigger: (() -> Void)?

    /// Registers `shortcut`, replacing the previous registration. Returns false when the
    /// system refused the combination, which usually means another app already owns it.
    @discardableResult
    func register(_ shortcut: HotKey) -> Bool {
        installHandler()
        unregister()

        guard shortcut.isEnabled else { return true }

        let hotKeyID = EventHotKeyID(signature: signature, id: identifier)
        let status = RegisterEventHotKey(
            shortcut.keyCode,
            shortcut.carbonModifiers,
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &reference
        )
        return status == noErr
    }

    func unregister() {
        if let reference {
            UnregisterEventHotKey(reference)
            self.reference = nil
        }
    }

    private func installHandler() {
        guard !isHandlerInstalled else { return }
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let status = InstallEventHandler(
            GetApplicationEventTarget(),
            { _, _, _ -> OSStatus in
                DispatchQueue.main.async { HotKeyCenter.shared.onTrigger?() }
                return noErr
            },
            1,
            &spec,
            nil,
            &handler
        )
        isHandlerInstalled = status == noErr
    }
}

/// Persists the shortcut and the menu-bar preference so both scenes read the same values.
final class HotKeyStore: ObservableObject {
    static let shared = HotKeyStore()

    private enum Key {
        static let shortcut = "AppShelf.hotkey.v1"
        static let statusItem = "AppShelf.statusItem.v1"
    }

    @Published var shortcut: HotKey {
        didSet { persistShortcut() }
    }

    @Published var showsStatusItem: Bool {
        didSet { UserDefaults.standard.set(showsStatusItem, forKey: Key.statusItem) }
    }

    /// Set when Carbon refuses a registration, so the settings UI can explain it.
    @Published var registrationFailed = false

    private init() {
        if let data = UserDefaults.standard.data(forKey: Key.shortcut),
           let saved = try? JSONDecoder().decode(HotKey.self, from: data),
           saved.isEnabled {
            shortcut = saved
        } else {
            shortcut = .fallback
        }
        showsStatusItem = UserDefaults.standard.object(forKey: Key.statusItem) as? Bool ?? true
    }

    func restoreDefault() {
        shortcut = .fallback
    }

    func clear() {
        shortcut = .disabled
    }

    private func persistShortcut() {
        guard let data = try? JSONEncoder().encode(shortcut) else { return }
        UserDefaults.standard.set(data, forKey: Key.shortcut)
    }
}
