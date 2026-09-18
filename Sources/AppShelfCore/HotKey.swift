import Foundation

/// A global shortcut for the Spotlight-style search panel.
///
/// `keyCode` is a virtual key code and `carbonModifiers` is a Carbon modifier mask.
/// The mask values are inlined because `AppShelfCore` must not link Carbon; they are part
/// of Carbon's stable ABI (`cmdKey`, `shiftKey`, `optionKey`, `controlKey`).
public struct HotKey: Codable, Equatable, Hashable, Sendable {
    /// The sentinel keyCode meaning "the user switched the shortcut off".
    public static let disabledKeyCode: UInt32 = .max

    public var keyCode: UInt32
    public var carbonModifiers: UInt32
    /// What the recorder shows. Empty for a disabled key: the UI resolves the label from
    /// the current language instead of reading a string baked in when the app launched.
    public var display: String

    public init(keyCode: UInt32, carbonModifiers: UInt32, display: String) {
        self.keyCode = keyCode
        self.carbonModifiers = carbonModifiers
        self.display = display
    }

    public var isEnabled: Bool { keyCode != Self.disabledKeyCode }

    /// Option-Space, the same space many launchers use and one Spotlight leaves free.
    public static let fallback = HotKey(keyCode: 49, carbonModifiers: CarbonModifier.option, display: "⌥Space")

    /// A shortcut the user switched off. `display` stays empty on purpose so a language
    /// switch after launch cannot leave a stale label on screen.
    public static let disabled = HotKey(keyCode: HotKey.disabledKeyCode, carbonModifiers: 0, display: "")
}

/// Carbon modifier masks used by `RegisterEventHotKey`.
public enum CarbonModifier {
    public static let command: UInt32 = 256
    public static let shift: UInt32 = 512
    public static let option: UInt32 = 2048
    public static let control: UInt32 = 4096
}

/// Script-independent modifier set, so the recorder's output can be tested without AppKit.
public struct KeyModifiers: OptionSet, Equatable, Sendable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }

    public static let command = KeyModifiers(rawValue: 1 << 0)
    public static let option = KeyModifiers(rawValue: 1 << 1)
    public static let control = KeyModifiers(rawValue: 1 << 2)
    public static let shift = KeyModifiers(rawValue: 1 << 3)

    /// Ordered the way macOS writes them: ⌃  ⇧ ⌘.
    public var symbolPrefix: String {
        var text = ""
        if contains(.control) { text += "⌃" }
        if contains(.option) { text += "⌥" }
        if contains(.shift) { text += "⇧" }
        if contains(.command) { text += "⌘" }
        return text
    }

    public var carbonMask: UInt32 {
        var mask: UInt32 = 0
        if contains(.command) { mask |= CarbonModifier.command }
        if contains(.shift) { mask |= CarbonModifier.shift }
        if contains(.option) { mask |= CarbonModifier.option }
        if contains(.control) { mask |= CarbonModifier.control }
        return mask
    }
}

/// Builds the human-readable form of a shortcut.
public enum HotKeyDisplay {
    /// Virtual key codes that have no printable character of their own.
    public static let specialKeyNames: [Int: String] = [
        36: "↩", 76: "⌤", 48: "⇥", 49: "Space", 51: "⌫", 53: "⎋", 117: "⌦",
        115: "↖", 119: "↘", 116: "⇞", 121: "⇟",
        123: "←", 124: "→", 125: "↓", 126: "↑",
        122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5", 97: "F6",
        98: "F7", 100: "F8", 101: "F9", 109: "F10", 103: "F11", 111: "F12"
    ]

    /// The key's own glyph, or `nil` when the caller should fall back to a localized
    /// "key 123" style label.
    public static func keyName(keyCode: UInt16, characters: String) -> String? {
        if let named = specialKeyNames[Int(keyCode)] { return named }
        let upper = characters.uppercased()
        return upper.isEmpty ? nil : upper
    }

    public static func string(modifiers: KeyModifiers, keyCode: UInt16, characters: String,
                              unknownKeyLabel: (UInt16) -> String) -> String {
        let key = keyName(keyCode: keyCode, characters: characters) ?? unknownKeyLabel(keyCode)
        return modifiers.symbolPrefix + key
    }
}

/// The three things a stored shortcut can turn out to be.
///
/// Distinguishing `.disabled` from `.unset` is the whole point: the previous decoder
/// collapsed them, which meant "switch the shortcut off" silently came back as ⌥Space on
/// the next launch.
public enum StoredHotKey: Equatable, Sendable {
    case enabled(HotKey)
    case disabled
    /// Nothing persisted, or a payload we cannot read: fall back to the default.
    case unset
}

public enum HotKeyCodec {
    public static func encode(_ shortcut: HotKey) -> Data? {
        try? JSONEncoder().encode(shortcut)
    }

    public static func decode(_ data: Data?) -> StoredHotKey {
        guard let data, let saved = try? JSONDecoder().decode(HotKey.self, from: data) else {
            return .unset
        }
        return saved.isEnabled ? .enabled(saved) : .disabled
    }
}
