import Foundation

/// The commands shared by the CLI, the HTTP API, MCP and the URL scheme.
public enum ControlCommand: String, CaseIterable, Codable, Sendable {
    case list
    case show
    case hide
    case click
    case move
    case order
    case expand
    case collapse
    case toggle
    case swap
    case zen
    case search
    case status

    /// Commands that only read. They run from any caller without confirmation.
    public var isReadOnly: Bool {
        switch self {
        case .list, .search, .status: return true
        default: return false
        }
    }

    /// One line describing the command, for help text and MCP tool descriptions.
    public var summary: String {
        switch self {
        case .list: return "List menu bar items with their section and whether they are on screen."
        case .show: return "Show one app's items in the menu bar for a while; they hide again after the auto-hide delay."
        case .hide: return "Hide an app's items again now (only for apps in Hidden or Always Hidden)."
        case .click: return "Open a menu bar item's menu, showing the item first if it is hidden."
        case .move: return "Move one or more apps to a section (shown, hidden or alwaysHidden). All items of an app move together."
        case .order: return "Reorder a shown item: put it just before (left of) or after (right of) another item."
        case .expand: return "Show the Hidden section."
        case .collapse: return "Hide the Hidden and Always Hidden sections."
        case .toggle: return "Show the Hidden section if it is hidden, otherwise hide it."
        case .swap: return "Swap the Shown and Hidden sections, or swap them back."
        case .zen: return "Turn Zen mode on or off: every app's items hidden except Apple's, and no way to reveal them."
        case .search: return "Fuzzy-search menu bar items by app and item name, best match first."
        case .status: return "Show the hiding and arranging methods in use, permissions, version and server settings."
        }
    }

    /// The MCP tool name.
    public var toolName: String { "snugbar_\(rawValue)" }

    public init?(toolName: String) {
        guard toolName.hasPrefix("snugbar_") else { return nil }
        self.init(rawValue: String(toolName.dropFirst("snugbar_".count)))
    }
}

/// Arguments of a command. Every field but `items` is a string so all transports (JSON bodies, MCP arguments, URL
/// query items, CLI words) map onto it the same way; the router validates them.
public struct ControlArguments: Codable, Equatable, Sendable {
    /// An item: ItemID, bundle ID or (part of) a name.
    public var item: String?
    /// For `move`: several items, each like `item`. Give `item` or `items`, not both.
    public var items: [String]?
    /// `shown`, `hidden` or `alwaysHidden`.
    public var section: String?
    /// For `order`: the item to place the moved item left of.
    public var before: String?
    /// For `order`: the item to place the moved item right of.
    public var after: String?
    /// For `search`.
    public var query: String?
    /// For `zen`: `on`, `off` or `toggle`.
    public var state: String?

    public init(item: String? = nil, items: [String]? = nil, section: String? = nil, before: String? = nil,
                after: String? = nil, query: String? = nil, state: String? = nil) {
        self.item = item
        self.items = items
        self.section = section
        self.before = before
        self.after = after
        self.query = query
        self.state = state
    }

    public static let fieldNames = ["item", "items", "section", "before", "after", "query", "state"]

    /// Sets a field by name. Returns false for an unknown name. A string for `items` is a comma-separated list.
    @discardableResult
    public mutating func set(_ name: String, _ value: String?) -> Bool {
        switch name {
        case "item": item = value
        case "items": items = value.map(Self.splitList)
        case "section": section = value
        case "before": before = value
        case "after": after = value
        case "query": query = value
        case "state": state = value
        default: return false
        }
        return true
    }

    /// `a, b,,c` → `["a", "b", "c"]`.
    public static func splitList(_ text: String) -> [String] {
        text.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }
}

public struct ControlRequest: Equatable, Sendable {
    public var command: ControlCommand
    public var arguments: ControlArguments

    public init(_ command: ControlCommand, _ arguments: ControlArguments = ControlArguments()) {
        self.command = command
        self.arguments = arguments
    }
}

/// A stable error code. Unknown codes from a newer SnugBar still decode.
public struct ControlErrorCode: RawRepresentable, Codable, Hashable, Sendable, CustomStringConvertible {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }

    /// No item matches.
    public static let notFound = ControlErrorCode(rawValue: "not_found")
    /// Several items match; `candidates` lists them.
    public static let ambiguous = ControlErrorCode(rawValue: "ambiguous")
    /// An argument is missing or has a wrong value.
    public static let invalidArgument = ControlErrorCode(rawValue: "invalid_argument")
    /// What the command needs isn't available now (a permission, a backend).
    public static let unavailable = ControlErrorCode(rawValue: "unavailable")
    /// Zen mode is on, which locks every reveal.
    public static let locked = ControlErrorCode(rawValue: "locked")
    /// The command was tried and failed.
    public static let failed = ControlErrorCode(rawValue: "failed")
    /// A token is required and was missing or wrong.
    public static let unauthorized = ControlErrorCode(rawValue: "unauthorized")
    /// The request's Host or Origin isn't allowed.
    public static let forbidden = ControlErrorCode(rawValue: "forbidden")
    public static let unknownCommand = ControlErrorCode(rawValue: "unknown_command")
    public static let badRequest = ControlErrorCode(rawValue: "bad_request")
    public static let methodNotAllowed = ControlErrorCode(rawValue: "method_not_allowed")
    public static let payloadTooLarge = ControlErrorCode(rawValue: "payload_too_large")
    public static let timeout = ControlErrorCode(rawValue: "timeout")

    public init(from decoder: Decoder) throws {
        rawValue = try decoder.singleValueContainer().decode(String.self)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(rawValue)
    }

    public var description: String { rawValue }

    /// The HTTP status used for this error on `/v1`.
    public var httpStatus: Int {
        switch self {
        case .notFound, .unknownCommand: return 404
        case .ambiguous, .invalidArgument, .badRequest: return 400
        case .unauthorized: return 401
        case .forbidden: return 403
        case .methodNotAllowed: return 405
        case .timeout: return 408
        case .locked: return 409
        case .payloadTooLarge: return 413
        case .unavailable: return 503
        default: return 500
        }
    }
}

/// One of several items that matched an ambiguous reference.
public struct ControlCandidate: Codable, Equatable, Sendable {
    public var id: String
    public var name: String
    public var app: String
    public var bundleId: String

    public init(id: String, name: String, app: String, bundleId: String) {
        self.id = id
        self.name = name
        self.app = app
        self.bundleId = bundleId
    }

    public init(_ item: MenuBarItem) {
        self.init(id: item.id.rawValue, name: item.displayName, app: item.appName, bundleId: item.ownerBundleID)
    }
}

public struct ControlError: Error, Codable, Equatable, Sendable, CustomStringConvertible {
    public var code: ControlErrorCode
    public var message: String
    public var candidates: [ControlCandidate]?

    public init(_ code: ControlErrorCode, _ message: String, candidates: [ControlCandidate]? = nil) {
        self.code = code
        self.message = message
        self.candidates = candidates
    }

    public var description: String { "\(code): \(message)" }
}

/// One item in `list` and `search` results.
public struct ControlItem: Codable, Equatable, Sendable {
    public var id: String
    public var app: String
    public var bundleId: String
    public var name: String
    public var section: Section
    /// On screen in the menu bar now.
    public var visible: Bool
    /// Squeezed into macOS's own overflow behind its « button.
    public var overflowed: Bool
    /// Left edge in screen points (0 when unknown).
    public var x: Double
    public var width: Double

    public init(id: String, app: String, bundleId: String, name: String, section: Section, visible: Bool,
                overflowed: Bool, x: Double, width: Double) {
        self.id = id
        self.app = app
        self.bundleId = bundleId
        self.name = name
        self.section = section
        self.visible = visible
        self.overflowed = overflowed
        self.x = x
        self.width = width
    }
}

public struct ControlPermissions: Codable, Equatable, Sendable {
    public var accessibility: Bool
    public var screenRecording: Bool
    public var menuBarFolder: Bool

    public init(accessibility: Bool, screenRecording: Bool, menuBarFolder: Bool) {
        self.accessibility = accessibility
        self.screenRecording = screenRecording
        self.menuBarFolder = menuBarFolder
    }
}

/// Every command answers with this object: `ok`, then either `error` or the fields of that command.
public struct ControlResponse: Codable, Equatable, Sendable {
    public var ok: Bool
    public var error: ControlError?

    /// `list`, `search`.
    public var items: [ControlItem]?
    public var query: String?
    /// The item acted on (`show`, `hide`, `click`, `order`).
    public var id: String?
    /// `click`: `event` (synthetic click) or `ax`. `order`: `orderFile` or `drag`.
    public var method: String?
    /// `move`: every item of the moved apps.
    public var moved: [String]?
    public var section: Section?
    /// `expand`, `collapse`, `toggle`, `swap`, `zen`, `status`.
    public var state: RevealLevel?
    public var swapped: Bool?
    public var zen: Bool?
    /// `status`.
    public var version: String?
    public var hider: String?
    public var arranger: String?
    public var permissions: ControlPermissions?
    public var port: Int?
    public var token: Bool?
    /// `status`: true without Accessibility (only basic hide and show work).
    public var reducedMode: Bool?
    /// `status`: features unavailable with the current permissions (`AppFeature` names), empty when none.
    public var unavailable: [String]?

    public init(ok: Bool, error: ControlError? = nil) {
        self.ok = ok
        self.error = error
    }

    public static func failure(_ error: ControlError) -> ControlResponse {
        ControlResponse(ok: false, error: error)
    }

    /// Pretty, sorted JSON with a trailing newline (HTTP bodies and `--json`).
    public func prettyJSON() -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        var data = (try? encoder.encode(self)) ?? Data(#"{"ok":false}"#.utf8)
        data.append(0x0A)
        return data
    }

    /// Compact, sorted JSON (MCP tool results).
    public func compactJSON() -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return (try? encoder.encode(self)).flatMap { String(data: $0, encoding: .utf8) } ?? #"{"ok":false}"#
    }
}

extension Section {
    /// Parses a section name as typed by a person or an agent: `shown`, `hidden`, `alwaysHidden` (also
    /// `always-hidden`, `always_hidden`, `always hidden`, `always`), any case.
    public init?(controlName: String) {
        let key = controlName.lowercased().filter { $0.isLetter }
        switch key {
        case "shown": self = .shown
        case "hidden": self = .hidden
        case "alwayshidden", "always": self = .alwaysHidden
        default: return nil
        }
    }
}
