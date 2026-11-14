import Foundation

/// The order inside Hidden and Always Hidden (feature 30).
///
/// Their items are usually not on screen, so the order is read from and written to the system order file only: a
/// reorder gives the section's items the order-file values they already hold, in the new order. Items of other
/// sections keep their values, so where a hidden item shows up between Shown items when the section is expanded doesn't
/// change; only the hidden items swap places among themselves. Without the order file a section can't be reordered.
public enum SectionOrder {
    /// The sections ordered this way.
    public static let sections: [Section] = [.hidden, .alwaysHidden]

    /// The key the order file knows an item by: its own ID, or the order-file key its fallback ID stands for. Nil when
    /// the file has neither.
    public static func fileKey(for id: ItemID, positions: [String: Double]) -> String? {
        if positions[id.rawValue] != nil { return id.rawValue }
        return ItemIdentityResolver.equivalentIDs(of: id, orderPositions: positions)
            .first { positions[$0.rawValue] != nil }?.rawValue
    }

    /// The keys the file has, each once, left to right by their values (larger is further left).
    public static func leftToRight(_ keys: [String], positions: [String: Double]) -> [String] {
        var seen = Set<String>()
        let known = keys.filter { positions[$0] != nil && seen.insert($0).inserted }
        return known.sorted { a, b in
            let va = positions[a]!, vb = positions[b]!
            return va != vb ? va > vb : a < b
        }
    }

    public struct Plan: Codable, Equatable, Sendable {
        /// The section's keys as the order file has them now, left to right.
        public var liveOrder: [String]
        /// The same keys in the desired order.
        public var targetOrder: [String]
        /// The desired order with keys it lacked merged in (what to save).
        public var desiredOrder: [String]
        public var desiredChanged: Bool
        /// Order-file values to write: the section's own values, handed out in the target order.
        public var changes: [String: Double]

        public var isNoOp: Bool { changes.isEmpty }
    }

    /// Plans a section's order.
    /// - Parameters:
    ///   - desired: the saved order (order-file keys; fallback IDs should be normalized first).
    ///   - keys: the order-file keys of the section's items, any order. Keys the file lacks are ignored.
    public static func plan(desired: [String], keys: [String], positions: [String: Double]) -> Plan {
        let live = leftToRight(keys, positions: positions)
        let merged = desired.isEmpty ? live : DesiredOrder.merging(live: live, into: desired)
        let present = Set(live)
        let target = merged.filter(present.contains)
        var changes: [String: Double] = [:]
        // Ties would leave the order up to the system: only plan when every value is distinct.
        let values = live.map { positions[$0]! }
        if Set(values).count == values.count {
            for (key, value) in zip(target, values) where positions[key] != value { changes[key] = value }
        }
        return Plan(liveOrder: live, targetOrder: target, desiredOrder: merged,
                    desiredChanged: !desired.isEmpty && merged != desired, changes: changes)
    }

    /// Puts the items of Hidden and Always Hidden in their section's order, leaving every other item where it is: the
    /// order file's order first (when readable), then the saved order for the keys it has. Used to list hidden items
    /// in the layout editor and the SnugBar Bar in the order they take when the section is expanded.
    public static func arranged(
        _ items: [MenuBarItem], sections map: AppSectionMap, layout: DesiredLayout, positions: [String: Double]?
    ) -> [MenuBarItem] {
        var result = items
        for section in sections {
            let slots = items.indices.filter { !items[$0].isAppleItem && map.section(for: items[$0]) == section }
            guard slots.count > 1 else { continue }
            var list = slots.map { items[$0] }
            // Each item under the key the order file and the saved order use.
            let key: (MenuBarItem) -> String = { item in
                positions.flatMap { fileKey(for: item.id, positions: $0) } ?? item.id.rawValue
            }
            if let positions {
                let value = { (item: MenuBarItem) in positions[key(item)] }
                // Stable: items the file doesn't know keep their relative order, after the ones it does.
                list = list.enumerated().sorted { a, b in
                    switch (value(a.element), value(b.element)) {
                    case let (va?, vb?): return va != vb ? va > vb : a.offset < b.offset
                    case (.some, nil): return true
                    case (nil, .some): return false
                    case (nil, nil): return a.offset < b.offset
                    }
                }.map(\.element)
            }
            let desired = DesiredOrder.normalized(layout.order(for: section), positions: positions)
            if !desired.isEmpty {
                let keys = list.map(key)
                let order = DesiredOrder.target(desired: desired, live: keys)
                var byKey: [String: [MenuBarItem]] = [:]
                for item in list { byKey[key(item), default: []].append(item) }
                var seen = Set<String>()
                list = order.filter { seen.insert($0).inserted }.flatMap { byKey[$0] ?? [] }
            }
            for (slot, item) in zip(slots, list) { result[slot] = item }
        }
        return result
    }
}
