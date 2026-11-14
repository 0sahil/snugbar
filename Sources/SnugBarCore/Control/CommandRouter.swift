import Foundation

/// An item as the control commands see it.
public struct ControlEngineItem: Equatable, Sendable {
    public var item: MenuBarItem
    /// On screen in the menu bar now.
    public var visible: Bool

    public init(item: MenuBarItem, visible: Bool) {
        self.item = item
        self.visible = visible
    }
}

/// How `order` moves items.
public enum ControlArranger: String, Codable, Sendable {
    /// Writes the system order file (no pointer movement).
    case orderFile
    /// Synthetic ⌘-drag in the menu bar.
    case drag
}

public enum ControlPlacement: Equatable, Sendable {
    /// Immediately left of the item.
    case before(MenuBarItem)
    /// Immediately right of the item.
    case after(MenuBarItem)
}

/// Facts for `status` that only the app knows.
public struct ControlStatusInfo: Equatable, Sendable {
    /// `assessment` or `overflowDivider`.
    public var hider: String
    public var permissions: ControlPermissions
    public var version: String
    public var port: Int
    public var tokenRequired: Bool

    public init(hider: String, permissions: ControlPermissions, version: String, port: Int, tokenRequired: Bool) {
        self.hider = hider
        self.permissions = permissions
        self.version = version
        self.port = port
        self.tokenRequired = tokenRequired
    }
}

/// What the commands act on. The app implements it on top of its controller and engine; tests and the `serve`
/// debug command use `InMemoryControlEngine`. Implementations do what they are told; the router checks arguments,
/// resolves items and enforces the rules (Zen locks reveals, Apple's items stay shown, and so on).
@MainActor
public protocol ControlEngine: AnyObject {
    /// Every item SnugBar knows, left to right, without SnugBar's own.
    func controlItems() -> [ControlEngineItem]
    var sections: AppSectionMap { get }
    var barState: BarState { get }
    var recentItems: [ItemID] { get }
    /// Whether one app can be shown on its own (needs the per-app hider).
    var canRevealSingleApp: Bool { get }
    var supportsSwap: Bool { get }
    /// How `order` would move items now, or nil when it can't.
    var arranger: ControlArranger? { get }

    /// Shows one app's items until the auto-hide delay passes.
    func reveal(bundleID: String) throws
    /// Ends a reveal of the app now.
    func hide(bundleID: String) throws
    /// Opens the item's menu. Returns the method used (`event` or `ax`).
    func click(_ item: MenuBarItem) async throws -> String
    /// Puts the apps in the section with one settings change.
    func setSection(_ section: Section, forBundleIDs bundleIDs: [String])
    /// Moves a shown item next to another. Returns the method used.
    func order(_ item: MenuBarItem, _ placement: ControlPlacement) async throws -> ControlArranger
    func setReveal(_ level: RevealLevel)
    func swap()
    func setZen(_ on: Bool)
    func statusInfo() -> ControlStatusInfo
}

/// Runs control commands against an engine. Every transport (HTTP `/v1`, MCP, the URL scheme) goes through here.
@MainActor
public final class CommandRouter {
    public let engine: ControlEngine

    public init(engine: ControlEngine) {
        self.engine = engine
    }

    /// Never throws: failures come back as `ok: false` with an error code.
    public func handle(_ request: ControlRequest) async -> ControlResponse {
        do {
            return try await perform(request)
        } catch let error as ControlError {
            return .failure(error)
        } catch {
            return .failure(ControlError(.failed, String(describing: error)))
        }
    }

    private func perform(_ request: ControlRequest) async throws -> ControlResponse {
        let args = request.arguments
        var r = ControlResponse(ok: true)
        switch request.command {
        case .list:
            let filter = try args.section.map { try section($0) }
            r.items = listed().filter { filter == nil || $0.section == filter }

        case .search:
            guard let query = nonEmpty(args.query) else { throw invalid("search needs a query") }
            let entries = engine.controlItems()
            let visible = Dictionary(entries.map { ($0.item.id, $0.visible) }, uniquingKeysWith: { a, _ in a })
            let ranked = FuzzyMatcher.rank(query, items: entries.map(\.item), recents: engine.recentItems)
            r.query = query
            r.items = ranked.map { controlItem($0.item, visible: visible[$0.item.id] ?? false) }

        case .status:
            let info = engine.statusInfo()
            r.version = info.version
            r.hider = info.hider
            r.arranger = engine.arranger?.rawValue ?? "none"
            r.permissions = info.permissions
            r.port = info.port
            r.token = info.tokenRequired
            fillState(&r)

        case .show:
            let entry = try resolve(args.item, role: "item")
            let item = entry.item
            try requireThirdParty(item, "is always shown")
            try requireNoZen()
            // Shown apps that are on screen need nothing; "Didn't fit" apps are in Shown but off screen.
            if !isShownWhenCollapsed(item) || !entry.visible {
                guard engine.canRevealSingleApp else {
                    throw ControlError(.unavailable, "showing a single app needs per-app hiding, which isn't available; use expand instead")
                }
                try engine.reveal(bundleID: item.ownerBundleID)
            }
            r.id = item.id.rawValue

        case .hide:
            let item = try resolve(args.item, role: "item").item
            try requireThirdParty(item, "is always shown and can't be hidden")
            if isShownWhenCollapsed(item) {
                let name = item.appName.isEmpty ? item.id.rawValue : item.appName
                throw invalid("\(name) is in the Shown section; move it to Hidden first (snugbar move \(Self.quoted(name)) hidden)")
            }
            try engine.hide(bundleID: item.ownerBundleID)
            r.id = item.id.rawValue

        case .click:
            let item = try resolve(args.item, role: "item").item
            try requireNoZen()
            r.id = item.id.rawValue
            r.method = try await engine.click(item)

        case .move:
            let references = try moveReferences(args)
            guard let name = nonEmpty(args.section) else { throw invalid("move needs a section: shown, hidden or alwaysHidden") }
            let target = try section(name)
            // Resolve and check every item before anything moves, so one bad item leaves everything as it was.
            let several = references.count > 1
            var bundles: [String] = []
            var fallbackIDs: [String: [String]] = [:]
            for reference in references {
                let item: MenuBarItem
                do {
                    item = try resolve(reference, role: "item").item
                } catch var e as ControlError where several {
                    e.message += "; nothing was moved"
                    throw e
                }
                try requireThirdParty(item, "is always shown and can't be moved to another section")
                let bundle = item.ownerBundleID
                guard !bundle.isEmpty else { throw invalid("\(item.id.rawValue) has no owning app, so it can't change section") }
                if !bundles.contains(bundle) { bundles.append(bundle) }
                fallbackIDs[bundle, default: []].append(item.id.rawValue)
            }
            engine.setSection(target, forBundleIDs: bundles)
            let all = engine.controlItems().map(\.item)
            var moved: [String] = []
            for bundle in bundles {
                let ids = all.filter { $0.ownerBundleID == bundle }.map(\.id.rawValue)
                for id in ids.isEmpty ? fallbackIDs[bundle] ?? [] : ids where !moved.contains(id) { moved.append(id) }
            }
            r.moved = moved
            r.section = target

        case .order:
            let item = try resolve(args.item, role: "item").item
            let before = nonEmpty(args.before), after = nonEmpty(args.after)
            guard (before == nil) != (after == nil) else { throw invalid("order needs exactly one of before or after") }
            let anchor = try resolve(before ?? after, role: before != nil ? "before" : "after").item
            guard anchor.id != item.id else { throw invalid("an item can't be placed next to itself") }
            for i in [item, anchor] where engine.sections.section(for: i) != .shown {
                throw invalid("\(i.displayName) is not in the Shown section; order works within Shown")
            }
            guard engine.arranger != nil else {
                throw ControlError(.unavailable, "moving items needs Accessibility (for ⌘-drag) or menu bar layout access; grant one in SnugBar's settings")
            }
            let used = try await engine.order(item, before != nil ? .before(anchor) : .after(anchor))
            r.id = item.id.rawValue
            r.method = used.rawValue

        case .expand:
            try requireNoZen()
            if engine.barState.reveal == .collapsed { engine.setReveal(.expanded) }
            fillState(&r)

        case .collapse:
            engine.setReveal(.collapsed)
            fillState(&r)

        case .toggle:
            if engine.barState.reveal == .collapsed {
                try requireNoZen()
                engine.setReveal(.expanded)
            } else {
                engine.setReveal(.collapsed)
            }
            fillState(&r)

        case .swap:
            try requireNoZen()
            guard engine.supportsSwap else {
                throw ControlError(.unavailable, "swapping needs per-app hiding, which isn't available")
            }
            engine.swap()
            fillState(&r)

        case .zen:
            let on: Bool
            switch nonEmpty(args.state)?.lowercased() ?? "toggle" {
            case "on", "true", "1": on = true
            case "off", "false", "0": on = false
            case "toggle": on = !engine.barState.zen
            case let other: throw invalid("zen takes on, off or toggle, not '\(other)'")
            }
            engine.setZen(on)
            fillState(&r)
        }
        return r
    }

    // MARK: - Items

    private func listed() -> [ControlItem] {
        engine.controlItems().map { controlItem($0.item, visible: $0.visible) }
    }

    private func controlItem(_ item: MenuBarItem, visible: Bool) -> ControlItem {
        ControlItem(
            id: item.id.rawValue, app: item.appName, bundleId: item.ownerBundleID, name: item.displayName,
            section: engine.sections.section(for: item), visible: visible, overflowed: item.isOverflowed,
            x: item.frame.x, width: item.frame.width
        )
    }

    /// Resolves an ItemID, a bundle ID or a (fuzzy) name.
    private func resolve(_ reference: String?, role: String) throws -> ControlEngineItem {
        guard let query = nonEmpty(reference) else { throw invalid("missing \(role): give an item ID, a bundle ID or a name") }
        let entries = engine.controlItems()
        switch ItemQuery.resolve(query, in: entries.map(\.item)) {
        case let .success(item):
            return entries.first { $0.item.id == item.id } ?? ControlEngineItem(item: item, visible: false)
        case .failure(.notFound):
            throw ControlError(.notFound, "no menu bar item matches '\(query)'")
        case let .failure(.ambiguous(_, ids)):
            let byID = Dictionary(entries.map { ($0.item.id, $0.item) }, uniquingKeysWith: { a, _ in a })
            let candidates = ids.compactMap { byID[$0] }.map(ControlCandidate.init)
            throw ControlError(.ambiguous, "'\(query)' matches several items; use one of their IDs", candidates: candidates)
        }
    }

    /// The items `move` names: `item` or `items`, exactly one of them.
    private func moveReferences(_ args: ControlArguments) throws -> [String] {
        switch (args.item, args.items) {
        case (nil, nil): throw invalid("move needs an item (or items): give an item ID, a bundle ID or a name")
        case (_?, _?): throw invalid("give item or items, not both")
        case let (item?, nil): return [item]
        case let (nil, items?):
            guard !items.isEmpty else { throw invalid("items is empty; give at least one item") }
            if items.contains(where: { nonEmpty($0) == nil }) { throw invalid("items contains an empty item") }
            return items
        }
    }

    /// The item's app is in the menu bar while collapsed (Shown, or Hidden while swapped).
    private func isShownWhenCollapsed(_ item: MenuBarItem) -> Bool {
        item.isAppleItem || engine.barState.collapsedSections.contains(engine.sections.section(for: item))
    }

    // MARK: - Checks

    private func section(_ name: String) throws -> Section {
        guard let s = Section(controlName: name) else {
            throw invalid("unknown section '\(name)'; use shown, hidden or alwaysHidden")
        }
        return s
    }

    private func requireNoZen() throws {
        if engine.barState.zen {
            throw ControlError(.locked, "Zen mode is on and locks every way of showing items; turn it off first (snugbar zen off)")
        }
    }

    private func requireThirdParty(_ item: MenuBarItem, _ why: String) throws {
        if item.isAppleItem { throw invalid("\(item.displayName) is one of Apple's items, which \(why)") }
    }

    private func fillState(_ r: inout ControlResponse) {
        let s = engine.barState
        r.state = s.reveal
        r.swapped = s.swapped
        r.zen = s.zen
    }

    private func invalid(_ message: String) -> ControlError { ControlError(.invalidArgument, message) }

    private func nonEmpty(_ s: String?) -> String? {
        guard let t = s?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty else { return nil }
        return t
    }

    static func quoted(_ s: String) -> String {
        s.contains(" ") ? "\"\(s)\"" : s
    }
}
