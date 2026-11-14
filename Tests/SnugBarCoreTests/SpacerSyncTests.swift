import XCTest
@testable import SnugBarCore

final class SpacerSyncTests: XCTestCase {
    let s = LayoutSpacer(id: "S", width: 24)
    let t = LayoutSpacer(id: "T", width: 8)

    func testCreatesMissingItems() {
        XCTAssertEqual(SpacerSync.steps(current: [:], spacers: [s, t], zen: false),
                       [.create(id: "S", length: 24), .create(id: "T", length: 8)])
    }

    func testZenRoundTripKeepsEverySpacerAndItsWidth() {
        let spacers = [s, t]
        var items = SpacerSync.applying(SpacerSync.steps(current: [:], spacers: spacers, zen: false), to: [:])
        let on = SpacerSync.steps(current: items, spacers: spacers, zen: true)
        // Zen never removes or recreates an item (that would lose its place); it only shrinks it.
        XCTAssertEqual(on, [.setLength(id: "S", length: 0), .setLength(id: "T", length: 0)])
        items = SpacerSync.applying(on, to: items)
        XCTAssertEqual(items, ["S": 0, "T": 0])
        let off = SpacerSync.steps(current: items, spacers: spacers, zen: false)
        XCTAssertEqual(off, [.setLength(id: "S", length: 24), .setLength(id: "T", length: 8)])
        items = SpacerSync.applying(off, to: items)
        XCTAssertEqual(items, ["S": 24, "T": 8])
        // Settled: nothing more to do.
        XCTAssertEqual(SpacerSync.steps(current: items, spacers: spacers, zen: false), [])
    }

    func testWidthChangedDuringZenAppliesAfterIt() {
        var wider = s
        wider.width = 40
        XCTAssertEqual(SpacerSync.steps(current: ["S": 0], spacers: [wider], zen: true), [])
        XCTAssertEqual(SpacerSync.steps(current: ["S": 0], spacers: [wider], zen: false), [.setLength(id: "S", length: 40)])
    }

    func testOnlyRemovedSpacersLoseTheirItem() {
        XCTAssertEqual(SpacerSync.steps(current: ["S": 24, "T": 8], spacers: [s], zen: false), [.remove(id: "T")])
        XCTAssertEqual(SpacerSync.steps(current: ["S": 0, "T": 0], spacers: [s], zen: true), [.remove(id: "T")])
    }
}
