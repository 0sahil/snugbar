import XCTest
@testable import SnugBarCore

final class CLIParserTests: XCTestCase {
    private func run(_ args: [String]) -> CLIOptions? {
        if case let .success(.run(o)) = CLIParser.parse(args) { return o }
        return nil
    }

    private func usageError(_ args: [String]) -> CLIUsageError? {
        if case let .failure(e) = CLIParser.parse(args) { return e }
        return nil
    }

    func testEveryCommand() {
        XCTAssertEqual(run(["list"])?.request, ControlRequest(.list))
        XCTAssertEqual(run(["list", "--section", "hidden"])?.request, ControlRequest(.list, .init(section: "hidden")))
        XCTAssertEqual(run(["list", "--section=alwaysHidden"])?.request, ControlRequest(.list, .init(section: "alwaysHidden")))
        XCTAssertEqual(run(["list", "hidden"])?.request, ControlRequest(.list, .init(section: "hidden")))
        XCTAssertEqual(run(["show", "chat"])?.request, ControlRequest(.show, .init(item: "chat")))
        XCTAssertEqual(run(["hide", "com.example.chat"])?.request, ControlRequest(.hide, .init(item: "com.example.chat")))
        XCTAssertEqual(run(["click", "Meters:", "CPU"])?.request, ControlRequest(.click, .init(item: "Meters: CPU")))
        XCTAssertEqual(run(["click", "Meters: CPU"])?.request, ControlRequest(.click, .init(item: "Meters: CPU")))
        XCTAssertEqual(run(["move", "chat", "hidden"])?.request, ControlRequest(.move, .init(item: "chat", section: "hidden")))
        XCTAssertEqual(run(["move", "Control Room", "shown"])?.request, ControlRequest(.move, .init(item: "Control Room", section: "shown")))
        XCTAssertEqual(run(["move", "chat", "--section", "shown"])?.request, ControlRequest(.move, .init(item: "chat", section: "shown")))
        XCTAssertEqual(run(["order", "chat", "--before", "module:Clock"])?.request, ControlRequest(.order, .init(item: "chat", before: "module:Clock")))
        XCTAssertEqual(run(["order", "chat", "--after", "Wi-Fi"])?.request, ControlRequest(.order, .init(item: "chat", after: "Wi-Fi")))
        for c in [ControlCommand.expand, .collapse, .toggle, .swap, .status] {
            XCTAssertEqual(run([c.rawValue])?.request, ControlRequest(c))
        }
        XCTAssertEqual(run(["zen"])?.request, ControlRequest(.zen))
        XCTAssertEqual(run(["zen", "ON"])?.request, ControlRequest(.zen, .init(state: "on")))
        XCTAssertEqual(run(["search", "cpu", "load"])?.request, ControlRequest(.search, .init(query: "cpu load")))
    }

    func testGlobalOptionsAnywhere() {
        let o = run(["--json", "list", "--port", "50000", "--section", "shown"])
        XCTAssertEqual(o?.json, true)
        XCTAssertEqual(o?.port, 50000)
        XCTAssertEqual(o?.request, ControlRequest(.list, .init(section: "shown")))
        XCTAssertEqual(run(["status", "--port=50001"])?.port, 50001)
        XCTAssertEqual(run(["status", "--token-file", "/tmp/x"])?.tokenFile, "/tmp/x")
        XCTAssertEqual(run(["status"])?.json, false)
        XCTAssertNil(run(["status"])?.port)
    }

    func testDoubleDashEndsOptions() {
        XCTAssertEqual(run(["search", "--", "--weird"])?.request, ControlRequest(.search, .init(query: "--weird")))
    }

    func testHelp() {
        XCTAssertEqual(try CLIParser.parse(["--help"]).get(), .help(nil))
        XCTAssertEqual(try CLIParser.parse(["-h"]).get(), .help(nil))
        XCTAssertEqual(try CLIParser.parse(["help"]).get(), .help(nil))
        XCTAssertEqual(try CLIParser.parse(["help", "move"]).get(), .help(.move))
        XCTAssertEqual(try CLIParser.parse(["move", "--help"]).get(), .help(.move))
        XCTAssertEqual(try CLIParser.parse(["order", "-h"]).get(), .help(.order))
    }

    func testMoveTakesSeveralItems() {
        // Each word is an item; the last is the section.
        XCTAssertEqual(run(["move", "chat", "weather", "hidden"])?.request,
                       ControlRequest(.move, .init(items: ["chat", "weather"], section: "hidden")))
        XCTAssertEqual(run(["move", "chat", "Meters: CPU", "com.example.tunnel", "alwaysHidden"])?.request,
                       ControlRequest(.move, .init(items: ["chat", "Meters: CPU", "com.example.tunnel"], section: "alwaysHidden")))
        // With --section every word is an item.
        XCTAssertEqual(run(["move", "chat", "weather", "--section", "shown"])?.request,
                       ControlRequest(.move, .init(items: ["chat", "weather"], section: "shown")))
        XCTAssertEqual(run(["move", "--json", "chat", "weather", "always-hidden"])?.request,
                       ControlRequest(.move, .init(items: ["chat", "weather"], section: "always-hidden")))
    }

    func testMoveUsageErrors() {
        XCTAssertEqual(usageError(["move"])?.message, "move needs at least one item and a section")
        XCTAssertEqual(usageError(["move", "chat"])?.command, .move)
        XCTAssertEqual(usageError(["move", "--section", "hidden"])?.message, "move needs at least one item and a section")
        // The last word must be a section.
        XCTAssertEqual(usageError(["move", "chat", "weather"])?.message, "unknown section 'weather'; use shown, hidden or alwaysHidden")
        XCTAssertNotNil(usageError(["move", "chat", "", "hidden"]))
        XCTAssertNotNil(usageError(["move", "chat", "weather", "hidden", "--before", "x"]))
    }

    func testUsageErrors() {
        XCTAssertEqual(usageError([])?.message, "missing command")
        XCTAssertEqual(usageError(["explode"])?.message, "unknown command 'explode'")
        XCTAssertEqual(usageError(["click"])?.command, .click)
        XCTAssertNotNil(usageError(["move", "chat"]))
        XCTAssertNotNil(usageError(["move", "chat", "attic"]))
        XCTAssertNotNil(usageError(["order", "chat"]))
        XCTAssertNotNil(usageError(["order", "chat", "--before", "a", "--after", "b"]))
        XCTAssertNotNil(usageError(["order", "--before", "a"]))
        XCTAssertNotNil(usageError(["zen", "maybe"]))
        XCTAssertNotNil(usageError(["search"]))
        XCTAssertNotNil(usageError(["expand", "now"]))
        XCTAssertNotNil(usageError(["list", "--section", "attic"]))
        XCTAssertNotNil(usageError(["list", "--before", "x"]))
        XCTAssertNotNil(usageError(["list", "--frobnicate"]))
        XCTAssertNotNil(usageError(["list", "--port"]))
        XCTAssertNotNil(usageError(["list", "--port", "0"]))
        XCTAssertNotNil(usageError(["list", "--port", "http"]))
        XCTAssertNotNil(usageError(["help", "explode"]))
    }

    func testHelpTexts() {
        let general = CLIHelp.general
        for c in ControlCommand.allCases { XCTAssertTrue(general.contains("  \(c.rawValue) "), c.rawValue) }
        XCTAssertTrue(general.contains("--json"))
        XCTAssertTrue(general.contains("Exit status"))
        let move = CLIHelp.command(.move)
        XCTAssertTrue(move.hasPrefix("Usage: snugbar move <item>... <section>"))
        XCTAssertTrue(move.contains("Examples:"))
        XCTAssertTrue(move.contains("  snugbar move chat weather hidden\n"))
    }
}

final class CLIFormatterTests: XCTestCase {
    private func item(_ id: String, _ name: String, _ section: Section, visible: Bool = true, overflowed: Bool = false) -> ControlItem {
        ControlItem(id: id, app: name, bundleId: "com.example.x", name: name, section: section, visible: visible,
                    overflowed: overflowed, x: 0, width: 20)
    }

    func testListTable() {
        var r = ControlResponse(ok: true)
        r.items = [
            item("status:com.example.meters::CPU", "Meters: CPU", .shown),
            item("com.example.chat#0", "Chat", .hidden, visible: false),
            item("status:com.example.tunnel::Item-0", "Tunnel", .alwaysHidden, visible: false, overflowed: true),
        ]
        let out = CLIFormatter.format(r, for: ControlRequest(.list))
        XCTAssertEqual(out.stderr, "")
        XCTAssertEqual(out.stdout, """
            NAME         SECTION        VISIBLE   ID
            Meters: CPU  Shown          yes       status:com.example.meters::CPU
            Chat         Hidden         no        com.example.chat#0
            Tunnel       Always Hidden  overflow  status:com.example.tunnel::Item-0

            """)
    }

    func testEmptyLists() {
        var r = ControlResponse(ok: true)
        r.items = []
        XCTAssertEqual(CLIFormatter.format(r, for: ControlRequest(.list)).stdout, "No items.\n")
        XCTAssertEqual(CLIFormatter.format(r, for: ControlRequest(.list, .init(section: "hidden"))).stdout, "No items in Hidden.\n")
        r.query = "zz"
        XCTAssertEqual(CLIFormatter.format(r, for: ControlRequest(.search, .init(query: "zz"))).stdout, "No items match 'zz'.\n")
    }

    func testActions() {
        var r = ControlResponse(ok: true)
        r.id = "com.example.chat#0"
        XCTAssertEqual(CLIFormatter.format(r, for: ControlRequest(.click, .init(item: "chat"))).stdout, "Opened com.example.chat#0.\n")
        XCTAssertEqual(CLIFormatter.format(r, for: ControlRequest(.hide, .init(item: "chat"))).stdout, "Hid com.example.chat#0.\n")
        XCTAssertTrue(CLIFormatter.format(r, for: ControlRequest(.show, .init(item: "chat"))).stdout.hasPrefix("Showing com.example.chat#0;"))
        r.method = "orderFile"
        XCTAssertEqual(CLIFormatter.format(r, for: ControlRequest(.order, .init(item: "chat", before: "Clock"))).stdout,
                       "Placed com.example.chat#0 before 'Clock' (order file).\n")

        var m = ControlResponse(ok: true)
        m.moved = ["status:com.example.meters::CPU", "status:com.example.meters::Memory"]
        m.section = .alwaysHidden
        XCTAssertEqual(CLIFormatter.format(m, for: ControlRequest(.move, .init(item: "meters", section: "alwaysHidden"))).stdout, """
            Moved 2 items to Always Hidden:
              status:com.example.meters::CPU
              status:com.example.meters::Memory

            """)

        var several = ControlResponse(ok: true)
        several.moved = ["status:com.example.chat::Item-0", "status:com.example.weather::Item-0"]
        several.section = .hidden
        let request = ControlRequest(.move, .init(items: ["chat", "weather"], section: "hidden"))
        XCTAssertEqual(CLIFormatter.format(several, for: request).stdout, """
            Moved 2 items to Hidden:
              status:com.example.chat::Item-0
              status:com.example.weather::Item-0

            """)
    }

    func testStateLines() {
        var r = ControlResponse(ok: true)
        r.state = .expanded
        r.swapped = false
        r.zen = false
        XCTAssertEqual(CLIFormatter.format(r, for: ControlRequest(.expand)).stdout, "Hidden items are shown.\n")
        r.state = .collapsed
        r.swapped = true
        XCTAssertEqual(CLIFormatter.format(r, for: ControlRequest(.swap)).stdout, "Hidden items are hidden. Shown and Hidden are swapped.\n")
        r.zen = true
        XCTAssertEqual(CLIFormatter.format(r, for: ControlRequest(.zen, .init(state: "on"))).stdout, "Zen mode is on: every app's items are hidden.\n")
    }

    func testStatus() {
        var r = ControlResponse(ok: true)
        r.version = "0.1.0"
        r.state = .collapsed
        r.zen = false
        r.swapped = false
        r.hider = "assessment"
        r.arranger = "drag"
        r.permissions = ControlPermissions(accessibility: true, screenRecording: false, menuBarFolder: false)
        r.port = 47811
        r.token = true
        XCTAssertEqual(CLIFormatter.format(r, for: ControlRequest(.status)).stdout, """
            Version:           0.1.0
            State:             collapsed
            Hiding:            whole apps (system)
            Arranging:         ⌘-drag
            Accessibility:     granted
            Screen Recording:  not granted
            Menu bar folder:   not granted
            Server:            127.0.0.1:47811
            Token:             required

            """)
    }

    func testErrorsGoToStderrWithCandidates() {
        let e = ControlError(.ambiguous, "'c' matches several items; use one of their IDs", candidates: [
            ControlCandidate(id: "com.example.chat#0", name: "Chat", app: "Chat", bundleId: "com.example.chat"),
            ControlCandidate(id: "status:org.example.clipboard::Item-0", name: "Clipboard", app: "Clipboard", bundleId: "org.example.clipboard"),
        ])
        let out = CLIFormatter.format(.failure(e), for: ControlRequest(.click, .init(item: "c")))
        XCTAssertEqual(out.stdout, "")
        XCTAssertEqual(out.stderr, """
            snugbar: 'c' matches several items; use one of their IDs
              Chat       com.example.chat#0
              Clipboard  status:org.example.clipboard::Item-0

            """)
    }
}

/// The whole command line with a fake transport: exit codes, output, port and token handling.
final class CLIRunnerTests: XCTestCase {
    private var out = ""
    private var err = ""
    private var sent: [URLRequest] = []

    private func run(_ args: [String], env: [String: String] = [:], settings: URL? = nil, token: URL? = nil,
                     answer: CLIRunner.TransportResult) -> Int32 {
        let missing = URL(fileURLWithPath: "/nonexistent/snugbar-test-\(UUID().uuidString)")
        let context = CLIRunner.Context(
            arguments: args, environment: env, settingsURL: settings ?? missing, defaultTokenURL: token ?? missing,
            write: { self.out += $0 }, writeError: { self.err += $0 },
            send: { request in self.sent.append(request); return answer }
        )
        return CLIRunner.run(context)
    }

    private func ok(_ response: ControlResponse) -> CLIRunner.TransportResult {
        .response(status: response.ok ? 200 : 404, body: response.prettyJSON())
    }

    func testSuccessPrintsTextAndExits0() throws {
        var r = ControlResponse(ok: true)
        r.items = []
        XCTAssertEqual(run(["list", "--section", "hidden"], answer: ok(r)), 0)
        XCTAssertEqual(out, "No items in Hidden.\n")
        let request = try XCTUnwrap(sent.first)
        XCTAssertEqual(request.url?.absoluteString, "http://127.0.0.1:47811/v1/list")
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")
        XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
        XCTAssertEqual(String(decoding: request.httpBody ?? Data(), as: UTF8.self), #"{"section":"hidden"}"#)
    }

    func testJSONPrintsRawBody() {
        var r = ControlResponse(ok: true)
        r.zen = true
        XCTAssertEqual(run(["zen", "on", "--json"], answer: ok(r)), 0)
        XCTAssertEqual(out, String(decoding: r.prettyJSON(), as: UTF8.self))
    }

    func testCommandErrorExits1() {
        XCTAssertEqual(run(["click", "nothing"], answer: ok(.failure(ControlError(.notFound, "no menu bar item matches 'nothing'")))), 1)
        XCTAssertEqual(out, "")
        XCTAssertEqual(err, "snugbar: no menu bar item matches 'nothing'\n")
    }

    func testUsageErrorExits2WithoutSending() {
        XCTAssertEqual(run(["move", "chat"], answer: .failed("unused")), 2)
        XCTAssertTrue(sent.isEmpty)
        XCTAssertTrue(err.hasPrefix("snugbar: move needs at least one item and a section\nUsage: snugbar move <item>... <section>\n"))
    }

    func testUnreachableExits3() {
        XCTAssertEqual(run(["status", "--port", "50999"], answer: .unreachable("connection refused")), 3)
        XCTAssertTrue(err.contains("can't reach SnugBar on 127.0.0.1:50999 (connection refused)"))
        XCTAssertEqual(sent.first?.url?.port, 50999)
    }

    func testHelpExits0() {
        XCTAssertEqual(run(["--help"], answer: .failed("unused")), 0)
        XCTAssertEqual(out, CLIHelp.general)
        XCTAssertTrue(sent.isEmpty)
    }

    func testGarbageAnswerExits1() {
        XCTAssertEqual(run(["status"], answer: .response(status: 200, body: Data("<html>".utf8))), 1)
        XCTAssertTrue(err.contains("unexpected answer"))
    }

    func testPortFromEnvironmentAndSettings() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("snugbar-cli-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let settings = dir.appendingPathComponent("settings.json")
        try Data(#"{"schemaVersion":1,"controlServer":{"port":50111}}"#.utf8).write(to: settings)
        _ = run(["status"], settings: settings, answer: ok(ControlResponse(ok: true)))
        XCTAssertEqual(sent.last?.url?.port, 50111)
        _ = run(["status"], env: ["SNUGBAR_PORT": "50222"], settings: settings, answer: ok(ControlResponse(ok: true)))
        XCTAssertEqual(sent.last?.url?.port, 50222)
        _ = run(["status", "--port", "50333"], env: ["SNUGBAR_PORT": "50222"], settings: settings, answer: ok(ControlResponse(ok: true)))
        XCTAssertEqual(sent.last?.url?.port, 50333)
    }

    func testSendsTokenFromFile() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("snugbar-cli-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = TokenStore(url: dir.appendingPathComponent("token"))
        let token = try store.ensure()
        _ = run(["status"], token: store.url, answer: ok(ControlResponse(ok: true)))
        XCTAssertEqual(sent.last?.value(forHTTPHeaderField: "Authorization"), "Bearer \(token)")
        _ = run(["status", "--token-file", store.url.path], answer: ok(ControlResponse(ok: true)))
        XCTAssertEqual(sent.last?.value(forHTTPHeaderField: "Authorization"), "Bearer \(token)")
        _ = run(["status"], env: ["SNUGBAR_TOKEN_FILE": store.url.path], answer: ok(ControlResponse(ok: true)))
        XCTAssertEqual(sent.last?.value(forHTTPHeaderField: "Authorization"), "Bearer \(token)")
    }
}
