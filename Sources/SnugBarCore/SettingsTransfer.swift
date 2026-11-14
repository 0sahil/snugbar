import Foundation

/// Exporting and importing the settings file (feature 82). The file is the same JSON as `settings.json`; the access
/// token and the order-file bookmark are never part of it.
public enum SettingsTransfer {
    public enum ImportError: Error, Equatable, CustomStringConvertible {
        case notJSON
        case missingSchemaVersion
        case newerSchemaVersion(Int)
        case invalid(String)

        public var description: String {
            switch self {
            case .notJSON:
                return "The file isn’t a SnugBar settings file (it doesn’t contain JSON)."
            case .missingSchemaVersion:
                return "The file isn’t a SnugBar settings file (it has no schemaVersion)."
            case let .newerSchemaVersion(v):
                return "The file was written by a newer SnugBar (settings version \(v); this SnugBar reads up to \(Settings.currentSchemaVersion)). Update SnugBar to import it."
            case let .invalid(why):
                return "The settings file couldn’t be read: \(why)"
            }
        }
    }

    /// Pretty-printed JSON, the same as `settings.json`.
    public static func export(_ settings: Settings) throws -> Data {
        try SettingsStore.encode(settings)
    }

    /// Validates and decodes an imported file. Keys the file lacks take their defaults.
    public static func decodeImport(_ data: Data) throws -> Settings {
        guard (try? JSONSerialization.jsonObject(with: data)) is [String: Any] else { throw ImportError.notJSON }
        do {
            return try SettingsStore.decode(data)
        } catch let error as SettingsError {
            switch error {
            case .missingSchemaVersion: throw ImportError.missingSchemaVersion
            case let .unsupportedSchemaVersion(v): throw ImportError.newerSchemaVersion(v)
            }
        } catch let error as DecodingError {
            throw ImportError.invalid(describe(error))
        } catch {
            throw ImportError.invalid(String(describing: error))
        }
    }

    static func describe(_ error: DecodingError) -> String {
        func path(_ context: DecodingError.Context) -> String {
            let p = context.codingPath.map { $0.intValue.map(String.init) ?? $0.stringValue }.joined(separator: ".")
            return p.isEmpty ? "" : " at \(p)"
        }
        switch error {
        case let .typeMismatch(_, c), let .valueNotFound(_, c), let .dataCorrupted(c):
            return c.debugDescription + path(c)
        case let .keyNotFound(key, c):
            return "missing \(key.stringValue)" + path(c)
        @unknown default:
            return String(describing: error)
        }
    }
}

/// "Reset Layout…" (feature 81): every third-party app back in the default section, no kept order, no spacers.
/// Everything else (shortcuts, the default section itself, known apps) stays.
public enum LayoutReset {
    public static func reset(_ settings: Settings) -> Settings {
        var s = settings
        s.sections.apps = [:]
        s.layout = DesiredLayout()
        return s
    }
}
