import Foundation

/// Fuzzy matching for the search palette (features 26 and 28).
///
/// A query matches a text in one of three ways, ranked from best to worst:
/// 1. **prefix**: the text starts with the query ("cha" in "Chatter").
/// 2. **word start**: a later word starts with the query ("cent" in "Control Center", "Control" in
///    "LightControl"), or the query spells the words' initials ("cc" for "Control Center").
/// 3. **subsequence**: the query's characters appear in order ("mtr" in "Meters"), tighter runs scoring higher.
/// Matching ignores case and diacritics. A recently used item gets a boost that reorders it within its tier but never
/// lifts it above a better kind of match.
public enum FuzzyMatcher {
    public enum Kind: Int, Comparable, Codable, Sendable {
        case subsequence = 1
        case wordStart = 2
        case prefix = 3

        public static func < (lhs: Kind, rhs: Kind) -> Bool { lhs.rawValue < rhs.rawValue }
    }

    public struct Match: Equatable, Sendable {
        public var kind: Kind
        public var score: Double
    }

    public struct Result: Equatable, Sendable {
        public var item: MenuBarItem
        /// Nil for an empty query (everything is listed).
        public var kind: Kind?
        public var score: Double
        /// Position in the recent list (0 = most recent), when the item is there.
        public var recentRank: Int?
    }

    /// Tier bases. Bonuses within a tier stay below the gap to the next tier.
    static let prefixBase = 300.0
    static let wordStartBase = 200.0
    static let subsequenceBase = 100.0
    /// Largest boost a recent item gets (the most recent one); it shrinks linearly down the list.
    static let maxRecentBoost = 50.0

    /// Matches `query` against one text.
    public static func match(_ query: String, in text: String) -> Match? {
        let q = Array(fold(query).split(whereSeparator: \.isWhitespace).joined(separator: " "))
        guard !q.isEmpty else { return nil }
        let words = wordStarts(text)
        let t = Array(fold(text))
        guard !t.isEmpty, q.count <= t.count else { return nil }
        let coverage = Double(q.count) / Double(t.count) // 0...1: closer to the whole text is better

        if t.starts(with: q) {
            return Match(kind: .prefix, score: prefixBase + 20 * coverage)
        }
        for (n, start) in words.enumerated() where start > 0 && start < t.count {
            if t[start...].starts(with: q) {
                return Match(kind: .wordStart, score: wordStartBase + 15 * coverage - min(Double(n), 5))
            }
        }
        if q.count >= 2, !q.contains(" ") {
            let initials = words.compactMap { $0 < t.count ? t[$0] : nil }
            if initials.starts(with: q) {
                return Match(kind: .wordStart, score: wordStartBase + 10 * Double(q.count) / Double(initials.count))
            }
        }
        // Subsequence, greedy from the left.
        var positions: [Int] = []
        var i = 0
        for c in q where c != " " {
            while i < t.count && t[i] != c { i += 1 }
            guard i < t.count else { return nil }
            positions.append(i)
            i += 1
        }
        guard let first = positions.first, let last = positions.last else { return nil }
        let tightness = Double(positions.count) / Double(last - first + 1) // 1 when contiguous
        let startsWord = words.contains(first) ? 5.0 : 0
        return Match(kind: .subsequence, score: subsequenceBase + 40 * tightness + startsWord)
    }

    /// Ranks items for `query`. Each item is matched on its app name and its display name (which includes the
    /// item's own name or description). An empty query lists recent items first (most recent first), then the rest
    /// in their given order.
    public static func rank(_ query: String, items: [MenuBarItem], recents: [ItemID]) -> [Result] {
        var recentRank: [ItemID: Int] = [:]
        for (n, id) in recents.enumerated() where recentRank[id] == nil { recentRank[id] = n }

        if query.trimmingCharacters(in: .whitespaces).isEmpty {
            let recent = items.filter { recentRank[$0.id] != nil }.sorted { recentRank[$0.id]! < recentRank[$1.id]! }
            let rest = items.filter { recentRank[$0.id] == nil }
            return (recent + rest).map { Result(item: $0, kind: nil, score: 0, recentRank: recentRank[$0.id]) }
        }

        var scored: [(result: Result, index: Int)] = []
        for (index, item) in items.enumerated() {
            let fields = [item.appName, item.displayName, descriptionPart(of: item)].filter { !$0.isEmpty }
            guard let best = fields.compactMap({ match(query, in: $0) }).max(by: { $0.score < $1.score }) else { continue }
            let rank = recentRank[item.id]
            let boost = rank.map { maxRecentBoost * (1 - Double($0) / Double(max(recents.count, 1))) } ?? 0
            scored.append((Result(item: item, kind: best.kind, score: best.score + boost, recentRank: rank), index))
        }
        scored.sort { $0.result.score != $1.result.score ? $0.result.score > $1.result.score : $0.index < $1.index }
        return scored.map(\.result)
    }

    // MARK: - Text

    /// Case- and diacritic-insensitive form.
    static func fold(_ s: String) -> String {
        s.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil).lowercased()
    }

    /// Indices (in the folded text) where words start: after a non-letter/digit, or at a lower-to-upper case change
    /// ("LightControl"). Folding keeps the character count for the texts SnugBar sees (names of apps and items);
    /// when it doesn't, only separator-based word starts are used.
    static func wordStarts(_ text: String) -> [Int] {
        let original = Array(text)
        guard Array(fold(text)).count == original.count else { return separatorStarts(fold(text)) }
        var starts: [Int] = []
        var previous: Character?
        for (i, c) in original.enumerated() {
            let isWordChar = c.isLetter || c.isNumber
            defer { previous = c }
            guard isWordChar else { continue }
            guard let p = previous else { starts.append(i); continue }
            if !(p.isLetter || p.isNumber) {
                starts.append(i)
            } else if p.isLowercase, c.isUppercase {
                starts.append(i)
            }
        }
        return starts
    }

    private static func separatorStarts(_ folded: String) -> [Int] {
        var starts: [Int] = []
        var previousIsWord = false
        for (i, c) in folded.enumerated() {
            let isWord = c.isLetter || c.isNumber
            if isWord && !previousIsWord { starts.append(i) }
            previousIsWord = isWord
        }
        return starts
    }

    /// "Meters: CPU" -> "CPU" (the part after the app name), else "".
    static func descriptionPart(of item: MenuBarItem) -> String {
        let prefix = item.appName + ": "
        guard !item.appName.isEmpty, item.displayName.hasPrefix(prefix) else { return "" }
        return String(item.displayName.dropFirst(prefix.count))
    }
}

/// The recently opened items list (feature 28).
public enum RecentItems {
    public static let limit = 20

    /// `id` moved to the front, without duplicates, at most `limit` long.
    public static func noting(_ id: ItemID, in list: [ItemID], limit: Int = limit) -> [ItemID] {
        Array(([id] + list.filter { $0 != id }).prefix(max(limit, 0)))
    }
}
