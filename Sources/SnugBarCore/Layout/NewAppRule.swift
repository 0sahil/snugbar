import Foundation

/// An app seen with a menu bar item for the first time.
public struct NewApp: Equatable, Sendable {
    public var bundleID: String
    public var name: String
    /// The section it was put in.
    public var section: Section

    public init(bundleID: String, name: String, section: Section) {
        self.bundleID = bundleID
        self.name = name
        self.section = section
    }
}

/// New items from newly seen apps go to the section chosen in Settings (feature 41).
public enum NewAppRule {
    /// Apps among `seen` that SnugBar has never seen: not in `knownApps` and without a section of their own. On the
    /// very first run (nothing known, nothing assigned) every app would be new, so none is reported.
    public static func detect(seen: [(bundleID: String, name: String)], settings: Settings, ownBundleID: String) -> [NewApp] {
        guard !settings.knownApps.isEmpty || !settings.sections.apps.isEmpty else { return [] }
        var result: [NewApp] = []
        var listed = Set<String>()
        for app in seen {
            let bundle = app.bundleID
            guard !bundle.isEmpty, bundle != ownBundleID, settings.knownApps[bundle] == nil,
                  settings.sections.apps[bundle] == nil, listed.insert(bundle).inserted
            else { continue }
            result.append(NewApp(bundleID: bundle, name: app.name.isEmpty ? bundle : app.name, section: settings.sections.defaultSection))
        }
        return result
    }

    /// Puts each new app in its section (so a later change of the default doesn't move it), remembers it, and when
    /// it went to Shown and an order is kept, adds its items at the end of Shown's order.
    /// - Parameter keys: each app's item keys, left to right.
    public static func apply(_ apps: [NewApp], keys: [String: [String]], to settings: inout Settings) {
        for app in apps {
            settings.sections.set(app.section, forBundleID: app.bundleID)
            settings.knownApps[app.bundleID] = app.name
            guard app.section == .shown, settings.layout.enforcesOrder, let appKeys = keys[app.bundleID], !appKeys.isEmpty else { continue }
            let order = settings.layout.shownOrder.filter { !appKeys.contains($0) }
            settings.layout.shownOrder = DesiredOrder.merging(live: appKeys, into: order, atEnd: Set(appKeys))
        }
    }
}

/// "New: <App> was put in Hidden" entries for SnugBar's menu, each shown once.
public struct NewAppNotices: Equatable, Sendable {
    public private(set) var pending: [NewApp] = []

    public init() {}

    /// Adds notices; a second notice for the same app replaces the first.
    public mutating func add(_ apps: [NewApp]) {
        for app in apps {
            pending.removeAll { $0.bundleID == app.bundleID }
            pending.append(app)
        }
    }

    /// The menu is opening: returns the notices to show, which are then gone.
    public mutating func takeForMenu() -> [NewApp] {
        defer { pending = [] }
        return pending
    }

    /// The user moved these apps themselves: their notices are no longer news.
    public mutating func appsMoved(_ bundleIDs: some Sequence<String>) {
        let moved = Set(bundleIDs)
        pending.removeAll { moved.contains($0.bundleID) }
    }

    public static func title(for app: NewApp) -> String {
        "New: \(app.name) was put in \(app.section.title)"
    }
}
