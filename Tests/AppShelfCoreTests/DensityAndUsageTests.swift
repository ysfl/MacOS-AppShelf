import Foundation
import Testing

@testable import AppShelfCore

/// Density presets and the usage-based ordering the floating panel falls back to.
struct DensityAndUsageTests {

    @Test("每个密度档都给出可比较的、单调的栅格参数")
    func densitiesAreOrdered() {
        let compact = GridDensity.compact.spec
        let standard = GridDensity.standard.spec
        let spacious = GridDensity.spacious.spec

        #expect(compact.maximum < standard.maximum)
        #expect(standard.maximum < spacious.maximum)
        #expect(compact.minimum < standard.minimum)
        #expect(standard.minimum < spacious.minimum)

        #expect(GridDensity.compact.minimumRowHeight < GridDensity.standard.minimumRowHeight)
        #expect(GridDensity.standard.iconSide < GridDensity.spacious.iconSide)
    }

    @Test("每一档都能算出合法栅格，不会退化出 0 列或 0 步长")
    func everyDensityMeasuresLegally() throws {
        for density in GridDensity.allCases {
            let measured = try #require(density.spec.measure(width: 900, height: 600, count: 24),
                                        "\(density.rawValue) produced no grid")
            #expect(measured.columns >= 1)
            #expect(measured.columnStep > 0)
            #expect(measured.rowStep > 0)
            // The slide distance must stay inside the spec's own bounds for every density.
            #expect(measured.columnStep <= density.spec.maximum + density.spec.columnSpacing + 0.001)
        }
    }

    @Test("默认档位是标准，且原始值稳定")
    func defaultAndRawValues() {
        #expect(GridDensity.defaultDensity == .standard)
        #expect(Set(GridDensity.allCases.map(\.rawValue)) == ["compact", "standard", "spacious"])
        #expect(GridDensity(rawValue: "nonsense") == nil)
    }

    // MARK: Usage ranking

    private struct Item: RankedApp {
        let displayName: String
        let isRunning: Bool
        let searchTokens: SearchTokens
        let uses: Int
        let last: Date?
    }

    private func item(_ name: String,
                      running: Bool = false,
                      uses: Int = 0,
                      last: Date? = nil) -> Item {
        Item(displayName: name,
             isRunning: running,
             searchTokens: SearchTokens(name: name),
             uses: uses,
             last: last)
    }

    private func order(_ items: [Item]) -> [String] {
        UsageRanking.sorted(items, counts: \.uses, lastUsed: \.last).map(\.displayName)
    }

    @Test("运行中的应用始终排在最前")
    func runningFirst() {
        #expect(order([item("Zeta", uses: 99), item("Alpha", running: true)]) == ["Alpha", "Zeta"])
    }

    @Test("启动次数优先于时间，次数相同才看最近一次")
    func countBeatsRecency() {
        let recent = Date(timeIntervalSince1970: 2_000)
        let older = Date(timeIntervalSince1970: 1_000)
        #expect(order([item("Rare", uses: 1, last: recent),
                       item("Often", uses: 5, last: older)]) == ["Often", "Rare"])
        #expect(order([item("OldButLasting", uses: 3, last: older),
                       item("Fresh", uses: 3, last: recent)]) == ["Fresh", "OldButLasting"])
    }

    @Test("从未用过时退回名称序，且已用过的排在未用过的后面还是前面都明确")
    func noHistoryIsAlphabetical() {
        #expect(order([item("Bravo"), item("Alpha")]) == ["Alpha", "Bravo"])
        // A recorded timestamp with no comparable counterpart still wins the slot.
        #expect(order([item("Used", last: Date()), item("Never")]) == ["Used", "Never"])
    }

    @Test("用量参与搜索同分破平，但不会盖过更好的匹配")
    func usageBreaksSearchTiesOnly() {
        struct Light: RankedApp {
            let displayName: String
            let isRunning: Bool
            let searchTokens: SearchTokens
            let uses: Int
        }
        let items = [
            Light(displayName: "Zebra App", isRunning: false, searchTokens: SearchTokens(name: "Zebra App"), uses: 50),
            Light(displayName: "Aardvark App", isRunning: false, searchTokens: SearchTokens(name: "Aardvark App"), uses: 1)
        ]
        // Both are prefix matches on "a"? No: only Aardvark is. It must win on score alone.
        let byScore = SearchMatcher.ranked(items, query: "aard", limit: 5, usageCount: \.uses)
        #expect(byScore.map(\.displayName) == ["Aardvark App"])

        // Both match "app" identically, so usage decides.
        let tied = SearchMatcher.ranked(items, query: "app", limit: 5, usageCount: \.uses)
        #expect(tied.map(\.displayName) == ["Zebra App", "Aardvark App"])
        // With no usage supplied, the alphabetical fallback takes over.
        #expect(SearchMatcher.ranked(items, query: "app", limit: 5).map(\.displayName)
                == ["Aardvark App", "Zebra App"])
    }
}
