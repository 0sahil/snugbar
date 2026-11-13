import Foundation

/// Gives each item in the SnugBar Bar a key to press for "open by letter" (feature 16).
///
/// - Keys are a–z without the easily confused `i`, `l` and `o`, then the digits 2–9 when there are more items than
///   letters. Items beyond that get no key.
/// - An item whose app name starts with a letter no other item's app name starts with gets that letter.
/// - Every other item, left to right, takes the first free key from: its app name's first letter, the first letters
///   of the words in its display name ("Meters: RAM" -> r), the other letters of its app name, then of its display
///   name, then any free key.
/// - The same list always gets the same keys.
public enum LetterAssigner {
    public static let skipped: Set<Character> = ["i", "l", "o"]
    public static let letters: [Character] = "abcdefghijklmnopqrstuvwxyz".filter { !skipped.contains($0) }
    public static let digits: [Character] = Array("23456789")
    public static var keys: [Character] { letters + digits }

    /// Keys in item order. Items without a key are left out.
    public static func assign(_ items: [MenuBarItem]) -> [ItemID: Character] {
        let pool = keys
        let allowed = Set(pool)
        var used = Set<Character>()
        var result: [ItemID: Character] = [:]

        let initials = items.map { initial(of: $0.appName) }
        var initialCount: [Character: Int] = [:]
        for c in initials.compactMap({ $0 }) { initialCount[c, default: 0] += 1 }

        // 1. Unique app initials.
        for (item, c) in zip(items, initials) {
            guard let c, initialCount[c] == 1, allowed.contains(c), !used.contains(c), result[item.id] == nil else { continue }
            result[item.id] = c
            used.insert(c)
        }

        // 2. Everything else, left to right.
        for (item, c) in zip(items, initials) where result[item.id] == nil {
            var candidates: [Character] = []
            if let c { candidates.append(c) }
            candidates += wordInitials(of: item.displayName)
            candidates += letters(of: item.appName)
            candidates += letters(of: item.displayName)
            candidates += pool
            guard let key = candidates.first(where: { allowed.contains($0) && !used.contains($0) }) else { continue }
            result[item.id] = key
            used.insert(key)
        }
        return result
    }

    /// The item for a typed character, if any.
    public static func item(for typed: String, in assignment: [ItemID: Character]) -> ItemID? {
        guard let c = fold(typed).first, fold(typed).count == 1 else { return nil }
        return assignment.first { $0.value == c }?.key
    }

    // MARK: - Private

    static func fold(_ s: String) -> String {
        s.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil).lowercased()
    }

    /// First character of the name when it is a plain letter a–z after folding ("Émoji" -> e).
    static func initial(of name: String) -> Character? {
        guard let c = fold(name.trimmingCharacters(in: .whitespaces)).first, c.isASCII, c.isLetter else { return nil }
        return c
    }

    static func wordInitials(of text: String) -> [Character] {
        fold(text).split(whereSeparator: { !($0.isLetter || $0.isNumber) }).compactMap(\.first)
    }

    static func letters(of text: String) -> [Character] {
        fold(text).filter { $0.isASCII && ($0.isLetter || $0.isNumber) }.map { $0 }
    }
}
