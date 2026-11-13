import Foundation

/// A copy of the system order dictionary taken before SnugBar changes it.
public struct LayoutBackup: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 1

    public var schemaVersion: Int
    public var createdAt: Date
    /// macOS build the backup was taken on.
    public var systemBuild: String?
    /// `TrailingItemPreferredPositions` as it was.
    public var positions: [String: Double]

    public init(createdAt: Date, systemBuild: String?, positions: [String: Double]) {
        schemaVersion = Self.currentSchemaVersion
        self.createdAt = createdAt
        self.systemBuild = systemBuild
        self.positions = positions
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
