import XCTest
@testable import SnugBarCore

/// Every control command through `CommandRouter`, against the in-memory engine and its made-up items:
/// Meters (two items) and Clipboard in Shown, Chat and Weather in Hidden, Tunnel in Always Hidden, and Apple's
/// Wi-Fi, Battery and Clock.
@MainActor
final class CommandRouterTests: XCTestCase {
    // XCTest makes a new instance for every test, so each test starts from the demo state.
    private lazy var engine = InMemoryControlEngine.demo(version: "1.2.3", port: 47811)
    private lazy var router = CommandRouter(engine: engine)

    private func run(_ command: ControlCommand, _ args: ControlArguments = ControlArguments()) async -> ControlResponse {
        await router.handle(ControlRequest(command, args))
    }

    private func assertError(_ r: ControlResponse, _ code: ControlErrorCode, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertFalse(r.ok, file: file, line: line)
        XCTAssertEqual(r.error?.code, code, "\(r.error?.message ?? "no error")", file: file, line: line)
    }

    // MARK: - list

    func testListReturnsEveryItemWithSectionAndVisibility() async {
        let r = await run(.list)
        XCTAssertTrue(r.ok)
        let items = r.items ?? []
        XCTAssertEqual(items.count, 9)
        let chat = items.first { $0.bundleId == "com.example.chat" }
        XCTAssertEqual(chat?.section, .hidden)
        XCTAssertEqual(chat?.visible, false)
        let cpu = items.first { $0.id == "status:com.example.meters::CPU" }
        XCTAssertEqual(cpu?.section, .shown)
        XCTAssertEqual(cpu?.visible, true)
        XCTAssertEqual(cpu?.name, "Meters: CPU")
        XCTAssertEqual(cpu?.app, "Meters")
        XCTAssertEqual(cpu?.width, 28)
        XCTAssertEqual(items.first { $0.id == "module:Clock" }?.section, .shown)
        // Left to right.
        XCTAssertEqual(items.map(\.x), items.map(\.x).sorted())
    }

    func testListFiltersBySection() async {
        let hidden = await run(.list, .init(section: "hidden"))
        XCTAssertEqual(Set(hidden.items?.map(\.bundleId) ?? []), ["com.example.chat", "com.example.weather"])
        let always = await run(.list, .init(section: "always-hidden"))
        XCTAssertEqual(always.items?.map(\.id), ["com.example.tunnel#0"])
    }

    func testListRejectsUnknownSection() async {
        assertError(await run(.list, .init(section: "sideways")), .invalidArgument)
    }

    func testListShowsExpandedItemsAsVisible() async {
        _ = await run(.expand)
        let items = await run(.list).items ?? []
        XCTAssertEqual(items.first { $0.bundleId == "com.example.chat" }?.visible, true)
        XCTAssertEqual(items.first { $0.bundleId == "com.example.tunnel" }?.visible, false)
    }

    // MARK: - search

    func testSearchRanksMatches() async {
        let r = await run(.search, .init(query: "mem"))
        XCTAssertTrue(r.ok)
        XCTAssertEqual(r.query, "mem")
        XCTAssertEqual(r.items?.first?.id, "status:com.example.meters::Memory")
    }

    func testSearchNeedsQuery() async {
        assertError(await run(.search), .invalidArgument)
        assertError(await run(.search, .init(query: "   ")), .invalidArgument)
    }

    func testSearchWithNoMatchIsEmptyNotError() async {
        let r = await run(.search, .init(query: "zzzz"))
        XCTAssertTrue(r.ok)
        XCTAssertEqual(r.items, [])
    }

    // MARK: - status

    func testStatus() async {
        engine.arranger = .drag
        let r = await run(.status)
        XCTAssertTrue(r.ok)
        XCTAssertEqual(r.version, "1.2.3")
        XCTAssertEqual(r.hider, "assessment")
        XCTAssertEqual(r.arranger, "drag")
        XCTAssertEqual(r.permissions, ControlPermissions(accessibility: true, screenRecording: false, menuBarFolder: true))
        XCTAssertEqual(r.port, 47811)
        XCTAssertEqual(r.token, false)
        XCTAssertEqual(r.state, .collapsed)
        XCTAssertEqual(r.zen, false)
        engine.arranger = nil
        let none = await run(.status)
        XCTAssertEqual(none.arranger, "none")
    }

    // MARK: - show / hide

    func testShowRevealsHiddenApp() async {
        let r = await run(.show, .init(item: "chat"))
        XCTAssertTrue(r.ok)
        XCTAssertEqual(r.id, "status:com.example.chat::Item-0")
        XCTAssertEqual(engine.revealedApps, ["com.example.chat"])
        let items = await run(.list).items ?? []
        XCTAssertEqual(items.first { $0.bundleId == "com.example.chat" }?.visible, true)
    }

    func testShowOfVisibleShownItemDoesNothing() async {
        let r = await run(.show, .init(item: "clipboard"))
        XCTAssertTrue(r.ok)
        XCTAssertTrue(engine.actions.isEmpty)
    }

    func testShowErrors() async {
        assertError(await run(.show), .invalidArgument)
        assertError(await run(.show, .init(item: "nothing-like-this")), .notFound)
        assertError(await run(.show, .init(item: "module:WiFi")), .invalidArgument)
        engine.canRevealSingleApp = false
        assertError(await run(.show, .init(item: "chat")), .unavailable)
        engine.canRevealSingleApp = true
        _ = await run(.zen, .init(state: "on"))
        assertError(await run(.show, .init(item: "chat")), .locked)
    }

    func testHideEndsReveal() async {
        _ = await run(.show, .init(item: "weather"))
        let r = await run(.hide, .init(item: "com.example.weather"))
        XCTAssertTrue(r.ok)
        XCTAssertEqual(r.id, "status:com.example.weather::Item-0")
        XCTAssertTrue(engine.revealedApps.isEmpty)
    }

    func testHideRefusesShownAndAppleItems() async {
        let shown = await run(.hide, .init(item: "clipboard"))
        assertError(shown, .invalidArgument)
        XCTAssertTrue(shown.error?.message.contains("Shown") ?? false)
        assertError(await run(.hide, .init(item: "Battery")), .invalidArgument)
        assertError(await run(.hide, .init(item: "nope-nope")), .notFound)
    }

    func testHideFollowsSwap() async {
        _ = await run(.swap)
        // Swapped: Hidden apps are in the collapsed menu bar, Shown ones are hidden.
        assertError(await run(.hide, .init(item: "chat")), .invalidArgument)
        let r = await run(.hide, .init(item: "clipboard"))
        XCTAssertTrue(r.ok)
    }

    // MARK: - click

    func testClick() async {
        let r = await run(.click, .init(item: "Meters: CPU"))
        XCTAssertTrue(r.ok)
        XCTAssertEqual(r.id, "status:com.example.meters::CPU")
        XCTAssertEqual(r.method, "event")
        XCTAssertEqual(engine.actions, ["click status:com.example.meters::CPU"])
    }

    func testClickAppleItem() async {
        let r = await run(.click, .init(item: "com.apple.menuextra.clock"))
        XCTAssertTrue(r.ok)
        XCTAssertEqual(r.id, "module:Clock")
    }

    func testClickErrors() async {
        assertError(await run(.click), .invalidArgument)
        assertError(await run(.click, .init(item: "nonexistent")), .notFound)
        engine.clickError = ControlError(.failed, "did not appear")
        assertError(await run(.click, .init(item: "chat")), .failed)
        struct Other: Error {}
        engine.clickError = Other()
        assertError(await run(.click, .init(item: "chat")), .failed)
        engine.clickError = nil
        _ = await run(.zen, .init(state: "on"))
        assertError(await run(.click, .init(item: "chat")), .locked)
    }

    // MARK: - move

    func testMoveMovesWholeApp() async {
        let r = await run(.move, .init(item: "Meters: CPU", section: "hidden"))
        XCTAssertTrue(r.ok)
        XCTAssertEqual(r.section, .hidden)
        XCTAssertEqual(r.moved, ["status:com.example.meters::CPU", "status:com.example.meters::Memory"])
        XCTAssertEqual(engine.sections.apps["com.example.meters"], .hidden)
    }

    func testMoveToAlwaysHiddenByBundleID() async {
        let r = await run(.move, .init(item: "com.example.chat", section: "alwaysHidden"))
        XCTAssertTrue(r.ok)
        XCTAssertEqual(r.moved, ["status:com.example.chat::Item-0"])
        XCTAssertEqual(engine.sections.apps["com.example.chat"], .alwaysHidden)
    }

    func testMoveErrors() async {
        assertError(await run(.move, .init(item: "chat")), .invalidArgument)
        assertError(await run(.move, .init(item: "chat", section: "attic")), .invalidArgument)
        assertError(await run(.move, .init(section: "hidden")), .invalidArgument)
        assertError(await run(.move, .init(item: "Clock", section: "hidden")), .invalidArgument)
        assertError(await run(.move, .init(item: "missing-app", section: "hidden")), .notFound)
        XCTAssertTrue(engine.actions.isEmpty)
    }

    func testMoveAmbiguousListsCandidates() async {
        // "e" is in several apps' names: Weather, Meters, Tunnel, Chat (via bundle ID), …
        let r = await run(.move, .init(item: "e", section: "hidden"))
        assertError(r, .ambiguous)
        let candidates = r.error?.candidates ?? []
        XCTAssertGreaterThan(candidates.count, 1)
        XCTAssertTrue(candidates.contains { $0.id == "status:com.example.weather::Item-0" && $0.app == "Weather" })
        XCTAssertTrue(engine.actions.isEmpty)
    }

    // MARK: - move several

    func testMoveSeveralItems() async {
        let r = await run(.move, .init(items: ["chat", "com.example.tunnel", "Meters: Memory"], section: "shown"))
        XCTAssertTrue(r.ok, "\(r.error?.message ?? "")")
        XCTAssertEqual(r.section, .shown)
        XCTAssertEqual(r.moved, ["status:com.example.chat::Item-0", "com.example.tunnel#0",
                                 "status:com.example.meters::CPU", "status:com.example.meters::Memory"])
        XCTAssertEqual(engine.sections.apps["com.example.chat"], .shown)
        XCTAssertEqual(engine.sections.apps["com.example.tunnel"], .shown)
        XCTAssertEqual(engine.sections.apps["com.example.weather"], .hidden)
        // One settings change for all the apps.
        XCTAssertEqual(engine.actions, ["section com.example.chat,com.example.tunnel,com.example.meters shown"])
    }

    func testMoveSeveralItemsDedupesByApp() async {
        let r = await run(.move, .init(items: ["Meters: CPU", "Meters: Memory", "com.example.meters", "weather"], section: "alwaysHidden"))
        XCTAssertTrue(r.ok, "\(r.error?.message ?? "")")
        XCTAssertEqual(r.moved, ["status:com.example.meters::CPU", "status:com.example.meters::Memory",
                                 "status:com.example.weather::Item-0"])
        XCTAssertEqual(engine.actions, ["section com.example.meters,com.example.weather alwaysHidden"])
    }

    func testMoveOneItemInItems() async {
        let r = await run(.move, .init(items: ["chat"], section: "shown"))
        XCTAssertTrue(r.ok)
        XCTAssertEqual(r.moved, ["status:com.example.chat::Item-0"])
    }

    func testMoveSeveralItemsNotFoundMovesNothing() async {
        let r = await run(.move, .init(items: ["chat", "no-such-app", "weather"], section: "shown"))
        assertError(r, .notFound)
        let message = r.error?.message ?? ""
        XCTAssertTrue(message.contains("'no-such-app'"), message)
        XCTAssertTrue(message.contains("nothing was moved"), message)
        XCTAssertTrue(engine.actions.isEmpty)
        XCTAssertEqual(engine.sections.apps["com.example.chat"], .hidden)
        XCTAssertEqual(engine.sections.apps["com.example.weather"], .hidden)
    }

    func testMoveSeveralItemsAmbiguousMovesNothing() async {
        let r = await run(.move, .init(items: ["chat", "e"], section: "shown"))
        assertError(r, .ambiguous)
        XCTAssertTrue(r.error?.message.contains("'e'") ?? false, r.error?.message ?? "")
        let candidates = r.error?.candidates ?? []
        XCTAssertGreaterThan(candidates.count, 1)
        XCTAssertTrue(candidates.contains { $0.id == "status:com.example.weather::Item-0" })
        XCTAssertTrue(engine.actions.isEmpty)
        XCTAssertEqual(engine.sections.apps["com.example.chat"], .hidden)
    }

    func testMoveSeveralItemsWithAppleItemMovesNothing() async {
        assertError(await run(.move, .init(items: ["chat", "Clock"], section: "hidden")), .invalidArgument)
        XCTAssertTrue(engine.actions.isEmpty)
    }

    func testMoveNeedsExactlyOneOfItemAndItems() async {
        assertError(await run(.move, .init(item: "chat", items: ["weather"], section: "shown")), .invalidArgument)
        assertError(await run(.move, .init(section: "shown")), .invalidArgument)
        assertError(await run(.move, .init(items: [], section: "shown")), .invalidArgument)
        assertError(await run(.move, .init(items: ["chat", " "], section: "shown")), .invalidArgument)
        assertError(await run(.move, .init(items: ["chat", "weather"])), .invalidArgument)
        XCTAssertTrue(engine.actions.isEmpty)
    }

    // MARK: - order

    func testOrderBefore() async {
        let r = await run(.order, .init(item: "clipboard", before: "Meters: CPU"))
        XCTAssertTrue(r.ok, "\(r.error?.message ?? "")")
        XCTAssertEqual(r.id, "status:org.example.clipboard::Item-0")
        XCTAssertEqual(r.method, "orderFile")
        let ids = engine.items.map(\.id.rawValue)
        XCTAssertEqual(ids.firstIndex(of: "status:org.example.clipboard::Item-0")! + 1, ids.firstIndex(of: "status:com.example.meters::CPU"))
    }

    func testOrderAfterAppleItem() async {
        let r = await run(.order, .init(item: "Meters: Memory", after: "module:Battery"))
        XCTAssertTrue(r.ok)
        let ids = engine.items.map(\.id.rawValue)
        XCTAssertEqual(ids.firstIndex(of: "module:Battery")! + 1, ids.firstIndex(of: "status:com.example.meters::Memory"))
    }

    func testOrderErrors() async {
        assertError(await run(.order, .init(item: "clipboard")), .invalidArgument)
        assertError(await run(.order, .init(item: "clipboard", before: "Clock", after: "Battery")), .invalidArgument)
        assertError(await run(.order, .init(item: "clipboard", before: "clipboard")), .invalidArgument)
        assertError(await run(.order, .init(item: "chat", before: "clipboard")), .invalidArgument)  // chat is Hidden
        assertError(await run(.order, .init(item: "clipboard", before: "tunnel")), .invalidArgument)  // Always Hidden
        assertError(await run(.order, .init(item: "clipboard", after: "unknown-anchor")), .notFound)
        engine.arranger = nil
        assertError(await run(.order, .init(item: "clipboard", before: "Clock")), .unavailable)
        engine.arranger = .drag
        engine.orderError = ControlError(.failed, "item is in the system overflow")
        assertError(await run(.order, .init(item: "clipboard", before: "Clock")), .failed)
        XCTAssertTrue(engine.actions.isEmpty)
    }

    func testOrderReportsDrag() async {
        engine.arranger = .drag
        let r = await run(.order, .init(item: "clipboard", after: "Clock"))
        XCTAssertEqual(r.method, "drag")
    }

    // MARK: - expand / collapse / toggle / swap

    func testExpandCollapseToggle() async {
        var r = await run(.expand)
        XCTAssertTrue(r.ok)
        XCTAssertEqual(r.state, .expanded)
        XCTAssertEqual(r.swapped, false)
        r = await run(.collapse)
        XCTAssertEqual(r.state, .collapsed)
        r = await run(.toggle)
        XCTAssertEqual(r.state, .expanded)
        r = await run(.toggle)
        XCTAssertEqual(r.state, .collapsed)
    }

    func testExpandKeepsAll() async {
        engine.barState.reveal = .all
        let r = await run(.expand)
        XCTAssertEqual(r.state, .all)
    }

    func testRevealsAreLockedInZen() async {
        _ = await run(.zen, .init(state: "on"))
        assertError(await run(.expand), .locked)
        assertError(await run(.toggle), .locked)
        assertError(await run(.swap), .locked)
        // Collapsing is always allowed.
        let r = await run(.collapse)
        XCTAssertTrue(r.ok)
        XCTAssertEqual(r.zen, true)
    }

    func testSwap() async {
        var r = await run(.swap)
        XCTAssertTrue(r.ok)
        XCTAssertEqual(r.swapped, true)
        XCTAssertEqual(r.state, .collapsed)
        r = await run(.swap)
        XCTAssertEqual(r.swapped, false)
    }

    func testSwapUnavailable() async {
        engine.supportsSwap = false
        assertError(await run(.swap), .unavailable)
    }

    // MARK: - zen

    func testZenOnOffToggle() async {
        var r = await run(.zen, .init(state: "on"))
        XCTAssertTrue(r.ok)
        XCTAssertEqual(r.zen, true)
        r = await run(.zen, .init(state: "OFF"))
        XCTAssertEqual(r.zen, false)
        r = await run(.zen)
        XCTAssertEqual(r.zen, true)
        r = await run(.zen, .init(state: "toggle"))
        XCTAssertEqual(r.zen, false)
    }

    func testZenInvalidState() async {
        assertError(await run(.zen, .init(state: "maybe")), .invalidArgument)
    }

    func testZenHidesEverythingButApple() async {
        _ = await run(.zen, .init(state: "on"))
        let visible = (await run(.list).items ?? []).filter(\.visible).map(\.id)
        XCTAssertEqual(visible, ["module:WiFi", "module:Battery", "module:Clock"])
    }

    // MARK: - JSON shape

    func testResponseJSONShape() async throws {
        let r = await run(.move, .init(item: "chat", section: "shown"))
        let json = try JSONSerialization.jsonObject(with: r.prettyJSON()) as? [String: Any]
        XCTAssertEqual(json?["ok"] as? Bool, true)
        XCTAssertEqual(json?["moved"] as? [String], ["status:com.example.chat::Item-0"])
        XCTAssertNil(json?["error"])
        XCTAssertNil(json?["items"])

        let e = await run(.click, .init(item: "nonexistent"))
        let ej = try JSONSerialization.jsonObject(with: e.prettyJSON()) as? [String: Any]
        XCTAssertEqual(ej?["ok"] as? Bool, false)
        let error = ej?["error"] as? [String: Any]
        XCTAssertEqual(error?["code"] as? String, "not_found")
        XCTAssertNotNil(error?["message"] as? String)

        let list = try JSONSerialization.jsonObject(with: (await run(.list)).prettyJSON()) as? [String: Any]
        let first = (list?["items"] as? [[String: Any]])?.first
        XCTAssertEqual(Set(first?.keys.map { $0 } ?? []), ["id", "app", "bundleId", "name", "section", "visible", "overflowed", "x", "width"])
    }

    func testResponseRoundTrips() async throws {
        let r = await run(.status)
        let decoded = try JSONDecoder().decode(ControlResponse.self, from: r.prettyJSON())
        XCTAssertEqual(decoded, r)
    }
}

/// Item references: ItemID, bundle ID, Accessibility identifier, exact name, substring and fuzzy name.
final class ItemResolutionTests: XCTestCase {
    let items = [
        Fixtures.item("status:com.example.chat::Item-0", bundle: Fixtures.chat, app: "Chat"),
        Fixtures.item("status:com.example.meters::CPU_mini", bundle: Fixtures.meters, app: "Meters", name: "Meters: CPU"),
        Fixtures.item("status:com.example.meters::RAM_mini", bundle: Fixtures.meters, app: "Meters", name: "Meters: RAM"),
        Fixtures.item("status:com.example.meterspro::Item-0", bundle: "com.example.meterspro", app: "Meters Pro"),
        Fixtures.item("module:WiFi", bundle: "com.apple.controlcenter", app: "Control Center", name: "Wi-Fi", apple: true, axID: "com.apple.menuextra.wifi"),
    ]

    func testExactID() throws {
        XCTAssertEqual(try ItemQuery.resolve("status:com.example.meters::RAM_mini", in: items).get().displayName, "Meters: RAM")
    }

    func testBundleID() throws {
        XCTAssertEqual(try ItemQuery.resolve("COM.EXAMPLE.CHAT", in: items).get().ownerBundleID, Fixtures.chat)
    }

    func testAXIdentifier() throws {
        XCTAssertEqual(try ItemQuery.resolve("com.apple.menuextra.wifi", in: items).get().id.rawValue, "module:WiFi")
    }

    func testExactAppNameBeatsLongerNames() throws {
        // "meters" is a substring of "Meters Pro" too, but it is exactly the Meters app's name.
        XCTAssertEqual(try ItemQuery.resolve("meters", in: items).get().ownerBundleID, Fixtures.meters)
    }

    func testSubstringWithinOneApp() throws {
        XCTAssertEqual(try ItemQuery.resolve("ram", in: items).get().displayName, "Meters: RAM")
    }

    func testFuzzyFallback() throws {
        // Not a substring of anything, but a subsequence of "Chat".
        XCTAssertEqual(try ItemQuery.resolve("cht", in: items).get().ownerBundleID, Fixtures.chat)
        // A subsequence of "Meters Pro" only.
        XCTAssertEqual(try ItemQuery.resolve("mtrpro", in: items).get().ownerBundleID, "com.example.meterspro")
        // "mp" is a substring of every com.example bundle ID, so it stays ambiguous rather than going fuzzy.
        guard case .failure(.ambiguous) = ItemQuery.resolve("mp", in: items) else { return XCTFail("expected ambiguity") }
    }

    func testAmbiguousAcrossApps() {
        guard case let .failure(.ambiguous(_, candidates)) = ItemQuery.resolve("mete", in: items) else {
            return XCTFail("expected ambiguity")
        }
        XCTAssertEqual(Set(candidates.map(\.rawValue)), [
            "status:com.example.meters::CPU_mini", "status:com.example.meters::RAM_mini", "status:com.example.meterspro::Item-0",
        ])
    }

    func testNotFoundAndEmpty() {
        guard case .failure(.notFound) = ItemQuery.resolve("qqqq", in: items) else { return XCTFail() }
        guard case .failure(.notFound) = ItemQuery.resolve("  ", in: items) else { return XCTFail() }
    }

    func testSectionNames() {
        XCTAssertEqual(Section(controlName: "Shown"), .shown)
        XCTAssertEqual(Section(controlName: "hidden"), .hidden)
        XCTAssertEqual(Section(controlName: "alwaysHidden"), .alwaysHidden)
        XCTAssertEqual(Section(controlName: "always-hidden"), .alwaysHidden)
        XCTAssertEqual(Section(controlName: "always_hidden"), .alwaysHidden)
        XCTAssertEqual(Section(controlName: "always"), .alwaysHidden)
        XCTAssertNil(Section(controlName: "visible"))
        XCTAssertNil(Section(controlName: ""))
    }
}
