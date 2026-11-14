import Foundation

/// Resolves a user-typed item reference: an exact ItemID, a bundle ID, or part of a name.
public enum ItemQuery {
    public enum Failure: Error, Equatable, CustomStringConvertible {
        case notFound(String)
        case ambiguous(String, candidates: [ItemID])

        public var description: String {
            switch self {
            case let .notFound(q):
                return "no item matches '\(q)'"
            case let .ambiguous(q, candidates):
                return "'\(q)' matches several items: \(candidates.map(\.rawValue).joined(separator: ", "))"
            }
        }
    }

    /// Exact ItemID wins, then exact bundle ID (first item of the app when it has several), then an exact
    /// (case-insensitive) display or app name, then a unique case-insensitive substring of the display name, app name
    /// or bundle ID.
    public static func find(_ query: String, in items: [MenuBarItem]) -> Result<MenuBarItem, Failure> {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return .failure(.notFound(q)) }
        if let exact = items.first(where: { $0.id.rawValue == q }) { return .success(exact) }

        let byBundle = items.filter { $0.ownerBundleID.caseInsensitiveCompare(q) == .orderedSame }
        if let first = byBundle.first { return .success(first) }

        if let byIdentifier = items.first(where: { $0.axIdentifier == q }) { return .success(byIdentifier) }

        // "Meters" names the app even when "Meters Pro" exists too.
        let byName = items.filter {
            $0.displayName.caseInsensitiveCompare(q) == .orderedSame || $0.appName.caseInsensitiveCompare(q) == .orderedSame
        }
        if !byName.isEmpty { return oneApp(byName, query: q) }

        let matches = items.filter {
            $0.displayName.localizedCaseInsensitiveContains(q)
                || $0.appName.localizedCaseInsensitiveContains(q)
                || $0.ownerBundleID.localizedCaseInsensitiveContains(q)
                || ($0.axIdentifier?.localizedCaseInsensitiveContains(q) ?? false)
        }
        if matches.isEmpty { return .failure(.notFound(q)) }
        return oneApp(matches, query: q)
    }

    /// `find`, and when nothing contains the query, a fuzzy match (`FuzzyMatcher`): the best kind of match wins if
    /// only one app has a match of that kind. Used by the control commands, where "mtrs" should still find Meters.
    public static func resolve(_ query: String, in items: [MenuBarItem]) -> Result<MenuBarItem, Failure> {
        let found = find(query, in: items)
        guard case .failure(.notFound) = found else { return found }
        let q = query.trimmingCharacters(in: .whitespaces)
        let ranked = FuzzyMatcher.rank(q, items: items, recents: [])
        guard let best = ranked.first, let kind = best.kind else { return found }
        let top = ranked.filter { $0.kind == kind }.map(\.item)
        return oneApp(Array(top.prefix(maxCandidates)), query: q)
    }

    /// Most candidates listed for an ambiguous reference.
    public static let maxCandidates = 12

    /// One match, or several items of one app (the first one stands for the app); otherwise ambiguous.
    private static func oneApp(_ matches: [MenuBarItem], query: String) -> Result<MenuBarItem, Failure> {
        if matches.count == 1 { return .success(matches[0]) }
        if Set(matches.map(\.ownerBundleID)).count == 1, !matches[0].ownerBundleID.isEmpty {
            return .success(matches[0])
        }
        return .failure(.ambiguous(query, candidates: matches.map(\.id)))
    }
}
