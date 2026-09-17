import Foundation

/// Text tokens precomputed once per app so typing stays responsive.
/// The tokens cover three ways people search: the real name, the pinyin spelling of a
/// Chinese name, and the initials of either ("wx" for 微信, "vsc" for Visual Studio Code).
struct SearchTokens: Hashable, Sendable {
    let name: String
    /// Diacritic- and case-insensitive name, used for direct matches.
    let foldedName: String
    /// `foldedName` split into words, so word-level matches outrank accidental substrings.
    let words: [String]
    /// `foldedName` without whitespace, so "visual studio" matches "visualstudio".
    let compactName: String
    /// Pinyin syllables joined together, e.g. 微信 -> "weixin". Empty for Latin-only names.
    let pinyin: String
    /// First letter of every syllable or word, e.g. 微信 -> "wx".
    let initials: String
    /// Bundle identifier and category, matched with a lower weight than the name itself.
    let extras: String

    init(name: String, extras: [String] = []) {
        let folded = Self.fold(name)
        let syllables = Pinyin.syllables(of: name).map { Self.fold($0) }
        self.name = name
        self.foldedName = folded
        self.words = folded
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
        self.compactName = folded.filter { !$0.isWhitespace }
        let transliteration = syllables.joined()
        // For Latin names the transliteration repeats the name itself, so keeping it would
        // only restate the matches above and add noise such as "ps" inside "appstore".
        self.pinyin = transliteration == self.compactName ? "" : transliteration
        self.initials = syllables.compactMap(\.first).map(String.init).joined()
        self.extras = Self.fold(extras.joined(separator: " "))
    }

    private static func fold(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
            .lowercased()
    }
}

/// Converts Chinese characters to latin syllables using the system transliterator.
enum Pinyin {
    static func syllables(of text: String) -> [String] {
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
enum SearchMatcher {
    /// Returns the relevance score for `query`, or `nil` when the app should be filtered out.
    static func score(_ tokens: SearchTokens, query: String) -> Int? {
        let foldedQuery = Self.normalize(query)
        guard !foldedQuery.isEmpty else { return 0 }

        let compactQuery = Self.compact(foldedQuery)
        guard !compactQuery.isEmpty else { return nil }

        var best: Int?

        func offer(_ value: Int) {
            if let current = best {
                if value > current { best = value }
            } else {
                best = value
            }
        }

        // 1. Whole-string name matches.
        if tokens.foldedName == foldedQuery {
            offer(1000)
        } else if tokens.foldedName.hasPrefix(foldedQuery) {
            offer(860)
        } else if tokens.foldedName.contains(foldedQuery) {
            offer(620)
        }

        // 2. Word matches, e.g. "store" for App Store or "photo" for Adobe Photoshop.
        if tokens.words.contains(where: { $0 == compactQuery }) {
            offer(900)
        } else if tokens.words.contains(where: { $0.hasPrefix(compactQuery) }) {
            offer(700)
        } else if tokens.words.contains(where: { $0.contains(compactQuery) }) {
            offer(520)
        }

        // 3. Name without spaces. Only the prefix counts here, otherwise letters that
        // merely run across two words ("ps" inside "appstore") outrank real word matches.
        if tokens.compactName.hasPrefix(compactQuery) {
            offer(480)
        }

        // 3. Pinyin: full spelling and initials.
        if !tokens.pinyin.isEmpty {
            if tokens.pinyin == compactQuery {
                offer(540)
            } else if tokens.pinyin.hasPrefix(compactQuery) {
                offer(510)
            } else if tokens.pinyin.contains(compactQuery) {
                offer(470)
            }
        }

        if !tokens.initials.isEmpty {
            if tokens.initials == compactQuery {
                offer(500)
            } else if tokens.initials.hasPrefix(compactQuery) {
                offer(480)
            } else if tokens.initials.contains(compactQuery) {
                offer(430)
            }
        }

        // 4. Secondary text such as the bundle identifier or the category.
        if !tokens.extras.isEmpty && tokens.extras.contains(foldedQuery) {
            offer(220)
        }

        // 5. Loose subsequence matching. Only used for two or more characters,
        // otherwise almost every app would match a single letter. A match that starts
        // at the beginning of a word ("ps" -> Photoshop) beats a scattered one.
        if compactQuery.count >= 2 {
            if tokens.words.contains(where: { $0.first == compactQuery.first && isSubsequence(compactQuery, in: $0) }) {
                offer(300)
            }
            if isSubsequence(compactQuery, in: tokens.compactName) { offer(150) }
            if isSubsequence(compactQuery, in: tokens.pinyin) { offer(160) }
            if isSubsequence(compactQuery, in: tokens.initials) { offer(120) }
        }

        return best
    }

    /// Lowercases, trims, and strips diacritics so "WeiXin" and "wéixìn" behave the same.
    static func normalize(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        return trimmed.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
            .lowercased()
    }

    static func compact(_ text: String) -> String {
        text.filter { !$0.isWhitespace && !$0.isPunctuation }
    }

    /// True when every character of `needle` appears in `haystack` in the same order.
    static func isSubsequence(_ needle: String, in haystack: String) -> Bool {
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
}
