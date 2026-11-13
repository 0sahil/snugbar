import XCTest
@testable import SnugBarCore

final class BarTileTests: XCTestCase {
    private let monitor = "com.example.monitor"

    /// A system monitor with five items, between a clipboard manager and a chat app.
    private var items: [MenuBarItem] {
        [Fixtures.item("status:org.example.clipboard::Item-0", bundle: Fixtures.clipboard, app: "Clipper")]
            + (0..<5).map { Fixtures.item("\(monitor)#\($0)", bundle: monitor, app: "Monitor", name: "Monitor: Sensor \($0)") }
            + [Fixtures.item("status:com.example.chat::Item-0", bundle: Fixtures.chat, app: "Chatter")]
    }

    func testAppWithSeveralItemsAndNoPicturesGetsOneTile() {
        let tiles = BarListing.tiles(for: items) { _ in false }
        XCTAssertEqual(tiles.count, 3)
        XCTAssertEqual(tiles.map(\.items.count), [1, 5, 1])
        let app = tiles[1]
        XCTAssertTrue(app.isAppTile)
        XCTAssertEqual(app.id.rawValue, "\(monitor)#0", "clicking opens the leftmost item")
        XCTAssertEqual(app.item.id, app.items[0].id)
        XCTAssertEqual(app.item.displayName, "Monitor", "named after the app, not its first item")
        XCTAssertEqual(app.helpText, "Monitor (5 items)")
        XCTAssertFalse(tiles[0].isAppTile)
        XCTAssertEqual(tiles[0].helpText, "Clipper")
    }

    func testItemsWithPicturesAreListedOneByOne() {
        let tiles = BarListing.tiles(for: items) { _ in true }
        XCTAssertEqual(tiles.count, 7)
        XCTAssertTrue(tiles.allSatisfy { !$0.isAppTile })
        XCTAssertEqual(tiles[2].helpText, "Monitor: Sensor 1")
    }

    func testPicturedItemsStandAloneAndTheRestShareATile() {
        // Two of the five have been captured: they show individually, the other three share the app tile, which sits
        // where the first of them is.
        let captured: Set<String> = ["\(monitor)#1", "\(monitor)#3"]
        let tiles = BarListing.tiles(for: items) { captured.contains($0.id.rawValue) }
        XCTAssertEqual(tiles.map(\.id.rawValue), [
            "status:org.example.clipboard::Item-0", "\(monitor)#0", "\(monitor)#1", "\(monitor)#3",
            "status:com.example.chat::Item-0",
        ])
        XCTAssertEqual(tiles[1].items.map(\.id.rawValue), ["\(monitor)#0", "\(monitor)#2", "\(monitor)#4"])
    }

    func testOneItemWithoutAPictureKeepsItsOwnTile() {
        let captured: Set<String> = (0..<4).map { "\(monitor)#\($0)" }.reduce(into: []) { $0.insert($1) }
        let tiles = BarListing.tiles(for: items) { captured.contains($0.id.rawValue) || $0.ownerBundleID != monitor }
        XCTAssertEqual(tiles.count, 7)
        XCTAssertEqual(tiles[5].helpText, "Monitor: Sensor 4")
    }

    func testItemsWithoutOwnerAreNeverMerged() {
        let orphans = [Fixtures.item("unknown#0", bundle: "", app: ""), Fixtures.item("unknown#1", bundle: "", app: "")]
        XCTAssertEqual(BarListing.tiles(for: orphans) { _ in false }.count, 2)
    }

    func testLettersGoToTilesNotHiddenItems() {
        let tiles = BarListing.tiles(for: items) { _ in false }
        let keys = LetterAssigner.assign(tiles.map(\.item))
        XCTAssertEqual(keys.count, 3)
        XCTAssertEqual(keys[ItemID(rawValue: "\(monitor)#0")], "m")
    }
}

final class EquivalentIDTests: XCTestCase {
    /// A clipboard manager whose only order-file key is `Item-1`, and a system monitor with two keys.
    private let positions: [String: Double] = [
        "status:com.example.clipper::Item-1": 400,
        "status:com.example.meters::CPU_mini": 340,
        "status:com.example.meters::RAM_mini": 300,
        "module:Battery": 200,
    ]

    func testFallbackIDMapsToTheOrderFileKeyAtTheSameIndex() {
        XCTAssertEqual(ItemIdentityResolver.equivalentIDs(of: .indexed(owner: "com.example.clipper", index: 0), orderPositions: positions),
                       [ItemID(rawValue: "status:com.example.clipper::Item-1")])
        // Keys left to right: larger distance from the right edge first.
        XCTAssertEqual(ItemIdentityResolver.equivalentIDs(of: .indexed(owner: "com.example.meters", index: 1), orderPositions: positions),
                       [ItemID(rawValue: "status:com.example.meters::RAM_mini")])
    }

    func testOrderFileKeyMapsToTheFallbackID() {
        XCTAssertEqual(ItemIdentityResolver.equivalentIDs(of: ItemID(rawValue: "status:com.example.meters::CPU_mini"), orderPositions: positions),
                       [.indexed(owner: "com.example.meters", index: 0)])
    }

    func testNoEquivalentWithoutAMatch() {
        XCTAssertEqual(ItemIdentityResolver.equivalentIDs(of: .indexed(owner: "com.example.meters", index: 2), orderPositions: positions), [])
        XCTAssertEqual(ItemIdentityResolver.equivalentIDs(of: .indexed(owner: "com.example.other", index: 0), orderPositions: positions), [])
        XCTAssertEqual(ItemIdentityResolver.equivalentIDs(of: .module("Battery"), orderPositions: positions), [])
        XCTAssertEqual(ItemIdentityResolver.equivalentIDs(of: .indexed(owner: "com.example.clipper", index: 0), orderPositions: nil), [])
    }

    func testAmbiguousOrderGivesNoEquivalent() {
        let tied: [String: Double] = ["status:com.example.meters::CPU_mini": 300, "status:com.example.meters::RAM_mini": 300]
        XCTAssertEqual(ItemIdentityResolver.equivalentIDs(of: .indexed(owner: "com.example.meters", index: 0), orderPositions: tied), [])
    }
}
