import XCTest
@testable import SnugBarCore

final class SpacerSyncTests: XCTestCase {
    let s = LayoutSpacer(id: "S", width: 24)
    let t = LayoutSpacer(id: "T", width: 8)
    /// Where the items are in the menu bar (order-file units), as the app would read them before taking them out.
    let places: [String: Double] = ["S": 3200, "T": 4100]

    private func run(_ state: SpacerSync.State, _ spacers: [LayoutSpacer], zen: Bool) -> (steps: [SpacerSync.Step], state: SpacerSync.State) {
        let steps = SpacerSync.steps(current: state, spacers: spacers, zen: zen)
        return (steps, SpacerSync.applying(steps, to: state) { self.places[$0] })
    }

    func testCreatesMissingItems() {
        XCTAssertEqual(SpacerSync.steps(current: .init(), spacers: [s, t], zen: false),
                       [.create(id: "S", length: 24), .create(id: "T", length: 8)])
    }

    func testZenTakesSpacersOutAndPutsThemBackAtTheirPlaceAndWidth() {
        let spacers = [s, t]
        var state = run(.init(), spacers, zen: false).state
        XCTAssertEqual(state.items, ["S": 24, "T": 8])

        let on = run(state, spacers, zen: true)
        // No zero-length item: it would still take a slot and its gaps in the menu bar.
        XCTAssertEqual(on.steps, [.stash(id: "S"), .stash(id: "T")])
        state = on.state
        XCTAssertEqual(state.items, [:], "nothing of the spacers is left in the menu bar")
        XCTAssertEqual(state.stashed, places)
        XCTAssertEqual(run(state, spacers, zen: true).steps, [], "Zen asked again: nothing more to do")

        let off = run(state, spacers, zen: false)
        XCTAssertEqual(off.steps, [.restore(id: "S", length: 24, position: 3200), .restore(id: "T", length: 8, position: 4100)])
        state = off.state
        XCTAssertEqual(state, SpacerSync.State(items: ["S": 24, "T": 8]))
        XCTAssertEqual(run(state, spacers, zen: false).steps, [], "settled")
    }

    func testZenToggledTwiceQuickly() {
        let spacers = [s]
        var state = run(.init(), spacers, zen: false).state
        for _ in 0..<2 {
            state = run(state, spacers, zen: true).state
            XCTAssertEqual(state.stashed, ["S": 3200])
            state = run(state, spacers, zen: false).state
            XCTAssertEqual(state, SpacerSync.State(items: ["S": 24]))
        }
        // On, on, off, off: each repeat is a no-op.
        state = run(state, spacers, zen: true).state
        state = run(state, spacers, zen: true).state
        let off = run(state, spacers, zen: false)
        XCTAssertEqual(off.steps, [.restore(id: "S", length: 24, position: 3200)])
        XCTAssertEqual(run(off.state, spacers, zen: false).steps, [])
    }

    func testSpacerDeletedDuringZenIsNotRestored() {
        var state = run(.init(), [s, t], zen: false).state
        state = run(state, [s, t], zen: true).state
        let deleted = run(state, [s], zen: true)
        XCTAssertEqual(deleted.steps, [.remove(id: "T")])
        XCTAssertEqual(deleted.state.stashed, ["S": 3200])
        XCTAssertEqual(run(deleted.state, [s], zen: false).steps, [.restore(id: "S", length: 24, position: 3200)])
    }

    func testWidthChangedOrSpacerAddedDuringZen() {
        var state = run(.init(), [s], zen: false).state
        state = run(state, [s], zen: true).state
        var wider = s
        wider.width = 40
        let added = LayoutSpacer(id: "U", width: 12)
        XCTAssertEqual(run(state, [wider, added], zen: true).steps, [], "nothing enters the menu bar during Zen")
        XCTAssertEqual(run(state, [wider, added], zen: false).steps,
                       [.restore(id: "S", length: 40, position: 3200), .create(id: "U", length: 12)])
    }

    func testUnknownPlaceIsCreatedPlainly() {
        let state = SpacerSync.applying([.stash(id: "S")], to: SpacerSync.State(items: ["S": 24])) { _ in nil }
        XCTAssertEqual(state, SpacerSync.State())
        XCTAssertEqual(SpacerSync.steps(current: state, spacers: [s], zen: false), [.create(id: "S", length: 24)])
    }

    func testOnlyRemovedSpacersLoseTheirItem() {
        XCTAssertEqual(SpacerSync.steps(current: .init(items: ["S": 24, "T": 8]), spacers: [s], zen: false), [.remove(id: "T")])
        XCTAssertEqual(SpacerSync.steps(current: .init(items: ["S": 24]), spacers: [s], zen: false), [])
        XCTAssertEqual(SpacerSync.steps(current: .init(items: ["S": 10]), spacers: [s], zen: false), [.setLength(id: "S", length: 24)])
    }
}
