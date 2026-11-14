import Foundation

/// One tile in the layout editor (features 30, 42): a menu bar item, several items of one app that share a picture,
/// or a spacer.
public struct LayoutTile: Equatable, Sendable, Identifiable {
    /// The item's ID, the first item's ID for an app tile, or the spacer's key.
    public var key: String
    /// Left to right; empty for a spacer.
    public var items: [MenuBarItem]
    public var spacer: LayoutSpacer?
    public var section: Section
    /// The clock and Control Center: shown, but macOS doesn't let them move.
    public var isLocked: Bool

    public init(key: String, items: [MenuBarItem], spacer: LayoutSpacer? = nil, section: Section, isLocked: Bool = false) {
        self.key = key
        self.items = items
        self.spacer = spacer
        self.section = section
        self.isLocked = isLocked
    }

    public var id: String { key }
    public var isSpacer: Bool { spacer != nil }
    public var isAppleItem: Bool { items.first?.isAppleItem ?? false }

    /// The app that moves when the tile changes section: nil for spacers and Apple's items.
    public var bundleID: String? {
        guard let first = items.first, !first.isAppleItem, !first.ownerBundleID.isEmpty else { return nil }
        return first.ownerBundleID
    }

    /// The keys this tile stands for in the desired order.
    public var orderKeys: [String] {
        spacer.map { [$0.key] } ?? items.map(\.id.rawValue)
    }

    /// Tooltip text: the item's name, the app and its item count for an app tile, or what a spacer is.
    public var helpText: String {
        if let spacer { return "Spacer, \(Int(spacer.width)) pt" }
        guard let first = items.first else { return "" }
        if isLocked { return "\(first.displayName): macOS keeps this item at the right end, so it can’t be moved" }
        return BarTile(items: items).helpText
    }
}

/// Builds the editor's three rows.
public enum LayoutEditorRows {
    /// - Parameters:
    ///   - items: every known item (live, then remembered), left to right, SnugBar's own left out.
    ///   - liveShown: Shown keys in the menu bar now, left to right, spacers included (`LayoutReconcile.liveKeys`).
    ///   - positions: the order file, which orders Hidden and Always Hidden (with their saved orders).
    ///   - hasImage: whether an item has a picture of its own; Hidden items of one app without one share a tile.
    public static func rows(
        items: [MenuBarItem], liveShown: [String], sections: AppSectionMap, layout: DesiredLayout,
        positions: [String: Double]? = nil, hasImage: (MenuBarItem) -> Bool
    ) -> [Section: [LayoutTile]] {
        var shownItems: [String: MenuBarItem] = [:]
        var locked: [MenuBarItem] = []
        var others: [Section: [MenuBarItem]] = [:]
        for item in SectionOrder.arranged(items, sections: sections, layout: layout, positions: positions) {
            let section = sections.section(for: item)
            if item.isAppleItem && LayoutReconcile.isLocked(item) {
                locked.append(item)
            } else if section == .shown {
                if shownItems[item.id.rawValue] == nil { shownItems[item.id.rawValue] = item }
            } else {
                others[section, default: []].append(item)
            }
        }
        let spacers = Dictionary(layout.spacers.map { ($0.key, $0) }, uniquingKeysWith: { a, _ in a })
        let exists: (String) -> Bool = { shownItems[$0] != nil || spacers[$0] != nil }

        // Live order first; Shown items not in the menu bar now (remembered) follow, then spacers not placed yet.
        var base = liveShown.filter(exists)
        var placed = Set(base)
        for item in items where shownItems[item.id.rawValue] != nil && placed.insert(item.id.rawValue).inserted {
            base.append(item.id.rawValue)
        }
        // The saved order decides, with spacers and live items it lacks merged in; items not running drop out.
        let order = layout.enforcesOrder ? DesiredOrder.merging(live: base, into: layout.shownOrder).filter(exists) : base
        var shownKeys = order
        for spacer in layout.spacers where !shownKeys.contains(spacer.key) {
            shownKeys.insert(spacer.key, at: 0)
        }

        var shown: [LayoutTile] = shownKeys.compactMap { key in
            if let spacer = spacers[key] { return LayoutTile(key: key, items: [], spacer: spacer, section: .shown) }
            guard let item = shownItems[key] else { return nil }
            return LayoutTile(key: key, items: [item], section: .shown)
        }
        shown += locked.map { LayoutTile(key: $0.id.rawValue, items: [$0], section: .shown, isLocked: true) }

        var result: [Section: [LayoutTile]] = [.shown: shown]
        for section in [Section.hidden, .alwaysHidden] {
            result[section] = BarListing.tiles(for: others[section] ?? [], hasImage: hasImage).map {
                LayoutTile(key: $0.id.rawValue, items: $0.items, section: section)
            }
        }
        return result
    }
}

/// The editor's selection (features 31, SPEC 10b): click selects, ⌘-click toggles, ⇧-click extends within a section,
/// ⌘A selects all, Esc clears. Dragging a selected tile drags the whole selection.
public struct LayoutSelection: Equatable, Sendable {
    public enum Modifier: Sendable {
        case none
        case command
        case shift
    }

    public private(set) var keys: Set<String> = []
    /// Where a ⇧-click range starts.
    public private(set) var anchor: String?

    public init(keys: Set<String> = [], anchor: String? = nil) {
        self.keys = keys
        self.anchor = anchor
    }

    public var isEmpty: Bool { keys.isEmpty }

    public func contains(_ key: String) -> Bool { keys.contains(key) }

    /// - Parameter rows: each section's selectable tile keys, left to right.
    public mutating func click(_ key: String, modifier: Modifier, rows: [[String]]) {
        switch modifier {
        case .none:
            keys = [key]
            anchor = key
        case .command:
            if keys.remove(key) == nil {
                keys.insert(key)
                anchor = key
            } else if anchor == key {
                anchor = nil
            }
        case .shift:
            guard let anchor, let row = rows.first(where: { $0.contains(anchor) }), let a = row.firstIndex(of: anchor),
                  let b = row.firstIndex(of: key)
            else {
                keys = [key]
                self.anchor = key
                return
            }
            keys.formUnion(row[min(a, b)...max(a, b)])
        }
    }

    public mutating func selectAll(_ rows: [[String]]) {
        keys = Set(rows.joined())
        anchor = rows.first(where: { !$0.isEmpty })?.first
    }

    public mutating func clear() {
        keys = []
        anchor = nil
    }

    /// Keeps only keys still listed.
    public mutating func retain(_ rows: [[String]]) {
        let listed = Set(rows.joined())
        keys.formIntersection(listed)
        if let anchor, !listed.contains(anchor) { self.anchor = nil }
    }

    /// The tiles a drag starting on `key` carries, in row order: the selection when the tile is part of it, else
    /// just the tile.
    public func dragged(from key: String, rows: [[String]]) -> [String] {
        guard keys.contains(key) else { return [key] }
        return rows.joined().filter(keys.contains)
    }
}

/// What a drag in the editor carries.
public struct LayoutDragContents: Equatable, Sendable {
    public var tiles: [LayoutTile]

    public init(tiles: [LayoutTile]) {
        self.tiles = tiles
    }

    /// The apps the tiles belong to, each once, in tile order. Spacers and Apple's items have none.
    public var bundleIDs: [String] {
        var seen = Set<String>()
        return tiles.compactMap(\.bundleID).filter { seen.insert($0).inserted }
    }

    public var spacerCount: Int { tiles.filter(\.isSpacer).count }

    /// The keys to place in the desired order, in tile order.
    public var orderKeys: [String] { tiles.flatMap(\.orderKeys) }

    /// The count shown on the drag image: "3 apps", "2 apps, 1 spacer", "2 items"; nil for a single tile (the image
    /// says it all).
    public var label: String? {
        guard tiles.count > 1 else { return nil }
        let apps = bundleIDs.count
        let spacers = spacerCount
        func plural(_ n: Int, _ word: String) -> String { "\(n) \(word)\(n == 1 ? "" : "s")" }
        if apps > 1 || (apps == 1 && spacers > 0) {
            return spacers > 0 ? "\(plural(apps, "app")), \(plural(spacers, "spacer"))" : plural(apps, "app")
        }
        if spacers == tiles.count { return plural(spacers, "spacer") }
        return plural(tiles.count, "item")
    }
}

/// Where a drop lands in the editor.
public enum LayoutDrop {
    public enum Outcome: Equatable, Sendable {
        /// The section row's new order of keys (left to right) and the apps that move into the section.
        case reorder(Section, order: [String], appsIn: [String])
        /// Apps that change section.
        case moveApps([String], to: Section)
        /// Nothing to do, with a short reason for the editor's status line (nil when the drop changes nothing).
        case none(String?)
    }

    static let stayInShown = "Spacers and Apple’s items always stay in Shown."

    /// - Parameters:
    ///   - row: the target section's tiles now, left to right (in Shown, locked ones last).
    ///   - gap: insertion index in `row` (0 = before the first tile). Nil when the section can't be reordered (Hidden
    ///     and Always Hidden without the order file): the drop only moves apps into it.
    public static func outcome(dragging contents: LayoutDragContents, onto section: Section, gap: Int?, row: [LayoutTile]) -> Outcome {
        var tiles = contents.tiles.filter { !$0.isLocked }
        guard !tiles.isEmpty else { return .none(nil) }
        // Only apps go into Hidden and Always Hidden.
        let leftOut = section != .shown && tiles.contains { $0.bundleID == nil }
        if section != .shown { tiles = tiles.filter { $0.bundleID != nil } }
        guard !tiles.isEmpty else { return .none(leftOut ? stayInShown : nil) }
        let incoming = LayoutDragContents(tiles: tiles.filter { $0.section != section }).bundleIDs

        guard section == .shown || gap != nil else {
            if incoming.isEmpty {
                return .none(leftOut ? stayInShown : "\(section.title) can be reordered once SnugBar has Menu Bar folder access.")
            }
            return .moveApps(incoming, to: section)
        }
        let draggedKeys = Set(tiles.map(\.key))
        let movable = row.filter { !$0.isLocked }
        // Locked tiles stay at the right end: a gap past them means the end of the movable tiles.
        let limit = min(gap ?? movable.count, movable.count)
        let left = movable.prefix(limit).filter { !draggedKeys.contains($0.key) }
        let right = movable.dropFirst(limit).filter { !draggedKeys.contains($0.key) }
        let order = (left + tiles + right).flatMap(\.orderKeys)
        let current = movable.flatMap(\.orderKeys)
        if order == current && incoming.isEmpty { return .none(leftOut ? stayInShown : nil) }
        return .reorder(section, order: order, appsIn: incoming)
    }
}
