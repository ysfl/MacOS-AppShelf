import Foundation

/// Text tokens precomputed once per app so typing stays responsive.
///
/// An app is usually known by more than one name: WeChat is filed as 微信 in its own
/// Chinese resources and Visual Studio Code reports "Code" as its bundle name. Each of
/// those names becomes a variant, and a query is matched against every variant.
public struct SearchTokens: Hashable, Sendable {
    public struct Variant: Hashable, Sendable {
        /// Diacritic- and case-insensitive name.
        public let folded: String
        /// `folded` split into words, so word matches outrank accidental substrings.
        public let words: [String]
        /// `folded` without whitespace, so "visual studio" matches "visualstudio".
        public let compact: String
        /// Pinyin syllables joined together, e.g. 微信 -> "weixin". Empty for Latin-only names.
        public let pinyin: String
        /// First letter of every syllable or word, e.g. 微信 -> "wx", Visual Studio Code -> "vsc".
        public let initials: String

        public init(folded: String, words: [String], compact: String, pinyin: String, initials: String) {
            self.folded = folded
            self.words = words
            self.compact = compact
            self.pinyin = pinyin
            self.initials = initials
        }
    }

    /// The display name is first; localized and file-system names follow.
    public let variants: [Variant]
    /// Bundle identifier and category, matched with a lower weight than the names.
    public let extras: String

    public init(name: String, aliases: [String] = [], extras: [String] = []) {
        var seen = Set<String>()
        var variants: [Variant] = []

        for text in [name] + aliases {
            let folded = Self.fold(text)
            guard !folded.isEmpty, seen.insert(folded).inserted else { continue }
            variants.append(Self.variant(folded: folded, original: text))
        }

        self.variants = variants
        self.extras = Self.fold(extras.joined(separator: " "))
    }

    private static func variant(folded: String, original: String) -> Variant {
        let words = folded
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
        let compact = folded.filter { !$0.isWhitespace }
        let syllables = Pinyin.syllables(of: original).map { Self.fold($0) }
        let transliteration = syllables.joined()
        // For Latin names the transliteration repeats the name itself, so keeping it would
        // only restate the matches above and add noise such as "ps" inside "appstore".
        let pinyin = transliteration == compact ? "" : transliteration
        let initials = syllables.compactMap(\.first).map(String.init).joined()
        return Variant(folded: folded, words: words, compact: compact, pinyin: pinyin, initials: initials)
    }

    private static func fold(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
            .lowercased()
    }
}

/// Converts Chinese characters to latin syllables using the system transliterator.
public enum Pinyin {
    public static func syllables(of text: String) -> [String] {
        guard !text.isEmpty else { return [] }
        // `.mandarinToLatin` keeps latin words intact, so mixed names such as
        // "微信 WeChat" still produce useful tokens for both scripts.
        let latin = text.applyingTransform(.mandarinToLatin, reverse: false) ?? text
        let plain = latin.applyingTransform(.stripDiacritics, reverse: false) ?? latin
        return plain
            .components(separatedBy: CharacterSet.whitespacesAndNewlines)
            .map { $0.trimmingCharacters(in: CharacterSet.alphanumerics.inverted) }
            .filter { !$0.isEmpty }
    }
}

/// Scores an app against a query. Higher is better; `nil` means no match.
public enum SearchMatcher {
    /// Returns the relevance score for `query`, or `nil` when the app should be filtered out.
    public static func score(_ tokens: SearchTokens, query: String) -> Int? {
        let foldedQuery = normalize(query)
        guard !foldedQuery.isEmpty else { return 0 }

        let compactQuery = compact(foldedQuery)
        guard !compactQuery.isEmpty else { return nil }

        var best: Int?

        func offer(_ value: Int) {
            guard value > 0 else { return }
            if let current = best {
                if value > current { best = value }
            } else {
                best = value
            }
        }

        for (index, variant) in tokens.variants.enumerated() {
            // The displayed name should win a tie against a localized or file-system alias.
            let bonus = index == 0 ? 0 : -20
            if let value = score(variant, foldedQuery: foldedQuery, compactQuery: compactQuery) {
                offer(value + bonus)
            }
        }

        // Secondary text such as the bundle identifier or the category.
        if !tokens.extras.isEmpty && tokens.extras.contains(foldedQuery) {
            offer(220)
        }

        return best
    }

    private static func score(_ variant: SearchTokens.Variant, foldedQuery: String, compactQuery: String) -> Int? {
        var best: Int?

        func offer(_ value: Int) {
            if let current = best {
                if value > current { best = value }
            } else {
                best = value
            }
        }

        // 1. Whole-string name matches.
        if variant.folded == foldedQuery {
            offer(1000)
        } else if variant.folded.hasPrefix(foldedQuery) {
            offer(860)
        } else if variant.folded.contains(foldedQuery) {
            offer(620)
        }

        // 2. Word matches, e.g. "store" for App Store or "photo" for Adobe Photoshop.
        if variant.words.contains(where: { $0 == compactQuery }) {
            offer(900)
        } else if variant.words.contains(where: { $0.hasPrefix(compactQuery) }) {
            offer(700)
        } else if variant.words.contains(where: { $0.contains(compactQuery) }) {
            offer(520)
        }

        // 3. Name without spaces. Only the prefix counts here, otherwise letters that
        // merely run across two words ("ps" inside "appstore") outrank real word matches.
        if variant.compact.hasPrefix(compactQuery) {
            offer(480)
        }

        // 4. Pinyin: full spelling and initials.
        //
        // An exact hit on either is the user typing the name the way this app is meant to
        // be searched, so it sits in the same tier as an exact or whole-word name match.
        // It used to score 540/500, which let a bare *prefix* of some other app's
        // romanized file name win: "wx" put 企业微信 (whose bundle is WXWork.app) above
        // 微信, whose initials *are* wx.
        if !variant.pinyin.isEmpty {
            if variant.pinyin == compactQuery {
                offer(900)
            } else if variant.pinyin.hasPrefix(compactQuery) {
                offer(510)
            } else if variant.pinyin.contains(compactQuery) {
                offer(470)
            }
        }

        if !variant.initials.isEmpty {
            if variant.initials == compactQuery {
                offer(880)
            } else if variant.initials.hasPrefix(compactQuery) {
                offer(480)
            } else if variant.initials.contains(compactQuery) {
                offer(430)
            }
        }

        // 5. Loose subsequence matching. Only used for two or more characters,
        // otherwise almost every app would match a single letter. A match that starts
        // at the beginning of a word ("ps" -> Photoshop) beats a scattered one.
        if compactQuery.count >= 2 {
            if variant.words.contains(where: { $0.first == compactQuery.first && isSubsequence(compactQuery, in: $0) }) {
                offer(300)
            }
            if isSubsequence(compactQuery, in: variant.compact) { offer(150) }
            if isSubsequence(compactQuery, in: variant.pinyin) { offer(160) }
            if isSubsequence(compactQuery, in: variant.initials) { offer(120) }
        }

        return best
    }

    /// Lowercases, trims, and strips diacritics so "WeiXin" and "wéixìn" behave the same.
    public static func normalize(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        return trimmed.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
            .lowercased()
    }

    public static func compact(_ text: String) -> String {
        text.filter { !$0.isWhitespace && !$0.isPunctuation }
    }

    /// True when every character of `needle` appears in `haystack` in the same order.
    public static func isSubsequence(_ needle: String, in haystack: String) -> Bool {
        if needle.isEmpty { return true }
        if needle.count > haystack.count { return false }

        var iterator = haystack.makeIterator()
        for character in needle {
            var found = false
            while let next = iterator.next() {
                if next == character {
                    found = true
                    break
                }
            }
            if !found { return false }
        }
        return true
    }

    /// Ranks `items` for `query`, dropping everything that does not match.
    ///
    /// Extracted from `LauncherStore.searchResults` so the ordering contract — score
    /// first, running apps break ties, then name — is testable without a store.
    public static func ranked<Item: RankedApp>(_ items: [Item], query: String, limit: Int) -> [Item] {
        let scored: [(Item, Int)] = items.compactMap { item in
            guard let score = score(item.searchTokens, query: query) else { return nil }
            return (item, score)
        }

        let sorted = scored.sorted { lhs, rhs in
            if lhs.1 != rhs.1 { return lhs.1 > rhs.1 }
            if lhs.0.isRunning != rhs.0.isRunning { return lhs.0.isRunning }
            return lhs.0.displayName.localizedCaseInsensitiveCompare(rhs.0.displayName) == .orderedAscending
        }

        return Array(sorted.prefix(limit).map(\.0))
    }
}

/// The minimum an item must expose to take part in ranked search.
public protocol RankedApp {
    var displayName: String { get }
    var isRunning: Bool { get }
    var searchTokens: SearchTokens { get }
}
