import AppKit
import SwiftUI
import UniformTypeIdentifiers

import AppShelfCore

// MARK: - States
/// Placeholder shown while the file-system scan is in progress.
struct LoadingState: View {
    var body: some View {
        VStack(spacing: 12) {
            ProgressView()
                .controlSize(.small)
            L10nText("正在读取应用…")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, minHeight: 280)
    }
}

/// Shared empty state, worded for whichever view is actually empty.
struct EmptyState: View {
    let query: String
    let selection: ShelfSelection
    let onClearSearch: () -> Void
    let onAddApp: () -> Void
    let onRevealAll: (() -> Void)?

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: symbolName)
                .font(.system(size: 31, weight: .light))
                .foregroundStyle(.tertiary)
                .frame(width: 66, height: 66)
                .background(AppShelfPalette.panel, in: RoundedRectangle(cornerRadius: 16))
                .accessibilityHidden(true)

            Text(headline)
                .font(.system(size: 16, weight: .semibold))

            Text(subheadline)
                .font(.shelfCaption)
                .foregroundStyle(.secondary)

            HStack(spacing: 8) {
                if !query.isEmpty {
                    Button(L10n.shared.t("清除搜索"), action: onClearSearch)
                        .buttonStyle(.bordered)
                }
                if selection == .hidden, let onRevealAll {
                    Button(L10n.shared.t("全部显示"), action: onRevealAll)
                        .buttonStyle(.borderedProminent)
                        .tint(AppShelfPalette.accent)
                }
                if selection != .running && selection != .hidden && selection != .ungrouped {
                    Button(action: onAddApp) {
                        Label(L10n.shared.t("添加应用"), systemImage: "plus")
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(AppShelfPalette.accent)
                }
            }
            .padding(.top, 3)
        }
        .frame(maxWidth: .infinity, minHeight: 300)
    }

    private var symbolName: String {
        if !query.isEmpty { return "magnifyingglass" }
        switch selection {
        case .running: return "bolt.slash"
        case .hidden: return "eye.slash"
        case .ungrouped: return "checkmark.seal"
        default: return "square.grid.2x2"
        }
    }

    private var headline: String {
        if !query.isEmpty { return L10n.shared.t("没有匹配的应用") }
        switch selection {
        case .running: return L10n.shared.t("没有正在运行的应用")
        case .hidden: return L10n.shared.t("没有隐藏的应用")
        case .ungrouped: return L10n.shared.t("所有应用都已分组")
        default: return L10n.shared.t("这个分组还没有应用")
        }
    }

    private var subheadline: String {
        if !query.isEmpty { return L10n.shared.t("换个关键词试试。") }
        switch selection {
        case .running: return L10n.shared.t("启动任意应用后即可看到。")
        case .hidden: return L10n.shared.t("隐藏的应用不会出现在列表和搜索结果里。")
        case .ungrouped: return L10n.shared.t("每个应用都至少在一个分组里。")
        default: return L10n.shared.t("可以添加一个 .app，或切换到其他分组。")
        }
    }
}
