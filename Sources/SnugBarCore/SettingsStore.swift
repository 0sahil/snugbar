import Foundation

public enum SettingsError: Error, Equatable, CustomStringConvertible {
    /// The file was written by a newer SnugBar.
    case unsupportedSchemaVersion(Int)
    case missingSchemaVersion

    public var description: String {
        switch self {
        case let .unsupportedSchemaVersion(v):
            return "settings schema version \(v) is newer than this SnugBar supports (\(Settings.currentSchemaVersion))"
        case .missingSchemaVersion:
            return "settings file has no schemaVersion"
        }
    }
}

/// Reads and writes the settings JSON file. Writes are atomic: the new content goes to a temporary file in the
/// same directory, which then replaces the old file in one rename, so a crash never leaves a half-written file.
public final class SettingsStore {
    public let url: URL

    public init(url: URL) {
        self.url = url
    }

    /// `~/Library/Application Support/SnugBar/settings.json`.
    public static var defaultURL: URL {
        SnugBarPaths.applicationSupport.appendingPathComponent("settings.json")
    }

    /// Loads the settings, or the defaults when the file doesn't exist.
    public func load() throws -> Settings {
        guard FileManager.default.fileExists(atPath: url.path) else { return .default }
        let data = try Data(contentsOf: url)
        return try Self.decode(data)
    }

    public func save(_ settings: Settings) throws {
        try AtomicFile.write(Self.encode(settings), to: url)
    }

    public static func encode(_ settings: Settings) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        var data = try encoder.encode(settings)
        data.append(0x0A)
        return data
    }

    public static func decode(_ data: Data) throws -> Settings {
        struct Header: Decodable { var schemaVersion: Int? }
        let header = try JSONDecoder().decode(Header.self, from: data)
        guard let version = header.schemaVersion else { throw SettingsError.missingSchemaVersion }
        guard version <= Settings.currentSchemaVersion else { throw SettingsError.unsupportedSchemaVersion(version) }
        // Version 1 is the only schema so far; migrations from older versions go here.
        return try JSONDecoder().decode(Settings.self, from: data)
    }
}

/// Well-known SnugBar locations.
public enum SnugBarPaths {
    public static var applicationSupport: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("SnugBar", isDirectory: true)
    }

    public static var backups: URL {
        applicationSupport.appendingPathComponent("backups", isDirectory: true)
    }
}

/// Write-to-temporary-then-rename.
public enum AtomicFile {
    public static func write(_ data: Data, to url: URL) throws {
        let fm = FileManager.default
        let dir = url.deletingLastPathComponent()
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let temp = dir.appendingPathComponent(".\(url.lastPathComponent).\(UUID().uuidString).tmp")
        do {
            try data.write(to: temp, options: [.withoutOverwriting])
            if rename(temp.path, url.path) != 0 {
                throw CocoaError(.fileWriteUnknown, userInfo: [
                    NSFilePathErrorKey: url.path,
                    NSUnderlyingErrorKey: POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO),
                ])
            }
        } catch {
            try? fm.removeItem(at: temp)
            throw error
        }
    }
}
