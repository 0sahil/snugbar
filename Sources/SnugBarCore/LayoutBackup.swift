import Foundation

/// A copy of the layout taken before SnugBar changes it (feature 81): the system order dictionary and, since
/// layout persistence, SnugBar's own desired layout. Files written before the layout was added still decode.
public struct LayoutBackup: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 1

    /// SnugBar's side of the layout.
    public struct Layout: Codable, Equatable, Sendable {
        public var sections: AppSectionMap
        public var shownOrder: [String]
        public var spacers: [LayoutSpacer]
        public var hiddenOrder: [String]
        public var alwaysHiddenOrder: [String]

        public init(sections: AppSectionMap, shownOrder: [String], spacers: [LayoutSpacer], hiddenOrder: [String] = [],
                    alwaysHiddenOrder: [String] = []) {
            self.sections = sections
            self.shownOrder = shownOrder
            self.spacers = spacers
            self.hiddenOrder = hiddenOrder
            self.alwaysHiddenOrder = alwaysHiddenOrder
        }

        public init(settings: Settings) {
            self.init(sections: settings.sections, shownOrder: settings.layout.shownOrder, spacers: settings.layout.spacers,
                      hiddenOrder: settings.layout.hiddenOrder, alwaysHiddenOrder: settings.layout.alwaysHiddenOrder)
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            sections = try c.decodeIfPresent(AppSectionMap.self, forKey: .sections) ?? AppSectionMap()
            shownOrder = try c.decodeIfPresent([String].self, forKey: .shownOrder) ?? []
            spacers = try c.decodeIfPresent([LayoutSpacer].self, forKey: .spacers) ?? []
            hiddenOrder = try c.decodeIfPresent([String].self, forKey: .hiddenOrder) ?? []
            alwaysHiddenOrder = try c.decodeIfPresent([String].self, forKey: .alwaysHiddenOrder) ?? []
        }

        /// Puts this layout into settings, leaving everything else alone.
        public func apply(to settings: inout Settings) {
            settings.sections = sections
            settings.layout.shownOrder = shownOrder
            settings.layout.spacers = spacers
            settings.layout.hiddenOrder = hiddenOrder
            settings.layout.alwaysHiddenOrder = alwaysHiddenOrder
        }
    }

    public var schemaVersion: Int
    public var createdAt: Date
    /// macOS build the backup was taken on.
    public var systemBuild: String?
    /// `TrailingItemPreferredPositions` as it was; empty when SnugBar couldn't read it.
    public var positions: [String: Double]
    /// SnugBar's desired layout as it was (nil in backups written before it was added).
    public var layout: Layout?
    /// Why it was taken: `order`, `reset`, `restore`, `macOS update`, `import`.
    public var reason: String?

    public init(createdAt: Date, systemBuild: String?, positions: [String: Double], layout: Layout? = nil, reason: String? = nil) {
        schemaVersion = Self.currentSchemaVersion
        self.createdAt = createdAt
        self.systemBuild = systemBuild
        self.positions = positions
        self.layout = layout
        self.reason = reason
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try c.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? Self.currentSchemaVersion
        createdAt = try c.decode(Date.self, forKey: .createdAt)
        systemBuild = try c.decodeIfPresent(String.self, forKey: .systemBuild)
        positions = try c.decodeIfPresent([String: Double].self, forKey: .positions) ?? [:]
        layout = try c.decodeIfPresent(Layout.self, forKey: .layout)
        reason = try c.decodeIfPresent(String.self, forKey: .reason)
    }

    /// Items in the backup: order-file positions, else the keys of the saved order.
    public var itemCount: Int {
        positions.isEmpty ? (layout?.shownOrder.count ?? 0) : positions.count
    }

    public func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(self)
    }

    public static func decode(_ data: Data) throws -> LayoutBackup {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(LayoutBackup.self, from: data)
    }
}

/// File naming and retention for layout backups.
public enum LayoutBackupPolicy {
    public static let keepCount = 20

    /// `20261113-171102-123.json` (UTC). Sorts chronologically as text.
    public static func fileName(for date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyyMMdd-HHmmss-SSS"
        return f.string(from: date) + ".json"
    }

    /// Backup file names to delete so that only the newest `keep` remain. Ignores files that aren't backups.
    public static func namesToPrune(_ names: [String], keep: Int = keepCount) -> [String] {
        let backups = names.filter(isBackupName).sorted()
        guard backups.count > keep else { return [] }
        return Array(backups.prefix(backups.count - keep))
    }

    static func isBackupName(_ name: String) -> Bool {
        // yyyyMMdd-HHmmss-SSS.json
        guard name.hasSuffix(".json") else { return false }
        let stem = name.dropLast(5)
        let parts = stem.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 3, parts[0].count == 8, parts[1].count == 6, parts[2].count == 3 else { return false }
        return parts.allSatisfy { $0.allSatisfy(\.isNumber) }
    }
}

/// The backups folder: saving with retention, listing, loading.
public struct LayoutBackupStore: Sendable {
    public struct Entry: Codable, Equatable, Sendable, Identifiable {
        public var url: URL
        public var createdAt: Date
        public var systemBuild: String?
        /// Order-file positions in the backup.
        public var positionCount: Int
        /// Items of SnugBar's saved order in the backup (nil for backups without SnugBar's layout).
        public var orderCount: Int?
        public var appSectionCount: Int?
        public var spacerCount: Int?
        public var reason: String?

        public init(url: URL, createdAt: Date, systemBuild: String?, positionCount: Int, orderCount: Int?,
                    appSectionCount: Int?, spacerCount: Int?, reason: String?) {
            self.url = url
            self.createdAt = createdAt
            self.systemBuild = systemBuild
            self.positionCount = positionCount
            self.orderCount = orderCount
            self.appSectionCount = appSectionCount
            self.spacerCount = spacerCount
            self.reason = reason
        }

        public var id: URL { url }
        public var hasLayout: Bool { orderCount != nil }
        /// Items listed in Settings: positions, else the saved order.
        public var itemCount: Int { positionCount > 0 ? positionCount : (orderCount ?? 0) }
    }

    public let directory: URL
    public var keep: Int

    public init(directory: URL, keep: Int = LayoutBackupPolicy.keepCount) {
        self.directory = directory
        self.keep = keep
    }

    /// Writes the backup under a name from its date (a later millisecond when that name is taken), then deletes
    /// all but the newest `keep`.
    @discardableResult
    public func save(_ backup: LayoutBackup) throws -> URL {
        let fm = FileManager.default
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        var date = backup.createdAt
        var url = directory.appendingPathComponent(LayoutBackupPolicy.fileName(for: date))
        while fm.fileExists(atPath: url.path) {
            date = date.addingTimeInterval(0.001)
            url = directory.appendingPathComponent(LayoutBackupPolicy.fileName(for: date))
        }
        try AtomicFile.write(backup.encoded(), to: url)
        let names = (try? fm.contentsOfDirectory(atPath: directory.path)) ?? []
        for name in LayoutBackupPolicy.namesToPrune(names, keep: keep) {
            try? fm.removeItem(at: directory.appendingPathComponent(name))
        }
        return url
    }

    /// Backups newest first. Files that aren't backups or don't decode are left out.
    public func list() -> [Entry] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        return names.filter(LayoutBackupPolicy.isBackupName).sorted(by: >).compactMap { name in
            let url = directory.appendingPathComponent(name)
            guard let backup = try? load(url) else { return nil }
            return Entry(
                url: url, createdAt: backup.createdAt, systemBuild: backup.systemBuild, positionCount: backup.positions.count,
                orderCount: backup.layout?.shownOrder.count, appSectionCount: backup.layout?.sections.apps.count,
                spacerCount: backup.layout?.spacers.count, reason: backup.reason
            )
        }
    }

    public func load(_ url: URL) throws -> LayoutBackup {
        try LayoutBackup.decode(Data(contentsOf: url))
    }
}
