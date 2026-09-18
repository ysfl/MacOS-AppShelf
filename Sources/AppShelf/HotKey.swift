import AppKit
import Carbon.HIToolbox
import Foundation

import AppShelfCore

// Re-exported so the app target can spell `HotKey` without qualifying it.
typealias HotKey = AppShelfCore.HotKey

extension HotKey {
    /// Builds a shortcut from the plain values the recorder extracted out of its key event.
    ///
    /// Takes the pieces rather than the `NSEvent`: the event is not `Sendable`, and the
    /// recorder reaches this from a main-actor hop. Main-actor isolated because the
    /// fallback key label resolves through the translation table.
    @MainActor
    init(keyCode: UInt16, cocoaModifiers: NSEvent.ModifierFlags, characters: String) {
        let modifiers = KeyModifiers(cocoaFlags: cocoaModifiers)
        self.init(keyCode: UInt32(keyCode),
                  carbonModifiers: modifiers.carbonMask,
                  display: HotKeyDisplay.string(modifiers: modifiers,
                                                keyCode: keyCode,
                                                characters: characters,
                                                unknownKeyLabel: { L10n.shared.t("key_code", args: ["n": "\($0)"]) }))
    }
}

extension KeyModifiers {
    /// Maps the Cocoa modifier set onto the script-independent one used by the codec.
    init(cocoaFlags flags: NSEvent.ModifierFlags) {
        var result: KeyModifiers = []
        if flags.contains(.command) { result.insert(.command) }
        if flags.contains(.option) { result.insert(.option) }
        if flags.contains(.control) { result.insert(.control) }
        if flags.contains(.shift) { result.insert(.shift) }
        self = result
    }
}

/// Registers the hotkey with Carbon so the panel can be opened from any app.
@MainActor
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
        if status != noErr {
            ShelfLog.hotkey.error("Carbon refused keyCode \(shortcut.keyCode) with modifiers \(shortcut.carbonModifiers): OSStatus \(status). Usually another app owns it.")
        }
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
@MainActor
final class HotKeyStore: ObservableObject {
    static let shared = HotKeyStore()

    /// The shortcut in force. `.disabled` is a real, persisted choice, not a missing value.
    @Published var shortcut: HotKey {
        didSet { persistShortcut() }
    }

    @Published var showsStatusItem: Bool {
        didSet { UserDefaults.standard.set(showsStatusItem, forKey: ShelfDefaults.statusItem) }
    }

    /// Set when Carbon refuses a registration, so the settings UI can explain it.
    @Published var registrationFailed = false

    private init() {
        // `.disabled` used to fall into the same branch as "nothing stored", which quietly
        // handed ⌥Space back on every launch and made 停用 last only for one session.
        switch HotKeyCodec.decode(UserDefaults.standard.data(forKey: ShelfDefaults.hotKey)) {
        case .enabled(let saved): shortcut = saved
        case .disabled: shortcut = .disabled
        case .unset: shortcut = .fallback
        }
        showsStatusItem = UserDefaults.standard.object(forKey: ShelfDefaults.statusItem) as? Bool ?? true
    }

    func restoreDefault() { shortcut = .fallback }

    func clear() { shortcut = .disabled }

    private func persistShortcut() {
        guard let data = HotKeyCodec.encode(shortcut) else {
            ShelfLog.hotkey.error("Shortcut could not be encoded; the choice will not survive relaunch.")
            return
        }
        UserDefaults.standard.set(data, forKey: ShelfDefaults.hotKey)
    }
}
