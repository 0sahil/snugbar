import AppKit
import SnugBarCore
import SnugBarEngine

/// SnugBar's spacer status items (feature 37): empty items of a set width. Their place is AppKit's
/// `NSStatusItem Preferred Position <autosave name>` in SnugBar's own defaults, unless the system order file has a key
/// for them. They are never part of the SnugBar Bar, search, letters or `list` (those leave SnugBar's own items out),
/// and the hider always lets SnugBar's items through.
@MainActor
final class SpacerBar {
    private var items: [String: NSStatusItem] = [:]
    /// Places of the items taken out for Zen (`SpacerSync.State.stashed`).
    private var stashed: [String: Double] = [:]
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    static func positionKey(_ spacer: LayoutSpacer) -> String { "NSStatusItem Preferred Position \(spacer.autosaveName)" }
    static func visibleKey(_ spacer: LayoutSpacer) -> String { "NSStatusItem Visible \(spacer.autosaveName)" }

    /// Spacers taken out of the menu bar for Zen (for diagnostics).
    var stashedPlaces: [String: Double] { stashed }

    /// Creates, resizes and removes items to match `spacers` (`SpacerSync`). In Zen the items leave the menu bar (a
    /// zero-length item still takes a slot) and come back at the same place afterwards.
    /// - Parameters:
    ///   - orderPositions: the system order file, when readable: a spacer's key there says where it is.
    ///   - ownBundleID: SnugBar's bundle ID (the order file's keys for its items).
    func sync(_ spacers: [LayoutSpacer], zen: Bool, orderPositions: [String: Double]?, ownBundleID: String) {
        let byID = Dictionary(spacers.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let current = SpacerSync.State(items: items.mapValues { Double($0.length) }, stashed: stashed)
        for step in SpacerSync.steps(current: current, spacers: spacers, zen: zen) {
            switch step {
            case let .remove(id):
                stashed[id] = nil
                if let item = items.removeValue(forKey: id) { NSStatusBar.system.removeStatusItem(item) }
            case let .create(id, length):
                guard let spacer = byID[id] else { continue }
                let item = make(spacer)
                item.length = CGFloat(length)
                items[id] = item
            case let .setLength(id, length):
                items[id]?.length = CGFloat(length)
            case let .stash(id):
                guard let spacer = byID[id], let item = items.removeValue(forKey: id) else { continue }
                let position = place(of: spacer, orderPositions: orderPositions, ownBundleID: ownBundleID)
                NSStatusBar.system.removeStatusItem(item)
                stashed[id] = position
                // Kept in AppKit's own record too, so a quit during Zen doesn't lose the place.
                if let position { defaults.set(position, forKey: Self.positionKey(spacer)) }
            case let .restore(id, length, position):
                stashed[id] = nil
                guard let spacer = byID[id] else { continue }
                place(spacer, at: position, length: length)
            }
        }
        // An item hidden by an earlier build (or dragged out) comes back.
        for item in items.values where !item.isVisible { item.isVisible = true }
    }

    /// Where a spacer's item is now, in the order file's units: the order file's value when it has a key for the item,
    /// else AppKit's preferred position for it. Nil when neither is known.
    func place(of spacer: LayoutSpacer, orderPositions: [String: Double]?, ownBundleID: String) -> Double? {
        if let value = orderPositions?[spacer.orderFileKey(ownBundleID: ownBundleID)] { return value }
        return (defaults.object(forKey: Self.positionKey(spacer)) as? NSNumber)?.doubleValue
    }

    /// Removes every item (SnugBar is quitting; the system removes them anyway).
    func removeAll() {
        for item in items.values { NSStatusBar.system.removeStatusItem(item) }
        items = [:]
    }

    /// Moves a spacer by giving it a new preferred position (distance from the right edge, the order file's units)
    /// and recreating its item, which is when AppKit reads the value. Also brings a spacer back after Zen.
    func place(_ spacer: LayoutSpacer, at position: Double, length: Double? = nil) {
        // A spacer out of the menu bar for Zen stays out; it comes back at this place when Zen ends.
        if stashed[spacer.id] != nil, items[spacer.id] == nil {
            stashed[spacer.id] = position
            defaults.set(position, forKey: Self.positionKey(spacer))
            return
        }
        let length = length.map { CGFloat($0) } ?? items[spacer.id]?.length ?? CGFloat(spacer.width)
        if let item = items.removeValue(forKey: spacer.id) { NSStatusBar.system.removeStatusItem(item) }
        defaults.set(position, forKey: Self.positionKey(spacer))
        let item = make(spacer)
        item.length = length
        items[spacer.id] = item
    }

    /// Drops what AppKit remembers about a removed spacer.
    func forget(_ spacer: LayoutSpacer) {
        stashed[spacer.id] = nil
        defaults.removeObject(forKey: Self.positionKey(spacer))
        defaults.removeObject(forKey: Self.visibleKey(spacer))
    }

    /// Spacer keys by their item's frame in global top-left coordinates (only items in the menu bar now).
    func frames() -> [String: CGRect] {
        guard let primaryHeight = NSScreen.screens.first?.frame.height else { return [:] }
        var result: [String: CGRect] = [:]
        // Zero-width items (Zen) aren't in the menu bar as far as the order goes.
        for (id, item) in items where item.isVisible && item.length > 0 {
            guard let frame = item.button?.window?.frame else { continue }
            result[LayoutSpacer.keyPrefix + id] = MenuBarGeometry.topLeftRect(fromCocoa: frame, primaryScreenHeight: primaryHeight)
        }
        return result
    }

    /// The spacer a reader item of SnugBar's stands for, matched by position.
    func key(for item: MenuBarItem, frames: [String: CGRect]) -> String? {
        frames.first { abs($0.value.minX - item.frame.x) < 3 && abs($0.value.width - item.frame.width) < 3 }?.key
    }

    private func make(_ spacer: LayoutSpacer) -> NSStatusItem {
        // A "not visible" mark left by an earlier build would create the item hidden.
        defaults.removeObject(forKey: Self.visibleKey(spacer))
        let item = NSStatusBar.system.statusItem(withLength: CGFloat(spacer.width))
        item.autosaveName = spacer.autosaveName
        item.behavior = []
        if let button = item.button {
            button.title = ""
            button.image = nil
            button.isEnabled = false
            button.setAccessibilityLabel("Spacer")
        }
        return item
    }
}
