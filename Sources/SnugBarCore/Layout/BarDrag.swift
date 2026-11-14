import Foundation

/// A press on a SnugBar Bar tile: a click, or a drag once the pointer has moved far enough with the button down.
///
/// A press that never reaches the threshold is always a click, so a slightly shaky click still opens the item.
public struct BarPress: Equatable, Sendable {
    /// Points the pointer must move (with the button down) before a press becomes a drag.
    public static let dragThreshold: Double = 4

    public enum Release: Equatable, Sendable {
        /// Open the tile's item.
        case click
        /// Drop the dragged tile.
        case drop
        /// Nothing: the press was cancelled (Esc) or ended away from the tile without dragging.
        case nothing
    }

    public let startX: Double
    public let startY: Double
    /// Whether this tile may be dragged at all. When not, moving never starts a drag.
    public let canDrag: Bool
    public private(set) var isDragging = false
    public private(set) var isCancelled = false

    public init(x: Double, y: Double, canDrag: Bool) {
        startX = x
        startY = y
        self.canDrag = canDrag
    }

    /// The distance from where the press started.
    public func distance(toX x: Double, y: Double) -> Double {
        ((x - startX) * (x - startX) + (y - startY) * (y - startY)).squareRoot()
    }

    /// The pointer moved with the button down. Returns true when this move starts the drag.
    public mutating func moved(toX x: Double, y: Double) -> Bool {
        guard canDrag, !isDragging, !isCancelled else { return false }
        guard distance(toX: x, y: y) >= Self.dragThreshold else { return false }
        isDragging = true
        return true
    }

    /// Esc: the drag (or press) ends without doing anything, even when the button is released over the tile.
    public mutating func cancel() {
        isCancelled = true
        isDragging = false
    }

    /// The button went up.
    /// - Parameter insideTile: the pointer is over the tile the press started on.
    public func released(atX x: Double, y: Double, insideTile: Bool) -> Release {
        if isCancelled { return .nothing }
        if isDragging { return .drop }
        return insideTile || distance(toX: x, y: y) < Self.dragThreshold ? .click : .nothing
    }
}

/// Reordering in the SnugBar Bar (drag a tile within its group, or onto the other group to move its app there).
///
/// Writes go through the layout editor's path: the drop becomes a `LayoutDrop` outcome for Hidden or Always Hidden,
/// applied through the order file. Coordinates are the bar's own, top-left origin.
public enum BarDrag {
    /// The section a group reorders, or nil when it isn't a section that can be ordered from the bar: "Didn't fit"
    /// (shown apps moved out for room) and, while swapped, the Hidden group (it lists Shown's apps then).
    public static func section(of group: BarGroupKind, swapped: Bool) -> Section? {
        switch group {
        case .hidden: return swapped ? nil : .hidden
        case .alwaysHidden: return .alwaysHidden
        case .didntFit: return nil
        }
    }

    /// Whether the order file knows one of the tile's items (an app's placeholder usually has no key).
    public static func hasOrderKey(_ tile: BarTile, positions: [String: Double]) -> Bool {
        tile.items.contains { SectionOrder.fileKey(for: $0.id, positions: positions) != nil }
    }

    /// Whether a tile may be dragged.
    /// - Parameter positions: the order file, or nil without Menu Bar folder access (then nothing is draggable).
    public static func canDrag(_ tile: BarTile, in group: BarGroupKind, swapped: Bool, positions: [String: Double]?) -> Bool {
        guard let positions, section(of: group, swapped: swapped) != nil else { return false }
        return hasOrderKey(tile, positions: positions)
    }

    /// The group under a point, allowing `slop` points around each group's frame. Nil when the point is away from
    /// every group (the drop is cancelled).
    public static func group(atX x: Double, y: Double, frames: [BarGroupKind: Rect], slop: Double = 8) -> BarGroupKind? {
        let hits = frames.filter { $0.value.insetBy(dx: -slop, dy: -slop).contains(x: x, y: y) }
        // Groups are stacked; when the slop overlaps two, the nearer one by vertical distance wins.
        return hits.min { a, b in
            let da = verticalDistance(y, a.value), db = verticalDistance(y, b.value)
            return da != db ? da < db : a.key.rawValue < b.key.rawValue
        }?.key
    }

    /// The tiles' lines: runs of consecutive tiles whose vertical centres are within half a tile of the line's first.
    static func lines(_ frames: [Rect]) -> [Range<Int>] {
        var result: [Range<Int>] = []
        var start = 0
        for i in frames.indices.dropFirst() where abs(frames[i].midY - frames[start].midY) > max(frames[start].height, 1) / 2 {
            result.append(start..<i)
            start = i
        }
        if !frames.isEmpty { result.append(start..<frames.count) }
        return result
    }

    private static func verticalDistance(_ y: Double, _ r: Rect) -> Double {
        max(r.minY - y, 0, y - r.maxY)
    }

    private static func lineSpan(_ frames: [Rect], _ line: Range<Int>) -> (minY: Double, maxY: Double) {
        (line.map { frames[$0].minY }.min() ?? 0, line.map { frames[$0].maxY }.max() ?? 0)
    }

    /// The line a pointer is on: the one whose height contains it, else the nearest.
    private static func line(at y: Double, in frames: [Rect]) -> Range<Int>? {
        lines(frames).min { a, b in
            let sa = lineSpan(frames, a), sb = lineSpan(frames, b)
            return max(sa.minY - y, 0, y - sa.maxY) < max(sb.minY - y, 0, y - sb.maxY)
        }
    }

    /// Insertion index in a group (0 = before the first tile) for the pointer: on the pointer's line (the group may
    /// wrap), before the first tile whose centre is right of the pointer, else after the line's last tile.
    /// - Parameter frames: the group's tile frames in order (left to right, line by line).
    public static func dropIndex(frames: [Rect], x: Double, y: Double) -> Int {
        guard let line = line(at: y, in: frames) else { return 0 }
        return line.first { x < frames[$0].midX } ?? line.upperBound
    }

    /// Where the insertion marker goes for a gap: in the gap before tile `gap`, or after the last tile of the
    /// pointer's line when the gap is at a line's end (a gap at a wrap is both; the pointer's line decides).
    public static func insertionMarker(frames: [Rect], gap: Int, y: Double, width: Double = 2, spacing: Double = 2) -> Rect? {
        guard !frames.isEmpty, gap >= 0, gap <= frames.count else { return nil }
        let pointerLine = line(at: y, in: frames)
        func before(_ f: Rect) -> Rect { Rect(x: f.minX - (spacing + width) / 2, y: f.minY, width: width, height: f.height) }
        func after(_ f: Rect) -> Rect { Rect(x: f.maxX + (spacing - width) / 2, y: f.minY, width: width, height: f.height) }
        if gap == frames.count { return after(frames[gap - 1]) }
        if gap > 0, let pointerLine, pointerLine.contains(gap - 1), !pointerLine.contains(gap) { return after(frames[gap - 1]) }
        return before(frames[gap])
    }

    public enum Outcome: Equatable, Sendable {
        /// The section's new order of keys (left to right) and the apps that move into it (`LayoutDrop.Outcome`).
        case reorder(Section, order: [String], appsIn: [String])
        /// The drop changes nothing.
        case none
        /// Not something the bar can order: "Didn't fit", a placeholder the order file doesn't know, the swapped
        /// Hidden group, or no Menu Bar folder access.
        case notAllowed
    }

    /// What dropping a tile does.
    /// - Parameters:
    ///   - from: the section of the group the tile came from (`section(of:swapped:)`).
    ///   - onto: the section of the group it was dropped on.
    ///   - gap: insertion index in `row` (from `dropIndex`).
    ///   - row: the target group's tiles now, the dragged tile included when it is the same group.
    ///   - positions: the order file, or nil without access.
    public static func outcome(
        dragging tile: BarTile, from: Section?, onto: Section?, gap: Int, row: [BarTile], positions: [String: Double]?
    ) -> Outcome {
        guard let positions, let from, let onto, SectionOrder.sections.contains(from), SectionOrder.sections.contains(onto),
              hasOrderKey(tile, positions: positions)
        else { return .notAllowed }
        let dragged = LayoutTile(key: tile.id.rawValue, items: tile.items, section: from)
        let targetRow = row.map { LayoutTile(key: $0.id.rawValue, items: $0.items, section: onto) }
        switch LayoutDrop.outcome(dragging: LayoutDragContents(tiles: [dragged]), onto: onto, gap: gap, row: targetRow) {
        case let .reorder(section, order, appsIn): return .reorder(section, order: order, appsIn: appsIn)
        // With a gap, the editor's logic always orders the row; a bare move can't come back.
        case .moveApps: return .notAllowed
        case .none: return .none
        }
    }
}
