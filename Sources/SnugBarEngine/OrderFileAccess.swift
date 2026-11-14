import AppKit
import SnugBarCore

/// Access to the system menu bar order file.
///
/// The order lives in `~/Library/Group Containers/com.apple.MenuBar/Library/Preferences/com.apple.MenuBar.plist`
/// under `TrailingItemPreferredPositions` (key -> distance from the right edge). The folder is protected: SnugBar
/// gets in when the user picks it in an open panel, and keeps a security-scoped bookmark in `UserDefaults`.
/// Writes must go through cfprefs (`CFPreferencesSetValue` on the plist path without `.plist`); raw file writes are
/// ignored by the system. Every write first saves the previous dictionary as a layout backup.
@MainActor
public final class OrderFileAccess {
    public enum Status: String, Codable, Sendable {
        case granted
        case notGranted
        /// A bookmark exists but the file can't be read through it.
        case unreadable
    }

    public enum AccessError: Error, CustomStringConvertible {
        case notGranted
        case unreadable(String)
        case noPositions
        case writeFailed
        case userIsDragging

        public var description: String {
            switch self {
            case .notGranted: return "menu bar layout access not granted"
            case let .unreadable(why): return "can't read the order file: \(why)"
            case .noPositions: return "order file has no TrailingItemPreferredPositions"
            case .writeFailed: return "CFPreferencesSynchronize failed"
            case .userIsDragging: return "not writing while the user is ⌘-dragging"
            }
        }
    }

    public static let positionsKey = "TrailingItemPreferredPositions"
    static let bookmarkDefaultsKey = "OrderFileBookmark"

    /// `~/Library/Group Containers/com.apple.MenuBar/Library`.
    public static var expectedFolder: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Group Containers/com.apple.MenuBar/Library", isDirectory: true)
    }

    public let defaults: UserDefaults
    public let backupDirectory: URL
    private var scopedURL: URL?
    /// SnugBar's desired layout, saved in every backup next to the system positions.
    public var backupLayout: (() -> LayoutBackup.Layout?)?
    /// Called after a successful write: items are about to move.
    public var didWrite: (() -> Void)?

    public init(defaults: UserDefaults = .standard, backupDirectory: URL = SnugBarPaths.backups) {
        self.defaults = defaults
        self.backupDirectory = backupDirectory
    }

    // MARK: - Access

    public var status: Status {
        guard defaults.data(forKey: Self.bookmarkDefaultsKey) != nil else { return .notGranted }
        return (try? readPositions()) != nil ? .granted : .unreadable
    }

    /// Asks the user to pick the folder. Returns true when the order file is readable afterwards.
    @discardableResult
    public func requestAccess() -> Bool {
        let panel = NSOpenPanel()
        panel.message = "Choose the “Library” folder to let SnugBar arrange menu bar items without moving the pointer."
        panel.prompt = "Allow"
        panel.directoryURL = Self.expectedFolder
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.showsHiddenFiles = true
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url else { return false }
        guard Self.plistURL(forPicked: url) != nil else { return false }

        let bookmark = (try? url.bookmarkData(options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil))
            ?? (try? url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil))
        guard let bookmark else { return false }
        stopAccessing()
        scopedURL = url
        _ = url.startAccessingSecurityScopedResource()
        defaults.set(bookmark, forKey: Self.bookmarkDefaultsKey)
        return (try? readPositions()) != nil
    }

    public func revoke() {
        stopAccessing()
        defaults.removeObject(forKey: Self.bookmarkDefaultsKey)
    }

    /// Accepts the `com.apple.MenuBar` container, its `Library` or `Preferences` folder.
    nonisolated static func plistURL(forPicked url: URL) -> URL? {
        let std = url.standardizedFileURL
        switch std.lastPathComponent {
        case "com.apple.MenuBar":
            return std.appendingPathComponent("Library/Preferences/com.apple.MenuBar.plist")
        case "Library" where std.deletingLastPathComponent().lastPathComponent == "com.apple.MenuBar":
            return std.appendingPathComponent("Preferences/com.apple.MenuBar.plist")
        case "Preferences" where std.deletingLastPathComponent().deletingLastPathComponent().lastPathComponent == "com.apple.MenuBar":
            return std.appendingPathComponent("com.apple.MenuBar.plist")
        default:
            return nil
        }
    }

    private func resolvedFolder() throws -> URL {
        if let scopedURL { return scopedURL }
        guard let data = defaults.data(forKey: Self.bookmarkDefaultsKey) else { throw AccessError.notGranted }
        var stale = false
        let url: URL
        if let scoped = try? URL(resolvingBookmarkData: data, options: [.withSecurityScope], relativeTo: nil, bookmarkDataIsStale: &stale) {
            url = scoped
        } else {
            url = try URL(resolvingBookmarkData: data, options: [], relativeTo: nil, bookmarkDataIsStale: &stale)
        }
        _ = url.startAccessingSecurityScopedResource()
        scopedURL = url
        if stale, let fresh = try? url.bookmarkData(options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil) {
            defaults.set(fresh, forKey: Self.bookmarkDefaultsKey)
        }
        return url
    }

    private func stopAccessing() {
        scopedURL?.stopAccessingSecurityScopedResource()
        scopedURL = nil
    }

    // MARK: - Read and write

    public func plistURL() throws -> URL {
        guard let url = Self.plistURL(forPicked: try resolvedFolder()) else {
            throw AccessError.unreadable("bookmarked folder is not the menu bar container")
        }
        return url
    }

    /// The raw dictionary, with the original number objects (so integer/real types can be preserved on write).
    func readRawPositions() throws -> [String: NSNumber] {
        let url = try plistURL()
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw AccessError.unreadable(error.localizedDescription)
        }
        guard let root = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else {
            throw AccessError.unreadable("not a dictionary")
        }
        guard let positions = root[Self.positionsKey] as? [String: NSNumber] else { throw AccessError.noPositions }
        return positions
    }

    public func readPositions() throws -> [String: Double] {
        try readRawPositions().mapValues(\.doubleValue)
    }

    /// Merges `changes` into the dictionary and writes it through cfprefs, after saving a backup.
    /// - Parameter takeBackup: false when the caller has just saved one (restore).
    /// - Returns: the URL of the backup, when one was taken.
    @discardableResult
    public func write(changes: [String: Double], takeBackup: Bool = true) throws -> URL? {
        if Self.userIsCommandDragging { throw AccessError.userIsDragging }
        let current = try readRawPositions()
        let backup = takeBackup ? try saveBackup(current.mapValues(\.doubleValue), reason: "order") : nil

        var next: [String: NSNumber] = current
        for (key, value) in changes {
            // Keep the number type of the existing value (or of the dictionary's other values).
            let sample = current[key] ?? current.values.first
            let isFloat = sample.map { CFNumberIsFloatType($0) } ?? false
            next[key] = isFloat || value.rounded() != value ? NSNumber(value: value) : NSNumber(value: Int(value))
        }
        let appID = try plistURL().deletingPathExtension().path as CFString
        CFPreferencesSetValue(Self.positionsKey as CFString, next as CFDictionary, appID, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
        guard CFPreferencesSynchronize(appID, kCFPreferencesCurrentUser, kCFPreferencesAnyHost) else {
            throw AccessError.writeFailed
        }
        didWrite?()
        return backup
    }

    /// Restores a dictionary exactly (used to undo).
    public func restore(_ positions: [String: Double], takeBackup: Bool = true) throws {
        let current = try readPositions()
        var changes = positions
        for key in current.keys where positions[key] == nil {
            // Keys that appeared since can't be removed through a merge; keep their current value.
            changes[key] = current[key]
        }
        try write(changes: changes, takeBackup: takeBackup)
    }

    /// Saves a backup of the positions as they are now (empty when the order file can't be read) and SnugBar's
    /// desired layout, before a reset, a restore, an import or a macOS update.
    @discardableResult
    public func saveBackup(reason: String) throws -> URL {
        let positions = (try? readPositions()) ?? [:]
        return try saveBackup(positions, reason: reason)
    }

    private func saveBackup(_ positions: [String: Double], reason: String) throws -> URL {
        let backup = LayoutBackup(createdAt: Date(), systemBuild: SystemInfo.build, positions: positions,
                                  layout: backupLayout?(), reason: reason)
        return try LayoutBackupStore(directory: backupDirectory).save(backup)
    }

    /// True while the left button is down with ⌘ held: the user may be rearranging items by hand.
    public static var userIsCommandDragging: Bool {
        NSEvent.pressedMouseButtons & 1 != 0 && NSEvent.modifierFlags.contains(.command)
    }
}
