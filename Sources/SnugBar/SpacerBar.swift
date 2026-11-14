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
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    static func positionKey(_ spacer: LayoutSpacer) -> String { "NSStatusItem Preferred Position \(spacer.autosaveName)" }
    static func visibleKey(_ spacer: LayoutSpacer) -> String { "NSStatusItem Visible \(spacer.autosaveName)" }

    /// Creates, resizes and removes items to match `spacers` (`SpacerSync`). In Zen the items shrink to zero width
    /// rather than being hidden: hiding an autosaved status item makes AppKit drop its place in the menu bar.
    func sync(_ spacers: [LayoutSpacer], zen: Bool) {
        let byID = Dictionary(spacers.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let current = items.mapValues { Double($0.length) }
        for step in SpacerSync.steps(current: current, spacers: spacers, zen: zen) {
            switch step {
            case let .remove(id):
                if let item = items.removeValue(forKey: id) { NSStatusBar.system.removeStatusItem(item) }
            case let .create(id, length):
                guard let spacer = byID[id] else { continue }
                let item = make(spacer)
                item.length = CGFloat(length)
                items[id] = item
            case let .setLength(id, length):
                items[id]?.length = CGFloat(length)
            }
        }
        // An item hidden by an earlier build (or dragged out) comes back.
        for item in items.values where !item.isVisible { item.isVisible = true }
    }

    /// Removes every item (SnugBar is quitting; the system removes them anyway).
    func removeAll() {
        for item in items.values { NSStatusBar.system.removeStatusItem(item) }
        items = [:]
    }

    /// Moves a spacer by giving it a new preferred position (distance from the right edge, the order file's units)
    /// and recreating its item, which is when AppKit reads the value.
    func place(_ spacer: LayoutSpacer, at position: Double) {
        let length = items[spacer.id]?.length ?? CGFloat(spacer.width)
        if let item = items.removeValue(forKey: spacer.id) { NSStatusBar.system.removeStatusItem(item) }
        defaults.set(position, forKey: Self.positionKey(spacer))
        let item = make(spacer)
        item.length = length
        items[spacer.id] = item
    }

    /// Drops what AppKit remembers about a removed spacer.
    func forget(_ spacer: LayoutSpacer) {
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
