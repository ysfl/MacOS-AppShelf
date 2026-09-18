import AppKit
import SwiftUI
import UniformTypeIdentifiers

import AppShelfCore

// MARK: - Quick tools
/// The quick tool row at the top of All Apps.
/// Its own view so the drop highlight does not invalidate the whole page.
struct QuickToolsRow: View {
    @ObservedObject private var quickTools = QuickToolStore.shared
    @State private var isTargeted = false

    let onLaunch: (QuickToolItem) -> Void
    let onAdded: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                L10nText("快捷工具")
                    .font(.shelfControlTitle)
                    .foregroundStyle(.secondary)
                Spacer()
                Text(isTargeted ? L10n.shared.t("松手即可添加") : L10n.shared.t("拖应用进来添加，拖出去移除"))
                    .font(.shelfMeta)
                    .foregroundStyle(isTargeted ? AppShelfPalette.accent : Color.secondary.opacity(0.7))
            }

            // A grid instead of a single row so any number of tools stays inside the window.
            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 150, maximum: 230), spacing: 10)],
                alignment: .leading,
                spacing: 10
            ) {
                ForEach(quickTools.items) { tool in
                    QuickToolTile(tool: tool) {
                        onLaunch(tool)
                    }
                }
            }
        }
        .padding(8)
        .background {
            RoundedRectangle(cornerRadius: 10)
                .stroke(
                    isTargeted ? AppShelfPalette.accent : Color.clear,
                    style: StrokeStyle(lineWidth: 1.5, dash: [5, 4])
                )
        }
        // Dropping an app card here pins it as a quick tool.
        .dropDestination(for: ShelfDragItem.self) { items, _ in
            pin(items.filter(\.isAppPath).map(\.value))
        } isTargeted: { isTargeted in
            self.isTargeted = isTargeted
        }
        // Bundles dragged in from Finder can be pinned the same way.
        .dropDestination(for: URL.self) { urls, _ in
            pin(urls.filter { ShelfPath.isApplicationBundle($0.path) }.map(\.path))
        }
    }

    private func pin(_ paths: [String]) -> Bool {
        let bundles = paths.filter { ShelfPath.isApplicationBundle($0) }
        guard !bundles.isEmpty else { return false }
        for path in bundles {
            let url = URL(fileURLWithPath: path)
            let name = AppDiscoveryService.item(for: url)?.name
                ?? url.deletingPathExtension().lastPathComponent
            quickTools.addCustom(name: name, path: path)
        }
        onAdded(L10n.shared.t("已加入快捷工具"))
        return true
    }
}

/// A larger shortcut tile shown above the full app grid.
struct QuickToolTile: View {
    let tool: QuickToolItem
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                toolIcon
                    .frame(width: 29, height: 29)
                    .background(AppShelfPalette.accent.opacity(0.10), in: RoundedRectangle(cornerRadius: 8))
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 2) {
                    Text(tool.title)
                        .font(.shelfLabel)
                        .foregroundStyle(.primary)
                    L10nText("打开")
                        .font(.shelfMicro)
                        .foregroundStyle(.tertiary)
                }

                Spacer(minLength: 4)
                Image(systemName: "arrow.up.right")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.tertiary)
                    .accessibilityHidden(true)
            }
            .padding(.horizontal, 11)
            .frame(maxWidth: .infinity, minHeight: 54, maxHeight: 54)
            .background(AppShelfPalette.panel.opacity(0.72), in: RoundedRectangle(cornerRadius: 8))
            .overlay {
                RoundedRectangle(cornerRadius: 8)
                    .stroke(AppShelfPalette.border, lineWidth: 1)
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(tool.title)
        .accessibilityHint(L10n.shared.t("拖应用进来添加，拖出去移除"))
        .help(L10n.shared.t("打开") + " \(tool.title)")
        // Drag the tile out of the row to remove it.
        .draggable(ShelfDragItem.quickTool(tool.id)) {
            Label(tool.title, systemImage: "square.dashed")
                .font(.shelfLabel)
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
        }
    }

    /// Built-in utilities keep their SF Symbol; user-added tools show their own icon.
    @ViewBuilder
    private var toolIcon: some View {
        if let symbol = tool.symbol {
            Image(systemName: symbol)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(AppShelfPalette.accent)
        } else if let path = tool.path {
            Image(nsImage: IconCache.shared.image(for: path))
                .resizable()
                .interpolation(.high)
        }
    }
}
