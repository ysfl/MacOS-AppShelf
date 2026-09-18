import Foundation

/// The starter groups and the keyword rules that seed them.
///
/// The raw value doubles as the persisted group name and as the translation key, so
/// renaming a built-in group stays a display concern rather than a data migration.
public enum ShelfCategory: String, CaseIterable, Sendable {
    case common = "常用"
    case development = "开发"
    case communication = "沟通"
    case creative = "创作"
    case everyday = "日常"
    case utility = "工具"
    case other = "其他"
}

/// Classifies a freshly discovered bundle into a starter group.
///
/// Deliberately keyword-based and conservative: users can change group membership, so a
/// wrong initial category never changes what an app does.
public enum AppCategorizer {
    /// Apps pulled into 常用 regardless of what their names contain.
    public static let commonNames: Set<String> = [
        "safari", "google chrome", "visual studio code", "xcode", "terminal", "chatgpt", "obsidian"
    ]

    public static func category(name: String, bundleIdentifier: String?) -> ShelfCategory {
        let normalizedName = name.lowercased()
        let normalizedIdentifier = (bundleIdentifier ?? "").lowercased()
        let text = "\(normalizedName) \(normalizedIdentifier)"
        // Multi-word rules are also tried against a space-free copy: 活动监视器 reports
        // "com.apple.ActivityMonitor", which contains no space for "activity monitor".
        let compactText = text.filter { !$0.isWhitespace }

        let isCodeEditor = normalizedName == "code"
            || normalizedName.contains("visual studio code")
            || normalizedName.contains("codex")
            || normalizedName.contains("claude code")
            || normalizedIdentifier.contains("vscode")
            || normalizedIdentifier.contains("visualstudio")

        if isCodeEditor || containsAny(text, compactText, ["xcode", "android studio", "hbuilder", "dbeaver", "mqtt", "redis", "sequel", "fork", "docker", "terminal", "termius", "transmit", "postman", "charles", "reqable"]) {
            return .development
        }
        if containsAny(text, compactText, ["wechat", "qq", "telegram", "discord", "dingtalk", "lark", "slack", "meeting", "teams", "chatgpt", "claude", "doubao", "qianwen", "workbuddy"]) {
            return .communication
        }
        if containsAny(text, compactText, ["photoshop", "illustrator", "figma", "sketch", "keynote", "powerpoint", "premiere", "after effects", "pixelmator"]) {
            return .creative
        }
        if containsAny(text, compactText, ["safari", "chrome", "firefox", "arc", "edge", "browser", "obsidian", "notion", "word", "excel", "numbers", "pages", "quark", "baidu", "netdisk"]) {
            return .everyday
        }
        if containsAny(text, compactText, ["calculator", "activity monitor", "screenshot", "system preferences", "system settings", "disk utility", "cleanmymac", "keka", "archive", "battery", "clash", "wireguard", "sunlogin", "utilities"]) {
            return .utility
        }
        return .other
    }

    private static func containsAny(_ text: String, _ compactText: String, _ values: [String]) -> Bool {
        for value in values {
            if text.contains(value) { return true }
            if value.contains(" "), compactText.contains(value.filter { !$0.isWhitespace }) { return true }
        }
        return false
    }

    /// Which starter group a discovered app is seeded into, or `nil` to leave it ungrouped.
    ///
    /// `other` is intentionally not seeded: an app nobody recognized belongs in 未分组,
    /// where the user will notice it, rather than buried in a group called 其他.
    public static func seedGroup(for name: String, bundleIdentifier: String?) -> ShelfCategory? {
        if commonNames.contains(name.lowercased()) { return .common }
        let detected = category(name: name, bundleIdentifier: bundleIdentifier)
        return detected == .other ? nil : detected
    }
}
