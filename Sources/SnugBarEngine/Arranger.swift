import AppKit
import SnugBarCore

/// Moves menu bar items.
///
/// Primary: write the new position to the system order file (no pointer movement; items move live).
/// Fallback: synthetic ⌘-drag, with the pointer put back afterwards.
@MainActor
public final class Arranger {
    public enum Method: String, Codable, Sendable {
        case orderFile
        case drag
    }

    public enum Placement {
        /// Immediately left of the item.
        case before(MenuBarItem)
        /// Immediately right of the item.
        case after(MenuBarItem)

        var anchor: MenuBarItem {
            switch self {
            case let .before(i), let .after(i): return i
            }
        }
    }

    public struct Result: Codable, Sendable {
        public var method: Method
        /// Why the order file was not used, when it wasn't.
        public var fallbackReason: String?
        public var changes: [String: Double]?
        public var renumbered: Bool?
        public var backup: String?
        public var pointerBefore: PointerPosition
        public var pointerDuring: PointerPosition?
        public var pointerAfter: PointerPosition
        public var orderBefore: [String]
        public var orderAfter: [String]
        /// The moved item ended up next to the anchor on the requested side.
        public var verified: Bool
    }

    public enum ArrangeError: Error, CustomStringConvertible {
        case sameItem
        case notDraggable(String)

        public var description: String {
            switch self {
            case .sameItem: return "an item can't be moved relative to itself"
            case let .notDraggable(why): return "can't drag: \(why)"
            }
        }
    }

    private let reader: MenuBarReader
    private let access: OrderFileAccess
    /// Time for the menu bar to settle after a move before it is re-read.
    public var settleDelay: TimeInterval = 1.5

    /// Skip the order-file write and use the ⌘-drag fallback (testing, or when the user prefers it).
    public var forceDrag = false

    public init(reader: MenuBarReader, access: OrderFileAccess) {
        self.reader = reader
        self.access = access
    }

    public func move(_ item: MenuBarItem, _ placement: Placement) async throws -> Result {
        guard item.id != placement.anchor.id else { throw ArrangeError.sameItem }
        let pointerBefore = SyntheticInput.pointer
        let positions = try? access.readPositions()
        let orderBefore = reader.snapshot(orderPositions: positions).items.map(\.id.rawValue)

        var fallbackReason: String?
        if forceDrag {
            fallbackReason = "drag forced"
        } else if let positions {
            if item.id.isOrderFileKey, placement.anchor.id.isOrderFileKey {
                let corePlacement: OrderPlanner.Placement = {
                    switch placement {
                    case let .before(a): return .before(a.id.rawValue)
                    case let .after(a): return .after(a.id.rawValue)
                    }
                }()
                let plan = try OrderPlanner.plan(positions: positions, moving: item.id.rawValue, to: corePlacement)
                let backup = try access.write(changes: plan.changes)
                try? await Task.sleep(nanoseconds: UInt64(settleDelay * 1_000_000_000))
                let after = reader.snapshot(orderPositions: try? access.readPositions()).items.map(\.id.rawValue)
                return Result(
                    method: .orderFile, fallbackReason: nil, changes: plan.changes, renumbered: plan.renumbered,
                    backup: backup.lastPathComponent, pointerBefore: PointerPosition(pointerBefore), pointerDuring: nil,
                    pointerAfter: PointerPosition(SyntheticInput.pointer), orderBefore: orderBefore, orderAfter: after,
                    verified: Self.isPlaced(item.id.rawValue, placement, in: after)
                )
            }
            fallbackReason = "item IDs are not order-file keys (ambiguous mapping)"
        } else {
            fallbackReason = "no order file access"
        }

        // ⌘-drag fallback.
        let snapshot = reader.snapshot(orderPositions: positions)
        guard let source = snapshot.entry(for: item.id)?.item, let anchor = snapshot.entry(for: placement.anchor.id)?.item else {
            throw ArrangeError.notDraggable("item no longer in the menu bar")
        }
        guard !source.isOverflowed, !anchor.isOverflowed else {
            throw ArrangeError.notDraggable("item is in the system overflow")
        }
        let start = CGPoint(x: source.frame.midX, y: source.frame.midY)
        let endX: Double
        switch placement {
        case .before: endX = anchor.frame.minX + 2
        case .after: endX = anchor.frame.maxX - 2
        }
        let end = CGPoint(x: endX, y: anchor.frame.midY)
        await SyntheticInput.commandDrag(from: start, to: end)
        let during = SyntheticInput.pointer
        SyntheticInput.restorePointer(pointerBefore)
        try? await Task.sleep(nanoseconds: UInt64(settleDelay * 1_000_000_000))
        let after = reader.snapshot(orderPositions: try? access.readPositions()).items
        // Index-based IDs of one app can change after a drag; `verified` then reads false even if the move worked.
        let afterIDs = after.map(\.id.rawValue)
        return Result(
            method: .drag, fallbackReason: fallbackReason, changes: nil, renumbered: nil, backup: nil,
            pointerBefore: PointerPosition(pointerBefore), pointerDuring: PointerPosition(during),
            pointerAfter: PointerPosition(SyntheticInput.pointer), orderBefore: orderBefore, orderAfter: afterIDs,
            verified: Self.isPlaced(item.id.rawValue, placement, in: afterIDs)
        )
    }

    static func isPlaced(_ key: String, _ placement: Placement, in order: [String]) -> Bool {
        guard let i = order.firstIndex(of: key), let a = order.firstIndex(of: placement.anchor.id.rawValue) else {
            return false
        }
        switch placement {
        case .before: return i + 1 == a
        case .after: return a + 1 == i
        }
    }
}
