import Foundation

/// A group of items in the SnugBar Bar.
public enum BarGroupKind: String, Codable, CaseIterable, Sendable {
    /// Apps hidden from the collapsed menu bar (the Hidden section, or Shown while swapped).
    case hidden
    /// Always-hidden apps; listed only when everything is revealed.
    case alwaysHidden
    /// Shown apps moved out because the menu bar has no room for them.
    case didntFit
}

public struct BarGroup: Equatable, Sendable {
    public var kind: BarGroupKind
    public var items: [MenuBarItem]

    public init(kind: BarGroupKind, items: [MenuBarItem]) {
        self.kind = kind
        self.items = items
    }
}

/// One tile in the SnugBar Bar: a single item, or several items of one app that have no picture of their own.
public struct BarTile: Equatable, Sendable, Identifiable {
    /// Left to right; never empty. More than one means the tile stands for the app.
    public let items: [MenuBarItem]

    public init(items: [MenuBarItem]) {
        precondition(!items.isEmpty, "a tile needs at least one item")
        self.items = items
    }

    public var isAppTile: Bool { items.count > 1 }

    /// What the tile opens and is named after: the item itself, or for an app tile its leftmost item named after the
    /// app. Keeps the item's ID, so keys and recents refer to a real item.
    public var item: MenuBarItem {
        var first = items[0]
        if isAppTile { first.displayName = first.appName }
        return first
    }

    public var id: ItemID { items[0].id }

    /// Tooltip text: the item's name, or the app's name and how many items it has.
    public var helpText: String {
        isAppTile ? "\(items[0].appName) (\(items.count) items)" : items[0].displayName
    }
}

/// How wide the box for an item's picture is, in the SnugBar Bar and the layout editor. Pictures are drawn aspect-fit
/// in a box of the tiles' usual height; a square box made a wide item (the clock's date and time) too small to read.
/// So a wide picture gets a box as wide as it needs: its own width (never blown up past its size in the menu bar), or
/// less when that is enough to fill the height, and at most `maxTiles` usual tiles in all.
public enum TilePicture {
    public static let maxTiles = 3.0

    /// - Parameters:
    ///   - width, height: the picture's size in points (0 when unknown: a square box).
    ///   - side: the usual (square) box's side.
    ///   - chrome: what the tile adds around the box (padding), so the whole tile is at most `maxTiles` usual tiles.
    public static func boxWidth(width: Double, height: Double, side: Double, chrome: Double) -> Double {
        guard width.isFinite, height.isFinite, width > 0, height > 0, width > height, width > side else { return side }
        let needed = min(width, side * width / height)
        let cap = maxTiles * (side + chrome) - chrome
        return min(max(needed, side), max(cap, side)).rounded()
    }
}

/// What the SnugBar Bar lists (features 20, 23).
public enum BarListing {
    /// The tiles for one group's items. Items with a picture of their own get a tile each. When an app has several
    /// items without one (they would all show the same app icon), those share one tile, placed where the first of
    /// them is; clicking it opens the leftmost. A lone item without a picture keeps its own tile.
    /// - Parameter hasImage: whether the item has a captured picture (not just its app's icon).
    public static func tiles(for items: [MenuBarItem], hasImage: (MenuBarItem) -> Bool) -> [BarTile] {
        let imaged = items.map(hasImage)
        var plain: [String: [MenuBarItem]] = [:]
        for (item, has) in zip(items, imaged) where !has && !item.ownerBundleID.isEmpty {
            plain[item.ownerBundleID, default: []].append(item)
        }
        var tiles: [BarTile] = []
        var placed = Set<String>()
        for (item, has) in zip(items, imaged) {
            if has || item.ownerBundleID.isEmpty {
                tiles.append(BarTile(items: [item]))
                continue
            }
            let group = plain[item.ownerBundleID] ?? [item]
            if group.count == 1 {
                tiles.append(BarTile(items: [item]))
            } else if placed.insert(item.ownerBundleID).inserted {
                tiles.append(BarTile(items: group))
            }
        }
        return tiles
    }

    /// Groups in display order (Hidden, Always hidden, Didn't fit), each in the items' given order. Empty groups are
    /// left out. Apple's items and `excluding` (SnugBar itself) are never listed.
    /// - Parameters:
    ///   - items: every known item, left to right.
    ///   - state: `reveal == .all` adds the Always hidden group. Nothing is listed in Zen.
    ///   - overflowHidden: apps currently moved out because they didn't fit.
    public static func groups(
        items: [MenuBarItem], sections: AppSectionMap, state: BarState, overflowHidden: Set<String>, excluding: Set<String>
    ) -> [BarGroup] {
        guard !state.zen else { return [] }
        var lists: [BarGroupKind: [MenuBarItem]] = [:]
        let collapsedVisible = state.collapsedSections
        for item in items where !item.isAppleItem && !excluding.contains(item.ownerBundleID) {
            guard let kind = kind(of: item, sections: sections, collapsedVisible: collapsedVisible, overflowHidden: overflowHidden)
            else { continue }
            if kind == .alwaysHidden && state.reveal != .all { continue }
            lists[kind, default: []].append(item)
        }
        return BarGroupKind.allCases.compactMap { kind in
            guard let list = lists[kind], !list.isEmpty else { return nil }
            return BarGroup(kind: kind, items: list)
        }
    }

    /// The group an item belongs to, or nil when it is in the collapsed menu bar.
    public static func kind(
        of item: MenuBarItem, sections: AppSectionMap, collapsedVisible: Set<Section>, overflowHidden: Set<String>
    ) -> BarGroupKind? {
        let section = sections.section(for: item)
        if section == .alwaysHidden { return .alwaysHidden }
        if !collapsedVisible.contains(section) { return .hidden }
        if overflowHidden.contains(item.ownerBundleID) { return .didntFit }
        return nil
    }
}

/// Remembers items seen in the menu bar, so items of apps that are hidden now (and so may be missing from the
/// Accessibility tree) can still be listed, searched and opened.
public struct ItemCatalog: Sendable {
    public private(set) var itemsByApp: [String: [MenuBarItem]] = [:]

    public init() {}

    /// Records the items of apps that are on screen now, replacing what was remembered for them.
    public mutating func record(_ items: [MenuBarItem], isOnScreen: (String) -> Bool) {
        var grouped: [String: [MenuBarItem]] = [:]
        for item in items where !item.isAppleItem && !item.ownerBundleID.isEmpty && isOnScreen(item.ownerBundleID) {
            grouped[item.ownerBundleID, default: []].append(item)
        }
        for (bundle, list) in grouped { itemsByApp[bundle] = list }
    }

    public mutating func forget(_ bundleID: String) {
        itemsByApp.removeValue(forKey: bundleID)
    }

    /// Every item to offer: the live items, then for each running app with no live item its remembered items, else
    /// one placeholder named after the app (from `knownApps`). Placeholders and remembered items follow the live
    /// ones, by app name.
    /// - Parameters:
    ///   - running: bundle IDs of running apps.
    ///   - knownApps: bundle ID -> app name, for placeholders.
    public func merged(live: [MenuBarItem], running: Set<String>, knownApps: [String: String]) -> [MenuBarItem] {
        let liveApps = Set(live.map(\.ownerBundleID))
        var extra: [(name: String, items: [MenuBarItem])] = []
        for bundle in running.subtracting(liveApps) {
            if let remembered = itemsByApp[bundle], !remembered.isEmpty {
                extra.append((remembered[0].appName, remembered))
            } else if let name = knownApps[bundle] {
                extra.append((name, [Self.placeholder(bundleID: bundle, appName: name)]))
            }
        }
        extra.sort { a, b in
            let order = a.name.localizedCaseInsensitiveCompare(b.name)
            return order != .orderedSame ? order == .orderedAscending : a.items[0].ownerBundleID < b.items[0].ownerBundleID
        }
        return live + extra.flatMap(\.items)
    }

    /// An item for an app whose items haven't been seen: `<bundle id>#0`, named after the app.
    public static func placeholder(bundleID: String, appName: String) -> MenuBarItem {
        MenuBarItem(
            id: .indexed(owner: bundleID, index: 0), ownerBundleID: bundleID, ownerPID: 0,
            appName: appName, displayName: appName, frame: .zero,
            isAppleItem: false, isOverflowed: false, axIdentifier: nil
        )
    }
}
