import Foundation

/// Plans writes to the system order file.
///
/// Positions are distances from the right edge of the screen: larger values sit further left. Moving an item means
/// giving it a value strictly between its new neighbours. Whole numbers are preferred; when no whole number fits,
/// every key is renumbered with even spacing, keeping the current order.
public enum OrderPlanner {
    /// Where to put the moved item, relative to another key, reading left to right.
    public enum Placement: Equatable, Sendable {
        /// Immediately to the left of the key.
        case before(String)
        /// Immediately to the right of the key.
        case after(String)

        public var anchor: String {
            switch self {
            case let .before(k), let .after(k): return k
            }
        }
    }

    public struct Plan: Equatable, Sendable {
        /// Keys whose value changes, with their new values.
        public var changes: [String: Double]
        /// True when no value fitted between the neighbours and all keys were respaced.
        public var renumbered: Bool
        /// Resulting left-to-right order of all keys.
        public var resultingOrder: [String]
    }

    public enum PlanError: Error, Equatable, CustomStringConvertible {
        case unknownAnchor(String)
        case anchorIsMovedItem

        public var description: String {
            switch self {
            case let .unknownAnchor(k): return "'\(k)' is not in the order file"
            case .anchorIsMovedItem: return "an item can't be moved relative to itself"
            }
        }
    }

    /// Default gap used when placing past either end and when renumbering.
    public static let defaultSpacing: Double = 32

    /// Keys sorted left to right (largest position first; ties broken by key for determinism).
    public static func leftToRight(_ positions: [String: Double]) -> [String] {
        positions.sorted { a, b in a.value != b.value ? a.value > b.value : a.key < b.key }.map(\.key)
    }

    /// - Parameters:
    ///   - positions: current `TrailingItemPreferredPositions`.
    ///   - key: the key to move. It may be missing from `positions` (it is then inserted).
    ///   - placement: the new place.
    public static func plan(
        positions: [String: Double],
        moving key: String,
        to placement: Placement,
        spacing: Double = defaultSpacing
    ) throws -> Plan {
        let anchor = placement.anchor
        guard anchor != key else { throw PlanError.anchorIsMovedItem }
        guard let anchorValue = positions[anchor] else { throw PlanError.unknownAnchor(anchor) }

        var others = positions
        others.removeValue(forKey: key)
        let order = leftToRight(others)
        let anchorIndex = order.firstIndex(of: anchor)!

        // Neighbours as (left, right) values; left is larger.
        let leftValue: Double?
        let rightValue: Double?
        let insertIndex: Int
        switch placement {
        case .before:
            leftValue = anchorIndex > 0 ? others[order[anchorIndex - 1]] : nil
            rightValue = anchorValue
            insertIndex = anchorIndex
        case .after:
            leftValue = anchorValue
            rightValue = anchorIndex + 1 < order.count ? others[order[anchorIndex + 1]] : nil
            insertIndex = anchorIndex + 1
        }

        var resultingOrder = order
        resultingOrder.insert(key, at: insertIndex)

        if let value = valueBetween(left: leftValue, right: rightValue, spacing: spacing) {
            var changes: [String: Double] = [:]
            if positions[key] != value { changes[key] = value }
            return Plan(changes: changes, renumbered: false, resultingOrder: resultingOrder)
        }

        // No room: respace everything, rightmost first.
        var changes: [String: Double] = [:]
        for (i, k) in resultingOrder.reversed().enumerated() {
            let value = spacing * Double(i + 1)
            if positions[k] != value { changes[k] = value }
        }
        return Plan(changes: changes, renumbered: true, resultingOrder: resultingOrder)
    }

    /// A whole number strictly between the neighbours, or nil when there is none.
    /// `left` is the larger value (or nil at the left end); `right` the smaller (or nil at the right end).
    static func valueBetween(left: Double?, right: Double?, spacing: Double) -> Double? {
        switch (left, right) {
        case let (nil, r?):
            return (r + spacing).rounded(.down)
        case let (l?, nil):
            // Right end: halfway to zero, kept positive.
            let v = (l / 2).rounded(.down)
            return v > 0 && v < l ? v : nil
        case let (l?, r?):
            let v = ((l + r) / 2).rounded(.down)
            return v > r && v < l ? v : nil
        case (nil, nil):
            return spacing
        }
    }

    /// Applies a plan to a dictionary.
    public static func apply(_ plan: Plan, to positions: [String: Double]) -> [String: Double] {
        positions.merging(plan.changes) { _, new in new }
    }
}
