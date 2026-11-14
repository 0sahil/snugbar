import Foundation

/// Planning a whole desired order (features 78–80): the moves and order-file changes that bring the items in the
/// menu bar now into the order the user arranged.
extension OrderPlanner {
    /// One item move, relative to another key. Applied in order, the moves turn the live order into the target.
    public struct Move: Codable, Equatable, Sendable {
        public var key: String
        /// The key it goes immediately left of, or nil.
        public var before: String?
        /// The key it goes immediately right of, or nil.
        public var after: String?

        public init(key: String, _ placement: Placement) {
            self.key = key
            switch placement {
            case let .before(k): before = k
            case let .after(k): after = k
            }
        }

        public var placement: Placement {
            if let after { return .after(after) }
            return .before(before ?? "")
        }
    }

    public struct LayoutPlan: Codable, Equatable, Sendable {
        /// The desired order with unknown live keys merged in (what to save).
        public var desiredOrder: [String]
        /// `desiredOrder` differs from the order passed in.
        public var desiredChanged: Bool
        /// The keys considered, as they are now, left to right.
        public var liveOrder: [String]
        /// The same keys in the desired order.
        public var targetOrder: [String]
        /// Moves for the ⌘-drag fallback, relative to `liveOrder`.
        public var moves: [Move]
        /// Order-file values to write (empty without the order file or when nothing is out of place).
        public var changes: [String: Double]
        public var renumbered: Bool
        /// Keys of `targetOrder` that the order file doesn't have, so a write can't place them.
        public var unplaced: [String]
        /// For unplaced spacer keys that are out of place: the position value they should get (the spacer's own
        /// preferred position, in the same units as the order file).
        public var freePositions: [String: Double]

        /// Nothing to do.
        public var isNoOp: Bool { moves.isEmpty && changes.isEmpty && freePositions.isEmpty }
    }

    /// Plans the order of the keys in `live` (left to right, as they are in the menu bar now) so they follow
    /// `desired`. Absent desired keys are ignored but keep their slot in `desiredOrder`; live keys missing from
    /// `desired` are merged in (`newKeys` at the end of the third-party items, others where they are).
    /// - Parameter positions: the order file. With it, `changes` holds the values to write; keys the file lacks are
    ///   reported as `unplaced`.
    public static func planLayout(
        desired: [String], live: [String], positions: [String: Double]?, newKeys: Set<String> = [],
        spacing: Double = defaultSpacing
    ) -> LayoutPlan {
        var seen = Set<String>()
        let live = live.filter { seen.insert($0).inserted }
        let merged = desired.isEmpty ? live : DesiredOrder.merging(live: live, into: desired, atEnd: newKeys)
        let present = Set(live)
        let target = merged.filter(present.contains)
        let moves = movesTurning(live, into: target)

        var changes: [String: Double] = [:]
        var renumbered = false
        var unplaced: [String] = []
        var free: [String: Double] = [:]
        if let positions {
            let placeable = target.filter { positions[$0] != nil }
            let placeableSet = Set(placeable)
            let fileLive = leftToRight(positions).filter(placeableSet.contains)
            var working = positions
            for move in movesTurning(fileLive, into: placeable) {
                guard let plan = try? plan(positions: working, moving: move.key, to: move.placement, spacing: spacing) else { continue }
                renumbered = renumbered || plan.renumbered
                working = apply(plan, to: working)
            }
            for (key, value) in working where positions[key] != value { changes[key] = value }

            unplaced = target.filter { positions[$0] == nil }
            // Only spacers can be placed outside the order file (through their status item's preferred position).
            for key in unplaced where LayoutSpacer.isSpacerKey(key) {
                guard let t = target.firstIndex(of: key), let l = live.firstIndex(of: key) else { continue }
                let inPlace = !renumbered
                    && (t > 0 ? target[t - 1] : nil) == (l > 0 ? live[l - 1] : nil)
                    && (t + 1 < target.count ? target[t + 1] : nil) == (l + 1 < live.count ? live[l + 1] : nil)
                if inPlace { continue }
                let left = target[..<t].last { working[$0] != nil }.flatMap { working[$0] }
                let right = target[(t + 1)...].first { working[$0] != nil }.flatMap { working[$0] }
                if let value = valueBetween(left: left, right: right, spacing: spacing) { free[key] = value }
            }
        }
        return LayoutPlan(
            desiredOrder: merged, desiredChanged: !desired.isEmpty && merged != desired, liveOrder: live,
            targetOrder: target, moves: moves, changes: changes, renumbered: renumbered, unplaced: unplaced,
            freePositions: free
        )
    }

    /// The fewest single-item moves that turn `live` into `target` (same keys, other order): the longest run of keys
    /// already in target order stays; every other key is placed right of its target predecessor (or left
    /// of the first key that stays, for the leftmost), working left to right.
    public static func movesTurning(_ live: [String], into target: [String]) -> [Move] {
        guard live != target, target.count > 1 else { return [] }
        let index = Dictionary(target.enumerated().map { ($1, $0) }, uniquingKeysWith: { a, _ in a })
        let sequence = live.compactMap { index[$0] }
        let kept = Set(longestIncreasing(sequence).map { target[$0] })
        guard let firstKept = target.first(where: kept.contains) else { return [] }
        var moves: [Move] = []
        for (i, key) in target.enumerated() where !kept.contains(key) {
            moves.append(i > 0 ? Move(key: key, .after(target[i - 1])) : Move(key: key, .before(firstKept)))
        }
        return moves
    }

    /// Applies moves to a list (for checks and the drag fallback's bookkeeping).
    public static func applying(_ moves: [Move], to order: [String]) -> [String] {
        moves.reduce(order) { DesiredOrder.moving([$1.key], to: $1.placement, in: $0) }
    }

    /// The values of one longest strictly increasing subsequence.
    static func longestIncreasing(_ values: [Int]) -> [Int] {
        guard !values.isEmpty else { return [] }
        var tails: [Int] = [] // index into values of the smallest tail of each length
        var previous = [Int](repeating: -1, count: values.count)
        for (i, v) in values.enumerated() {
            var lo = 0, hi = tails.count
            while lo < hi {
                let mid = (lo + hi) / 2
                if values[tails[mid]] < v { lo = mid + 1 } else { hi = mid }
            }
            if lo > 0 { previous[i] = tails[lo - 1] }
            if lo == tails.count { tails.append(i) } else { tails[lo] = i }
        }
        var result: [Int] = []
        var i = tails.last ?? -1
        while i >= 0 {
            result.append(values[i])
            i = previous[i]
        }
        return result.reversed()
    }
}
