import AppKit
import SwiftUI
import UniformTypeIdentifiers

import AppShelfCore

// MARK: - Sheets
/// Create or edit one group without exposing persistence details to the form.
struct GroupEditorSheet: View {
    @Environment(\.dismiss) private var dismiss

    private let existing: AppGroup?
    private let onSave: (String, String, String) -> Void

    @State private var name: String
    @State private var selectedSymbol: String
    @State private var color: Color
    @State private var symbolFilter = ""

    private let symbols = GroupSymbolCatalog.available
    private let columns = 8

    init(existing: AppGroup? = nil, onSave: @escaping (String, String, String) -> Void) {
        self.existing = existing
        self.onSave = onSave
        _name = State(initialValue: existing?.name ?? "")
        _selectedSymbol = State(initialValue: existing?.symbol ?? "folder.fill")
        _color = State(initialValue: existing.map { Color(hex: $0.colorHex) } ?? AppShelfPalette.accent)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(existing == nil ? L10n.shared.t("新建分组") : L10n.shared.t("编辑分组"))
                        .font(.shelfSheetTitle)
                    L10nText("给分组一个容易辨认的名称和图标")
                        .font(.shelfCaption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }

            VStack(alignment: .leading, spacing: 8) {
                L10nText("名称")
                    .font(.shelfLabel)
                TextField(L10n.shared.t("例如：项目、影音、常用"), text: $name)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityLabel(L10n.shared.t("名称"))
            }

            VStack(alignment: .leading, spacing: 9) {
                L10nText("图标")
                    .font(.shelfLabel)

                // The catalogue is long enough that a fixed grid without a filter was
                // unusable once the wanted symbol was not among the first fifteen.
                TextField(L10n.shared.t("搜索图标"), text: $symbolFilter)
                    .textFieldStyle(.roundedBorder)
                    .font(.shelfCaption)
                    .accessibilityLabel(L10n.shared.t("搜索图标"))

                ScrollView {
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: columns),
                              spacing: 8) {
                        ForEach(shownSymbols, id: \.self) { symbol in
                            Button {
                                selectedSymbol = symbol
                            } label: {
                                Image(systemName: symbol)
                                    .font(.shelfSectionTitle)
                                    .foregroundStyle(selectedSymbol == symbol ? color : .secondary)
                                    .frame(width: 31, height: 31)
                                    .background {
                                        RoundedRectangle(cornerRadius: 7)
                                            .fill(selectedSymbol == symbol ? color.opacity(0.14) : AppShelfPalette.panel)
                                    }
                                    .overlay {
                                        RoundedRectangle(cornerRadius: 7)
                                            .stroke(selectedSymbol == symbol ? color.opacity(0.55) : AppShelfPalette.border,
                                                    lineWidth: 1)
                                    }
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(symbol)
                            .accessibilityAddTraits(selectedSymbol == symbol ? .isSelected : [])
                        }
                    }
                    .padding(2)
                }
                .frame(height: 132)
            }

            ColorPicker(L10n.shared.t("颜色"), selection: $color, supportsOpacity: false)
                .font(.shelfLabel)

            HStack {
                Spacer()
                Button(L10n.shared.t("取消"), role: .cancel) { dismiss() }
                Button(existing == nil ? L10n.shared.t("创建") : L10n.shared.t("保存")) {
                    onSave(name, selectedSymbol, color.appShelfHex)
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .tint(AppShelfPalette.accent)
                .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(24)
        .frame(width: 430)
    }

    private var shownSymbols: [String] {
        let query = symbolFilter.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !query.isEmpty else { return symbols }
        // The chosen symbol stays visible while filtering, so the selection never vanishes.
        let matches = symbols.filter { $0.lowercased().contains(query) }
        if matches.isEmpty { return [selectedSymbol] }
        return matches.contains(selectedSymbol) ? matches : [selectedSymbol] + matches
    }
}

/// Review selected app bundles and choose their destination group.
struct AddAppsSheet: View {
    @Environment(\.dismiss) private var dismiss

    let urls: [URL]
    let groups: [AppGroup]
    let defaultGroupID: UUID
    let onAdd: ([URL], UUID) -> Void

    @State private var selectedGroupID: UUID

    init(urls: [URL], groups: [AppGroup], defaultGroupID: UUID, onAdd: @escaping ([URL], UUID) -> Void) {
        self.urls = urls
        self.groups = groups
        self.defaultGroupID = defaultGroupID
        self.onAdd = onAdd
        _selectedGroupID = State(initialValue: defaultGroupID)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 4) {
                L10nText("添加到应用架")
                    .font(.shelfSheetTitle)
                Text(L10n.shared.t("已选择 个应用", args: ["count": "\(urls.count)"]))
                    .font(.shelfCaption)
                    .foregroundStyle(.secondary)
            }

            ScrollView {
                VStack(alignment: .leading, spacing: 7) {
                    ForEach(urls, id: \.path) { url in
                        HStack(spacing: 9) {
                            Image(nsImage: IconCache.shared.image(for: url.path))
                                .resizable()
                                .frame(width: 28, height: 28)
                                .accessibilityHidden(true)
                            Text(url.deletingPathExtension().lastPathComponent)
                                .font(.shelfBody)
                                .lineLimit(1)
                            Spacer()
                        }
                        .padding(.horizontal, 9)
                        .padding(.vertical, 6)
                        .background(AppShelfPalette.panel.opacity(0.7), in: RoundedRectangle(cornerRadius: 8))
                    }
                }
            }
            .frame(maxHeight: 190)

            Picker(L10n.shared.t("目标分组"), selection: $selectedGroupID) {
                ForEach(groups) { group in
                    Label(group.name, systemImage: group.symbol)
                        .tag(group.id)
                }
            }
            .pickerStyle(.menu)

            HStack {
                Spacer()
                Button(L10n.shared.t("取消"), role: .cancel) { dismiss() }
                Button {
                    onAdd(urls, selectedGroupID)
                    dismiss()
                } label: {
                    Label(L10n.shared.t("加入分组"), systemImage: "plus")
                }
                .buttonStyle(.borderedProminent)
                .tint(AppShelfPalette.accent)
                .disabled(groups.isEmpty)
            }
        }
        .padding(24)
        .frame(width: 430)
    }
}

/// Choose another group for an existing app card.
struct MoveAppSheet: View {
    @Environment(\.dismiss) private var dismiss

    let app: AppItem
    let groups: [AppGroup]
    let onMove: (UUID) -> Void

    @State private var selectedGroupID: UUID?

    init(app: AppItem, groups: [AppGroup], onMove: @escaping (UUID) -> Void) {
        self.app = app
        self.groups = groups
        self.onMove = onMove
        _selectedGroupID = State(initialValue: groups.first?.id)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 12) {
                Image(nsImage: IconCache.shared.image(for: app.path))
                    .resizable()
                    .frame(width: 44, height: 44)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 3) {
                    L10nText("加入其他分组")
                        .font(.system(size: 18, weight: .semibold, design: .rounded))
                    Text(app.name)
                        .font(.shelfCaption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            Picker(L10n.shared.t("目标分组"), selection: $selectedGroupID) {
                ForEach(groups) { group in
                    Label(group.name, systemImage: group.symbol)
                        .tag(Optional(group.id))
                }
            }
            .pickerStyle(.menu)

            HStack {
                Spacer()
                Button(L10n.shared.t("取消"), role: .cancel) { dismiss() }
                Button(L10n.shared.t("加入")) {
                    if let selectedGroupID { onMove(selectedGroupID) }
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .tint(AppShelfPalette.accent)
                .disabled(selectedGroupID == nil)
            }
        }
        .padding(24)
        .frame(width: 380)
    }
}
