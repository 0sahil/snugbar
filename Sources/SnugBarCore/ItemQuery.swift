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

    /// Exact ItemID wins, then exact bundle ID (first item of the app when it has several), then a unique
    /// case-insensitive substring of the display name, app name or bundle ID.
    public static func find(_ query: String, in items: [MenuBarItem]) -> Result<MenuBarItem, Failure> {
        let q = query.trimmingCharacters(in: .whitespaces)
        if let exact = items.first(where: { $0.id.rawValue == q }) { return .success(exact) }

        let byBundle = items.filter { $0.ownerBundleID.caseInsensitiveCompare(q) == .orderedSame }
        if let first = byBundle.first { return .success(first) }

        if let byIdentifier = items.first(where: { $0.axIdentifier == q }) { return .success(byIdentifier) }

        let matches = items.filter {
            $0.displayName.localizedCaseInsensitiveContains(q)
                || $0.appName.localizedCaseInsensitiveContains(q)
                || $0.ownerBundleID.localizedCaseInsensitiveContains(q)
                || ($0.axIdentifier?.localizedCaseInsensitiveContains(q) ?? false)
        }
        switch matches.count {
        case 0: return .failure(.notFound(q))
        case 1: return .success(matches[0])
        default:
            // Several items of one app count as one match.
            if Set(matches.map(\.ownerBundleID)).count == 1, !matches[0].ownerBundleID.isEmpty {
                return .success(matches[0])
            }
            return .failure(.ambiguous(q, candidates: matches.map(\.id)))
        }
    }
}
