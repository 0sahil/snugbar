import XCTest
@testable import SnugBarCore

final class OrderPlannerTests: XCTestCase {
    let chat = "status:com.example.chat::Item-0"
    let clipboard = "status:org.example.clipboard::Item-0"
    let cpu = "status:com.example.meters::CPU_mini"
    let ram = "status:com.example.meters::RAM_mini"

    func testLeftToRight() {
        XCTAssertEqual(OrderPlanner.leftToRight(Fixtures.positions), [
            chat, clipboard, cpu, ram, "module:Battery", "module:WiFi", "module:FocusModes",
        ])
    }

    func testMoveBeforePicksValueBetweenNeighbours() throws {
        // Move RAM to the left of the clipboard app: between chat (420) and clipboard (380).
        let plan = try OrderPlanner.plan(positions: Fixtures.positions, moving: ram, to: .before(clipboard))
        XCTAssertEqual(plan.changes, [ram: 400])
        XCTAssertFalse(plan.renumbered)
        XCTAssertEqual(Array(plan.resultingOrder.prefix(4)), [chat, ram, clipboard, cpu])
        XCTAssertEqual(OrderPlanner.leftToRight(OrderPlanner.apply(plan, to: Fixtures.positions)), plan.resultingOrder)
    }

    func testMoveAfterPicksValueBetweenNeighbours() throws {
        // Chat to the right of CPU: between CPU (340) and RAM (300).
        let plan = try OrderPlanner.plan(positions: Fixtures.positions, moving: chat, to: .after(cpu))
        XCTAssertEqual(plan.changes, [chat: 320])
        XCTAssertEqual(Array(plan.resultingOrder.prefix(4)), [clipboard, cpu, chat, ram])
    }

    func testValueIsStrictlyBetween() throws {
        for anchor in Fixtures.positions.keys where anchor != cpu {
            for placement in [OrderPlanner.Placement.before(anchor), .after(anchor)] {
                let plan = try OrderPlanner.plan(positions: Fixtures.positions, moving: cpu, to: placement)
                let applied = OrderPlanner.apply(plan, to: Fixtures.positions)
                let order = OrderPlanner.leftToRight(applied)
                let i = order.firstIndex(of: cpu)!, a = order.firstIndex(of: anchor)!
                switch placement {
                case .before: XCTAssertEqual(i + 1, a, "\(placement)")
                case .after: XCTAssertEqual(a + 1, i, "\(placement)")
                }
                XCTAssertEqual(Set(applied.values).count, applied.count, "no ties after \(placement)")
                XCTAssertTrue(applied.values.allSatisfy { $0 > 0 })
            }
        }
    }

    func testMoveToLeftEnd() throws {
        let plan = try OrderPlanner.plan(positions: Fixtures.positions, moving: ram, to: .before(chat))
        XCTAssertEqual(plan.changes, [ram: 452])
        XCTAssertEqual(plan.resultingOrder.first, ram)
    }

    func testMoveToRightEnd() throws {
        let plan = try OrderPlanner.plan(positions: Fixtures.positions, moving: chat, to: .after("module:FocusModes"))
        XCTAssertEqual(plan.changes, [chat: 60])
        XCTAssertEqual(plan.resultingOrder.last, chat)
    }

    func testNoRoomRenumbersKeepingOrder() throws {
        let tight = ["a": 101.0, "b": 100.0, "c": 50.0]
        let plan = try OrderPlanner.plan(positions: tight, moving: "c", to: .before("b"))
        XCTAssertTrue(plan.renumbered)
        XCTAssertEqual(plan.resultingOrder, ["a", "c", "b"])
        let applied = OrderPlanner.apply(plan, to: tight)
        XCTAssertEqual(OrderPlanner.leftToRight(applied), ["a", "c", "b"])
        XCTAssertEqual(applied, ["a": 96, "c": 64, "b": 32])
    }

    func testRightEndWithNoRoomRenumbers() throws {
        let tight = ["a": 1.0, "b": 50.0]
        let plan = try OrderPlanner.plan(positions: tight, moving: "b", to: .after("a"))
        XCTAssertTrue(plan.renumbered)
        XCTAssertEqual(OrderPlanner.leftToRight(OrderPlanner.apply(plan, to: tight)), ["a", "b"])
    }

    func testFractionalNeighboursStillGetWholeNumberWhenPossible() throws {
        let positions = ["a": 100.5, "b": 97.2, "c": 10]
        let plan = try OrderPlanner.plan(positions: positions, moving: "c", to: .before("b"))
        XCTAssertEqual(plan.changes, ["c": 98])
    }

    func testInsertsKeyMissingFromFile() throws {
        let plan = try OrderPlanner.plan(positions: Fixtures.positions, moving: "status:com.example.new::Item-0", to: .after(chat))
        XCTAssertEqual(plan.changes, ["status:com.example.new::Item-0": 400])
    }

    func testUnchangedValueIsNotWritten() throws {
        // CPU already sits between clipboard and RAM at the midpoint.
        let positions = ["x": 380.0, "y": 340.0, "z": 300.0]
        let plan = try OrderPlanner.plan(positions: positions, moving: "y", to: .after("x"))
        XCTAssertEqual(plan.changes, [:])
    }

    func testErrors() {
        XCTAssertThrowsError(try OrderPlanner.plan(positions: Fixtures.positions, moving: cpu, to: .before("nope"))) {
            XCTAssertEqual($0 as? OrderPlanner.PlanError, .unknownAnchor("nope"))
        }
        XCTAssertThrowsError(try OrderPlanner.plan(positions: Fixtures.positions, moving: cpu, to: .after(cpu))) {
            XCTAssertEqual($0 as? OrderPlanner.PlanError, .anchorIsMovedItem)
        }
    }
}
