import AppKit
import Foundation

import AppShelfCore

/// Apple utilities that can be launched even when they are not in the app grid.
enum QuickTool: String, CaseIterable, Identifiable {
    case calculator
    case terminal
    case activityMonitor
    case screenshot
    case systemSettings

    var id: String { rawValue }

    var title: String {
        switch self {
        case .calculator: return L10n.shared.t("计算器")
        case .terminal: return L10n.shared.t("终端")
        case .activityMonitor: return L10n.shared.t("活动监视器")
        case .screenshot: return L10n.shared.t("截图")
        case .systemSettings: return L10n.shared.t("系统设置")
        }
    }

    var symbol: String {
        switch self {
        case .calculator: return "plus.forwardslash.minus"
        case .terminal: return "apple.terminal"
        case .activityMonitor: return "waveform.path.ecg"
        case .screenshot: return "rectangle.dashed.and.paperclip"
        case .systemSettings: return "gearshape"
        }
    }

    var bundleIdentifier: String {
        switch self {
        case .calculator: return "com.apple.calculator"
        case .terminal: return "com.apple.Terminal"
        case .activityMonitor: return "com.apple.ActivityMonitor"
        case .screenshot: return "com.apple.screenshot"
        case .systemSettings: return "com.apple.systempreferences"
        }
    }

    var fallbackPaths: [String] {
        switch self {
        case .calculator:
            return ["/System/Applications/Calculator.app"]
        case .terminal:
            return ["/System/Applications/Utilities/Terminal.app"]
        case .activityMonitor:
            return ["/System/Applications/Utilities/Activity Monitor.app"]
        case .screenshot:
            return [
                "/System/Applications/Utilities/Screenshot.app",
                "/System/Applications/Screenshot.app"
            ]
        case .systemSettings:
            return ["/System/Applications/System Settings.app"]
        }
    }
}

/// The SF Symbols offered when naming a group.
enum GroupSymbolCatalog {
    /// Every symbol here is verified to exist on macOS 14; the picker filters this list by
    /// what `NSImage(systemSymbolName:)` can actually resolve, so a rename cannot leave a
    /// group with a blank icon.
    static let candidates: [String] = [
        "star.fill", "folder.fill", "hammer.fill", "bubble.left.fill", "wand.and.stars",
        "house.fill", "wrench.and.screwdriver.fill", "book.fill", "music.note", "gamecontroller.fill",
        "camera.fill", "doc.fill", "network", "globe", "heart.fill",
        "briefcase.fill", "cart.fill", "graduationcap.fill", "leaf.fill", "flame.fill",
        "cpu.fill", "cloud.fill", "lock.fill", "paintpalette.fill", "play.tv.fill",
        "banknote.fill", "gift.fill", "airplane", "bell.fill", "magnifyingglass",
        "checklist", "cpu", "desktopcomputer", "externaldrive.fill", "gamecontroller",
        "lightbulb.fill", "mail.fill", "map.fill", "moon.fill", "person.2.fill",
        "phone.fill", "puzzlepiece.extension.fill", "shippingbox.fill", "sparkles",
        "sun.max.fill", "theatermasks.fill", "tray.full.fill", "tv.fill", "circle.grid.2x2.fill"
    ]

    /// Symbols the running system can draw, preserving the list order.
    static var available: [String] {
        candidates.filter { NSImage(systemSymbolName: $0, accessibilityDescription: nil) != nil }
    }
}
