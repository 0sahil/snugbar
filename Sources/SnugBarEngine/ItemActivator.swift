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
    public var rehideDelay: TimeInterval = 1.0
    private var rehideMonitors: [String: Any] = [:]

    public init(reader: MenuBarReader, hider: AssessmentHider?) {
        self.reader = reader
        self.hider = hider
    }

    public func activate(_ item: MenuBarItem, orderPositions: [String: Double]? = nil) async throws -> Result {
        let before = SyntheticInput.pointer
        var entry = reader.snapshot(orderPositions: orderPositions).entry(for: item.id)
        var allowed = false

        // 1. Temporarily allow a hidden app.
        if let hider, hider.isHiding, !item.ownerBundleID.isEmpty, !hider.allowedBundleIDs.contains(item.ownerBundleID),
           !item.isAppleItem {
            hider.allowTemporarily(item.ownerBundleID)
            allowed = true
            entry = await waitForEntry(item, orderPositions: orderPositions)
            guard entry != nil else {
                hider.endTemporaryAllowance(item.ownerBundleID)
                throw ActivationError.itemDidNotAppear(item.id)
            }
        }
        guard let entry else { throw ActivationError.itemDidNotAppear(item.id) }
        defer { if allowed { scheduleRehide(bundleID: item.ownerBundleID, frame: entry.item.frame.cgRect) } }

        // 2. The app's own extras menu bar. Verified on macOS 27.2: AXPress here returns success and highlights the
        // item but does NOT open the menu for third-party apps (Tailscale, Slack, Wickbar), so it is opt-in only.
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
            await reader.clickOverflowButton(open: true)
            try? await Task.sleep(nanoseconds: 700_000_000)
            guard let frame = reader.expandedRowFrame(for: entry, overflowed: overflowed) else {
                // Clicking the stacked frame would hit « and close the row again, so stop here.
                await reader.clickOverflowButton(open: false)
                throw ActivationError.itemDidNotAppear(item.id)
            }
            target = frame
            detail = "opened overflow, synthetic click"
        }
        let restoreDelay = UInt64(ProcessInfo.processInfo.environment["SNUGBAR_RESTORE_DELAY_MS"].flatMap(UInt64.init) ?? 60)
        SyntheticInput.click(at: CGPoint(x: target.midX, y: target.midY))
        // MenuBarAgent hit-tests against the live pointer, so let the click land before moving the pointer back.
        try? await Task.sleep(nanoseconds: restoreDelay * 1_000_000)
        SyntheticInput.restorePointer(before)
        return Result(method: .event, detail: detail, pointerBefore: PointerPosition(before),
                      pointerAfter: PointerPosition(SyntheticInput.pointer), temporarilyAllowed: allowed)
    }

    // MARK: - Private

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
