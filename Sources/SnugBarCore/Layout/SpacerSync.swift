import Foundation

/// What SnugBar does to its spacer status items to match the settings (feature 37).
///
/// Outside Zen a spacer's item lives as long as the spacer. In Zen the items leave the menu bar: macOS 27 gives even a
/// zero-length item a slot of its own plus the gaps beside it, so shrinking would leave a visible gap. They aren't
/// hidden either: hiding an autosaved status item (`isVisible = false`) makes AppKit treat it like an item the user
/// dragged out and drop its preferred position, so it would come back at the far left end of the status items. So Zen
/// removes each item after remembering its place (`stash`), and the end of Zen creates it again at that place with
/// its width (`restore`, the same path that places a spacer the layout moved).
public enum SpacerSync {
    public enum Step: Equatable, Sendable {
        case create(id: String, length: Double)
        case setLength(id: String, length: Double)
        /// The spacer is gone from the settings: remove its item and forget a place remembered for Zen.
        case remove(id: String)
        /// Zen: remember where the item is, then take it out of the menu bar.
        case stash(id: String)
        /// Zen ended: create the item again at the place remembered for it.
        case restore(id: String, length: Double, position: Double)
    }

    /// The spacer items as they are.
    public struct State: Equatable, Sendable {
        /// Items in the menu bar, by spacer ID, with their lengths.
        public var items: [String: Double]
        /// Places (order-file units: distance from the right end) of items taken out for Zen, by spacer ID. A spacer
        /// whose place wasn't known has no entry and is simply created again.
        public var stashed: [String: Double]

        public init(items: [String: Double] = [:], stashed: [String: Double] = [:]) {
            self.items = items
            self.stashed = stashed
        }
    }

    public static func steps(current: State, spacers: [LayoutSpacer], zen: Bool) -> [Step] {
        let wanted = Set(spacers.map(\.id))
        let known = Set(current.items.keys).union(current.stashed.keys)
        var steps: [Step] = known.sorted().filter { !wanted.contains($0) }.map { .remove(id: $0) }
        var seen = Set<String>()
        for spacer in spacers where seen.insert(spacer.id).inserted {
            let id = spacer.id
            if zen {
                // A spacer added during Zen gets its item when Zen ends.
                if current.items[id] != nil { steps.append(.stash(id: id)) }
            } else if let now = current.items[id] {
                if now != spacer.width { steps.append(.setLength(id: id, length: spacer.width)) }
            } else if let position = current.stashed[id] {
                steps.append(.restore(id: id, length: spacer.width, position: position))
            } else {
                steps.append(.create(id: id, length: spacer.width))
            }
        }
        return steps
    }

    /// Applies steps (what the items look like afterwards). `position` is where a stashed item is now (nil: unknown).
    public static func applying(_ steps: [Step], to current: State, position: (String) -> Double? = { _ in nil }) -> State {
        var result = current
        for step in steps {
            switch step {
            case let .create(id, length), let .restore(id, length, _):
                result.items[id] = length
                result.stashed[id] = nil
            case let .setLength(id, length):
                result.items[id] = length
            case let .remove(id):
                result.items[id] = nil
                result.stashed[id] = nil
            case let .stash(id):
                result.items[id] = nil
                result.stashed[id] = position(id)
            }
        }
        return result
    }
}
