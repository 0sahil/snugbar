import XCTest
@testable import SnugBarCore

final class ControlURLTests: XCTestCase {
    private func parse(_ s: String) -> ControlRequest? { try? ControlURL.parse(s).get() }

    private func error(_ s: String) -> ControlErrorCode? {
        if case let .failure(e) = ControlURL.parse(s) { return e.code }
        return nil
    }

    func testCommandsWithArguments() {
        XCTAssertEqual(parse("snugbar://expand"), ControlRequest(.expand))
        XCTAssertEqual(parse("snugbar://list?section=hidden"), ControlRequest(.list, .init(section: "hidden")))
        XCTAssertEqual(parse("snugbar://move?item=com.example.chat&section=alwaysHidden"),
                       ControlRequest(.move, .init(item: "com.example.chat", section: "alwaysHidden")))
        XCTAssertEqual(parse("snugbar://order?item=chat&before=module:Clock"), ControlRequest(.order, .init(item: "chat", before: "module:Clock")))
        XCTAssertEqual(parse("snugbar://order?item=chat&after=Wi-Fi"), ControlRequest(.order, .init(item: "chat", after: "Wi-Fi")))
        XCTAssertEqual(parse("snugbar://zen?state=on"), ControlRequest(.zen, .init(state: "on")))
        XCTAssertEqual(parse("snugbar://search?query=cpu"), ControlRequest(.search, .init(query: "cpu")))
        XCTAssertEqual(parse("snugbar://search?q=cpu"), ControlRequest(.search, .init(query: "cpu")))
    }

    func testSeveralItems() {
        XCTAssertEqual(parse("snugbar://move?item=chat&item=weather&section=hidden"),
                       ControlRequest(.move, .init(items: ["chat", "weather"], section: "hidden")))
        XCTAssertEqual(parse("snugbar://move?items=chat,weather&section=hidden"),
                       ControlRequest(.move, .init(items: ["chat", "weather"], section: "hidden")))
        XCTAssertEqual(parse("snugbar://move?items=chat,%20Meters%3A%20CPU,&section=hidden"),
                       ControlRequest(.move, .init(items: ["chat", "Meters: CPU"], section: "hidden")))
        XCTAssertEqual(parse("snugbar://move?items=chat&items=weather&section=hidden"),
                       ControlRequest(.move, .init(items: ["chat", "weather"], section: "hidden")))
        // One `item` stays `item`; `item` together with `items` is passed on for the router to reject.
        XCTAssertEqual(parse("snugbar://move?item=chat&section=hidden"), ControlRequest(.move, .init(item: "chat", section: "hidden")))
        XCTAssertEqual(parse("snugbar://move?item=chat&items=weather&section=hidden"),
                       ControlRequest(.move, .init(item: "chat", items: ["weather"], section: "hidden")))
    }

    func testSeveralItemsRoundTripAndDescription() {
        let r = ControlRequest(.move, .init(items: ["chat", "Meters: CPU"], section: "alwaysHidden"))
        let link = ControlURL.make(r)
        XCTAssertEqual(link, "snugbar://move?item=chat&item=Meters:%20CPU&section=alwaysHidden")
        XCTAssertEqual(parse(link), r)
        XCTAssertEqual(ControlURL.describe(r), "move “chat”, “Meters: CPU” to Always Hidden")
    }

    func testPercentEncodingAndCase() {
        XCTAssertEqual(parse("snugbar://click?item=Meters%3A%20CPU"), ControlRequest(.click, .init(item: "Meters: CPU")))
        XCTAssertEqual(parse("SNUGBAR://Click?item=status%3Acom.example.meters%3A%3ACPU"),
                       ControlRequest(.click, .init(item: "status:com.example.meters::CPU")))
    }

    func testPathForms() {
        XCTAssertEqual(parse("snugbar:collapse"), ControlRequest(.collapse))
        XCTAssertEqual(parse("snugbar:///toggle"), ControlRequest(.toggle))
        XCTAssertEqual(parse("snugbar://swap/"), ControlRequest(.swap))
    }

    func testEmptyValuesAreMissing() {
        XCTAssertEqual(parse("snugbar://list?section="), ControlRequest(.list))
    }

    func testErrors() {
        XCTAssertEqual(error("snugbar://explode"), .unknownCommand)
        XCTAssertEqual(error("snugbar://"), .unknownCommand)
        XCTAssertEqual(error("https://list"), .badRequest)
        XCTAssertEqual(error("snugbar://move?item=a&to=hidden"), .invalidArgument)
    }

    func testMakeRoundTrips() {
        let r = ControlRequest(.move, .init(item: "Meters: CPU", section: "hidden"))
        let link = ControlURL.make(r)
        XCTAssertTrue(link.hasPrefix("snugbar://move?"))
        XCTAssertEqual(parse(link), r)
    }

    func testDescriptions() {
        XCTAssertEqual(ControlURL.describe(ControlRequest(.move, .init(item: "chat", section: "alwayshidden"))), "move “chat” to Always Hidden")
        XCTAssertEqual(ControlURL.describe(ControlRequest(.zen, .init(state: "on"))), "turn Zen mode on")
        XCTAssertEqual(ControlURL.describe(ControlRequest(.click, .init(item: "chat"))), "open the menu of “chat”")
        XCTAssertEqual(ControlURL.describe(ControlRequest(.expand)), "show hidden items")
    }
}

final class URLCallerPolicyTests: XCTestCase {
    private let own = "app.example.SnugBarTest"

    private func decide(_ c: ControlCommand, _ caller: String?, _ s: URLSchemeSettings = .init()) -> URLCallerPolicy.Decision {
        URLCallerPolicy.decide(command: c, callerBundleID: caller, ownBundleID: own, settings: s)
    }

    func testReadOnlyCommandsAlwaysRun() {
        for c in [ControlCommand.list, .search, .status] {
            XCTAssertEqual(decide(c, nil), .run)
            XCTAssertEqual(decide(c, "com.example.launcher", .init(deniedCallers: ["com.example.launcher"])), .run)
        }
    }

    func testStateChangingAsksOncePerApp() {
        XCTAssertEqual(decide(.expand, "com.example.launcher"), .ask(remember: "com.example.launcher"))
        var s = URLSchemeSettings()
        s.remember("com.example.launcher", allowed: true)
        XCTAssertEqual(decide(.expand, "com.example.launcher", s), .run)
        XCTAssertEqual(decide(.move, "com.example.other", s), .ask(remember: "com.example.other"))
        s.remember("com.example.other", allowed: false)
        XCTAssertEqual(decide(.move, "com.example.other", s), .deny)
        // A later answer replaces the earlier one.
        s.remember("com.example.other", allowed: true)
        XCTAssertEqual(s.deniedCallers, [])
        XCTAssertEqual(s.allowedCallers, ["com.example.launcher", "com.example.other"])
        s.reset()
        XCTAssertEqual(s, URLSchemeSettings())
    }

    func testUnknownSenderAsksEveryTime() {
        XCTAssertEqual(decide(.zen, nil), .ask(remember: nil))
        XCTAssertEqual(decide(.zen, ""), .ask(remember: nil))
    }

    func testOwnLinksRun() {
        XCTAssertEqual(decide(.collapse, own), .run)
    }
}

final class ControlSettingsTests: XCTestCase {
    /// A settings file written before the control surface existed.
    private let olderFile = #"""
    {
      "hider" : "automatic",
      "knownApps" : { "com.example.meters" : "Meters" },
      "moveItemsThatDontFit" : true,
      "recentItems" : [ "status:com.example.meters::CPU" ],
      "revealIn" : "snugBarBar",
      "schemaVersion" : 1,
      "sections" : { "apps" : { "com.example.meters" : "shown" }, "defaultSection" : "hidden" },
      "showIcon" : true
    }
    """#

    func testOlderFileLoadsWithDefaults() throws {
        let s = try SettingsStore.decode(Data(olderFile.utf8))
        XCTAssertEqual(s.controlServer, ControlServerSettings())
        XCTAssertTrue(s.controlServer.enabled)
        XCTAssertEqual(s.controlServer.port, 47811)
        XCTAssertFalse(s.controlServer.requireToken)
        XCTAssertEqual(s.urlScheme.allowedCallers, [])
        XCTAssertEqual(s.urlScheme.deniedCallers, [])
        XCTAssertEqual(s.sections.apps["com.example.meters"], .shown)
        XCTAssertEqual(s.recentItems.first?.rawValue, "status:com.example.meters::CPU")
    }

    func testPartialControlKeysTakeDefaults() throws {
        let json = #"{"schemaVersion":1,"controlServer":{"port":50000},"urlScheme":{"allowedCallers":["com.example.launcher"]}}"#
        let s = try SettingsStore.decode(Data(json.utf8))
        XCTAssertEqual(s.controlServer, ControlServerSettings(enabled: true, port: 50000, requireToken: false))
        XCTAssertEqual(s.urlScheme, URLSchemeSettings(allowedCallers: ["com.example.launcher"], deniedCallers: []))
    }

    func testRoundTrip() throws {
        var s = Settings()
        s.controlServer = ControlServerSettings(enabled: false, port: 50123, requireToken: true)
        s.urlScheme.remember("com.example.launcher", allowed: false)
        let data = try SettingsStore.encode(s)
        XCTAssertEqual(try SettingsStore.decode(data), s)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let server = json?["controlServer"] as? [String: Any]
        XCTAssertEqual(server?["port"] as? Int, 50123)
        XCTAssertEqual(server?["requireToken"] as? Bool, true)
        XCTAssertEqual((json?["urlScheme"] as? [String: Any])?["deniedCallers"] as? [String], ["com.example.launcher"])
    }

    func testEffectivePort() {
        XCTAssertEqual(ControlServerSettings(port: 80).effectivePort, 47811)
        XCTAssertEqual(ControlServerSettings(port: 70000).effectivePort, 47811)
        XCTAssertEqual(ControlServerSettings(port: 50000).effectivePort, 50000)
    }

    func testTokenStoreCreatesPrivateFile() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("snugbar-token-\(UUID().uuidString)/nested")
        defer { try? FileManager.default.removeItem(at: dir.deletingLastPathComponent()) }
        let store = TokenStore(url: dir.appendingPathComponent("token"))
        XCTAssertNil(store.read())
        let token = try store.ensure()
        XCTAssertEqual(token.count, 43)
        XCTAssertEqual(store.read(), token)
        XCTAssertEqual(try store.ensure(), token, "ensure keeps an existing token")
        let attributes = try FileManager.default.attributesOfItem(atPath: store.url.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        let next = try store.regenerate()
        XCTAssertNotEqual(next, token)
        XCTAssertEqual(store.read(), next)
        XCTAssertEqual((try FileManager.default.attributesOfItem(atPath: store.url.path)[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        // No temporary files left behind.
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: dir.path), ["token"])
    }

    func testTokenStoreTightensLooseFile() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("snugbar-token-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("token")
        try Data("handmade-token\n".utf8).write(to: url)
        chmod(url.path, 0o644)
        XCTAssertEqual(try TokenStore(url: url).ensure(), "handmade-token")
        XCTAssertEqual((try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber)?.intValue, 0o600)
    }
}
