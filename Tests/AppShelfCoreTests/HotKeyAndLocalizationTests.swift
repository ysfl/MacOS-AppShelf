import Foundation
import Testing

@testable import AppShelfCore

/// The shortcut codec, including the bug this file exists to keep fixed.
struct HotKeyCodecTests {

    @Test("停用状态能穿过存储往返，不会在下次启动变回默认")
    func disabledSurvivesRoundTrip() throws {
        // `HotKeyStore.init` used to collapse "the user switched it off" and "nothing was
        // ever stored" into one branch, so 停用 came back as ⌥Space on next launch.
        let data = try #require(HotKeyCodec.encode(.disabled))
        switch HotKeyCodec.decode(data) {
        case .disabled: break
        case let .enabled(other): Issue.record("disabled shortcut decoded as enabled: \(other)")
        case .unset: Issue.record("disabled shortcut decoded as unset, which falls back to ⌥Space")
        }
    }

    @Test("未存储时回退到默认组合")
    func unsetFallsBack() throws {
        #expect(HotKeyCodec.decode(nil) == .unset)
        #expect(HotKeyCodec.decode(Data()) == .unset)
        #expect(HotKeyCodec.decode(Data("not json".utf8)) == .unset)
    }

    @Test("已录制的组合原样恢复")
    func enabledRoundTrip() throws {
        let recorded = HotKey(keyCode: 46, carbonModifiers: CarbonModifier.command | CarbonModifier.shift, display: "⌘⇧N")
        let data = try #require(HotKeyCodec.encode(recorded))
        #expect(HotKeyCodec.decode(data) == .enabled(recorded))
    }

    @Test("默认组合是 ⌥Space")
    func fallbackIsOptionSpace() throws {
        #expect(HotKey.fallback.keyCode == 49)
        #expect(HotKey.fallback.carbonModifiers == CarbonModifier.option)
        #expect(HotKey.fallback.display == "⌥Space")
        #expect(HotKey.fallback.isEnabled)
    }

    @Test("停用项不带写死的语言标签")
    func disabledCarriesNoBakedLabel() throws {
        // A label resolved at launch would keep the old language after a switch.
        #expect(HotKey.disabled.display.isEmpty)
        #expect(!HotKey.disabled.isEnabled)
    }

    @Test("Carbon 修饰键掩码与 Cocoa 集合一一对应")
    func carbonMasks() throws {
        #expect(KeyModifiers([.command]).carbonMask == 256)
        #expect(KeyModifiers([.shift]).carbonMask == 512)
        #expect(KeyModifiers([.option]).carbonMask == 2048)
        #expect(KeyModifiers([.control]).carbonMask == 4096)
        #expect(KeyModifiers([.control, .option, .shift, .command]).carbonMask == 256 + 512 + 2048 + 4096)
        #expect(KeyModifiers().carbonMask == 0)
    }

    @Test("显示串按 ⌃⌥⇧⌘ 的 macOS 顺序拼接")
    func displayOrdering() throws {
        let all = KeyModifiers([.control, .option, .shift, .command])
        #expect(all.symbolPrefix == "⌃⌥⇧⌘")
        #expect(HotKeyDisplay.string(modifiers: all, keyCode: 8, characters: "c") { _ in "?" } == "⌃⌥⇧⌘C")
        #expect(HotKeyDisplay.keyName(keyCode: 49, characters: " ") == "Space")
        #expect(HotKeyDisplay.keyName(keyCode: 125, characters: "") == "↓")
        #expect(HotKeyDisplay.keyName(keyCode: 122, characters: "") == "F1")
        #expect(HotKeyDisplay.keyName(keyCode: 8, characters: "c") == "C")
        #expect(HotKeyDisplay.keyName(keyCode: 800, characters: "") == nil)
    }

    @Test("未知键走调用方给的本地化标签")
    func unknownKeyUsesCallerLabel() throws {
        let label = HotKeyDisplay.string(modifiers: [.command], keyCode: 800, characters: "") { "键\($0)" }
        #expect(label == "⌘键800")
    }
}

/// Language resolution and translation fallback.
struct LocalizationTests {

    @Test("系统语言映射到内置语种")
    func systemLanguageMapping() throws {
        let resolve = { LocalizationResolver.effectiveLanguage(selection: "system", preferredLanguages: $0) }
        #expect(resolve(["zh-Hans-CN"]) == "zh-Hans")
        #expect(resolve(["zh-Hant-TW"]) == "zh-Hans")
        #expect(resolve(["en-GB"]) == "en")
        #expect(resolve(["fr-CA"]) == "fr-CA")   // unknown: passed through, falls back per key
        #expect(resolve([]) == "en")
    }

    @Test("显式选择优先于系统偏好")
    func explicitSelectionWins() throws {
        #expect(LocalizationResolver.effectiveLanguage(selection: "en", preferredLanguages: ["zh-Hans"]) == "en")
    }

    @Test("外部文件按条目覆盖内置，而不是整表替换")
    func externalOverridesPerKey() throws {
        let bundled = ["en": ["a": "Apple", "b": "Banana"]]
        let external = ["en": ["b": "Big banana"]]
        let table = LocalizationResolver.table(bundled: bundled, external: external, language: "en")
        #expect(table["b"] == "Big banana")
        // Used to be lost entirely: a partial external file dropped every other entry and
        // the UI fell back to the Chinese key.
        #expect(table["a"] == "Apple")
    }

    @Test("空字符串不算覆盖")
    func emptyExternalValueDoesNotOverride() throws {
        let table = LocalizationResolver.table(bundled: ["en": ["a": "Apple"]],
                                               external: ["en": ["a": ""]],
                                               language: "en")
        #expect(table["a"] == "Apple")
    }

    @Test("回退顺序：本语种 → 内置英文 → 原文")
    func fallbackChain() throws {
        let bundled = ["en": ["greeting": "Hello"], "zh-Hans": ["greeting": "你好"]]
        let zh = LocalizationResolver.table(bundled: bundled, external: [:], language: "zh-Hans")
        #expect(LocalizationResolver.resolve(key: "greeting", table: zh, englishFallback: bundled["en"]!) == "你好")
        // A key only English has still resolves, rather than showing the raw Chinese key.
        #expect(LocalizationResolver.resolve(key: "greeting", table: [:], englishFallback: bundled["en"]!) == "Hello")
        #expect(LocalizationResolver.resolve(key: "未知键", table: [:], englishFallback: [:]) == "未知键")
    }

    @Test("占位符替换，缺失的占位符原样保留")
    func substitution() throws {
        let text = LocalizationResolver.substitute("共 {count} 个应用，{running} 在运行",
                                                   args: ["count": "12", "running": "3"])
        #expect(text == "共 12 个应用，3 在运行")
        #expect(LocalizationResolver.substitute("{missing} 还在", args: [:]) == "{missing} 还在")
    }

    @Test("可选语种列表固定顺序在前，新增语种按字母排在后")
    func availableLanguagesOrder() throws {
        let codes = LocalizationResolver.availableLanguages(bundled: ["zh-Hans": [:], "en": [:]],
                                                            external: ["ja": [:], "ko": [:]])
        #expect(codes == ["system", "zh-Hans", "en", "ja", "ko"])
    }

    @Test("没有任何内置表时仍提供 system")
    func alwaysOffersSystem() throws {
        #expect(LocalizationResolver.availableLanguages(bundled: [:], external: [:]) == ["system"])
    }
}
