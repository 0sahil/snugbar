import Foundation

/// What SnugBar does to its spacer status items to match the settings (feature 37).
///
/// A spacer's item lives as long as the spacer: it is created once and removed only when the spacer is removed. Zen
/// doesn't take spacers out of the menu bar; it shrinks them to zero width. Hiding an autosaved status item
/// (`isVisible = false`) makes AppKit treat it like an item the user dragged out: it records it as not visible and
/// drops its preferred position, so when it is shown again macOS puts it back at the far left end of the status items
/// (often behind the notch or in the overflow) instead of where it was. A zero-width item keeps its place.
public enum SpacerSync {
    public enum Step: Equatable, Sendable {
        case create(id: String, length: Double)
        case setLength(id: String, length: Double)
        case remove(id: String)
    }

    /// The width a spacer's item gets.
    public static func length(of spacer: LayoutSpacer, zen: Bool) -> Double {
        zen ? 0 : spacer.width
    }

    /// - Parameter current: the items there are now, by spacer ID, with their lengths.
    public static func steps(current: [String: Double], spacers: [LayoutSpacer], zen: Bool) -> [Step] {
        let wanted = Set(spacers.map(\.id))
        var steps: [Step] = current.keys.sorted().filter { !wanted.contains($0) }.map { .remove(id: $0) }
        var seen = Set<String>()
        for spacer in spacers where seen.insert(spacer.id).inserted {
            let length = length(of: spacer, zen: zen)
            if let now = current[spacer.id] {
                if now != length { steps.append(.setLength(id: spacer.id, length: length)) }
            } else {
                steps.append(.create(id: spacer.id, length: length))
            }
        }
        return steps
    }

    /// Applies steps to a list of lengths (what the items look like afterwards).
    public static func applying(_ steps: [Step], to current: [String: Double]) -> [String: Double] {
        var result = current
        for step in steps {
            switch step {
            case let .create(id, length), let .setLength(id, length): result[id] = length
            case let .remove(id): result[id] = nil
            }
        }
        return result
    }
}
