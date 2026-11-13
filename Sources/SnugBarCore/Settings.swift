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

    public init(
        schemaVersion: Int = Settings.currentSchemaVersion,
        sections: AppSectionMap = AppSectionMap(),
        hider: HiderPreference = .automatic
    ) {
        self.schemaVersion = schemaVersion
        self.sections = sections
        self.hider = hider
    }

    /// A fresh install: every third-party app hidden, no personal data.
    public static let `default` = Settings()

    enum CodingKeys: String, CodingKey {
        case schemaVersion, sections, hider
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try c.decode(Int.self, forKey: .schemaVersion)
        sections = try c.decodeIfPresent(AppSectionMap.self, forKey: .sections) ?? AppSectionMap()
        hider = try c.decodeIfPresent(HiderPreference.self, forKey: .hider) ?? .automatic
    }
}
