import Foundation

/// Which hiding backend to use.
public enum HiderPreference: String, Codable, CaseIterable, Sendable {
    /// The per-app system hider when available, else the overflow divider.
    case automatic
    /// Always the per-app system hider (fails when unavailable).
    case assessment
    /// Always the public overflow divider.
    case overflowDivider
}

/// Where revealed Hidden (and Always hidden) items appear (feature 24).
public enum RevealDestination: String, Codable, CaseIterable, Sendable {
    /// The menu bar shows them in place.
    case menuBar
    /// SnugBar's own panel under the menu bar lists them; the menu bar stays as it is.
    case snugBarBar
}

/// SnugBar's settings file. Unknown keys are ignored and missing keys take their defaults, so older and newer
/// files of the same schema version load.
public struct Settings: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 1

    public var schemaVersion: Int
    public var sections: AppSectionMap
    public var hider: HiderPreference
    /// Show SnugBar's icon in the menu bar (feature 3). When off, use a hotkey, a click on the empty bar or the CLI.
    public var showIcon: Bool
    public var autoCollapse: AutoCollapseSettings
    public var reveal: RevealSettings
    public var hotkeys: HotkeySettings
    /// Apps seen with a menu bar item: bundle ID -> app name. Lets Settings list apps while they're hidden.
    public var knownApps: [String: String]
    /// Where revealed items appear (feature 24).
    public var revealIn: RevealDestination
    /// Move the leftmost shown apps out of the menu bar when they don't fit beside the notch, and list them in the
    /// SnugBar Bar under "Didn't fit" (features 17–18).
    public var moveItemsThatDontFit: Bool
    /// Items opened from the SnugBar Bar, search or by letter, most recent first (feature 28).
    public var recentItems: [ItemID]
    /// The local HTTP server for the CLI and MCP (features 70–73).
    public var controlServer: ControlServerSettings
    /// `snugbar://` links from other apps (feature 76).
    public var urlScheme: URLSchemeSettings
    /// The order of Shown items and the spacers the user arranged, kept in place (features 37, 78–80).
    public var layout: DesiredLayout
    /// The macOS build seen at the last launch; a different build means macOS was updated, so the layout is backed up
    /// and checked.
    public var lastSystemBuild: String?
    /// The setup window was finished or closed (feature 85). Nil in files from before it existed: see
    /// `SetupLaunchDecision`. Not taken over from an imported file (it belongs to this Mac).
    public var setupCompleted: Bool?

    public init(
        schemaVersion: Int = Settings.currentSchemaVersion,
        sections: AppSectionMap = AppSectionMap(),
        hider: HiderPreference = .automatic,
        showIcon: Bool = true,
        autoCollapse: AutoCollapseSettings = AutoCollapseSettings(),
        reveal: RevealSettings = RevealSettings(),
        hotkeys: HotkeySettings = HotkeySettings(),
        knownApps: [String: String] = [:],
        revealIn: RevealDestination = .snugBarBar,
        moveItemsThatDontFit: Bool = true,
        recentItems: [ItemID] = [],
        controlServer: ControlServerSettings = ControlServerSettings(),
        urlScheme: URLSchemeSettings = URLSchemeSettings(),
        layout: DesiredLayout = DesiredLayout(),
        lastSystemBuild: String? = nil,
        setupCompleted: Bool? = nil
    ) {
        self.schemaVersion = schemaVersion
        self.sections = sections
        self.hider = hider
        self.showIcon = showIcon
        self.autoCollapse = autoCollapse
        self.reveal = reveal
        self.hotkeys = hotkeys
        self.knownApps = knownApps
        self.revealIn = revealIn
        self.moveItemsThatDontFit = moveItemsThatDontFit
        self.recentItems = recentItems
        self.controlServer = controlServer
        self.urlScheme = urlScheme
        self.layout = layout
        self.lastSystemBuild = lastSystemBuild
        self.setupCompleted = setupCompleted
    }

    /// A fresh install: every third-party app hidden, no hotkeys, no personal data.
    public static let `default` = Settings()

    enum CodingKeys: String, CodingKey {
        case schemaVersion, sections, hider, showIcon, autoCollapse, reveal, hotkeys, knownApps
        case revealIn, moveItemsThatDontFit, recentItems
        case controlServer, urlScheme
        case layout, lastSystemBuild, setupCompleted
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try c.decode(Int.self, forKey: .schemaVersion)
        sections = try c.decodeIfPresent(AppSectionMap.self, forKey: .sections) ?? AppSectionMap()
        hider = try c.decodeIfPresent(HiderPreference.self, forKey: .hider) ?? .automatic
        showIcon = try c.decodeIfPresent(Bool.self, forKey: .showIcon) ?? true
        autoCollapse = try c.decodeIfPresent(AutoCollapseSettings.self, forKey: .autoCollapse) ?? AutoCollapseSettings()
        reveal = try c.decodeIfPresent(RevealSettings.self, forKey: .reveal) ?? RevealSettings()
        hotkeys = try c.decodeIfPresent(HotkeySettings.self, forKey: .hotkeys) ?? HotkeySettings()
        knownApps = try c.decodeIfPresent([String: String].self, forKey: .knownApps) ?? [:]
        revealIn = try c.decodeIfPresent(RevealDestination.self, forKey: .revealIn) ?? .snugBarBar
        moveItemsThatDontFit = try c.decodeIfPresent(Bool.self, forKey: .moveItemsThatDontFit) ?? true
        recentItems = try c.decodeIfPresent([ItemID].self, forKey: .recentItems) ?? []
        controlServer = try c.decodeIfPresent(ControlServerSettings.self, forKey: .controlServer) ?? ControlServerSettings()
        urlScheme = try c.decodeIfPresent(URLSchemeSettings.self, forKey: .urlScheme) ?? URLSchemeSettings()
        layout = try c.decodeIfPresent(DesiredLayout.self, forKey: .layout) ?? DesiredLayout()
        lastSystemBuild = try c.decodeIfPresent(String.self, forKey: .lastSystemBuild)
        setupCompleted = try c.decodeIfPresent(Bool.self, forKey: .setupCompleted)
    }

    /// Records that an item was opened: it moves to the front of `recentItems`, which keeps `RecentItems.limit`.
    public mutating func noteRecent(_ id: ItemID) {
        recentItems = RecentItems.noting(id, in: recentItems)
    }

    /// Records apps seen in the menu bar. Returns true when something changed.
    @discardableResult
    public mutating func noteApps(_ apps: [(bundleID: String, name: String)]) -> Bool {
        var changed = false
        for app in apps where !app.bundleID.isEmpty {
            let name = app.name.isEmpty ? app.bundleID : app.name
            if knownApps[app.bundleID] != name {
                knownApps[app.bundleID] = name
                changed = true
            }
        }
        return changed
    }
}
