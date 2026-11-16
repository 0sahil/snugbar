import Foundation

/// The three things SnugBar asks the user to allow (features 85–87).
public enum PermissionKind: String, CaseIterable, Codable, Sendable {
    /// Reads the menu bar and opens items. Required for everything but basic hide and show.
    case accessibility
    /// Pictures of items. Without it, app icons.
    case screenRecording
    /// The Menu Bar folder (the system order file): reorder without moving the pointer.
    case menuBarFolder

    /// Its pane's name in System Settings > Privacy & Security on macOS 27, or "Menu Bar Folder". Users look for
    /// this name, so titles and errors use it (`SystemSettingsNames`).
    public var title: String {
        switch self {
        case .accessibility: return SystemSettingsNames.accessibilityPane
        case .screenRecording: return SystemSettingsNames.screenRecordingPane
        case .menuBarFolder: return "Menu Bar Folder"
        }
    }

    /// The pane's name before macOS 27, when it changed in a way users wouldn't recognize.
    public var earlierName: String? {
        switch self {
        case .accessibility: return SystemSettingsNames.accessibilityEarlierName
        case .screenRecording, .menuBarFolder: return nil
        }
    }

    /// "(called Accessibility in earlier macOS versions)", or nil.
    public var earlierNameNote: String? {
        earlierName.map { "(called \($0) in earlier macOS versions)" }
    }

    /// The anchor that opens its pane (`x-apple.systempreferences:com.apple.preference.security?<anchor>`); nil for
    /// the folder.
    public var settingsAnchor: String? {
        switch self {
        case .accessibility: return SystemSettingsNames.accessibilityAnchor
        case .screenRecording: return SystemSettingsNames.screenRecordingAnchor
        case .menuBarFolder: return nil
        }
    }

    public var isRequired: Bool { self == .accessibility }

    /// What SnugBar uses it for. Shown where each permission is explained (the setup page and Settings >
    /// Permissions), so it carries the earlier name once.
    public var purpose: String {
        switch self {
        case .accessibility:
            return "SnugBar uses \(title) \(earlierNameNote ?? "") to read the menu bar and open items."
        case .screenRecording:
            // The pane's name now says audio; SnugBar never records any.
            return "SnugBar uses \(title) to show pictures of items in the SnugBar Bar and the layout editor. It captures only the menu bar, never audio."
        case .menuBarFolder:
            return "With access to the Menu Bar folder, SnugBar can reorder items without moving the pointer."
        }
    }

    /// What still works without it.
    public var withoutIt: String {
        switch self {
        case .accessibility:
            return "Without it, only basic hide and show work: no item list, search, SnugBar Bar, showing items from the menu bar, or layout editor."
        case .screenRecording:
            return "Without it, SnugBar shows app icons instead. Everything else works."
        case .menuBarFolder:
            return "Without it, reordering moves the pointer briefly."
        }
    }

    /// The button that opens the right System Settings pane, or the folder picker. The pane's full name is the title
    /// beside it, so the button doesn't repeat it (and stays short).
    public var buttonTitle: String {
        switch self {
        case .accessibility, .screenRecording: return "Open System Settings"
        case .menuBarFolder: return "Choose Folder…"
        }
    }

    /// "Allowed" / "Not allowed" (the folder: "Chosen" / "Not chosen").
    public func statusText(granted: Bool) -> String {
        switch self {
        case .accessibility, .screenRecording: return granted ? "Allowed" : "Not allowed"
        case .menuBarFolder: return granted ? "Chosen" : "Not chosen"
        }
    }

    /// A short name for tight places, as in "Needs Device Control" (a feature's reason on one line).
    public var needsPhrase: String {
        switch self {
        case .accessibility: return SystemSettingsNames.accessibilityShort
        case .screenRecording: return SystemSettingsNames.screenRecordingShort
        case .menuBarFolder: return "Menu Bar folder"
        }
    }
}

/// The System Settings names SnugBar's wording points to, in one place.
///
/// macOS 27 renamed two panes in Privacy & Security: Accessibility is now "Device Control and Data Access" and
/// Screen Recording is "Screen & System Audio Recording" (macOS 27.2, SecurityPrivacyExtension.appex
/// Localizable.loctable, keys `ACCESSIBILITY` and `SCREENANDAUDIOCAPTURE`). The deep-link anchors didn't change: the
/// same extension's PrivacySecurity.searchTerms still registers `Privacy_Accessibility` and `Privacy_ScreenCapture`.
public enum SystemSettingsNames {
    public static let privacyAndSecurity = "System Settings > Privacy & Security"
    public static let accessibilityPane = "Device Control and Data Access"
    public static let accessibilityEarlierName = "Accessibility"
    /// The start of the pane's name, for the menu entry and one-line reasons.
    public static let accessibilityShort = "Device Control"
    public static let screenRecordingPane = "Screen & System Audio Recording"
    /// macOS 27 still calls the permission itself "Screen Recording" (key `SCREEN_CAPTURE`).
    public static let screenRecordingShort = "Screen Recording"
    public static let accessibilityAnchor = "Privacy_Accessibility"
    public static let screenRecordingAnchor = "Privacy_ScreenCapture"

    /// "System Settings > Privacy & Security > <pane>".
    public static func path(_ pane: String) -> String { "\(privacyAndSecurity) > \(pane)" }
}

/// Which permissions SnugBar has. `orderFile` is the Menu Bar folder.
public struct PermissionGrants: Codable, Equatable, Hashable, Sendable {
    public var accessibility: Bool
    public var screenRecording: Bool
    public var orderFile: Bool

    public init(accessibility: Bool, screenRecording: Bool, orderFile: Bool) {
        self.accessibility = accessibility
        self.screenRecording = screenRecording
        self.orderFile = orderFile
    }

    public static let none = PermissionGrants(accessibility: false, screenRecording: false, orderFile: false)
    public static let all = PermissionGrants(accessibility: true, screenRecording: true, orderFile: true)

    public func has(_ kind: PermissionKind) -> Bool {
        switch kind {
        case .accessibility: return accessibility
        case .screenRecording: return screenRecording
        case .menuBarFolder: return orderFile
        }
    }

    /// All eight combinations.
    public static var allCombinations: [PermissionGrants] {
        [false, true].flatMap { a in [false, true].flatMap { s in [false, true].map { o in
            PermissionGrants(accessibility: a, screenRecording: s, orderFile: o)
        } } }
    }

    /// Parses `none` or a comma list of `accessibility`, `screenRecording`, `orderFile` (also `menuBarFolder`, any
    /// case). Nil for an unknown name.
    public init?(list: String) {
        self = .none
        let names = list.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces).lowercased() }.filter { !$0.isEmpty }
        if names == ["none"] { return }
        if names == ["all"] { self = .all; return }
        for name in names {
            switch name {
            case "accessibility", "ax": accessibility = true
            case "screenrecording", "screen-recording", "sr": screenRecording = true
            case "orderfile", "order-file", "menubarfolder", "menu-bar-folder", "folder": orderFile = true
            default: return nil
            }
        }
    }

    /// `accessibility,screenRecording,orderFile` or `none`.
    public var listDescription: String {
        var names: [String] = []
        if accessibility { names.append("accessibility") }
        if screenRecording { names.append("screenRecording") }
        if orderFile { names.append("orderFile") }
        return names.isEmpty ? "none" : names.joined(separator: ",")
    }
}

/// What SnugBar can do, by feature, for the reduced modes (features 86, 87).
public enum AppFeature: String, CaseIterable, Codable, Sendable {
    /// Hide and show sections: icon click, shortcuts, the command line's expand, collapse, toggle, swap and Zen.
    case hideAndShow
    case keyboardShortcuts
    case snugBarBar
    case search
    case openByLetter
    case layoutEditor
    /// Showing hidden items by clicking, resting the pointer or scrolling on the menu bar.
    case revealGestures
    /// Opening Notification Center from the clock while items are hidden.
    case notificationCenter
    /// Opening items' menus (SnugBar Bar, search, letters, `click`), and `order`.
    case openItems
    /// Moving shown items that don't fit beside the notch into Hidden.
    case fitHandling
    /// Keeping the arranged order after apps relaunch, wake and display changes.
    case keepOrder
    /// Pictures of items instead of app icons.
    case itemPictures
    /// Reordering through the order file instead of a ⌘-drag.
    case reorderWithoutPointer

    public var title: String {
        switch self {
        case .hideAndShow: return "Hide and show items"
        case .keyboardShortcuts: return "Keyboard shortcuts"
        case .snugBarBar: return "SnugBar Bar"
        case .search: return "Search"
        case .openByLetter: return "Open by letter"
        case .layoutEditor: return "Layout editor"
        case .revealGestures: return "Click, hover or scroll on the menu bar"
        case .notificationCenter: return "Notification Center from the clock while items are hidden"
        case .openItems: return "Open and reorder items from SnugBar"
        case .fitHandling: return "Move items that don’t fit beside the notch"
        case .keepOrder: return "Keep the item order"
        case .itemPictures: return "Pictures of items"
        case .reorderWithoutPointer: return "Reorder without moving the pointer"
        }
    }

    /// The permissions it needs.
    public var requirements: [PermissionKind] {
        switch self {
        case .hideAndShow, .keyboardShortcuts: return []
        case .snugBarBar, .search, .openByLetter, .layoutEditor, .revealGestures, .notificationCenter, .openItems,
             .fitHandling, .keepOrder:
            return [.accessibility]
        case .itemPictures: return [.accessibility, .screenRecording]
        case .reorderWithoutPointer: return [.accessibility, .menuBarFolder]
        }
    }

    /// The short list on the last setup page.
    public static let summary: [AppFeature] = [
        .hideAndShow, .keyboardShortcuts, .snugBarBar, .search, .revealGestures, .layoutEditor, .itemPictures,
        .reorderWithoutPointer,
    ]
}

/// What works with a set of permissions.
public struct FeatureAvailability: Equatable, Sendable {
    public struct Entry: Codable, Equatable, Sendable {
        public var feature: AppFeature
        public var title: String
        public var available: Bool
        /// Why not, when unavailable ("Needs Device Control").
        public var reason: String?
    }

    public let grants: PermissionGrants

    public init(grants: PermissionGrants) {
        self.grants = grants
    }

    public init(accessibility: Bool, screenRecording: Bool, orderFile: Bool) {
        self.init(grants: PermissionGrants(accessibility: accessibility, screenRecording: screenRecording, orderFile: orderFile))
    }

    public func missing(for feature: AppFeature) -> [PermissionKind] {
        feature.requirements.filter { !grants.has($0) }
    }

    public func isAvailable(_ feature: AppFeature) -> Bool {
        missing(for: feature).isEmpty
    }

    /// "Needs Device Control", "Needs Device Control and Screen Recording", or nil when available.
    public func reason(_ feature: AppFeature) -> String? {
        let missing = missing(for: feature)
        guard !missing.isEmpty else { return nil }
        return "Needs " + missing.map(\.needsPhrase).joined(separator: " and ")
    }

    public func entry(_ feature: AppFeature) -> Entry {
        Entry(feature: feature, title: feature.title, available: isAvailable(feature), reason: reason(feature))
    }

    public var entries: [Entry] { AppFeature.allCases.map(entry) }

    public var unavailable: [AppFeature] { AppFeature.allCases.filter { !isAvailable($0) } }

    /// Without Accessibility SnugBar runs in reduced mode: basic hide and show only.
    public var isReduced: Bool { !grants.accessibility }

    /// Live item images may be captured and shown; otherwise app icons everywhere.
    public var showsItemPictures: Bool { isAvailable(.itemPictures) }
}

/// Shared wording for the setup window, Settings, the menu, the layout editor and the command line.
public enum PermissionText {
    public static let setupWindowTitle = "Set Up SnugBar"
    public static let welcome = "SnugBar keeps your menu bar tidy: it hides the items you don’t need all the time and shows them when you ask."
    public static let welcomeDetail = "It needs a few permissions to do that. The next steps explain each one."
    public static let reducedMode = "SnugBar runs in reduced mode until \(SystemSettingsNames.accessibilityPane) is allowed: only basic hide and show work."
    /// Screen Recording is allowed in System Settings but this process still can't capture (macOS applies the grant
    /// only after a restart).
    public static let restartForScreenRecording = "If you just allowed it, SnugBar needs to restart to use it."
    public static let restartButton = "Restart SnugBar"
    public static let showSetupAgain = "Show Setup Again…"
    /// The menu's first entry when Accessibility is missing: short, an action, and it starts with the words the
    /// user will see in System Settings. It opens the setup page, which has the pane's full name.
    public static let accessibilityNeededMenuTitle = "Allow Device Control…"
    public static let setUpMenuTitle = "Set Up SnugBar…"
    /// SnugBar's icon's tooltip in reduced mode.
    public static let iconTooltipReduced = "SnugBar needs \(SystemSettingsNames.accessibilityPane) permission. Right-click for the menu."
    /// "Allow SnugBar in System Settings > Privacy & Security > Device Control and Data Access."
    public static func allowInSettings(_ permission: PermissionKind) -> String {
        "Allow SnugBar in \(SystemSettingsNames.path(permission.title))."
    }
    /// Error for `click`/`order` and other reader features without Accessibility.
    public static func needsAccessibility(_ what: String) -> String {
        "\(what) needs \(SystemSettingsNames.accessibilityPane) permission. \(allowInSettings(.accessibility))"
    }
    /// `move` with neither Accessibility (for ⌘-drag) nor the Menu Bar folder.
    public static let moveNeedsPermission = "moving items needs \(SystemSettingsNames.accessibilityPane) (for ⌘-drag) or Menu Bar folder access; allow one in SnugBar's Settings > Permissions"
    /// The command line's `status` line in reduced mode.
    public static let statusReducedMode = "Reduced mode: \(SystemSettingsNames.accessibilityPane) is not granted, so only basic hide and show work."
    public static let doneIntro = "SnugBar is ready. With the current permissions:"
    public static let doneChangeLater = "You can change permissions at any time in Settings > Permissions."

    /// The layout editor's line when the Menu Bar folder isn't chosen.
    public static let layoutEditorNoFolder = "Without Menu Bar folder access, reordering Shown moves the pointer briefly and Hidden and Always Hidden can’t be reordered."
    /// Where the SnugBar Bar and layout editor say pictures need Screen Recording.
    public static let noScreenRecordingPictures = "App icons are shown because SnugBar doesn’t have \(SystemSettingsNames.screenRecordingPane) permission."

    public static let privacyTelemetry = "SnugBar collects no usage data and has no telemetry."
    /// Feature 58: the update check is the only network request.
    public static let privacyNetwork = "The only network request SnugBar makes is the optional update check to GitHub, which you can turn off in Settings > General."
    public static let privacyServer = "The control server for the command line and MCP accepts connections from this Mac only (127.0.0.1)."
    public static let privacySettings = "Settings are kept in one JSON file on this Mac."
}
