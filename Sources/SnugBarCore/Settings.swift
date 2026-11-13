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

    public init(
        schemaVersion: Int = Settings.currentSchemaVersion,
        sections: AppSectionMap = AppSectionMap(),
        hider: HiderPreference = .automatic,
        showIcon: Bool = true,
        autoCollapse: AutoCollapseSettings = AutoCollapseSettings(),
        reveal: RevealSettings = RevealSettings(),
        hotkeys: HotkeySettings = HotkeySettings(),
        knownApps: [String: String] = [:]
    ) {
        self.schemaVersion = schemaVersion
        self.sections = sections
        self.hider = hider
        self.showIcon = showIcon
        self.autoCollapse = autoCollapse
        self.reveal = reveal
        self.hotkeys = hotkeys
        self.knownApps = knownApps
    }

    /// A fresh install: every third-party app hidden, no hotkeys, no personal data.
    public static let `default` = Settings()

    enum CodingKeys: String, CodingKey {
        case schemaVersion, sections, hider, showIcon, autoCollapse, reveal, hotkeys, knownApps
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
