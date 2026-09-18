import Foundation
import Testing

@testable import AppShelfCore

/// The portable snapshot, which is the only way a user's hand-arranged shelf survives a
/// new Mac.
struct ShelfExportTests {

    private func sampleExport(version: Int = ShelfExport.currentVersion) -> ShelfExport {
        ShelfExport(version: version,
                    exportedAt: Date(timeIntervalSince1970: 1_800_000_000),
                    groups: [AppGroup(name: "开发", symbol: "hammer.fill", colorHex: "#2F80ED",
                                       appPaths: ["/Applications/Xcode.app"])],
                    hiddenApps: ["/Applications/Junk.app"],
                    preferences: .init(language: "en", appearance: "dark", showsStatusItem: false,
                                       hotKey: HotKey(keyCode: 46, carbonModifiers: 256, display: "⌘N")),
                    quickTools: .init(enabledIDs: ["builtin.terminal", "custom.\(UUID().uuidString)"],
                                      custom: []))
    }

    @Test("导出与导入往返一致")
    func roundTrip() throws {
        let original = sampleExport()
        let data = try #require(ShelfImport.encode(original, pretty: false))
        let decoded = try #require(ShelfImport.decode(data))
        #expect(decoded.groups == original.groups)
        #expect(decoded.hiddenApps == original.hiddenApps)
        #expect(decoded.preferences == original.preferences)
        #expect(decoded.exportedAt == original.exportedAt)
    }

    @Test("美化输出可被人读，键有序")
    func prettyOutputIsReadable() throws {
        let data = try #require(ShelfImport.encode(sampleExport(), pretty: true))
        let text = try #require(String(data: data, encoding: .utf8))
        #expect(text.contains("\n"))
        #expect(text.contains("\"groups\""))
    }

    @Test("比本版本更新的导入被拒绝，而不是被截断应用")
    func refusesNewerVersion() throws {
        let result = ShelfImport.validate(sampleExport(version: ShelfExport.currentVersion + 1))
        #expect(result.cleaned == nil)
        #expect(result.report == .unsupportedVersion(ShelfExport.currentVersion + 1,
                                                     supported: ShelfExport.currentVersion))
    }

    @Test("空分组名与重复 id 被丢弃并上报")
    func repairsGroups() throws {
        let duplicate = AppGroup(name: "开发", symbol: "hammer.fill", colorHex: "#2F80ED")
        var export = sampleExport()
        export.groups = [
            export.groups[0],
            AppGroup(name: "   ", symbol: "folder", colorHex: "#000"),
            duplicate,
            duplicate
        ]
        let result = ShelfImport.validate(export)
        guard case .appliedWithWarnings(let warnings) = result.report else {
            Issue.record("expected warnings, got \(result.report)")
            return
        }
        #expect(warnings.contains(.groupWithoutName))
        #expect(warnings.contains(.duplicateGroupID))
        #expect(result.cleaned?.groups.count == 2)
    }

    @Test("无法解析的快捷工具 id 被剔除并点名")
    func dropsUnresolvedQuickToolIDs() throws {
        var export = sampleExport()
        export.quickTools.enabledIDs = ["builtin.terminal", "nonsense", "custom.not-a-uuid"]
        let result = ShelfImport.validate(export)
        #expect(result.cleaned?.quickTools.enabledIDs == ["builtin.terminal"])
        guard case .appliedWithWarnings(let warnings) = result.report else {
            Issue.record("expected warnings, got \(result.report)")
            return
        }
        #expect(warnings.contains(.unresolvedQuickToolID("nonsense")))
        #expect(warnings.contains(.unresolvedQuickToolID("custom.not-a-uuid")))
    }

    @Test("导入时隐藏路径被归一")
    func normalizesHiddenPaths() throws {
        var export = sampleExport()
        export.hiddenApps = ["/Applications//Junk.app"]
        let cleaned = try #require(ShelfImport.validate(export).cleaned)
        #expect(cleaned.hiddenApps == ["/Applications/Junk.app"])
    }

    @Test("干净的文件报 valid")
    func cleanFileReportsValid() throws {
        #expect(ShelfImport.validate(sampleExport()).report == .valid)
    }

    @Test("不是本项目格式的 JSON 解不出来，而不是半应用")
    func rejectsForeignJSON() throws {
        #expect(ShelfImport.decode(Data("{\"nope\":1}".utf8)) == nil)
        #expect(ShelfImport.decode(Data()) == nil)
    }
}
