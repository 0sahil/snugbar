import AppKit
import SnugBarCore

/// Opens a menu bar item's menu.
///
/// 1. If the item's app is hidden by `AssessmentHider`, allow it temporarily and wait for it to appear (1.5 s).
/// 2. `AXPress` the owning app's own `AXExtrasMenuBar` child that matches the item. No pointer movement.
/// 3. Otherwise synthetic click at the item's centre (opening the system overflow first if the item is in it) and
///    put the pointer back.
/// 4. Keep a temporarily allowed app visible until the next click elsewhere, then hide it again after a delay.
@MainActor
public final class ItemActivator {
    public enum Method: String, Codable, Sendable {
        case accessibility = "ax"
        case event
    }

    public struct Result: Codable, Sendable {
        public var method: Method
        public var detail: String
        public var pointerBefore: PointerPosition
        public var pointerAfter: PointerPosition
        public var temporarilyAllowed: Bool
    }

    public enum ActivationError: Error, CustomStringConvertible {
        case itemDidNotAppear(ItemID)
        case noOwner(ItemID)

        public var description: String {
            switch self {
            case let .itemDidNotAppear(id): return "\(id) did not appear within the timeout"
            case let .noOwner(id): return "\(id) has no owning app to activate"
            }
        }
    }

    private let reader: MenuBarReader
    private let hider: AssessmentHider?
    public var appearTimeout: TimeInterval = 1.5
    /// Delay before re-hiding a temporarily allowed app after the user clicks elsewhere.
    public var rehideDelay: TimeInterval = 0.3
    /// After focusing a hidden item: wait at least this long, then until the items hold still (see `settledSnapshot`).
    public var settleMinimum: TimeInterval = 0.15
    public var settleInterval: TimeInterval = 0.06
    public var settleTimeout: TimeInterval = 0.8
    /// Called after a hidden item has been focused into view and before it is clicked, with the item as it is now and
    /// every item on screen at that moment. Lets the app capture a picture of an item that is otherwise never visible.
    public var beforeClick: (@MainActor (MenuBarItem, [MenuBarItem]) async -> Void)?
    private var rehideMonitors: [String: Any] = [:]

    public init(reader: MenuBarReader, hider: AssessmentHider?) {
        self.reader = reader
        self.hider = hider
    }

    public func activate(_ item: MenuBarItem, orderPositions: [String: Double]? = nil) async throws -> Result {
        let before = SyntheticInput.pointer
        var entry = reader.snapshot(orderPositions: orderPositions).entry(for: item.id)
        var allowed = false

        // 1. Hidden or squeezed into macOS's overflow row: focus. Show only the item's app (plus Apple's items and
        // SnugBar) so it lands in the visible bar right of the notch, click it there, and restore the layout after the
        // menu closes. macOS's own overflow row is not used: how many items it can show depends on the frontmost
        // app's menus (verified on 27.2: with Chrome in front the row had no room at all).
        let isHiddenByUs = hider.map { $0.isHiding && !$0.allowedBundleIDs.contains(item.ownerBundleID) } ?? false
        let currentlyOverflowed = entry?.item.isOverflowed ?? item.isOverflowed
        if let hider, hider.isAvailable, !item.ownerBundleID.isEmpty, !item.isAppleItem,
           isHiddenByUs || currentlyOverflowed || entry == nil {
            var focus: Set<String> = [item.ownerBundleID]
            if let own = Bundle.main.bundleIdentifier { focus.insert(own) }
            try hider.focus(on: focus)
            allowed = true
            entry = await waitForEntry(item, orderPositions: orderPositions)
            guard entry != nil else {
                hider.endFocus()
                throw ActivationError.itemDidNotAppear(item.id)
            }
            // Let the bar settle after reflowing: items slide into place, and a picture or a click taken mid-slide
            // lands on the wrong part of the item.
            let settled = await settledSnapshot(focus: focus, orderPositions: orderPositions)
            entry = settled.entries.first {
                $0.item.ownerBundleID == item.ownerBundleID && $0.indexInApp == (entry?.indexInApp ?? 0) && !$0.item.isOverflowed
            } ?? entry
            if let beforeClick, let focused = entry?.item {
                // Only the focused apps and Apple's items are on screen now; other entries may be stale.
                await beforeClick(focused, settled.items.filter { $0.isAppleItem || focus.contains($0.ownerBundleID) })
            }
        }
        guard let entry else { throw ActivationError.itemDidNotAppear(item.id) }
        defer { if allowed { scheduleEndFocus(frame: entry.item.frame.cgRect) } }

        // 2. The app's own extras menu bar. Verified on macOS 27.2: AXPress here returns success and highlights the
        // item but does NOT open the menu for third-party apps (tested with several native and Electron apps), so it is opt-in only.
        let preferAX = ProcessInfo.processInfo.environment["SNUGBAR_CLICK_METHOD"] == "ax"
        if preferAX, entry.item.ownerPID > 0, let element = extrasElement(for: entry) {
            for action in [kAXPressAction, "AXShowMenu"] where AX.actions(element).contains(action) {
                let result = AX.perform(element, action)
                if result == .success {
                    return Result(method: .accessibility, detail: "\(action) on AXExtrasMenuBar item",
                                  pointerBefore: PointerPosition(before), pointerAfter: PointerPosition(SyntheticInput.pointer),
                                  temporarilyAllowed: allowed)
                }
            }
        }
        // Apple items: press MenuBarAgent's element directly. (For third-party items that copy reports success but
        // does nothing, so it is not tried for them.)
        if entry.item.isAppleItem, AX.perform(entry.element, kAXPressAction) == .success {
            return Result(method: .accessibility, detail: "AXPress on MenuBarAgent element",
                          pointerBefore: PointerPosition(before), pointerAfter: PointerPosition(SyntheticInput.pointer),
                          temporarilyAllowed: allowed)
        }

        // 3. Synthetic click.
        var target = entry.item.frame.cgRect
        var detail = "synthetic click"
        if entry.item.isOverflowed {
            let overflowed = reader.snapshot(orderPositions: orderPositions).entries.filter { $0.item.isOverflowed }
            // Never click a row frame unless the row is confirmed open: otherwise the click lands on whatever is
            // underneath (another app's menus).
            guard await reader.setOverflowRow(open: true),
                  let frame = reader.expandedRowFrame(for: entry, overflowed: overflowed) else {
                await reader.setOverflowRow(open: false)
                throw ActivationError.itemDidNotAppear(item.id)
            }
            target = frame
            detail = "opened overflow, synthetic click"
        }
        let restoreDelay = UInt64(ProcessInfo.processInfo.environment["SNUGBAR_RESTORE_DELAY_MS"].flatMap(UInt64.init) ?? 60)
        // The pointer has to travel to the item: on macOS 27.2 clicks posted to MenuBarAgent's or the owner's pid are
        // ignored, and a session-tap click moves the pointer too. Hide it for the round trip so the jump isn't seen.
        let hidden = SyntheticInput.hidePointer()
        SyntheticInput.click(at: CGPoint(x: target.midX, y: target.midY))
        // MenuBarAgent hit-tests against the live pointer, so let the click land before moving the pointer back.
        try? await Task.sleep(nanoseconds: restoreDelay * 1_000_000)
        SyntheticInput.restorePointer(before)
        if hidden { SyntheticInput.showPointer(); detail += ", pointer hidden" }
        return Result(method: .event, detail: detail, pointerBefore: PointerPosition(before),
                      pointerAfter: PointerPosition(SyntheticInput.pointer), temporarilyAllowed: allowed)
    }

    // MARK: - Private

    /// A snapshot once the focused apps' items have stopped moving: two reads `settleInterval` apart agree, after at
    /// least `settleMinimum` and at most `settleTimeout`.
    private func settledSnapshot(focus: Set<String>, orderPositions: [String: Double]?) async -> MenuBarSnapshot {
        func frames(_ s: MenuBarSnapshot) -> [ItemID: CGRect] {
            Dictionary(s.items.filter { $0.isAppleItem || focus.contains($0.ownerBundleID) }.map { ($0.id, $0.frame.cgRect) },
                       uniquingKeysWith: { a, _ in a })
        }
        let start = Date()
        try? await Task.sleep(nanoseconds: UInt64(settleMinimum * 1_000_000_000))
        var snapshot = reader.snapshot(orderPositions: orderPositions)
        while Date().timeIntervalSince(start) < settleTimeout {
            try? await Task.sleep(nanoseconds: UInt64(settleInterval * 1_000_000_000))
            let next = reader.snapshot(orderPositions: orderPositions)
            defer { snapshot = next }
            if frames(next) == frames(snapshot) { return next }
        }
        return snapshot
    }

    private func waitForEntry(_ item: MenuBarItem, orderPositions: [String: Double]?) async -> MenuBarEntry? {
        let start = Date()
        while Date().timeIntervalSince(start) < appearTimeout {
            let snapshot = reader.snapshot(orderPositions: orderPositions)
            // The ID may be a fallback index while the app was hidden, so match by owner and position in the app.
            if let found = snapshot.entry(for: item.id) ?? snapshot.entries.first(where: {
                $0.item.ownerBundleID == item.ownerBundleID && !$0.item.isOverflowed
            }) {
                return found
            }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        return nil
    }

    private func extrasElement(for entry: MenuBarEntry) -> AXUIElement? {
        let app = AXUIElementCreateApplication(entry.item.ownerPID)
        guard let bar = AX.element(AX.attribute(app, "AXExtrasMenuBar")) else { return nil }
        let children = AX.children(bar)
        let appItemCount = reader.snapshot().items.filter { $0.ownerBundleID == entry.item.ownerBundleID }.count
        guard let index = MenuBarGeometry.matchExtrasItem(
            target: entry.item.frame.cgRect,
            indexInApp: entry.indexInApp,
            appItemCount: max(appItemCount, 1),
            candidates: children.map(AX.frame)
        ) else { return nil }
        return children[index]
    }

    /// Ends a focus after the next click outside the item (its menu has closed or the user moved on).
    private func scheduleEndFocus(frame: CGRect) {
        guard let hider else { return }
        if let old = rehideMonitors.removeValue(forKey: "focus") { NSEvent.removeMonitor(old) }
        let monitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .keyDown]) { [weak self] event in
            let location = event.type == .keyDown ? nil : event.cgEvent?.location
            MainActor.assumeIsolated {
                guard let self else { return }
                if let location, MenuBarGeometry.hit(location, in: frame) { return }
                // Escape or Return closes the menu too; other keys navigate it.
                if event.type == .keyDown, ![53, 36, 76].contains(Int(event.keyCode)) { return }
                if let m = self.rehideMonitors.removeValue(forKey: "focus") { NSEvent.removeMonitor(m) }
                let delay = self.rehideDelay
                Task { @MainActor in
                    try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                    hider.endFocus()
                }
            }
        }
        if let monitor { rehideMonitors["focus"] = monitor } else { hider.endFocus() }
    }

    private func scheduleRehide(bundleID: String, frame: CGRect) {
        guard let hider else { return }
        if let old = rehideMonitors.removeValue(forKey: bundleID) { NSEvent.removeMonitor(old) }
        let monitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            let location = event.cgEvent?.location
            MainActor.assumeIsolated {
                guard let self else { return }
                // A click on the item itself toggles its menu; keep waiting.
                if let location, MenuBarGeometry.hit(location, in: frame) { return }
                if let m = self.rehideMonitors.removeValue(forKey: bundleID) { NSEvent.removeMonitor(m) }
                let delay = self.rehideDelay
                Task { @MainActor in
                    try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                    hider.endTemporaryAllowance(bundleID)
                }
            }
        }
        if let monitor { rehideMonitors[bundleID] = monitor } else { hider.endTemporaryAllowance(bundleID) }
    }
}
