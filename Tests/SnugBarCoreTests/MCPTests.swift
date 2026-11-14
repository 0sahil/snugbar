import XCTest
@testable import SnugBarCore

@MainActor
final class MCPTests: XCTestCase {
    private lazy var engine = InMemoryControlEngine.demo(version: "1.0.0")
    private lazy var mcp = MCPHandler(router: CommandRouter(engine: engine), serverVersion: "1.0.0")

    private func call(_ json: String, header: String? = nil) async throws -> (status: Int, body: JSONValue?) {
        let reply = await mcp.handle(body: Data(json.utf8), protocolVersionHeader: header)
        let body = try reply.body.map { try JSONDecoder().decode(JSONValue.self, from: $0) }
        return (reply.status, body)
    }

    func testInitializeNegotiatesVersion() async throws {
        let (status, body) = try await call(#"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-03-26","capabilities":{},"clientInfo":{"name":"test","version":"1"}}}"#)
        XCTAssertEqual(status, 200)
        XCTAssertEqual(body?["jsonrpc"], "2.0")
        XCTAssertEqual(body?["id"], 1)
        let result = body?["result"]
        XCTAssertEqual(result?["protocolVersion"], "2025-03-26")
        XCTAssertEqual(result?["serverInfo"]?["name"], "snugbar")
        XCTAssertEqual(result?["serverInfo"]?["version"], "1.0.0")
        XCTAssertEqual(result?["capabilities"]?["tools"]?["listChanged"], false)
        XCTAssertNotNil(result?["instructions"]?.stringValue)
    }

    func testInitializeWithUnknownVersionGetsLatest() async throws {
        let (_, body) = try await call(#"{"jsonrpc":"2.0","id":"a","method":"initialize","params":{"protocolVersion":"1999-01-01"}}"#)
        XCTAssertEqual(body?["id"], "a")
        XCTAssertEqual(body?["result"]?["protocolVersion"], .string(MCPHandler.latestProtocolVersion))
        let (_, missing) = try await call(#"{"jsonrpc":"2.0","id":2,"method":"initialize"}"#)
        XCTAssertEqual(missing?["result"]?["protocolVersion"], .string(MCPHandler.latestProtocolVersion))
    }

    func testNotificationsAndResponsesGet202() async throws {
        var r = try await call(#"{"jsonrpc":"2.0","method":"notifications/initialized"}"#)
        XCTAssertEqual(r.status, 202)
        XCTAssertNil(r.body)
        r = try await call(#"{"jsonrpc":"2.0","method":"notifications/cancelled","params":{"requestId":1}}"#)
        XCTAssertEqual(r.status, 202)
        r = try await call(#"{"jsonrpc":"2.0","id":5,"result":{}}"#)
        XCTAssertEqual(r.status, 202)
        r = try await call(#"[{"jsonrpc":"2.0","method":"notifications/initialized"},{"jsonrpc":"2.0","id":9,"error":{"code":1,"message":"x"}}]"#)
        XCTAssertEqual(r.status, 202)
    }

    func testPing() async throws {
        let (status, body) = try await call(#"{"jsonrpc":"2.0","id":7,"method":"ping"}"#)
        XCTAssertEqual(status, 200)
        XCTAssertEqual(body?["result"], .object([:]))
    }

    func testToolsList() async throws {
        let (_, body) = try await call(#"{"jsonrpc":"2.0","id":2,"method":"tools/list"}"#)
        let tools = body?["result"]?["tools"]?.arrayValue ?? []
        XCTAssertEqual(tools.count, ControlCommand.allCases.count)
        XCTAssertEqual(Set(tools.compactMap { $0["name"]?.stringValue }), Set(ControlCommand.allCases.map { "snugbar_\($0.rawValue)" }))
        for tool in tools {
            XCTAssertEqual(tool["inputSchema"]?["type"], "object", "\(tool)")
            XCTAssertNotNil(tool["description"]?.stringValue)
            XCTAssertNotNil(tool["inputSchema"]?["properties"]?.objectValue)
        }
        let move = tools.first { $0["name"] == "snugbar_move" }
        XCTAssertEqual(move?["inputSchema"]?["required"], ["section"])
        XCTAssertEqual(move?["inputSchema"]?["properties"]?["item"]?["type"], "string")
        XCTAssertEqual(move?["inputSchema"]?["properties"]?["items"]?["type"], "array")
        XCTAssertEqual(move?["inputSchema"]?["properties"]?["items"]?["items"]?["type"], "string")
        XCTAssertEqual(move?["inputSchema"]?["properties"]?["items"]?["minItems"], 1)
        let moveDescription = move?["description"]?.stringValue ?? ""
        XCTAssertTrue(moveDescription.contains("one or more apps"), moveDescription)
        XCTAssertTrue(moveDescription.contains("All items of an app move together"), moveDescription)
        XCTAssertEqual(move?["inputSchema"]?["properties"]?["section"]?["enum"], ["shown", "hidden", "alwaysHidden"])
        XCTAssertEqual(move?["annotations"]?["readOnlyHint"], false)
        let list = tools.first { $0["name"] == "snugbar_list" }
        XCTAssertNil(list?["inputSchema"]?["required"])
        XCTAssertEqual(list?["annotations"]?["readOnlyHint"], true)
        let zen = tools.first { $0["name"] == "snugbar_zen" }
        XCTAssertEqual(zen?["inputSchema"]?["properties"]?["state"]?["enum"], ["on", "off", "toggle"])
    }

    func testToolsCallList() async throws {
        let (_, body) = try await call(#"{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"snugbar_list","arguments":{"section":"hidden"}}}"#)
        let result = body?["result"]
        XCTAssertEqual(result?["isError"], false)
        let content = result?["content"]?.arrayValue?.first
        XCTAssertEqual(content?["type"], "text")
        let text = try XCTUnwrap(content?["text"]?.stringValue)
        let response = try JSONDecoder().decode(ControlResponse.self, from: Data(text.utf8))
        XCTAssertTrue(response.ok)
        XCTAssertEqual(Set(response.items?.map(\.bundleId) ?? []), ["com.example.chat", "com.example.weather"])
    }

    func testToolsCallMove() async throws {
        let (_, body) = try await call(#"{"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"snugbar_move","arguments":{"item":"Meters","section":"alwaysHidden"}}}"#)
        XCTAssertEqual(body?["result"]?["isError"], false)
        let text = body?["result"]?["content"]?.arrayValue?.first?["text"]?.stringValue ?? ""
        let response = try JSONDecoder().decode(ControlResponse.self, from: Data(text.utf8))
        XCTAssertEqual(response.moved?.count, 2)
        XCTAssertEqual(engine.sections.apps["com.example.meters"], .alwaysHidden)
    }

    private func moveResult(_ arguments: String) async throws -> (isError: JSONValue?, response: ControlResponse) {
        let message = #"{"jsonrpc":"2.0","id":11,"method":"tools/call","params":{"name":"snugbar_move","arguments":"# + arguments + "}}"
        let (_, body) = try await call(message)
        let text = body?["result"]?["content"]?.arrayValue?.first?["text"]?.stringValue ?? ""
        return (body?["result"]?["isError"], try JSONDecoder().decode(ControlResponse.self, from: Data(text.utf8)))
    }

    func testToolsCallMoveSeveralItems() async throws {
        let (isError, response) = try await moveResult(#"{"items":["chat","Meters: CPU","com.example.meters"],"section":"alwaysHidden"}"#)
        XCTAssertEqual(isError, false)
        XCTAssertEqual(response.section, .alwaysHidden)
        XCTAssertEqual(response.moved, ["status:com.example.chat::Item-0", "status:com.example.meters::CPU", "status:com.example.meters::Memory"])
        XCTAssertEqual(engine.sections.apps["com.example.chat"], .alwaysHidden)
        XCTAssertEqual(engine.sections.apps["com.example.meters"], .alwaysHidden)
        XCTAssertEqual(engine.actions, ["section com.example.chat,com.example.meters alwaysHidden"])
    }

    func testToolsCallMoveSeveralItemsAbortsOnUnknownItem() async throws {
        let (isError, response) = try await moveResult(#"{"items":["chat","no-such-app"],"section":"shown"}"#)
        XCTAssertEqual(isError, true)
        XCTAssertEqual(response.error?.code, .notFound)
        XCTAssertTrue(response.error?.message.contains("'no-such-app'") ?? false)
        XCTAssertEqual(engine.sections.apps["com.example.chat"], .hidden)
        XCTAssertTrue(engine.actions.isEmpty)
    }

    func testToolsCallMoveRejectsBadItems() async throws {
        let bad = [#"{"item":"chat","items":["weather"],"section":"shown"}"#, #"{"items":[],"section":"shown"}"#,
                   #"{"items":["chat",3],"section":"shown"}"#, #"{"section":"shown"}"#]
        for args in bad {
            let (isError, response) = try await moveResult(args)
            XCTAssertEqual(isError, true, args)
            XCTAssertEqual(response.error?.code, .invalidArgument, args)
        }
        XCTAssertTrue(engine.actions.isEmpty)
    }

    func testToolsCallWithoutArguments() async throws {
        let (_, body) = try await call(#"{"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"snugbar_expand"}}"#)
        XCTAssertEqual(body?["result"]?["isError"], false)
        XCTAssertEqual(engine.barState.reveal, .expanded)
    }

    func testToolErrorsAreResultsWithIsError() async throws {
        let (status, body) = try await call(#"{"jsonrpc":"2.0","id":5,"method":"tools/call","params":{"name":"snugbar_click","arguments":{"item":"nothing-like-it"}}}"#)
        XCTAssertEqual(status, 200)
        XCTAssertEqual(body?["result"]?["isError"], true)
        let text = body?["result"]?["content"]?.arrayValue?.first?["text"]?.stringValue ?? ""
        XCTAssertEqual(try JSONDecoder().decode(ControlResponse.self, from: Data(text.utf8)).error?.code, .notFound)
        // A wrongly typed or unknown argument is a tool error the model can fix, not a protocol error.
        let (_, bad) = try await call(#"{"jsonrpc":"2.0","id":6,"method":"tools/call","params":{"name":"snugbar_click","arguments":{"itme":"chat"}}}"#)
        XCTAssertEqual(bad?["result"]?["isError"], true)
        let (_, notObject) = try await call(#"{"jsonrpc":"2.0","id":6,"method":"tools/call","params":{"name":"snugbar_click","arguments":["chat"]}}"#)
        XCTAssertEqual(notObject?["result"]?["isError"], true)
    }

    func testUnknownToolAndMethod() async throws {
        let (_, tool) = try await call(#"{"jsonrpc":"2.0","id":8,"method":"tools/call","params":{"name":"snugbar_explode"}}"#)
        XCTAssertEqual(tool?["error"]?["code"], -32602)
        let (_, noName) = try await call(#"{"jsonrpc":"2.0","id":8,"method":"tools/call","params":{}}"#)
        XCTAssertEqual(noName?["error"]?["code"], -32602)
        let (status, method) = try await call(#"{"jsonrpc":"2.0","id":9,"method":"resources/list"}"#)
        XCTAssertEqual(status, 200)
        XCTAssertEqual(method?["id"], 9)
        XCTAssertEqual(method?["error"]?["code"], -32601)
    }

    func testMalformedMessages() async throws {
        let (status, parse) = try await call("{not json")
        XCTAssertEqual(status, 400)
        XCTAssertEqual(parse?["error"]?["code"], -32700)
        XCTAssertEqual(parse?["id"], .null)
        let (_, version) = try await call(#"{"jsonrpc":"1.0","id":1,"method":"ping"}"#)
        XCTAssertEqual(version?["error"]?["code"], -32600)
        let (_, noMethod) = try await call(#"{"jsonrpc":"2.0","id":1}"#)
        XCTAssertEqual(noMethod?["error"]?["code"], -32600)
        let (_, badID) = try await call(#"{"jsonrpc":"2.0","id":{"x":1},"method":"ping"}"#)
        XCTAssertEqual(badID?["error"]?["code"], -32600)
        let (_, badParams) = try await call(#"{"jsonrpc":"2.0","id":1,"method":"tools/list","params":[1]}"#)
        XCTAssertEqual(badParams?["error"]?["code"], -32602)
        let (emptyStatus, _) = try await call("[]")
        XCTAssertEqual(emptyStatus, 400)
    }

    func testBatch() async throws {
        let (status, body) = try await call(#"[{"jsonrpc":"2.0","id":1,"method":"ping"},{"jsonrpc":"2.0","method":"notifications/initialized"},{"jsonrpc":"2.0","id":2,"method":"tools/list"}]"#)
        XCTAssertEqual(status, 200)
        XCTAssertEqual(body?.arrayValue?.compactMap { $0["id"] }, [1, 2])
    }

    func testProtocolVersionHeader() async throws {
        let (ok, _) = try await call(#"{"jsonrpc":"2.0","id":1,"method":"ping"}"#, header: "2025-06-18")
        XCTAssertEqual(ok, 200)
        let (bad, body) = try await call(#"{"jsonrpc":"2.0","id":1,"method":"ping"}"#, header: "2030-01-01")
        XCTAssertEqual(bad, 400)
        XCTAssertEqual(body?["error"]?["code"], -32600)
    }

    func testJSONValueRoundTrip() throws {
        let value: JSONValue = ["a": [1, 2.5, "x", true, nil], "b": ["c": false]]
        let data = try JSONEncoder().encode(value)
        XCTAssertEqual(try JSONDecoder().decode(JSONValue.self, from: data), value)
        XCTAssertEqual(String(decoding: try JSONEncoder().encode(JSONValue.number(3)), as: UTF8.self), "3")
    }
}
