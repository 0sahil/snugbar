import Foundation

/// The local control server (CLI, HTTP API and MCP).
public struct ControlServerSettings: Codable, Equatable, Sendable {
    public static let defaultPort = 47811
    /// Ports a user may pick (no privileged ports).
    public static let portRange = 1024...65535

    /// Run the server while SnugBar runs.
    public var enabled: Bool
    /// TCP port on 127.0.0.1.
    public var port: Int
    /// Every request must carry `Authorization: Bearer <token>`, with the token from the token file.
    public var requireToken: Bool

    public init(enabled: Bool = true, port: Int = ControlServerSettings.defaultPort, requireToken: Bool = false) {
        self.enabled = enabled
        self.port = port
        self.requireToken = requireToken
    }

    enum CodingKeys: String, CodingKey { case enabled, port, requireToken }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        port = try c.decodeIfPresent(Int.self, forKey: .port) ?? Self.defaultPort
        requireToken = try c.decodeIfPresent(Bool.self, forKey: .requireToken) ?? false
    }

    /// The configured port when valid, else the default.
    public var effectivePort: Int {
        Self.portRange.contains(port) ? port : Self.defaultPort
    }
}

/// `snugbar://` links from other apps.
public struct URLSchemeSettings: Codable, Equatable, Sendable {
    /// Bundle IDs of apps allowed to run state-changing links without asking.
    public var allowedCallers: [String]
    /// Bundle IDs of apps whose state-changing links are ignored without asking.
    public var deniedCallers: [String]

    public init(allowedCallers: [String] = [], deniedCallers: [String] = []) {
        self.allowedCallers = allowedCallers
        self.deniedCallers = deniedCallers
    }

    enum CodingKeys: String, CodingKey { case allowedCallers, deniedCallers }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        allowedCallers = try c.decodeIfPresent([String].self, forKey: .allowedCallers) ?? []
        deniedCallers = try c.decodeIfPresent([String].self, forKey: .deniedCallers) ?? []
    }

    /// Records the user's answer for an app; it replaces any earlier answer.
    public mutating func remember(_ bundleID: String, allowed: Bool) {
        allowedCallers.removeAll { $0 == bundleID }
        deniedCallers.removeAll { $0 == bundleID }
        if allowed { allowedCallers.append(bundleID) } else { deniedCallers.append(bundleID) }
        allowedCallers.sort()
        deniedCallers.sort()
    }

    public mutating func reset() {
        allowedCallers = []
        deniedCallers = []
    }
}

/// Whether a `snugbar://` link runs.
public enum URLCallerPolicy {
    public enum Decision: Equatable, Sendable {
        case run
        case deny
        /// Ask the user. `remember` is the caller's bundle ID when the answer can be remembered for it; nil when the
        /// caller couldn't be identified (then SnugBar asks every time).
        case ask(remember: String?)
    }

    /// Read-only commands always run. State-changing ones run for allowed apps and for SnugBar itself, are ignored for
    /// denied apps, and otherwise need the user's confirmation.
    public static func decide(command: ControlCommand, callerBundleID: String?, ownBundleID: String,
                              settings: URLSchemeSettings) -> Decision {
        if command.isReadOnly { return .run }
        guard let caller = callerBundleID, !caller.isEmpty else { return .ask(remember: nil) }
        if caller == ownBundleID { return .run }
        if settings.deniedCallers.contains(caller) { return .deny }
        if settings.allowedCallers.contains(caller) { return .run }
        return .ask(remember: caller)
    }
}

/// `snugbar://<command>?item=…&section=…&before=…&after=…&query=…&state=…`
public enum ControlURL {
    public static let scheme = "snugbar"

    public static func parse(_ string: String) -> Result<ControlRequest, ControlError> {
        guard let components = URLComponents(string: string) else {
            return .failure(ControlError(.badRequest, "not a valid URL"))
        }
        return parse(components)
    }

    public static func parse(_ components: URLComponents) -> Result<ControlRequest, ControlError> {
        guard components.scheme?.lowercased() == scheme else {
            return .failure(ControlError(.badRequest, "not a snugbar:// URL"))
        }
        // `snugbar://list` puts the command in the host; `snugbar:list` and `snugbar:///list` in the path.
        let name: String
        if let host = components.host, !host.isEmpty {
            name = host
        } else {
            name = components.path.split(separator: "/").first.map(String.init) ?? ""
        }
        guard !name.isEmpty else { return .failure(ControlError(.unknownCommand, "the URL names no command")) }
        guard let command = ControlCommand(rawValue: name.lowercased()) else {
            return .failure(ControlError(.unknownCommand, "unknown command '\(name)'"))
        }
        var arguments = ControlArguments()
        // `item` may repeat (`?item=a&item=b`); `items` is comma-separated and may repeat too.
        var itemValues: [String] = []
        var listValues: [String]?
        for item in components.queryItems ?? [] {
            let key = item.name == "q" ? "query" : item.name
            let value = item.value.flatMap { $0.isEmpty ? nil : $0 }
            guard ControlArguments.fieldNames.contains(key) else {
                return .failure(ControlError(.invalidArgument, "unknown parameter '\(item.name)'; use \(ControlArguments.fieldNames.joined(separator: ", "))"))
            }
            switch key {
            case "item": if let value { itemValues.append(value) }
            case "items": listValues = (listValues ?? []) + (value.map(ControlArguments.splitList) ?? [])
            default: arguments.set(key, value)
            }
        }
        if itemValues.count > 1, listValues == nil {
            arguments.items = itemValues
        } else {
            arguments.item = itemValues.first
            arguments.items = listValues
        }
        return .success(ControlRequest(command, arguments))
    }

    /// What a link asks for, in words, for the confirmation dialog ("move “chat” to Hidden").
    public static func describe(_ request: ControlRequest) -> String {
        let a = request.arguments
        let quotedItems = a.items.flatMap { $0.isEmpty ? nil : $0.map { "“\($0)”" }.joined(separator: ", ") }
        let item = a.item.map { "“\($0)”" } ?? quotedItems ?? "an item"
        switch request.command {
        case .list: return "list menu bar items"
        case .search: return "search menu bar items"
        case .status: return "report its status"
        case .show: return "show \(item)"
        case .hide: return "hide \(item)"
        case .click: return "open the menu of \(item)"
        case .move:
            let section = a.section.flatMap(Section.init(controlName:)).map(CLIFormatter.title) ?? a.section ?? "another section"
            return "move \(item) to \(section)"
        case .order:
            if let b = a.before { return "move \(item) before “\(b)”" }
            if let b = a.after { return "move \(item) after “\(b)”" }
            return "reorder \(item)"
        case .expand: return "show hidden items"
        case .collapse: return "hide hidden items"
        case .toggle: return "show or hide hidden items"
        case .swap: return "swap shown and hidden items"
        case .zen:
            switch a.state?.lowercased() {
            case "on"?: return "turn Zen mode on"
            case "off"?: return "turn Zen mode off"
            default: return "turn Zen mode on or off"
            }
        }
    }

    /// Builds a link (for documentation and tests).
    public static func make(_ request: ControlRequest) -> String {
        var c = URLComponents()
        c.scheme = scheme
        c.host = request.command.rawValue
        let a = request.arguments
        let pairs: [(String, String?)] = [("item", a.item)] + (a.items ?? []).map { ("item", $0) }
            + [("section", a.section), ("before", a.before), ("after", a.after), ("query", a.query), ("state", a.state)]
        let items = pairs.compactMap { name, value in value.map { URLQueryItem(name: name, value: $0) } }
        c.queryItems = items.isEmpty ? nil : items
        return c.string ?? "\(scheme)://\(request.command.rawValue)"
    }
}
