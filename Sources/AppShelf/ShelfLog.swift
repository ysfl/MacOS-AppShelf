import Foundation
import os

/// Local diagnostics.
///
/// The project shipped with zero log statements and seventeen `try?` sites, so the worst
/// class of failure was invisible: a corrupt group blob decoded to `nil`, the store fell
/// back to the starter groups, and the user just saw "my groups are gone" with nothing to
/// check. These go to the unified log only — nothing leaves the machine.
///
/// View Console with:
///     log show --predicate 'subsystem == "local.dan.AppShelf"' --last 5m
enum ShelfLog {
    static let subsystem = Bundle.main.bundleIdentifier ?? "local.dan.AppShelf"

    /// State the user arranged by hand. Losing it is the most expensive failure here.
    static let state = Logger(subsystem: subsystem, category: "state")
    /// Disk and memory measurement, caching, and the process scan.
    static let metrics = Logger(subsystem: subsystem, category: "metrics")
    /// Translation loading and language resolution.
    static let l10n = Logger(subsystem: subsystem, category: "localization")
    /// Global shortcut registration and persistence.
    static let hotkey = Logger(subsystem: subsystem, category: "hotkey")
    /// Bundle discovery.
    static let discovery = Logger(subsystem: subsystem, category: "discovery")
    /// Export and import of the user's arrangement.
    static let transfer = Logger(subsystem: subsystem, category: "transfer")
}
