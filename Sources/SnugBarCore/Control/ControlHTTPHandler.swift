import Foundation

/// Turns HTTP requests into control commands: `POST /v1/<command>` (JSON body of `ControlArguments`), `GET /v1/status`
/// and `/mcp` (MCP Streamable HTTP, JSON responses only).
///
/// Every request is checked first: the `Host` header must name this server on loopback (DNS rebinding), an `Origin`
/// header must be a loopback origin (web pages), and when a token is required, `Authorization: Bearer <token>` must
/// carry it.
@MainActor
public final class ControlHTTPHandler {
    public struct Access: Equatable, Sendable {
        /// The port the server listens on (part of the allowed Host values).
        public var port: Int
        /// The token every request must carry, or nil when none is required. An empty string rejects everything (the
        /// token is required but couldn't be read).
        public var requiredToken: String?

        public init(port: Int, requiredToken: String? = nil) {
            self.port = port
            self.requiredToken = requiredToken
        }
    }

    public let router: CommandRouter
    public let mcp: MCPHandler
    /// Read for every request, so settings changes apply at once.
    public var access: () -> Access

    public init(router: CommandRouter, serverVersion: String, access: @escaping () -> Access) {
        self.router = router
        self.mcp = MCPHandler(router: router, serverVersion: serverVersion)
        self.access = access
    }

    public func respond(to request: HTTPRequest) async -> HTTPResponse {
        if let rejection = Self.check(request, access: access()) { return rejection }
        var path = request.path
        while path.count > 1 && path.hasSuffix("/") { path.removeLast() }

        if path == "/mcp" {
            guard request.method == "POST" else {
                return Self.methodNotAllowed(allow: "POST", "the MCP endpoint takes POST (JSON responses; no event stream)")
            }
            let reply = await mcp.handle(body: request.body, protocolVersionHeader: request.headers["MCP-Protocol-Version"])
            guard let body = reply.body else { return HTTPResponse(status: reply.status) }
            return .json(reply.status, body)
        }

        if path.hasPrefix("/v1/") {
            let name = String(path.dropFirst("/v1/".count))
            guard let command = ControlCommand(rawValue: name) else {
                return Self.error(ControlError(.unknownCommand, "unknown command '\(name)'; commands: \(ControlCommand.allCases.map(\.rawValue).joined(separator: ", "))"))
            }
            let allowed = request.method == "POST" || (request.method == "GET" && command == .status)
            guard allowed else {
                return Self.methodNotAllowed(allow: command == .status ? "GET, POST" : "POST", "use POST /v1/\(name)")
            }
            let arguments: ControlArguments
            do {
                arguments = try ControlArguments(jsonBody: request.method == "GET" ? Data() : request.body)
            } catch let e as ControlError {
                return Self.error(e)
            } catch {
                return Self.error(ControlError(.badRequest, "\(error)"))
            }
            let response = await router.handle(ControlRequest(command, arguments))
            return .json(response.ok ? 200 : (response.error?.code.httpStatus ?? 500), response.prettyJSON())
        }

        return Self.error(ControlError(.notFound, "no such endpoint '\(request.path)'; use POST /v1/<command> or POST /mcp"))
    }

    // MARK: - Checks

    /// The response rejecting a request, or nil when it may proceed.
    public nonisolated static func check(_ request: HTTPRequest, access: Access) -> HTTPResponse? {
        guard isAllowedHost(request.headers["Host"], port: access.port) else {
            return error(ControlError(.forbidden, "Host must be 127.0.0.1:\(access.port) or localhost:\(access.port)"))
        }
        if let origin = request.headers["Origin"], !isLoopbackOrigin(origin) {
            return error(ControlError(.forbidden, "requests from web pages are not allowed (Origin \(origin))"))
        }
        if let token = access.requiredToken {
            guard ControlToken.authorizes(request.headers["Authorization"], expected: token) else {
                var r = error(ControlError(.unauthorized, token.isEmpty
                    ? "a token is required but SnugBar couldn't read its token file; regenerate it in SnugBar's settings"
                    : "a token is required: send Authorization: Bearer <token> (the token is in ~/Library/Application Support/SnugBar/token)"))
                r.headers.add("WWW-Authenticate", "Bearer")
                return r
            }
        }
        return nil
    }

    /// `127.0.0.1:<port>` or `localhost:<port>`, any case.
    public nonisolated static func isAllowedHost(_ host: String?, port: Int) -> Bool {
        guard let host = host?.trimmingCharacters(in: .whitespaces).lowercased() else { return false }
        return host == "127.0.0.1:\(port)" || host == "localhost:\(port)"
    }

    /// `http(s)://localhost`, `127.x.x.x` or `[::1]`, with any port.
    public nonisolated static func isLoopbackOrigin(_ origin: String) -> Bool {
        guard let c = URLComponents(string: origin.trimmingCharacters(in: .whitespaces)),
              let scheme = c.scheme?.lowercased(), scheme == "http" || scheme == "https",
              var host = c.host?.lowercased(), c.path.isEmpty || c.path == "/"
        else { return false }
        if host.hasPrefix("[") && host.hasSuffix("]") { host = String(host.dropFirst().dropLast()) }
        if host == "localhost" || host == "::1" { return true }
        let octets = host.split(separator: ".", omittingEmptySubsequences: false)
        guard octets.count == 4, octets[0] == "127" else { return false }
        return octets.allSatisfy { o in !o.isEmpty && o.count <= 3 && o.allSatisfy(\.isNumber) && (Int(o) ?? 256) <= 255 }
    }

    // MARK: - Responses

    public nonisolated static func error(_ e: ControlError) -> HTTPResponse {
        .json(e.code.httpStatus, ControlResponse.failure(e).prettyJSON())
    }

    nonisolated static func methodNotAllowed(allow: String, _ message: String) -> HTTPResponse {
        var r = error(ControlError(.methodNotAllowed, message))
        r.headers.add("Allow", allow)
        return r
    }
}

extension ControlArguments {
    /// From a `/v1` request body: empty, or a JSON object whose values are strings (numbers and booleans are taken as
    /// their text, null as missing). Unknown keys are rejected so typos don't pass silently.
    public init(jsonBody body: Data) throws {
        if body.allSatisfy({ $0 == 0x20 || $0 == 0x0A || $0 == 0x0D || $0 == 0x09 }) {
            self.init()
            return
        }
        guard let value = try? JSONDecoder().decode(JSONValue.self, from: body), case let .object(object) = value else {
            throw ControlError(.badRequest, "the body must be a JSON object, e.g. {\"item\": \"com.example.app\"}")
        }
        try self.init(json: object)
    }

    /// From a JSON object (a `/v1` body or MCP tool arguments). `items` takes an array of strings.
    public init(json object: [String: JSONValue]) throws {
        self.init()
        for (key, value) in object {
            if key == "items", case let .array(values) = value {
                items = try values.map { v in
                    guard case let .string(s) = v else { throw ControlError(.invalidArgument, "'items' must be an array of strings") }
                    return s
                }
                continue
            }
            let text: String?
            switch value {
            case .null: text = nil
            case let .string(s): text = s
            case let .bool(b): text = b ? "true" : "false"
            case let .number(n): text = n.rounded() == n && abs(n) < 1e15 ? String(Int64(n)) : String(n)
            case .array, .object:
                throw ControlError(.invalidArgument, "'\(key)' must be a string")
            }
            guard set(key, text) else {
                throw ControlError(.invalidArgument, "unknown argument '\(key)'; arguments are \(Self.fieldNames.joined(separator: ", "))")
            }
        }
    }
}
