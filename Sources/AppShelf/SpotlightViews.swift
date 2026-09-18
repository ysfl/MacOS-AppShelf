import AppKit
import SwiftUI
import UniformTypeIdentifiers

import AppShelfCore

/// The panel's content: one search field, a short result list, and a hint bar.
struct SpotlightView: View {
    @ObservedObject var controller: SpotlightController

    @FocusState private var isFieldFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            searchField
            if controller.results.isEmpty {
                noResults
            } else {
                resultsList
            }
            hintBar
        }
        .frame(width: spotlightPanelWidth)
        .background(
            RoundedRectangle(cornerRadius: 14)
                .fill(.regularMaterial)
        )
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .overlay {
            RoundedRectangle(cornerRadius: 14)
                .stroke(AppShelfPalette.panelEdge, lineWidth: 1)
        }
        .onAppear {
            focusField()
        }
        // The view is created once and reused, so refocus on every presentation.
        .onReceive(NotificationCenter.default.publisher(for: .spotlightPanelDidPresent)) { _ in
            focusField()
        }
    }

    private func focusField() {
        // Focus slightly after the panel becomes key so the field is ready to type.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            isFieldFocused = true
        }
    }

    private var searchField: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(.secondary)

            TextField(L10n.shared.t("搜索应用…"), text: $controller.query)
                .textFieldStyle(.plain)
                .font(.system(size: 18, weight: .regular))
                .focused($isFieldFocused)
                .onSubmit { controller.openSelected() }

            Text(controller.shortcutHint)
                .font(.shelfNote)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 7)
                .padding(.vertical, 3)
                .background(Color.primary.opacity(0.07), in: RoundedRectangle(cornerRadius: 5))
        }
        .padding(.horizontal, 16)
        .frame(height: 54)
    }

    /// The list is capped at eight rows, so the selection can walk out of sight.
    /// `ScrollViewReader` keeps the highlighted row under the scroll position, which is the
    /// only reason ↑/↓ past the eighth result is usable at all.
    private var resultsList: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical, showsIndicators: false) {
                // A plain VStack, not a lazy one: `scrollTo` cannot reach a row that has
                // not been realized yet, which is exactly the row the arrow keys move to.
                VStack(spacing: 2) {
                    ForEach(Array(controller.results.enumerated()), id: \.element.id) { index, app in
                        SpotlightRow(
                            app: app,
                            isSelected: index == controller.selectedIndex
                        ) {
                            controller.open(app)
                        }
                        .id(app.path)
                        .onHover { isHovering in
                            if isHovering { controller.select(index) }
                        }
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
            }
            .frame(maxHeight: 8 * SpotlightRow.rowHeight)
            .onChange(of: controller.selectedIndex, initial: false) { _, index in
                guard controller.results.indices.contains(index) else { return }
                proxy.scrollTo(controller.results[index].path, anchor: .center)
            }
        }
    }

    private var noResults: some View {
        VStack(spacing: 6) {
            L10nText("没有匹配的应用")
                .font(.shelfControlTitle)
            L10nText("试试应用名、拼音全拼或首字母，例如“wx”")
                .font(.shelfMeta)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, minHeight: 76)
    }

    private var hintBar: some View {
        HStack(spacing: 14) {
            hint("↑↓", L10n.shared.t("选择"))
            hint("⏎", L10n.shared.t("打开"))
            hint("esc", L10n.shared.t("关闭"))
            Spacer()
            L10nText("应用架")
                .font(.system(size: 10, weight: .semibold, design: .rounded))
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 16)
        .frame(height: 30)
        .background(Color.primary.opacity(0.04))
    }

    private func hint(_ key: String, _ title: String) -> some View {
        HStack(spacing: 5) {
            Text(key)
                .font(.system(size: 10, weight: .semibold))
                .padding(.horizontal, 5)
                .padding(.vertical, 2)
                .background(Color.primary.opacity(0.08), in: RoundedRectangle(cornerRadius: 4))
            Text(title)
                .font(.shelfMicro)
                .foregroundStyle(.secondary)
        }
    }
}

/// One result row: icon, name, and a short subtitle with size and running state.
struct SpotlightRow: View {
    static let rowHeight: CGFloat = 52

    let app: AppItem
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 11) {
                Image(nsImage: IconCache.shared.image(for: app.path))
                    .resizable()
                    .interpolation(.high)
                    .frame(width: 34, height: 34)

                VStack(alignment: .leading, spacing: 2) {
                    Text(app.name)
                        .font(.system(size: 13.5, weight: .semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)

                    HStack(spacing: 6) {
                        if app.isRunning {
                            Circle()
                                .fill(AppShelfPalette.success)
                                .frame(width: 5, height: 5)
                            L10nText("运行中")
                                .font(.system(size: 10.5, weight: .medium))
                                .foregroundStyle(AppShelfPalette.success)
                        }
                        Text(L10n.shared.t(app.category))
                            .font(.system(size: 10.5))
                            .foregroundStyle(.secondary)
                    }
                }

                Spacer(minLength: 8)

                if isSelected {
                    Image(systemName: "return")
                        .font(.shelfLabel)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 10)
            .frame(height: SpotlightRow.rowHeight)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                RoundedRectangle(cornerRadius: 8)
                    .fill(isSelected ? AppShelfPalette.accent.opacity(0.16) : Color.clear)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
