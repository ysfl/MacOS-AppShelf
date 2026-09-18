import AppKit
import SwiftUI
import UniformTypeIdentifiers

import AppShelfCore

// MARK: - Export / import
extension LauncherStore {
    /// Everything the user arranged, as a portable payload.
    func exportSnapshot() -> ShelfExport {
        ShelfExport(groups: groups,
                    hiddenApps: Array(hidden.paths).sorted(),
                    preferences: .init(language: L10n.shared.language,
                                       appearance: Appearance.shared.mode.rawValue,
                                       showsStatusItem: HotKeyStore.shared.showsStatusItem,
                                       hotKey: HotKeyStore.shared.shortcut),
                    quickTools: .init(enabledIDs: QuickToolStore.shared.enabledIDs,
                                       custom: QuickToolStore.shared.customTools))
    }

    /// Applies an import, reporting what had to be dropped. Returns false when refused.
    @discardableResult
    func applyImport(_ export: ShelfExport) -> Bool {
        let result = ShelfImport.validate(export)
        switch result.report {
        case .unsupportedVersion(let found, let supported):
            errorMessage = L10n.shared.t("import_version_too_new",
                                         args: ["found": "\(found)", "supported": "\(supported)"])
            return false
        case .appliedWithWarnings(let warnings):
            note(L10n.shared.t("import_partial", args: ["count": "\(warnings.count)"]))
        case .valid:
            break
        }

        guard let cleaned = result.cleaned else { return false }

        replaceArrangement(groups: cleaned.groups, hidden: HiddenAppList(paths: cleaned.hiddenApps))
        if selection == .hidden, hidden.isEmpty { selection = .all }
        L10n.shared.language = cleaned.preferences.language
        Appearance.shared.mode = AppearanceMode(rawValue: cleaned.preferences.appearance) ?? .system
        HotKeyStore.shared.showsStatusItem = cleaned.preferences.showsStatusItem
        HotKeyStore.shared.shortcut = cleaned.preferences.hotKey ?? .fallback
        QuickToolStore.shared.restore(enabledIDs: cleaned.quickTools.enabledIDs,
                                      custom: cleaned.quickTools.custom)
        return true
    }
}
