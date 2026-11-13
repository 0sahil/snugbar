import AppKit
import ApplicationServices
import SnugBarCore

/// One item from a snapshot together with its Accessibility element in MenuBarAgent's tree.
public struct MenuBarEntry {
    public let item: MenuBarItem
    /// Index among the owning app's items, left to right.
    public let indexInApp: Int
    let element: AXUIElement
}

public struct MenuBarSnapshot {
    public let entries: [MenuBarEntry]
    /// Frame of the system « button, when it is shown.
    public let overflowIndicatorFrame: CGRect?
    public let takenAt: Date
    /// Why the snapshot is empty, when it is.
    public let problem: String?

    public var items: [MenuBarItem] { entries.map(\.item) }

    public func entry(for id: ItemID) -> MenuBarEntry? { entries.first { $0.item.id == id } }
}

/// Reads the macOS 27 menu bar through MenuBarAgent's Accessibility tree.
///
/// MenuBarAgent draws every status item. It has one window per bar state; the one to read is the window whose
/// item groups carry an `AXApplication` child (owner info) and which is not the expanded-overflow row.
@MainActor
public final class MenuBarReader {
    public static let agentBundleID = "com.apple.MenuBarAgent"
    static let overflowIndicatorID = "menu-bar-overflow-indicator"
    static let expandedIndicatorID = "menu-bar-overflow-indicator-expanded"

    public init() {}

    public var agentPID: pid_t? {
        NSRunningApplication.runningApplications(withBundleIdentifier: Self.agentBundleID).first?.processIdentifier
    }

    /// Takes a snapshot. Pass the order file dictionary to get order-file IDs; without it IDs use the fallback form.
    public func snapshot(orderPositions: [String: Double]? = nil) -> MenuBarSnapshot {
        guard AXIsProcessTrusted() else {
            return MenuBarSnapshot(entries: [], overflowIndicatorFrame: nil, takenAt: Date(), problem: "accessibility not granted")
        }
        guard let pid = agentPID else {
            return MenuBarSnapshot(entries: [], overflowIndicatorFrame: nil, takenAt: Date(), problem: "MenuBarAgent is not running")
        }
        guard let window = mainWindow(agentPID: pid) else {
            return MenuBarSnapshot(entries: [], overflowIndicatorFrame: nil, takenAt: Date(), problem: "no menu bar window with owner info")
        }

        struct Raw {
            let element: AXUIElement
            let frame: CGRect
            let identifier: String?
            let description: String?
            let ownerPID: pid_t
            let ownerBundleID: String?
            let appName: String
            let childOrder: Int
        }

        var indicator: CGRect?
        var raws: [Raw] = []
        for (order, child) in AX.children(window).enumerated() {
            guard let frame = AX.frame(child) else { continue }
            let identifier = AX.firstIdentifier(child)
            if identifier == Self.overflowIndicatorID {
                indicator = frame
                continue
            }
            if identifier == Self.expandedIndicatorID { continue }
            let owner = Self.owner(of: child)
            raws.append(Raw(
                element: child,
                frame: frame,
                identifier: identifier,
                description: AX.firstDescription(child),
                ownerPID: owner.pid,
                ownerBundleID: owner.bundleID,
                appName: owner.name,
                childOrder: order
            ))
        }
        // Left to right; stacked overflow items keep their tree order.
        raws.sort { a, b in a.frame.minX != b.frame.minX ? a.frame.minX < b.frame.minX : a.childOrder < b.childOrder }

        let observed = raws.map {
            ObservedItem(
                ownerBundleID: $0.ownerBundleID,
                axIdentifier: $0.identifier,
                minX: $0.frame.minX,
                isOverflowed: MenuBarGeometry.isOverflowed($0.frame, indicator: indicator)
            )
        }
        let resolved = ItemIdentityResolver.resolve(observed, orderPositions: orderPositions)

        var perOwner: [String: Int] = [:]
        var entries: [MenuBarEntry] = []
        for (i, raw) in raws.enumerated() {
            let isApple = AppleItems.isAppleIdentifier(raw.identifier)
            let ownerKey = ItemIdentityResolver.fallbackOwner(observed[i])
            let indexInApp = perOwner[ownerKey, default: 0]
            perOwner[ownerKey] = indexInApp + 1
            let item = MenuBarItem(
                id: resolved[i].id,
                ownerBundleID: raw.ownerBundleID ?? "",
                ownerPID: raw.ownerPID,
                appName: raw.appName,
                displayName: MenuBarItem.makeDisplayName(
                    appName: raw.appName, description: raw.description, isAppleItem: isApple, axIdentifier: raw.identifier
                ),
                frame: raw.frame.coreRect,
                isAppleItem: isApple,
                isOverflowed: observed[i].isOverflowed,
                axIdentifier: raw.identifier
            )
            entries.append(MenuBarEntry(item: item, indexInApp: indexInApp, element: raw.element))
        }
        return MenuBarSnapshot(entries: entries, overflowIndicatorFrame: indicator, takenAt: Date(), problem: nil)
    }

    /// MenuBarAgent's « button element, if shown.
    func overflowIndicator() -> AXUIElement? {
        guard let pid = agentPID else { return nil }
        for window in AX.children(AXUIElementCreateApplication(pid)) where !Self.isExpandedWindow(window) {
            if let el = AX.children(window).first(where: { AX.firstIdentifier($0) == Self.overflowIndicatorID }) {
                return el
            }
        }
        return nil
    }

    /// MenuBarAgent's » button (shown while the overflow row is open), if present.
    public func expandedIndicator() -> AXUIElement? {
        guard let pid = agentPID else { return nil }
        for window in AX.children(AXUIElementCreateApplication(pid)) where Self.isExpandedWindow(window) {
            if let el = AX.children(window).first(where: { AX.firstIdentifier($0) == Self.expandedIndicatorID }) {
                return el
            }
        }
        return nil
    }

    /// Whether macOS's overflow row is open. Verified on 27.2: MenuBarAgent's "Menu Extras" element (role AXMenuBar)
    /// holds the « button, whose identifier becomes `menu-bar-overflow-indicator-expanded` exactly while the row is
    /// open. (The expanded-row windows exist in AX even while the row is closed, so their presence means nothing.)
    public func isOverflowRowOpen() -> Bool? {
        guard let pid = agentPID else { return nil }
        for el in AX.children(AXUIElementCreateApplication(pid)) where AX.role(el) == kAXMenuBarRole {
            for c in AX.children(el) {
                let id = AX.firstIdentifier(c)
                if id == Self.expandedIndicatorID { return true }
                if id == Self.overflowIndicatorID { return false }
            }
        }
        return nil
    }

    /// Opens or closes the overflow row and waits (up to `timeout`) until the state is confirmed.
    @discardableResult
    public func setOverflowRow(open: Bool, timeout: TimeInterval = 1.5) async -> Bool {
        if isOverflowRowOpen() == open { return true }
        guard await clickOverflowButton(open: open) else { return false }
        let start = Date()
        while Date().timeIntervalSince(start) < timeout {
            if isOverflowRowOpen() == open {
                try? await Task.sleep(nanoseconds: 250_000_000) // let the row's animation settle
                return true
            }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        return false
    }

    /// Clicks the « / » button with a synthetic click (AXPress on it is accepted but ignored on macOS 27.2) and puts
    /// the pointer back. `open` true clicks «, false clicks ». Returns false if the button isn't there.
    @discardableResult
    public func clickOverflowButton(open: Bool) async -> Bool {
        guard let el = open ? overflowIndicator() : expandedIndicator(), let frame = AX.frame(el) else { return false }
        let before = SyntheticInput.pointer
        SyntheticInput.click(at: CGPoint(x: frame.midX, y: frame.midY))
        try? await Task.sleep(nanoseconds: 60_000_000)
        SyntheticInput.restorePointer(before)
        return true
    }

    /// Debug: MenuBarAgent's AX windows with their attributes and indicator identifiers.
    public func debugAgentWindows() -> [String] {
        guard let pid = agentPID else { return [] }
        var out: [String] = []
        for (i, w) in AX.children(AXUIElementCreateApplication(pid)).enumerated() {
            var names: CFArray?
            AXUIElementCopyAttributeNames(w, &names)
            let skip: Set<String> = ["AXChildren", "AXParent", "AXTopLevelUIElement", "AXWindow", "AXChildrenInNavigationOrder"]
            let vals = (names as? [String] ?? []).filter { !skip.contains($0) }.map { n -> String in
                var v: AnyObject?
                AXUIElementCopyAttributeValue(w, n as CFString, &v)
                return "\(n)=\(v.map { String(String(describing: $0).replacingOccurrences(of: "\n", with: " ").prefix(60)) } ?? "nil")"
            }
            let kids = AX.children(w)
            let ids = kids.compactMap { AX.firstIdentifier($0) }.filter { $0.hasPrefix("menu-bar") }
            let leftOfNotch = kids.compactMap(AX.frame).filter { $0.maxX < 640 }.count
            out.append("win\(i) kids=\(kids.count) leftOfNotch=\(leftOfNotch) ind=\(ids) " + vals.joined(separator: " | "))
        }
        return out
    }

    /// Debug: every expanded-row window with its children's owner and frame.
    public func debugExpandedWindows() -> [[String]] {
        guard let pid = agentPID else { return [] }
        return AX.children(AXUIElementCreateApplication(pid)).filter(Self.isExpandedWindow).map { window in
            AX.children(window).map { c in
                let f = AX.frame(c).map { "\(Int($0.minX)),\(Int($0.minY)) \(Int($0.width))x\(Int($0.height))" } ?? "-"
                return "\(Self.owner(of: c).bundleID ?? AX.firstIdentifier(c)) @ \(f)"
            }
        }
    }

    /// Frames of an app's items in the expanded overflow row, left to right (only while the row is open).
    func expandedRowFrames(ownerBundleID: String) -> [CGRect] {
        guard let pid = agentPID else { return [] }
        for window in AX.children(AXUIElementCreateApplication(pid)) where Self.isExpandedWindow(window) {
            let owned = AX.children(window)
                .filter { Self.owner(of: $0).bundleID == ownerBundleID }
                .compactMap(AX.frame)
                .sorted { $0.minX < $1.minX }
            if !owned.isEmpty { return owned }
        }
        return []
    }

    /// Frame of an overflowed item in the open overflow row. On macOS 27.2 the row's items carry no owner info, so
    /// match by width (each item keeps its width in the row), then by order among same-width overflowed items.
    func expandedRowFrame(for entry: MenuBarEntry, overflowed: [MenuBarEntry]) -> CGRect? {
        let owned = expandedRowFrames(ownerBundleID: entry.item.ownerBundleID)
        if entry.indexInApp < owned.count { return owned[entry.indexInApp] }
        guard let pid = agentPID else { return nil }
        let notchLimit = NSScreen.screens.first?.auxiliaryTopLeftArea.map { $0.maxX } ?? .greatestFiniteMagnitude
        let width = entry.item.frame.width
        func sameWidth(_ w: Double) -> Bool { abs(w - width) < 1.5 }
        for window in AX.children(AXUIElementCreateApplication(pid)) where Self.isExpandedWindow(window) {
            let row = AX.children(window)
                .filter { AX.firstIdentifier($0)?.hasPrefix("com.apple.") != true && AX.firstIdentifier($0)?.hasPrefix("menu-bar-") != true }
                .compactMap(AX.frame)
                .filter { $0.maxX <= notchLimit + 1 && sameWidth($0.width) }
                .sorted { $0.minX < $1.minX }
            guard !row.isEmpty else { continue }
            // Rank of this entry among overflowed entries of the same width, in their reported order.
            let peers = overflowed.filter { sameWidth($0.item.frame.width) }
            let rank = peers.firstIndex { $0.item.id == entry.item.id } ?? 0
            return row[min(rank, row.count - 1)]
        }
        return nil
    }

    // MARK: - Private

    private func mainWindow(agentPID pid: pid_t) -> AXUIElement? {
        var best: (window: AXUIElement, owned: Int)?
        for window in AX.children(AXUIElementCreateApplication(pid)) where AX.role(window) == kAXWindowRole {
            if Self.isExpandedWindow(window) { continue }
            let owned = AX.children(window).filter { Self.hasOwner($0) }.count
            if owned > (best?.owned ?? 0) { best = (window, owned) }
        }
        return best?.window
    }

    static func isExpandedWindow(_ window: AXUIElement) -> Bool {
        AX.children(window).contains { AX.firstIdentifier($0) == expandedIndicatorID }
    }

    static func hasOwner(_ group: AXUIElement) -> Bool {
        AX.children(group).contains { AX.role($0) == kAXApplicationRole }
    }

    static func owner(of group: AXUIElement) -> (pid: pid_t, bundleID: String?, name: String) {
        for child in AX.children(group) where AX.role(child) == kAXApplicationRole {
            let pid = AX.pid(child) ?? 0
            let app = pid > 0 ? NSRunningApplication(processIdentifier: pid) : nil
            let name = app?.localizedName ?? AX.string(child, kAXTitleAttribute) ?? ""
            return (pid, app?.bundleIdentifier, name)
        }
        return (0, nil, "")
    }
}
