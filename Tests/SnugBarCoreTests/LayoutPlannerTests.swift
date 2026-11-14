import XCTest
@testable import SnugBarCore

final class LayoutPlannerTests: XCTestCase {
    let chat = "status:com.example.chat::Item-0"
    let clipboard = "status:org.example.clipboard::Item-0"
    let cpu = "status:com.example.meters::CPU_mini"
    let ram = "status:com.example.meters::RAM_mini"
    let battery = "module:Battery"
    let wifi = "module:WiFi"

    /// Shown keys as `Fixtures.positions` orders them.
    var live: [String] { [chat, clipboard, cpu, ram, battery, wifi] }

    /// The plan's changes give the target order.
    func assertWritten(_ plan: OrderPlanner.LayoutPlan, _ positions: [String: Double], file: StaticString = #filePath, line: UInt = #line) {
        let after = OrderPlanner.leftToRight(positions.merging(plan.changes) { _, new in new })
        let targetSet = Set(plan.targetOrder.filter { positions[$0] != nil })
        XCTAssertEqual(after.filter(targetSet.contains), plan.targetOrder.filter(targetSet.contains), file: file, line: line)
        XCTAssertTrue(plan.changes.values.allSatisfy { $0 > 0 }, file: file, line: line)
    }

    func testNoOpWhenLiveMatchesDesired() {
        let plan = OrderPlanner.planLayout(desired: live, live: live, positions: Fixtures.positions)
        XCTAssertTrue(plan.isNoOp)
        XCTAssertEqual(plan.changes, [:])
        XCTAssertFalse(plan.desiredChanged)
        XCTAssertEqual(plan.targetOrder, live)
    }

    func testEmptyDesiredDoesNothing() {
        let plan = OrderPlanner.planLayout(desired: [], live: live, positions: Fixtures.positions)
        XCTAssertTrue(plan.isNoOp)
        XCTAssertFalse(plan.desiredChanged)
    }

    func testSingleMovedItemIsOneWrite() {
        // The user wants RAM at the left end; the bar has it where it was.
        let desired = [ram, chat, clipboard, cpu, battery, wifi]
        let plan = OrderPlanner.planLayout(desired: desired, live: live, positions: Fixtures.positions)
        XCTAssertEqual(plan.changes.count, 1)
        XCTAssertNotNil(plan.changes[ram])
        XCTAssertEqual(plan.moves, [OrderPlanner.Move(key: ram, .before(chat))])
        XCTAssertFalse(plan.renumbered)
        assertWritten(plan, Fixtures.positions)
    }

    func testRelaunchedAppReturnsToItsSlot() {
        // Clipboard was between chat and the meters; it relaunched and macOS put it at the left end.
        let desired = [chat, clipboard, cpu, ram, battery, wifi]
        var positions = Fixtures.positions
        positions[clipboard] = 500
        let liveNow = [clipboard, chat, cpu, ram, battery, wifi]
        let plan = OrderPlanner.planLayout(desired: desired, live: liveNow, positions: positions)
        XCTAssertEqual(plan.targetOrder, desired)
        XCTAssertEqual(Array(plan.changes.keys).count, 1)
        assertWritten(plan, positions)
        XCTAssertEqual(OrderPlanner.applying(plan.moves, to: liveNow), desired)
    }

    func testMissingItemsAreIgnoredButKeepTheirSlot() {
        // Chat isn't running. The rest is in order: nothing to do, and chat keeps its slot.
        let desired = [chat, clipboard, cpu, ram, battery, wifi]
        let liveNow = [clipboard, cpu, ram, battery, wifi]
        let plan = OrderPlanner.planLayout(desired: desired, live: liveNow, positions: Fixtures.positions)
        XCTAssertTrue(plan.isNoOp)
        XCTAssertEqual(plan.desiredOrder, desired)
        XCTAssertFalse(plan.desiredChanged)
    }

    func testUnknownLiveItemIsAdoptedWhereItIs() {
        let desired = [chat, cpu, ram, battery, wifi]
        let plan = OrderPlanner.planLayout(desired: desired, live: live, positions: Fixtures.positions)
        XCTAssertTrue(plan.isNoOp)
        XCTAssertTrue(plan.desiredChanged)
        XCTAssertEqual(plan.desiredOrder, live)
    }

    func testNewAppGoesToTheEndOfThirdPartyItems() {
        let desired = [chat, cpu, ram, battery, wifi]
        let plan = OrderPlanner.planLayout(desired: desired, live: live, positions: Fixtures.positions, newKeys: [clipboard])
        XCTAssertEqual(plan.desiredOrder, [chat, cpu, ram, clipboard, battery, wifi])
        XCTAssertEqual(plan.targetOrder, [chat, cpu, ram, clipboard, battery, wifi])
        XCTAssertFalse(plan.changes.isEmpty)
        assertWritten(plan, Fixtures.positions)
    }

    func testReversedOrderNeedsFewestMoves() {
        let desired = Array(live.reversed())
        let plan = OrderPlanner.planLayout(desired: desired, live: live, positions: Fixtures.positions)
        XCTAssertEqual(plan.moves.count, live.count - 1)
        XCTAssertEqual(OrderPlanner.applying(plan.moves, to: live), desired)
        assertWritten(plan, Fixtures.positions)
    }

    func testRenumbersWhenThereIsNoRoom() {
        let tight: [String: Double] = [chat: 4, clipboard: 3, cpu: 2, ram: 1]
        let desired = [ram, cpu, clipboard, chat]
        let plan = OrderPlanner.planLayout(desired: desired, live: [chat, clipboard, cpu, ram], positions: tight)
        XCTAssertTrue(plan.renumbered)
        assertWritten(plan, tight)
        let after = OrderPlanner.leftToRight(tight.merging(plan.changes) { _, n in n })
        XCTAssertEqual(after, desired)
        XCTAssertEqual(Set(tight.merging(plan.changes) { _, n in n }.values).count, 4)
    }

    func testOtherKeysInTheFileArePreservedAndOrderOnlyAmongTarget() {
        // A hidden app's key sits between shown ones; only shown keys are ordered.
        var positions = Fixtures.positions
        positions["status:com.example.hiddenapp::Item-0"] = 330
        let desired = [cpu, chat, clipboard, ram, battery, wifi]
        let plan = OrderPlanner.planLayout(desired: desired, live: live, positions: positions)
        XCTAssertNil(plan.changes["status:com.example.hiddenapp::Item-0"])
        assertWritten(plan, positions)
    }

    func testSpacerWithoutOrderFileKeyGetsAFreePosition() {
        let spacer = LayoutSpacer(id: "S1").key
        // Desired: spacer between clipboard and cpu. Live: the spacer sits at the left end.
        let desired = [chat, clipboard, spacer, cpu, ram, battery, wifi]
        let liveNow = [spacer, chat, clipboard, cpu, ram, battery, wifi]
        let plan = OrderPlanner.planLayout(desired: desired, live: liveNow, positions: Fixtures.positions)
        XCTAssertEqual(plan.unplaced, [spacer])
        XCTAssertEqual(plan.changes, [:])
        let value = try? XCTUnwrap(plan.freePositions[spacer])
        XCTAssertEqual(value, 360) // between clipboard (380) and cpu (340)
        XCTAssertFalse(plan.isNoOp)
    }

    func testSpacerInPlaceNeedsNothing() {
        let spacer = LayoutSpacer(id: "S1").key
        let desired = [chat, clipboard, spacer, cpu, ram, battery, wifi]
        let plan = OrderPlanner.planLayout(desired: desired, live: desired, positions: Fixtures.positions)
        XCTAssertTrue(plan.isNoOp)
    }

    func testSpacerWithOrderFileKeyIsAnOrdinaryKey() {
        let s = LayoutSpacer(id: "S2")
        let own = "app.example.SnugBar"
        var positions = Fixtures.positions
        positions[s.orderFileKey(ownBundleID: own)] = 440
        let map = LayoutSpacer.orderKeyMap([s], ownBundleID: own, positions: positions)
        XCTAssertEqual(map, [s.key: s.orderFileKey(ownBundleID: own)])
        let desired = DesiredOrder.mapped([chat, clipboard, s.key, cpu, ram, battery, wifi], map)
        let liveNow = DesiredOrder.mapped([s.key] + live, map)
        let plan = OrderPlanner.planLayout(desired: desired, live: liveNow, positions: positions)
        XCTAssertEqual(plan.unplaced, [])
        XCTAssertNotNil(plan.changes[s.orderFileKey(ownBundleID: own)])
        assertWritten(plan, positions)
    }

    func testWithoutPositionsOnlyMoves() {
        let desired = [ram, chat, clipboard, cpu, battery, wifi]
        let plan = OrderPlanner.planLayout(desired: desired, live: live, positions: nil)
        XCTAssertEqual(plan.changes, [:])
        XCTAssertEqual(plan.moves.count, 1)
        XCTAssertEqual(OrderPlanner.applying(plan.moves, to: live), desired)
    }

    func testMovesTurningRandomOrders() {
        var rng = SystemRandomNumberGenerator()
        for _ in 0..<200 {
            let keys = (0..<Int.random(in: 2...9, using: &rng)).map { "k\($0)" }
            let a = keys.shuffled(using: &rng), b = keys.shuffled(using: &rng)
            let moves = OrderPlanner.movesTurning(a, into: b)
            XCTAssertEqual(OrderPlanner.applying(moves, to: a), b)
            XCTAssertLessThanOrEqual(moves.count, keys.count - 1)
        }
    }

    func testOrderFilePlanRandomOrders() {
        var rng = SystemRandomNumberGenerator()
        for _ in 0..<100 {
            let keys = (0..<8).map { "status:com.example.app\($0)::Item-0" }
            var positions: [String: Double] = [:]
            for (i, k) in keys.shuffled(using: &rng).enumerated() { positions[k] = Double(100 + i * Int.random(in: 1...40, using: &rng)) }
            let liveNow = OrderPlanner.leftToRight(positions)
            let desired = keys.shuffled(using: &rng)
            let plan = OrderPlanner.planLayout(desired: desired, live: liveNow, positions: positions)
            XCTAssertEqual(OrderPlanner.leftToRight(positions.merging(plan.changes) { _, n in n }), desired)
        }
    }
}

final class DesiredOrderTests: XCTestCase {
    func testMergingPlacesUnknownKeysWhereTheyAre() {
        XCTAssertEqual(DesiredOrder.merging(live: ["a", "x", "b"], into: ["a", "b"]), ["a", "x", "b"])
        XCTAssertEqual(DesiredOrder.merging(live: ["x", "a"], into: ["z", "a"]), ["z", "x", "a"])
        XCTAssertEqual(DesiredOrder.merging(live: ["x"], into: ["a"]), ["a", "x"])
    }

    func testMergingNewKeysGoBeforeAppleItems() {
        let merged = DesiredOrder.merging(live: ["n1", "a", "module:WiFi"], into: ["a", "module:WiFi"], atEnd: ["n1"])
        XCTAssertEqual(merged, ["a", "n1", "module:WiFi"])
    }

    func testAdoptingKeepsAbsentSlots() {
        // "gone" isn't running; the user swapped a and b in the bar.
        XCTAssertEqual(DesiredOrder.adopting(live: ["b", "a"], into: ["a", "gone", "b"]), ["b", "gone", "a"])
        XCTAssertEqual(DesiredOrder.adopting(live: ["a", "b"], into: []), ["a", "b"])
    }

    func testMovingBlock() {
        let order = ["a", "b", "c", "d"]
        XCTAssertEqual(DesiredOrder.moving(["c", "d"], to: .before("a"), in: order), ["c", "d", "a", "b"])
        XCTAssertEqual(DesiredOrder.moving(["a"], to: .after("d"), in: order), ["b", "c", "d", "a"])
        XCTAssertEqual(DesiredOrder.moving(["n"], to: .after("b"), in: order), ["a", "b", "n", "c", "d"])
        XCTAssertEqual(DesiredOrder.moving(["a"], to: .after("a"), in: order), order)
    }

    func testNormalizedMapsFallbackIDs() {
        let order = ["com.example.meters#1", "status:com.example.chat::Item-0", "status:com.example.meters::RAM_mini"]
        XCTAssertEqual(DesiredOrder.normalized(order, positions: Fixtures.positions),
                       ["status:com.example.meters::RAM_mini", "status:com.example.chat::Item-0"])
        XCTAssertEqual(DesiredOrder.normalized(order, positions: nil), order)
    }

    func testAppleKeys() {
        XCTAssertTrue(DesiredOrder.isAppleKey("module:WiFi"))
        XCTAssertTrue(DesiredOrder.isAppleKey("com.apple.menuextra.battery#0"))
        XCTAssertFalse(DesiredOrder.isAppleKey("status:com.example.chat::Item-0"))
        XCTAssertFalse(DesiredOrder.isAppleKey("spacer:1"))
    }
}
