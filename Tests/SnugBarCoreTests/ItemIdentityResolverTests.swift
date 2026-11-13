import XCTest
@testable import SnugBarCore

final class ItemIdentityResolverTests: XCTestCase {
    private func ids(_ items: [ObservedItem], _ positions: [String: Double]?) -> [String] {
        ItemIdentityResolver.resolve(items, orderPositions: positions).map(\.id.rawValue)
    }

    func testMapsEveryItemWhenOrderFileMatches() {
        XCTAssertEqual(ids(Fixtures.observed, Fixtures.positions), [
            "status:com.example.chat::Item-0",
            "status:org.example.clipboard::Item-0",
            "status:com.example.meters::CPU_mini",
            "status:com.example.meters::RAM_mini",
            "module:Battery",
            "module:WiFi",
            "module:FocusModes",
            "com.apple.menuextra.controlcenter#0",
            "com.apple.menuextra.clock#0",
        ])
    }

    func testMarksOrderFileOrigin() {
        let r = ItemIdentityResolver.resolve(Fixtures.observed, orderPositions: Fixtures.positions)
        XCTAssertEqual(r.map(\.fromOrderFile), [true, true, true, true, true, true, true, false, false])
    }

    func testMultipleItemsOfOneAppFollowPositionOrder() {
        // Same app, keys listed in the opposite order of their positions.
        let positions = [
            "status:com.example.meters::RAM_mini": 300.0,
            "status:com.example.meters::CPU_mini": 340.0,
            "status:com.example.meters::GPU_mini": 320.0,
        ]
        let items = [1000.0, 1040, 1080].map { ObservedItem(ownerBundleID: Fixtures.meters, minX: $0) }
        XCTAssertEqual(ids(items, positions), [
            "status:com.example.meters::CPU_mini",
            "status:com.example.meters::GPU_mini",
            "status:com.example.meters::RAM_mini",
        ])
    }

    func testFallsBackWithoutOrderFile() {
        XCTAssertEqual(ids(Fixtures.observed, nil), [
            "com.example.chat#0",
            "org.example.clipboard#0",
            "com.example.meters#0",
            "com.example.meters#1",
            "com.apple.menuextra.battery#0",
            "com.apple.menuextra.wifi#0",
            "com.apple.menuextra.focusmode#0",
            "com.apple.menuextra.controlcenter#0",
            "com.apple.menuextra.clock#0",
        ])
    }

    func testCountMismatchIsAmbiguous() {
        // The app has three keys (one module disabled) but shows two items: don't guess.
        var positions = Fixtures.positions
        positions["status:com.example.meters::GPU_mini"] = 320
        let result = ids(Fixtures.observed, positions)
        XCTAssertEqual(result[2], "com.example.meters#0")
        XCTAssertEqual(result[3], "com.example.meters#1")
        // Other apps are unaffected.
        XCTAssertEqual(result[0], "status:com.example.chat::Item-0")
    }

    func testTiedPositionsAreAmbiguous() {
        let positions = [
            "status:com.example.meters::CPU_mini": 300.0,
            "status:com.example.meters::RAM_mini": 300.0,
        ]
        let items = [1000.0, 1040].map { ObservedItem(ownerBundleID: Fixtures.meters, minX: $0) }
        XCTAssertEqual(ids(items, positions), ["com.example.meters#0", "com.example.meters#1"])
    }

    func testTwoOverflowedItemsOfOneAppAreAmbiguous() {
        let positions = [
            "status:com.example.meters::CPU_mini": 340.0,
            "status:com.example.meters::RAM_mini": 300.0,
        ]
        // Both stacked under the « button at the same x.
        let items = [
            ObservedItem(ownerBundleID: Fixtures.meters, minX: 900, isOverflowed: true),
            ObservedItem(ownerBundleID: Fixtures.meters, minX: 900, isOverflowed: true),
        ]
        XCTAssertEqual(ids(items, positions), ["com.example.meters#0", "com.example.meters#1"])
    }

    func testOneOverflowedItemStillMaps() {
        let positions = ["status:com.example.chat::Item-0": 420.0]
        let items = [ObservedItem(ownerBundleID: Fixtures.chat, minX: 900, isOverflowed: true)]
        XCTAssertEqual(ids(items, positions), ["status:com.example.chat::Item-0"])
    }

    func testAppHiddenFromSnapshotDoesNotDisturbOthers() {
        // While hiding, the clipboard app's item is gone from the tree; its key is still in the file.
        let visible = Fixtures.observed.filter { $0.ownerBundleID != Fixtures.clipboard }
        let result = ids(visible, Fixtures.positions)
        XCTAssertEqual(result[0], "status:com.example.chat::Item-0")
        XCTAssertEqual(result[1], "status:com.example.meters::CPU_mini")
    }

    func testModuleMatchingIgnoresCaseAndPunctuationAndPlural() {
        let modules = ["wifi": "module:WiFi", "focusmodes": "module:FocusModes", "nowplaying": "module:NowPlaying"]
        XCTAssertEqual(ItemIdentityResolver.matchModule(suffix: "wifi", moduleKeys: modules), "module:WiFi")
        XCTAssertEqual(ItemIdentityResolver.matchModule(suffix: "focusmode", moduleKeys: modules), "module:FocusModes")
        XCTAssertEqual(ItemIdentityResolver.matchModule(suffix: "now-playing", moduleKeys: modules), "module:NowPlaying")
        XCTAssertNil(ItemIdentityResolver.matchModule(suffix: "bluetooth", moduleKeys: modules))
    }

    func testModuleKeyIsUsedOnce() {
        let positions = ["module:WiFi": 160.0]
        let items = [
            ObservedItem(ownerBundleID: nil, axIdentifier: "com.apple.menuextra.wifi", minX: 1000),
            ObservedItem(ownerBundleID: nil, axIdentifier: "com.apple.menuextra.wifi", minX: 1040),
        ]
        XCTAssertEqual(ids(items, positions), ["module:WiFi", "com.apple.menuextra.wifi#1"])
    }

    func testUnknownOwnerFallsBackToUnknown() {
        let items = [ObservedItem(ownerBundleID: nil, minX: 0), ObservedItem(ownerBundleID: "", minX: 10)]
        XCTAssertEqual(ids(items, [:]), ["unknown#0", "unknown#1"])
    }

    func testIgnoresUnrelatedKeys() {
        var positions = Fixtures.positions
        positions["SomeOtherKey"] = 10
        XCTAssertEqual(ids(Fixtures.observed, positions)[0], "status:com.example.chat::Item-0")
    }
}

final class ItemIDTests: XCTestCase {
    func testParsesStatusKey() {
        let id = ItemID(rawValue: "status:com.example.meters::CPU_mini")
        XCTAssertEqual(id.kind, .status(bundleID: "com.example.meters", autosaveName: "CPU_mini"))
        XCTAssertEqual(id.bundleID, "com.example.meters")
        XCTAssertTrue(id.isOrderFileKey)
    }

    func testParsesStatusKeyWithColonsInName() {
        let id = ItemID(rawValue: "status:com.example.app::name::with::colons")
        XCTAssertEqual(id.kind, .status(bundleID: "com.example.app", autosaveName: "name::with::colons"))
    }

    func testParsesModuleAndIndexed() {
        XCTAssertEqual(ItemID(rawValue: "module:WiFi").kind, .module(name: "WiFi"))
        XCTAssertEqual(ItemID(rawValue: "com.example.chat#2").kind, .indexed(owner: "com.example.chat", index: 2))
        XCTAssertFalse(ItemID(rawValue: "com.example.chat#2").isOrderFileKey)
        XCTAssertEqual(ItemID(rawValue: "#2").kind, .other)
        XCTAssertEqual(ItemID(rawValue: "status:broken").kind, .other)
    }

    func testFactoriesRoundTrip() {
        XCTAssertEqual(ItemID.status(bundleID: "a.b", autosaveName: "X").rawValue, "status:a.b::X")
        XCTAssertEqual(ItemID.module("Clock").rawValue, "module:Clock")
        XCTAssertEqual(ItemID.indexed(owner: "a.b", index: 1).rawValue, "a.b#1")
    }

    func testCodesAsPlainString() throws {
        let data = try JSONEncoder().encode([ItemID(rawValue: "module:WiFi")])
        XCTAssertEqual(String(decoding: data, as: UTF8.self), #"["module:WiFi"]"#)
        XCTAssertEqual(try JSONDecoder().decode([ItemID].self, from: data), [ItemID(rawValue: "module:WiFi")])
    }

    func testDisplayName() {
        XCTAssertEqual(MenuBarItem.makeDisplayName(appName: "Meters", description: "CPU", isAppleItem: false, axIdentifier: nil), "Meters: CPU")
        XCTAssertEqual(MenuBarItem.makeDisplayName(appName: "Meters", description: "meters", isAppleItem: false, axIdentifier: nil), "Meters")
        XCTAssertEqual(MenuBarItem.makeDisplayName(appName: "Chat", description: nil, isAppleItem: false, axIdentifier: nil), "Chat")
        XCTAssertEqual(MenuBarItem.makeDisplayName(appName: "Control Center", description: "Wi-Fi", isAppleItem: true, axIdentifier: "com.apple.menuextra.wifi"), "Wi-Fi")
        XCTAssertEqual(MenuBarItem.makeDisplayName(appName: "Control Center", description: nil, isAppleItem: true, axIdentifier: "com.apple.menuextra.clock"), "clock")
    }
}
