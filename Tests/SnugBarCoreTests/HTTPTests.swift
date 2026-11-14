import XCTest
@testable import SnugBarCore

final class HTTPParserTests: XCTestCase {
    private func parse(_ text: String, limits: HTTPLimits = .standard) -> HTTPRequestParser.Result {
        HTTPRequestParser.parse(Data(text.utf8), limits: limits)
    }

    private func request(_ text: String) throws -> (HTTPRequest, Int) {
        guard case let .complete(r, consumed) = parse(text) else {
            XCTFail("expected a complete request, got \(parse(text))")
            throw CancellationError()
        }
        return (r, consumed)
    }

    func testPostWithBody() throws {
        let text = "POST /v1/move HTTP/1.1\r\nHost: 127.0.0.1:47811\r\nContent-Type: application/json\r\nContent-Length: 17\r\n\r\n{\"item\":\"chat\"}\r\n"
        let (r, consumed) = try request(text)
        XCTAssertEqual(r.method, "POST")
        XCTAssertEqual(r.path, "/v1/move")
        XCTAssertEqual(r.version, "HTTP/1.1")
        XCTAssertEqual(r.headers["content-type"], "application/json")
        XCTAssertEqual(r.headers["HOST"], "127.0.0.1:47811")
        XCTAssertEqual(String(decoding: r.body, as: UTF8.self), "{\"item\":\"chat\"}\r\n")
        XCTAssertEqual(consumed, text.utf8.count)
        XCTAssertTrue(r.keepAlive)
    }

    func testGetWithQueryAndNoBody() throws {
        let (r, _) = try request("GET /v1/status?x=1 HTTP/1.1\r\nHost: localhost:47811\r\n\r\n")
        XCTAssertEqual(r.path, "/v1/status")
        XCTAssertEqual(r.target, "/v1/status?x=1")
        XCTAssertTrue(r.body.isEmpty)
    }

    func testPartialRequestsAreIncomplete() {
        XCTAssertEqual(parse(""), .incomplete)
        XCTAssertEqual(parse("POST /v1/list HT"), .incomplete)
        XCTAssertEqual(parse("POST /v1/list HTTP/1.1\r\nHost: 127.0.0.1:1"), .incomplete)
        // Headers complete, body still arriving.
        XCTAssertEqual(parse("POST /v1/list HTTP/1.1\r\nHost: a\r\nContent-Length: 10\r\n\r\n{\"a\":"), .incomplete)
    }

    func testRequestArrivingInPieces() throws {
        let full = Data("POST /mcp HTTP/1.1\r\nHost: 127.0.0.1:9\r\nContent-Length: 2\r\n\r\n{}".utf8)
        for cut in 1..<full.count {
            XCTAssertEqual(HTTPRequestParser.parse(full.prefix(cut)), .incomplete, "cut at \(cut)")
        }
        guard case .complete = HTTPRequestParser.parse(full) else { return XCTFail() }
    }

    func testPipelinedRequestsConsumeOnlyTheFirst() throws {
        let one = "POST /v1/expand HTTP/1.1\r\nHost: a\r\nContent-Length: 0\r\n\r\n"
        let two = "POST /v1/collapse HTTP/1.1\r\nHost: a\r\n\r\n"
        let (r, consumed) = try request(one + two)
        XCTAssertEqual(r.path, "/v1/expand")
        XCTAssertEqual(consumed, one.utf8.count)
        let rest = Data((one + two).utf8).dropFirst(consumed)
        guard case let .complete(second, _) = HTTPRequestParser.parse(Data(rest)) else { return XCTFail() }
        XCTAssertEqual(second.path, "/v1/collapse")
    }

    func testOversizedBodyIsRejectedFromHeaders() {
        let limits = HTTPLimits(maxHeaderBytes: 1024, maxBodyBytes: 100)
        XCTAssertEqual(parse("POST /v1/list HTTP/1.1\r\nHost: a\r\nContent-Length: 101\r\n\r\n", limits: limits), .invalid(.payloadTooLarge))
        XCTAssertEqual(HTTPParseError.payloadTooLarge.status, 413)
    }

    func testOversizedHeaders() {
        let limits = HTTPLimits(maxHeaderBytes: 64, maxBodyBytes: 100)
        let long = "GET /v1/status HTTP/1.1\r\nHost: a\r\nX-Pad: " + String(repeating: "a", count: 100)
        XCTAssertEqual(parse(long, limits: limits), .invalid(.headersTooLarge))
        XCTAssertEqual(parse(long + "\r\n\r\n", limits: limits), .invalid(.headersTooLarge))
        var many = "GET / HTTP/1.1\r\nHost: a\r\n"
        for i in 0..<70 { many += "X-\(i): 1\r\n" }
        XCTAssertEqual(parse(many + "\r\n"), .invalid(.headersTooLarge))
    }

    func testMalformedRequests() {
        func isBad(_ text: String, file: StaticString = #filePath, line: UInt = #line) {
            guard case let .invalid(e) = parse(text) else { return XCTFail("accepted: \(text.debugDescription)", file: file, line: line) }
            XCTAssertEqual(e.status, 400, file: file, line: line)
        }
        isBad("GARBAGE\r\n\r\n")
        isBad("GET /a HTTP/1.1 extra\r\nHost: a\r\n\r\n")
        isBad("GET  /a HTTP/1.1\r\nHost: a\r\n\r\n")
        isBad("GET a HTTP/1.1\r\nHost: a\r\n\r\n")
        isBad("GET /a FTP/1.1\r\nHost: a\r\n\r\n")
        isBad("GET /a HTTP/1.1\r\n\r\n")  // no Host
        isBad("GET /a HTTP/1.1\r\nHost: a\r\nHost: b\r\n\r\n")
        isBad("GET /a HTTP/1.1\r\nHost: a\r\nNoColon\r\n\r\n")
        isBad("GET /a HTTP/1.1\r\nHost: a\r\nBad Name: x\r\n\r\n")
        isBad("GET /a HTTP/1.1\r\nHost: a\r\nX: 1\r\n folded\r\n\r\n")
        isBad("POST /a HTTP/1.1\r\nHost: a\r\nContent-Length: -1\r\n\r\n")
        isBad("POST /a HTTP/1.1\r\nHost: a\r\nContent-Length: 1, 2\r\n\r\n")
        isBad("POST /a HTTP/1.1\r\nHost: a\r\nContent-Length: abc\r\n\r\n")
        isBad("POST /a HTTP/1.1\r\nHost: a\r\nContent-Length: 3\r\nContent-Length: 4\r\n\r\n")
        // A bad request line is caught before the headers end.
        isBad("NOT HTTP AT ALL\r\nmore")
    }

    func testChunkedAndUnknownVersions() {
        XCTAssertEqual(parse("POST /a HTTP/1.1\r\nHost: a\r\nTransfer-Encoding: chunked\r\n\r\n"), .invalid(.notImplemented("Transfer-Encoding")))
        XCTAssertEqual(parse("GET /a HTTP/2.0\r\nHost: a\r\n\r\n"), .invalid(.versionNotSupported))
    }

    func testHTTP10AndConnectionHeader() throws {
        let (old, _) = try request("GET /v1/status HTTP/1.0\r\n\r\n")
        XCTAssertFalse(old.keepAlive)
        let (oldKeep, _) = try request("GET /v1/status HTTP/1.0\r\nConnection: keep-alive\r\n\r\n")
        XCTAssertTrue(oldKeep.keepAlive)
        let (close, _) = try request("GET /v1/status HTTP/1.1\r\nHost: a\r\nConnection: Upgrade, close\r\n\r\n")
        XCTAssertFalse(close.keepAlive)
    }

    func testResponseSerialization() {
        var r = HTTPResponse.json(200, Data("{\"ok\":true}\n".utf8))
        r.headers.add("Allow", "POST")
        let text = String(decoding: r.serialized(keepAlive: true), as: UTF8.self)
        XCTAssertTrue(text.hasPrefix("HTTP/1.1 200 OK\r\n"))
        XCTAssertTrue(text.contains("Content-Type: application/json; charset=utf-8\r\n"))
        XCTAssertTrue(text.contains("Allow: POST\r\n"))
        XCTAssertTrue(text.contains("Content-Length: 12\r\n"))
        XCTAssertTrue(text.contains("Connection: keep-alive\r\n"))
        XCTAssertTrue(text.hasSuffix("\r\n\r\n{\"ok\":true}\n"))
        let closing = String(decoding: HTTPResponse(status: 202).serialized(keepAlive: false), as: UTF8.self)
        XCTAssertTrue(closing.hasPrefix("HTTP/1.1 202 Accepted\r\n"))
        XCTAssertTrue(closing.contains("Content-Length: 0\r\n"))
        XCTAssertTrue(closing.contains("Connection: close\r\n"))
    }
}

@MainActor
final class ControlHTTPHandlerTests: XCTestCase {
    private let port = 47811
    private lazy var engine = InMemoryControlEngine.demo(version: "9.9.9", port: port)
    private var token: String?
    private lazy var handler = ControlHTTPHandler(router: CommandRouter(engine: engine), serverVersion: "9.9.9") { [unowned self] in
        .init(port: self.port, requiredToken: self.token)
    }

    private func req(_ method: String = "POST", _ path: String, host: String? = "127.0.0.1:47811", headers: [(String, String)] = [], body: String = "") -> HTTPRequest {
        var h = HTTPHeaders()
        if let host { h.add("Host", host) }
        for (k, v) in headers { h.add(k, v) }
        return HTTPRequest(method: method, target: path, headers: h, body: Data(body.utf8))
    }

    private func decode(_ r: HTTPResponse) throws -> ControlResponse {
        try JSONDecoder().decode(ControlResponse.self, from: r.body)
    }

    // MARK: - Host and Origin

    func testAllowedHosts() {
        XCTAssertTrue(ControlHTTPHandler.isAllowedHost("127.0.0.1:47811", port: 47811))
        XCTAssertTrue(ControlHTTPHandler.isAllowedHost("LOCALHOST:47811", port: 47811))
        XCTAssertFalse(ControlHTTPHandler.isAllowedHost("127.0.0.1", port: 47811))
        XCTAssertFalse(ControlHTTPHandler.isAllowedHost("127.0.0.1:47812", port: 47811))
        XCTAssertFalse(ControlHTTPHandler.isAllowedHost("evil.example:47811", port: 47811))
        XCTAssertFalse(ControlHTTPHandler.isAllowedHost("localhost.evil.example:47811", port: 47811))
        XCTAssertFalse(ControlHTTPHandler.isAllowedHost(nil, port: 47811))
    }

    func testLoopbackOrigins() {
        for ok in ["http://127.0.0.1:47811", "http://localhost:3000", "https://localhost", "http://[::1]:8080", "http://127.1.2.3"] {
            XCTAssertTrue(ControlHTTPHandler.isLoopbackOrigin(ok), ok)
        }
        for bad in ["null", "https://example.com", "http://localhost.example.com", "http://127.0.0.1.example.com",
                    "http://128.0.0.1", "file://", "chrome-extension://abc", "http://127.0.0.256", ""] {
            XCTAssertFalse(ControlHTTPHandler.isLoopbackOrigin(bad), bad)
        }
    }

    func testBadHostIsRejected() async throws {
        let r = await handler.respond(to: req("POST", "/v1/list", host: "attacker.example:47811"))
        XCTAssertEqual(r.status, 403)
        XCTAssertEqual(try decode(r).error?.code, .forbidden)
        let missing = await handler.respond(to: req("POST", "/v1/list", host: nil))
        XCTAssertEqual(missing.status, 403)
    }

    func testForeignOriginIsRejected() async throws {
        let r = await handler.respond(to: req("POST", "/v1/expand", headers: [("Origin", "https://evil.example")]))
        XCTAssertEqual(r.status, 403)
        XCTAssertEqual(try decode(r).error?.code, .forbidden)
        XCTAssertTrue(engine.actions.isEmpty)
        let ok = await handler.respond(to: req("POST", "/v1/status", headers: [("Origin", "http://localhost:47811")]))
        XCTAssertEqual(ok.status, 200)
    }

    func testOriginIsCheckedOnMCPToo() async {
        let r = await handler.respond(to: req("POST", "/mcp", headers: [("Origin", "https://evil.example")], body: #"{"jsonrpc":"2.0","id":1,"method":"ping"}"#))
        XCTAssertEqual(r.status, 403)
    }

    // MARK: - Token

    func testTokenRequired() async throws {
        token = "s3cret-token-value"
        let missing = await handler.respond(to: req("POST", "/v1/status"))
        XCTAssertEqual(missing.status, 401)
        XCTAssertEqual(missing.headers["WWW-Authenticate"], "Bearer")
        XCTAssertEqual(try decode(missing).error?.code, .unauthorized)
        let wrong = await handler.respond(to: req("POST", "/v1/status", headers: [("Authorization", "Bearer s3cret-token-valuX")]))
        XCTAssertEqual(wrong.status, 401)
        let basic = await handler.respond(to: req("POST", "/v1/status", headers: [("Authorization", "Basic s3cret-token-value")]))
        XCTAssertEqual(basic.status, 401)
        let mcp = await handler.respond(to: req("POST", "/mcp", body: #"{"jsonrpc":"2.0","id":1,"method":"ping"}"#))
        XCTAssertEqual(mcp.status, 401)
        let right = await handler.respond(to: req("POST", "/v1/status", headers: [("Authorization", "bearer  s3cret-token-value ")]))
        XCTAssertEqual(right.status, 200)
        XCTAssertEqual(try decode(right).ok, true)
    }

    func testUnreadableTokenRejectsEverything() async {
        token = ""
        let r = await handler.respond(to: req("POST", "/v1/status", headers: [("Authorization", "Bearer ")]))
        XCTAssertEqual(r.status, 401)
    }

    func testNoTokenNeededWhenOff() async {
        token = nil
        let r = await handler.respond(to: req("POST", "/v1/status", headers: [("Authorization", "Bearer anything")]))
        XCTAssertEqual(r.status, 200)
    }

    func testTokenHelpers() {
        XCTAssertEqual(ControlToken.bearer(fromAuthorization: "Bearer abc"), "abc")
        XCTAssertNil(ControlToken.bearer(fromAuthorization: "Bearer"))
        XCTAssertNil(ControlToken.bearer(fromAuthorization: "Token abc"))
        XCTAssertTrue(ControlToken.constantTimeEquals("abc", "abc"))
        XCTAssertFalse(ControlToken.constantTimeEquals("abc", "abd"))
        XCTAssertFalse(ControlToken.constantTimeEquals("abc", "abcd"))
        XCTAssertFalse(ControlToken.constantTimeEquals("", "a"))
        XCTAssertFalse(ControlToken.authorizes("Bearer ", expected: ""))
        let t = ControlToken.generate()
        XCTAssertEqual(t.count, 43)
        XCTAssertTrue(t.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" })
        XCTAssertNotEqual(t, ControlToken.generate())
    }

    // MARK: - Routing

    func testPostCommand() async throws {
        let r = await handler.respond(to: req("POST", "/v1/move", body: #"{"item":"chat","section":"shown"}"#))
        XCTAssertEqual(r.status, 200)
        XCTAssertEqual(r.headers["Content-Type"], "application/json; charset=utf-8")
        let body = try decode(r)
        XCTAssertEqual(body.moved, ["status:com.example.chat::Item-0"])
    }

    func testEmptyBodyAndTrailingSlash() async throws {
        let r = await handler.respond(to: req("POST", "/v1/list/"))
        XCTAssertEqual(r.status, 200)
        XCTAssertEqual(try decode(r).items?.count, 9)
    }

    func testGetStatusAllowedOtherGetsNot() async throws {
        let status = await handler.respond(to: req("GET", "/v1/status"))
        XCTAssertEqual(status.status, 200)
        XCTAssertEqual(try decode(status).version, "9.9.9")
        let list = await handler.respond(to: req("GET", "/v1/list"))
        XCTAssertEqual(list.status, 405)
        XCTAssertEqual(list.headers["Allow"], "POST")
        let delete = await handler.respond(to: req("DELETE", "/v1/status"))
        XCTAssertEqual(delete.status, 405)
    }

    func testCommandErrorsMapToStatus() async throws {
        let notFound = await handler.respond(to: req("POST", "/v1/click", body: #"{"item":"no-such-thing"}"#))
        XCTAssertEqual(notFound.status, 404)
        XCTAssertEqual(try decode(notFound).error?.code, .notFound)
        let ambiguous = await handler.respond(to: req("POST", "/v1/click", body: #"{"item":"e"}"#))
        XCTAssertEqual(ambiguous.status, 400)
        XCTAssertFalse(try decode(ambiguous).error?.candidates?.isEmpty ?? true)
        engine.arranger = nil
        let unavailable = await handler.respond(to: req("POST", "/v1/order", body: #"{"item":"clipboard","before":"Clock"}"#))
        XCTAssertEqual(unavailable.status, 503)
        _ = await handler.respond(to: req("POST", "/v1/zen", body: #"{"state":"on"}"#))
        let locked = await handler.respond(to: req("POST", "/v1/expand"))
        XCTAssertEqual(locked.status, 409)
    }

    func testBadBodies() async throws {
        for body in ["not json", "[1,2]", "\"text\""] {
            let r = await handler.respond(to: req("POST", "/v1/list", body: body))
            XCTAssertEqual(r.status, 400, body)
            XCTAssertEqual(try decode(r).error?.code, .badRequest)
        }
        let unknownKey = await handler.respond(to: req("POST", "/v1/list", body: #"{"sectoin":"hidden"}"#))
        XCTAssertEqual(try decode(unknownKey).error?.code, .invalidArgument)
        let nested = await handler.respond(to: req("POST", "/v1/click", body: #"{"item":{"id":1}}"#))
        XCTAssertEqual(try decode(nested).error?.code, .invalidArgument)
        // Booleans and null are accepted leniently.
        let zen = await handler.respond(to: req("POST", "/v1/zen", body: #"{"state":true,"item":null}"#))
        XCTAssertEqual(try decode(zen).zen, true)
    }

    func testUnknownCommandAndPath() async throws {
        let r = await handler.respond(to: req("POST", "/v1/explode"))
        XCTAssertEqual(r.status, 404)
        XCTAssertEqual(try decode(r).error?.code, .unknownCommand)
        let other = await handler.respond(to: req("GET", "/"))
        XCTAssertEqual(other.status, 404)
    }

    func testMCPEndpointMethods() async {
        let get = await handler.respond(to: req("GET", "/mcp"))
        XCTAssertEqual(get.status, 405)
        XCTAssertEqual(get.headers["Allow"], "POST")
        let note = await handler.respond(to: req("POST", "/mcp", body: #"{"jsonrpc":"2.0","method":"notifications/initialized"}"#))
        XCTAssertEqual(note.status, 202)
        XCTAssertTrue(note.body.isEmpty)
    }
}
