import Foundation

/// A gap in the menu bar (feature 37): an empty status item owned by SnugBar. Spacers live in Shown only, because
/// sections are per app and spacers belong to SnugBar.
public struct LayoutSpacer: Codable, Equatable, Hashable, Sendable, Identifiable {
    /// A UUID string; stable for the spacer's life.
    public var id: String
    /// Width in points, within `widthRange`.
    public var width: Double

    public static let defaultWidth: Double = 16
    public static let widthRange: ClosedRange<Double> = 1...64
    public static let keyPrefix = "spacer:"
    public static let autosavePrefix = "snugbar.spacer."

    public init(id: String = UUID().uuidString, width: Double = LayoutSpacer.defaultWidth) {
        self.id = id
        self.width = Self.clamped(width)
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        width = Self.clamped(try c.decodeIfPresent(Double.self, forKey: .width) ?? Self.defaultWidth)
    }

    /// A width rounded to whole points and kept within `widthRange`.
    public static func clamped(_ width: Double) -> Double {
        guard width.isFinite else { return defaultWidth }
        return min(max(width.rounded(), widthRange.lowerBound), widthRange.upperBound)
    }

    /// The spacer's key in the desired order: `spacer:<id>`.
    public var key: String { Self.keyPrefix + id }

    /// The status item's autosave name: `snugbar.spacer.<id>`.
    public var autosaveName: String { Self.autosavePrefix + id }

    /// The key the system order file would use for this spacer, if it gives SnugBar's items keys at all.
    public func orderFileKey(ownBundleID: String) -> String {
        ItemID.status(bundleID: ownBundleID, autosaveName: autosaveName).rawValue
    }

    public static func isSpacerKey(_ key: String) -> Bool { key.hasPrefix(keyPrefix) }

    /// `spacer:<id>` -> `<id>`.
    public static func id(fromKey key: String) -> String? {
        isSpacerKey(key) ? String(key.dropFirst(keyPrefix.count)) : nil
    }

    /// Maps spacer keys to their order-file keys, for the spacers the order file knows. Spacers it doesn't know are
    /// placed through their status item's own preferred position instead.
    public static func orderKeyMap(_ spacers: [LayoutSpacer], ownBundleID: String, positions: [String: Double]?) -> [String: String] {
        guard let positions else { return [:] }
        var map: [String: String] = [:]
        for spacer in spacers {
            let fileKey = spacer.orderFileKey(ownBundleID: ownBundleID)
            if positions[fileKey] != nil { map[spacer.key] = fileKey }
        }
        return map
    }
}

/// What the user arranged, which SnugBar keeps in place (features 78–80). Sections are per app and live in
/// `Settings.sections`; this holds the rest.
public struct DesiredLayout: Codable, Equatable, Sendable {
    /// Keys of Shown items left to right: order-file keys (or fallback item IDs) and spacer keys. Items that aren't
    /// in the menu bar now keep their slot, so a relaunched app goes back where it was. Empty means the order isn't
    /// enforced: nothing is moved until the user arranges items.
    public var shownOrder: [String]
    public var spacers: [LayoutSpacer]
    /// Keys of Hidden items left to right, kept like `shownOrder` but applied through the order file only (the items
    /// aren't on screen to drag). Empty means not enforced.
    public var hiddenOrder: [String]
    /// The same for Always Hidden.
    public var alwaysHiddenOrder: [String]

    public init(shownOrder: [String] = [], spacers: [LayoutSpacer] = [], hiddenOrder: [String] = [], alwaysHiddenOrder: [String] = []) {
        self.shownOrder = shownOrder
        self.spacers = spacers
        self.hiddenOrder = hiddenOrder
        self.alwaysHiddenOrder = alwaysHiddenOrder
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        shownOrder = try c.decodeIfPresent([String].self, forKey: .shownOrder) ?? []
        spacers = try c.decodeIfPresent([LayoutSpacer].self, forKey: .spacers) ?? []
        hiddenOrder = try c.decodeIfPresent([String].self, forKey: .hiddenOrder) ?? []
        alwaysHiddenOrder = try c.decodeIfPresent([String].self, forKey: .alwaysHiddenOrder) ?? []
    }

    public var enforcesOrder: Bool { !shownOrder.isEmpty }

    /// Some order is kept: Shown's, Hidden's or Always Hidden's.
    public var enforcesAnyOrder: Bool { enforcesOrder || !hiddenOrder.isEmpty || !alwaysHiddenOrder.isEmpty }

    /// The saved order of a section.
    public func order(for section: Section) -> [String] {
        switch section {
        case .shown: return shownOrder
        case .hidden: return hiddenOrder
        case .alwaysHidden: return alwaysHiddenOrder
        }
    }

    public mutating func setOrder(_ order: [String], for section: Section) {
        switch section {
        case .shown: shownOrder = order
        case .hidden: hiddenOrder = order
        case .alwaysHidden: alwaysHiddenOrder = order
        }
    }

    public func spacer(id: String) -> LayoutSpacer? { spacers.first { $0.id == id } }

    /// Adds a spacer at the left end of Shown (where macOS puts a new status item). Seeds the order from `live`
    /// when none is saved yet.
    public mutating func addSpacer(_ spacer: LayoutSpacer, live: [String]) {
        spacers.append(spacer)
        let base = shownOrder.isEmpty ? live : DesiredOrder.merging(live: live, into: shownOrder)
        shownOrder = [spacer.key] + base.filter { $0 != spacer.key }
    }

    public mutating func removeSpacer(id: String) {
        spacers.removeAll { $0.id == id }
        shownOrder.removeAll { $0 == LayoutSpacer.keyPrefix + id }
    }

    public mutating func setSpacerWidth(id: String, _ width: Double) {
        guard let i = spacers.firstIndex(where: { $0.id == id }) else { return }
        spacers[i].width = LayoutSpacer.clamped(width)
    }
}

/// Operations on a desired left-to-right order of keys.
public enum DesiredOrder {
    /// Apple's items: `module:` keys and fallback IDs of `com.apple.menuextra.*` items.
    public static func isAppleKey(_ key: String) -> Bool {
        let id = ItemID(rawValue: key)
        switch id.kind {
        case .module: return true
        case let .indexed(owner, _): return AppleItems.isAppleIdentifier(owner)
        case .status, .other: return false
        }
    }

    /// `desired` with every key of `live` it lacks. Keys in `atEnd` (items of newly seen apps) go after the last key
    /// that isn't one of Apple's; every other unknown key goes right of its nearest left neighbour in `live` that
    /// `desired` has (or left of its nearest right one), so it stays where it is.
    public static func merging(live: [String], into desired: [String], atEnd: Set<String> = []) -> [String] {
        var result = desired
        var known = Set(desired)
        for key in live where !known.contains(key) && atEnd.contains(key) {
            let insert = (result.lastIndex { !isAppleKey($0) }).map { $0 + 1 } ?? 0
            result.insert(key, at: insert)
            known.insert(key)
        }
        for (i, key) in live.enumerated() where !known.contains(key) {
            if let left = live[..<i].last(where: known.contains), let at = result.firstIndex(of: left) {
                result.insert(key, at: at + 1)
            } else if let right = live[(i + 1)...].first(where: known.contains), let at = result.firstIndex(of: right) {
                result.insert(key, at: at)
            } else {
                result.append(key)
            }
            known.insert(key)
        }
        return result
    }

    /// The keys of `live` in the order `desired` gives them (after merging unknown ones in).
    public static func target(desired: [String], live: [String]) -> [String] {
        let present = Set(live)
        return merging(live: live, into: desired).filter(present.contains)
    }

    /// Present keys take their order from `live`; absent keys keep their slots. Used when the user arranged the bar
    /// by hand (⌘-drag) or in the editor.
    public static func adopting(live: [String], into desired: [String]) -> [String] {
        var merged = merging(live: live, into: desired)
        let present = Set(live)
        var seen = Set<String>()
        let liveOrder = live.filter { seen.insert($0).inserted }
        let slots = merged.indices.filter { present.contains(merged[$0]) }
        for (slot, key) in zip(slots, liveOrder) { merged[slot] = key }
        return merged
    }

    /// Moves `keys` (as one block, in the given order) next to `anchor`. Keys missing from `order` are inserted.
    public static func moving(_ keys: [String], to placement: OrderPlanner.Placement, in order: [String]) -> [String] {
        let moving = Set(keys)
        guard !moving.contains(placement.anchor) else { return order }
        var result = order.filter { !moving.contains($0) }
        guard let a = result.firstIndex(of: placement.anchor) else { return result + keys }
        switch placement {
        case .before: result.insert(contentsOf: keys, at: a)
        case .after: result.insert(contentsOf: keys, at: a + 1)
        }
        return result
    }

    /// Replaces fallback IDs (`<bundle>#<index>`) by the order-file keys they stand for, when the order file says
    /// which, and drops duplicates (first one wins).
    public static func normalized(_ order: [String], positions: [String: Double]?) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for key in order {
            var k = key
            let id = ItemID(rawValue: key)
            if case .indexed = id.kind, let fileKey = ItemIdentityResolver.equivalentIDs(of: id, orderPositions: positions).first {
                k = fileKey.rawValue
            }
            if seen.insert(k).inserted { result.append(k) }
        }
        return result
    }

    /// Replaces keys through `map` (and back, with the inverse map).
    public static func mapped(_ order: [String], _ map: [String: String]) -> [String] {
        guard !map.isEmpty else { return order }
        return order.map { map[$0] ?? $0 }
    }
}
