import Foundation
import Testing

@testable import AppShelfCore

/// Locks down the ranking contract the search field depends on.
///
/// These cases came from the bugs the project actually hit: an alias beating the
/// displayed name, a scattered subsequence outranking a real word match, and "wx" not
/// finding 微信 at all.
struct SearchMatchingTests {

    private func tokens(_ name: String, aliases: [String] = [], extras: [String] = []) -> SearchTokens {
        SearchTokens(name: name, aliases: aliases, extras: extras)
    }

    private func score(_ tokens: SearchTokens, _ query: String) -> Int? {
        SearchMatcher.score(tokens, query: query)
    }

    // MARK: Pinyin

    @Test("拼音首字母命中中文应用名")
    func pinyinInitials() {
        #expect(score(tokens("微信", aliases: ["WeChat"]), "wx") == 880)
        #expect(score(tokens("微信"), "weixin") == 900)
        #expect(score(tokens("计算器"), "jsq") == 880)
        #expect(score(tokens("飞书", aliases: ["Lark"]), "feishu") == 900)
    }

    @Test("首字母精确命中要赢过别名的前缀命中")
    func exactInitialsBeatAnAliasPrefix() {
        // The regression this guards: 企业微信 ships as WXWork.app, so "wx" used to hit it
        // as an 860 prefix on a secondary name and outrank 微信, whose initials *are* wx.
        let wechat = tokens("微信", aliases: ["WeChat"])
        let wecom = tokens("企业微信", aliases: ["WeCom", "WXWork"])
        #expect(score(wechat, "wx")! > score(wecom, "wx")!)

        let ranked = SearchMatcher.ranked([Named("企业微信", wecom), Named("微信", wechat)],
                                          query: "wx", limit: 5)
        #expect(ranked.map(\.displayName) == ["微信", "企业微信"])
    }

    @Test("英文缩写取词首字母")
    func englishInitials() {
        let code = tokens("Code", aliases: ["Visual Studio Code"])
        // Exact initials on the alias, minus the tie penalty against the displayed name.
        #expect(score(code, "vsc") == 860)
        // The displayed name wins a tie against an alias, so it is not penalised.
        #expect(score(code, "code") == 1000)
    }

    @Test("拉丁名不重复生成拼音 token")
    func latinNamesSkipTransliteration() {
        // Otherwise "appstore" would produce a spurious "ps" style match.
        let tokens = tokens("App Store")
        #expect(tokens.variants.first?.pinyin.isEmpty == true)
        #expect(tokens.variants.first?.initials == "as")
    }

    // MARK: Ranking order

    @Test("词首子序列胜过跨词子序列")
    func wordBoundaryBeatsScattered() {
        let photoShop = score(tokens("Adobe Photoshop"), "ps")
        let appStore = score(tokens("App Store"), "ps")
        #expect(photoShop == 300)
        #expect(appStore == 150)
        #expect(photoShop! > appStore!)
    }

    @Test("完整名 > 前缀 > 包含")
    func wholePrefixContains() {
        let safari = tokens("Safari")
        #expect(score(safari, "safari") == 1000)
        #expect(score(safari, "saf") == 860)
        #expect(score(safari, "afari") == 620)
    }

    @Test("别名得分低于显示名")
    func aliasScoresLowerThanDisplayName() {
        let wechat = tokens("微信", aliases: ["WeChat"])
        // An exact match on the alias still scores 1000, but loses 20 to the displayed
        // name, so 微信 wins the tie.
        #expect(score(wechat, "wechat") == 980)
        #expect(score(wechat, "微信") == 1000)
    }

    @Test("bundle id 只作为次要匹配")
    func extrasAreSecondary() {
        let calc = tokens("计算器", extras: ["com.apple.calculator"])
        #expect(score(calc, "calc") == 220)
        #expect(score(calc, "jsq")! > score(calc, "calc")!)
    }

    // MARK: Normalisation and rejection

    @Test("大小写、空格、变音与全半角一律归一")
    func normalization() {
        let wechat = tokens("微信")
        #expect(score(wechat, "W X") == score(wechat, "wx"))
        #expect(score(wechat, "  wx  ") == score(wechat, "wx"))
        #expect(SearchMatcher.normalize("ＷＸ") == "wx")
    }

    @Test("单字母按前缀命中，散落的子序列至少要两个字符")
    func rejectsNoise() {
        let finder = tokens("Finder")
        // A single letter still matches as a prefix or a substring; only the loose
        // subsequence rule is gated at two characters, otherwise every app would match
        // every letter.
        #expect(score(finder, "f") == 880)   // Finder's whole initial string
        #expect(score(finder, "i") == 620)
        #expect(score(finder, "fr") == 300)     // f..r, not contiguous, but starts a word
        #expect(score(finder, "zx") == nil)
        #expect(score(finder, "。，") == nil)
        #expect(score(finder, "-") == nil)
    }

    @Test("空查询给每个应用 0 分而不是过滤掉")
    func emptyQueryMatchesEverything() {
        #expect(score(tokens("Safari"), "") == 0)
        #expect(score(tokens("Safari"), "   ") == 0)
    }

    @Test("跨空格输入仍然命中紧凑名")
    func compactMatchingAcrossSpaces() {
        #expect(score(tokens("App Store"), "appstore") == 480)
    }

    // MARK: Ranked list

    /// Minimal stand-in for an app, so ranking can be tested without a store.
    struct Named: RankedApp {
        let displayName: String
        let searchTokens: SearchTokens
        var isRunning: Bool = false

        init(_ displayName: String, _ searchTokens: SearchTokens) {
            self.displayName = displayName
            self.searchTokens = searchTokens
        }
    }

    private struct Probe: RankedApp {
        let displayName: String
        let isRunning: Bool
        let searchTokens: SearchTokens
    }

    @Test("排序先看得分，再用运行状态破平，最后按名称")
    func rankingTieBreaks() {
        let items = [
            Probe(displayName: "Zeta", isRunning: true, searchTokens: tokens("Zeta")),
            Probe(displayName: "Alpha", isRunning: false, searchTokens: tokens("Alpha")),
            Probe(displayName: "Beta", isRunning: true, searchTokens: tokens("Beta"))
        ]
        let ranked = SearchMatcher.ranked(items, query: "a", limit: 10)
        #expect(ranked.first?.displayName == "Alpha")   // prefix match outranks a subsequence
        #expect(ranked.count == 3)
    }

    @Test("limit 生效")
    func limitIsApplied() {
        let items = (1...20).map { Probe(displayName: "App\($0)", isRunning: false, searchTokens: tokens("App\($0)")) }
        #expect(SearchMatcher.ranked(items, query: "app", limit: 5).count == 5)
    }
}
