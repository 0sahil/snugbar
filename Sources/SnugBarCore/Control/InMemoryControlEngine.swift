import Foundation

/// A control engine that keeps everything in memory and touches nothing on screen. Used by unit tests and by the
/// `serve --fake` debug command, which runs the real HTTP/MCP server without changing the menu bar.
@MainActor
public final class InMemoryControlEngine: ControlEngine {
    public var items: [MenuBarItem]
    public var sections: AppSectionMap
    public var barState: BarState
    public var recentItems: [ItemID]
    public var canRevealSingleApp = true
    public var supportsSwap = true
    public var arranger: ControlArranger? = .orderFile
    /// What `click` reports, or an error it throws.
    public var clickMethod = "event"
    public var clickError: Error?
    public var orderError: Error?
    public var status: ControlStatusInfo
    /// Apps shown on their own by `show`.
    public private(set) var revealedApps: Set<String> = []
    /// Every action that changed something, in order ("click status:…", "section com.example.chat hidden", …).
    public private(set) var actions: [String] = []

    public init(items: [MenuBarItem], sections: AppSectionMap, barState: BarState = .initial, recentItems: [ItemID] = [],
                status: ControlStatusInfo) {
        self.items = items
        self.sections = sections
        self.barState = barState
        self.recentItems = recentItems
        self.status = status
    }

    public func controlItems() -> [ControlEngineItem] {
        let visibleSections = barState.visibleSections
        return items.map { item in
            let onScreen = item.isAppleItem
                || (!barState.zen && (visibleSections.contains(sections.section(for: item)) || revealedApps.contains(item.ownerBundleID)))
            return ControlEngineItem(item: item, visible: onScreen && !item.isOverflowed && item.frame.width > 0)
        }
    }

    public func reveal(bundleID: String) throws {
        revealedApps.insert(bundleID)
        actions.append("reveal \(bundleID)")
    }

    public func hide(bundleID: String) throws {
        revealedApps.remove(bundleID)
        actions.append("hide \(bundleID)")
    }

    public func click(_ item: MenuBarItem) async throws -> String {
        if let clickError { throw clickError }
        actions.append("click \(item.id.rawValue)")
        recentItems = RecentItems.noting(item.id, in: recentItems)
        return clickMethod
    }

    /// One action per call, so tests can see that a bulk move is one change: "section a,b hidden".
    public func setSection(_ section: Section, forBundleIDs bundleIDs: [String]) {
        sections.set(section, forBundleIDs: bundleIDs)
        actions.append("section \(bundleIDs.joined(separator: ",")) \(section.rawValue)")
    }

    public func order(_ item: MenuBarItem, _ placement: ControlPlacement) async throws -> ControlArranger {
        if let orderError { throw orderError }
        guard let arranger else { throw ControlError(.unavailable, "no arranger") }
        guard let from = items.firstIndex(where: { $0.id == item.id }) else { throw ControlError(.notFound, "item gone") }
        let moving = items.remove(at: from)
        let anchorID: ItemID
        switch placement {
        case let .before(a): anchorID = a.id
        case let .after(a): anchorID = a.id
        }
        guard let anchorIndex = items.firstIndex(where: { $0.id == anchorID }) else {
            items.insert(moving, at: from)
            throw ControlError(.notFound, "anchor gone")
        }
        if case .before = placement { items.insert(moving, at: anchorIndex) } else { items.insert(moving, at: anchorIndex + 1) }
        Self.relayout(&items)
        actions.append("order \(item.id.rawValue) \(placement.label) \(anchorID.rawValue)")
        return arranger
    }

    public func setReveal(_ level: RevealLevel) {
        guard !barState.zen || level == .collapsed else { return }
        barState.reveal = level
        if level == .collapsed { revealedApps = [] }
        actions.append("reveal-level \(level.rawValue)")
    }

    public func swap() {
        barState.swapped.toggle()
        barState.reveal = .collapsed
        actions.append("swap")
    }

    public func setZen(_ on: Bool) {
        barState.zen = on
        barState.reveal = .collapsed
        revealedApps = []
        actions.append("zen \(on ? "on" : "off")")
    }

    public func statusInfo() -> ControlStatusInfo { status }

    /// Lays items out left to right from x = 900, 28 points wide with 6 points between them.
    static func relayout(_ items: inout [MenuBarItem]) {
        var x = 900.0
        for i in items.indices where items[i].frame.width > 0 {
            items[i].frame = Rect(x: x, y: 0, width: 28, height: 24)
            x += 34
        }
    }

    // MARK: - Demo data

    /// Made-up apps and items: a system monitor with two items (Shown), a clipboard manager (Shown), a chat app and a
    /// weather app (Hidden), a VPN client (Always Hidden), and Apple's Wi-Fi, Battery and clock.
    public static func demo(version: String = "0.0.0", port: Int = 47811, tokenRequired: Bool = false) -> InMemoryControlEngine {
        func item(_ id: String, _ bundle: String, _ app: String, _ name: String? = nil, apple: Bool = false, axID: String? = nil) -> MenuBarItem {
            MenuBarItem(id: ItemID(rawValue: id), ownerBundleID: bundle, ownerPID: 100, appName: app, displayName: name ?? app,
                        frame: Rect(x: 0, y: 0, width: 28, height: 24), isAppleItem: apple, isOverflowed: false, axIdentifier: axID)
        }
        var items = [
            item("status:com.example.chat::Item-0", "com.example.chat", "Chat"),
            item("status:com.example.weather::Item-0", "com.example.weather", "Weather"),
            item("com.example.tunnel#0", "com.example.tunnel", "Tunnel"),
            item("status:com.example.meters::CPU", "com.example.meters", "Meters", "Meters: CPU"),
            item("status:com.example.meters::Memory", "com.example.meters", "Meters", "Meters: Memory"),
            item("status:org.example.clipboard::Item-0", "org.example.clipboard", "Clipboard"),
            item("module:WiFi", "com.apple.controlcenter", "Control Center", "Wi-Fi", apple: true, axID: "com.apple.menuextra.wifi"),
            item("module:Battery", "com.apple.controlcenter", "Control Center", "Battery", apple: true, axID: "com.apple.menuextra.battery"),
            item("module:Clock", "com.apple.controlcenter", "Control Center", "Clock", apple: true, axID: "com.apple.menuextra.clock"),
        ]
        relayout(&items)
        let sections = AppSectionMap(apps: [
            "com.example.meters": .shown,
            "org.example.clipboard": .shown,
            "com.example.chat": .hidden,
            "com.example.weather": .hidden,
            "com.example.tunnel": .alwaysHidden,
        ], defaultSection: .hidden)
        let status = ControlStatusInfo(
            hider: "assessment",
            permissions: ControlPermissions(accessibility: true, screenRecording: false, menuBarFolder: true),
            version: version, port: port, tokenRequired: tokenRequired
        )
        return InMemoryControlEngine(items: items, sections: sections, status: status)
    }
}

extension ControlPlacement {
    var label: String {
        switch self {
        case .before: return "before"
        case .after: return "after"
        }
    }
}
