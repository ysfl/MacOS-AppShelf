import Foundation
import SwiftUI
import AppKit
import Combine

import AppShelfCore

/// Controls the app-wide appearance: follow the OS, force light, or force dark.
final class Appearance: ObservableObject {
    static let shared = Appearance()

    @Published var mode: AppearanceMode {
        didSet {
            guard oldValue != mode else { return }
            UserDefaults.standard.set(mode.rawValue, forKey: ShelfDefaults.appearance)
            apply()
        }
    }

    private init() {
        let raw = UserDefaults.standard.string(forKey: ShelfDefaults.appearance) ?? "system"
        self.mode = AppearanceMode(rawValue: raw) ?? .system
    }

    /// Apply the current mode to the whole app. Call once at launch.
    func apply() {
        switch mode {
        case .system: NSApp.appearance = nil
        case .light: NSApp.appearance = NSAppearance(named: .aqua)
        case .dark: NSApp.appearance = NSAppearance(named: .darkAqua)
        }
    }
}

enum AppearanceMode: String, CaseIterable {
    case system
    case light
    case dark

    var titleKey: String {
        switch self {
        case .system: return "appearance.system"
        case .light: return "appearance.light"
        case .dark: return "appearance.dark"
        }
    }

    var symbol: String {
        switch self {
        case .system: return "circle.lefthalf.filled"
        case .light: return "sun.max.fill"
        case .dark: return "moon.fill"
        }
    }
}
