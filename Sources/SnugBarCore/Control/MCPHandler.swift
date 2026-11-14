import Foundation

/// MCP over Streamable HTTP, answering with plain JSON (no event streams) and no sessions.
///
/// Supports `initialize`, `ping`, `tools/list` and `tools/call`; notifications (such as `notifications/initialized`)
/// and responses from the client are accepted with 202 and no body. Each control command is a tool named
/// `snugbar_<command>`; its result is the command's JSON as text, with `isError` set when the command failed.
@MainActor
public final class MCPHandler {
    /// Newest first. A client asking for one of these gets it; any other version gets `latestProtocolVersion`.
    public static let supportedProtocolVersions = ["2025-11-25", "2025-06-18", "2025-03-26", "2024-11-05"]
    public static let latestProtocolVersion = "2025-06-18"

    public struct Reply: Equatable, Sendable {
        public var status: Int
        /// Nil for 202 Accepted.
        public var body: Data?
    }

    enum RPCError {
        static let parse = -32700
        static let invalidRequest = -32600
        static let methodNotFound = -32601
        static let invalidParams = -32602
    }

    let router: CommandRouter
    let serverVersion: String

    public init(router: CommandRouter, serverVersion: String) {
        self.router = router
        self.serverVersion = serverVersion
    }

    /// Handles one POST body: a JSON-RPC message, or a batch (array) of them.
    public func handle(body: Data, protocolVersionHeader: String? = nil) async -> Reply {
        if let header = protocolVersionHeader?.trimmingCharacters(in: .whitespaces), !header.isEmpty,
           !Self.supportedProtocolVersions.contains(header) {
            return Reply(status: 400, body: Self.encode(Self.errorMessage(id: .null, code: RPCError.invalidRequest,
                message: "Unsupported MCP-Protocol-Version: \(header); supported: \(Self.supportedProtocolVersions.joined(separator: ", "))")))
        }
        guard let message = try? JSONDecoder().decode(JSONValue.self, from: body) else {
            return Reply(status: 400, body: Self.encode(Self.errorMessage(id: .null, code: RPCError.parse, message: "Parse error")))
        }
        if case let .array(batch) = message {
            guard !batch.isEmpty else {
                return Reply(status: 400, body: Self.encode(Self.errorMessage(id: .null, code: RPCError.invalidRequest, message: "Invalid Request: empty batch")))
            }
            var replies: [JSONValue] = []
            for m in batch { if let r = await process(m) { replies.append(r) } }
            return replies.isEmpty ? Reply(status: 202, body: nil) : Reply(status: 200, body: Self.encode(.array(replies)))
        }
        guard let reply = await process(message) else { return Reply(status: 202, body: nil) }
        return Reply(status: 200, body: Self.encode(reply))
    }

    /// The response to one message, or nil for a notification or a response.
    func process(_ message: JSONValue) async -> JSONValue? {
        guard case let .object(o) = message else {
            return Self.errorMessage(id: .null, code: RPCError.invalidRequest, message: "Invalid Request: not an object")
        }
        let id = o["id"]
        guard let methodValue = o["method"] else {
            // A response to a request of ours (SnugBar sends none): nothing to answer.
            if o["result"] != nil || o["error"] != nil { return nil }
            return Self.errorMessage(id: id ?? .null, code: RPCError.invalidRequest, message: "Invalid Request: no method")
        }
        guard o["jsonrpc"] == .string("2.0") else {
            return Self.errorMessage(id: id ?? .null, code: RPCError.invalidRequest, message: "Invalid Request: jsonrpc must be \"2.0\"")
        }
        guard case let .string(method) = methodValue else {
            return Self.errorMessage(id: id ?? .null, code: RPCError.invalidRequest, message: "Invalid Request: method must be a string")
        }
        // Notifications get no answer, whatever their method.
        guard let id else { return nil }
        switch id {
        case .string, .number: break
        default: return Self.errorMessage(id: .null, code: RPCError.invalidRequest, message: "Invalid Request: id must be a string or a number")
        }
        let params = o["params"]
        if let params, params != .null, params.objectValue == nil {
            return Self.errorMessage(id: id, code: RPCError.invalidParams, message: "Invalid params: params must be an object")
        }

        switch method {
        case "initialize":
            let requested = params?["protocolVersion"]?.stringValue
            let version = requested.flatMap { Self.supportedProtocolVersions.contains($0) ? $0 : nil } ?? Self.latestProtocolVersion
            return Self.result(id: id, [
                "protocolVersion": .string(version),
                "capabilities": ["tools": ["listChanged": false]],
                "serverInfo": ["name": "snugbar", "title": "SnugBar", "version": .string(serverVersion)],
                "instructions": .string(Self.instructions),
            ])
        case "ping":
            return Self.result(id: id, [:])
        case "tools/list":
            return Self.result(id: id, ["tools": .array(ControlCommand.allCases.map(Self.tool))])
        case "tools/call":
            return await callTool(id: id, params: params)
        default:
            return Self.errorMessage(id: id, code: RPCError.methodNotFound, message: "Method not found: \(method)")
        }
    }

    private func callTool(id: JSONValue, params: JSONValue?) async -> JSONValue {
        guard let name = params?["name"]?.stringValue else {
            return Self.errorMessage(id: id, code: RPCError.invalidParams, message: "Invalid params: tools/call needs a tool name")
        }
        guard let command = ControlCommand(toolName: name) else {
            return Self.errorMessage(id: id, code: RPCError.invalidParams, message: "Unknown tool: \(name)")
        }
        let response: ControlResponse
        switch params?["arguments"] {
        case nil, .null?:
            response = await router.handle(ControlRequest(command))
        case let .object(object)?:
            do {
                response = await router.handle(ControlRequest(command, try ControlArguments(json: object)))
            } catch let e as ControlError {
                response = .failure(e)
            } catch {
                response = .failure(ControlError(.invalidArgument, "\(error)"))
            }
        default:
            response = .failure(ControlError(.invalidArgument, "arguments must be an object"))
        }
        return Self.result(id: id, [
            "content": [["type": "text", "text": .string(response.compactJSON())]],
            "isError": .bool(!response.ok),
        ])
    }

    // MARK: - Tools

    static let instructions = """
        SnugBar manages the macOS menu bar. Items belong to apps, and every app is in one section: shown (always in \
        the menu bar), hidden (shown on demand) or alwaysHidden. Use snugbar_list or snugbar_search to find items; \
        other tools take an item as an ID from those results, an app's bundle ID, or a name. Moving one item to \
        another section moves all items of its app; snugbar_move takes several items at once.
        """

    public static func tool(_ command: ControlCommand) -> JSONValue {
        [
            "name": .string(command.toolName),
            "title": .string(title(command)),
            "description": .string(command.summary),
            "inputSchema": inputSchema(command),
            "annotations": [
                "title": .string(title(command)),
                "readOnlyHint": .bool(command.isReadOnly),
                "destructiveHint": false,
                "openWorldHint": false,
            ],
        ]
    }

    static func title(_ command: ControlCommand) -> String {
        switch command {
        case .list: return "List menu bar items"
        case .show: return "Show an app's items"
        case .hide: return "Hide an app's items"
        case .click: return "Open an item's menu"
        case .move: return "Move apps to a section"
        case .order: return "Reorder a shown item"
        case .expand: return "Show hidden items"
        case .collapse: return "Hide hidden items"
        case .toggle: return "Toggle hidden items"
        case .swap: return "Swap shown and hidden"
        case .zen: return "Zen mode"
        case .search: return "Search menu bar items"
        case .status: return "SnugBar status"
        }
    }

    public static func inputSchema(_ command: ControlCommand) -> JSONValue {
        let item: JSONValue = ["type": "string", "description": "An item ID from snugbar_list, an app's bundle ID, or (part of) an app or item name."]
        func section(_ description: String) -> JSONValue {
            ["type": "string", "enum": ["shown", "hidden", "alwaysHidden"], "description": .string(description)]
        }
        var properties: [String: JSONValue] = [:]
        var required: [String] = []
        switch command {
        case .list:
            properties["section"] = section("Only list items in this section.")
        case .show, .hide, .click:
            properties["item"] = item
            required = ["item"]
        case .move:
            properties["item"] = ["type": "string", "description": "One item: an item ID from snugbar_list, an app's bundle ID, or (part of) an app or item name. Give item or items, not both."]
            properties["items"] = [
                "type": "array", "items": ["type": "string"], "minItems": 1,
                "description": "Several items, each like item, to move together. All are resolved first; if any is not found or ambiguous, nothing moves. Give item or items, not both.",
            ]
            properties["section"] = section("The section to move the items' apps to.")
            required = ["section"]
        case .order:
            properties["item"] = item
            properties["before"] = ["type": "string", "description": "Place the item immediately left of this item. Give before or after, not both."]
            properties["after"] = ["type": "string", "description": "Place the item immediately right of this item. Give before or after, not both."]
            required = ["item"]
        case .zen:
            properties["state"] = ["type": "string", "enum": ["on", "off", "toggle"], "description": "Default: toggle."]
        case .search:
            properties["query"] = ["type": "string", "description": "Text to match against app and item names."]
            required = ["query"]
        case .expand, .collapse, .toggle, .swap, .status:
            break
        }
        var schema: [String: JSONValue] = [
            "type": "object",
            "properties": .object(properties),
            "additionalProperties": false,
        ]
        if !required.isEmpty { schema["required"] = .array(required.map { .string($0) }) }
        return .object(schema)
    }

    // MARK: - JSON-RPC

    static func result(id: JSONValue, _ result: [String: JSONValue]) -> JSONValue {
        ["jsonrpc": "2.0", "id": id, "result": .object(result)]
    }

    static func errorMessage(id: JSONValue, code: Int, message: String) -> JSONValue {
        ["jsonrpc": "2.0", "id": id, "error": ["code": .number(Double(code)), "message": .string(message)]]
    }

    static func encode(_ value: JSONValue) -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        var data = (try? encoder.encode(value)) ?? Data("null".utf8)
        data.append(0x0A)
        return data
    }
}
