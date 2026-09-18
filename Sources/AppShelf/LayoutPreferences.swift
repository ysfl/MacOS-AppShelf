import Foundation
import ServiceManagement
import SwiftUI

import AppShelfCore

/// Layout choices the user makes in Settings.
@MainActor
final class LayoutPreferences: ObservableObject {
    static let shared = LayoutPreferences()

    /// Tile density. Changing it re-renders the grid and re-measures the slide geometry.
    @Published var density: GridDensity {
        didSet {
            guard oldValue != density else { return }
            UserDefaults.standard.set(density.rawValue, forKey: ShelfDefaults.gridDensity)
        }
    }

    private init() {
        let raw = UserDefaults.standard.string(forKey: ShelfDefaults.gridDensity)
        self.density = raw.flatMap(GridDensity.init(rawValue:)) ?? .defaultDensity
    }

    /// Derived once from `density` so every consumer reads the same numbers.
    private var current: GridMetricsSpec { density.spec }

    var columns: [GridItem] {
        [GridItem(.adaptive(minimum: CGFloat(current.minimum), maximum: CGFloat(current.maximum)),
                  spacing: CGFloat(current.columnSpacing))]
    }

    var rowSpacing: CGFloat { CGFloat(current.rowSpacing) }
    var columnSpacing: CGFloat { CGFloat(current.columnSpacing) }
    var minimumRowHeight: CGFloat { CGFloat(density.minimumRowHeight) }
    var iconSide: CGFloat { CGFloat(density.iconSide) }
}

/// Which app the shelf should start again at sign-in.
///
/// Backed by `SMAppService`, so the registration lives with the bundle rather than in a
/// login item the user has to notice and re-add. Failures are surfaced instead of
/// swallowed: a toggle that silently does nothing is worse than one that says it did not
/// take.
@MainActor
final class LaunchAtLogin: ObservableObject {
    static let shared = LaunchAtLogin()

    @Published private(set) var isEnabled: Bool
    @Published private(set) var lastError: String?

    private init() {
        isEnabled = SMAppService.mainApp.status == .enabled
    }

    /// Applies the choice and re-reads the real status afterwards.
    ///
    /// The service can refuse — an ad-hoc signed bundle run from a temporary folder is a
    /// common case — so the reported state comes from the system, not from the request.
    func setEnabled(_ wanted: Bool) {
        do {
            if wanted {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            lastError = nil
        } catch {
            lastError = error.localizedDescription
            ShelfLog.state.error("Launch-at-login \(wanted ? "register" : "unregister", privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
        }
        isEnabled = SMAppService.mainApp.status == .enabled
        objectWillChange.send()
    }
}

/// How often each bundle has been launched, and when last.
///
/// Only used to order results the score cannot separate, and to fill the empty-query list
/// of the floating panel. Nothing is uploaded, and clearing the shelf's state clears it.
@MainActor
final class UsageRecorder {
    static let shared = UsageRecorder()

    private struct Record: Codable {
        var count: Int
        var lastUsed: Date
    }

    private var records: [String: Record]
    private let key = ShelfDefaults.usage

    private init() {
        records = [:]
        guard let data = UserDefaults.standard.data(forKey: key) else { return }
        do {
            records = try JSONDecoder().decode([String: Record].self, from: data)
        } catch {
            // Unreadable history is dropped, not kept: otherwise it fails again on every
            // launch and the ranking silently stops working for the rest of the install.
            ShelfLog.metrics.error(
                "Usage history was not readable and has been discarded: \(error.localizedDescription, privacy: .public)"
            )
            UserDefaults.standard.removeObject(forKey: key)
        }
    }

    func recordLaunch(path: String) {
        let normalized = ShelfPath.normalize(path)
        let existing = records[normalized]
        records[normalized] = Record(count: (existing?.count ?? 0) + 1, lastUsed: Date())
        persist()
    }

    func count(for path: String) -> Int { records[path]?.count ?? 0 }

    func lastUsed(for path: String) -> Date? { records[path]?.lastUsed }

    func forgetAll() {
        records.removeAll()
        UserDefaults.standard.removeObject(forKey: key)
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(records) else {
            ShelfLog.state.error("Usage history could not be encoded; it will not survive relaunch.")
            return
        }
        UserDefaults.standard.set(data, forKey: key)
    }
}
