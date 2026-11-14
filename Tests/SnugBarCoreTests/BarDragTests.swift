import XCTest
@testable import SnugBarCore

final class BarPressTests: XCTestCase {
    func testSmallMovementStaysAClick() {
        var press = BarPress(x: 10, y: 10, canDrag: true)
        XCTAssertFalse(press.moved(toX: 12, y: 12)) // 2.8 pt
        XCTAssertFalse(press.moved(toX: 13.9, y: 10))
        XCTAssertFalse(press.isDragging)
        XCTAssertEqual(press.released(atX: 13.9, y: 10, insideTile: true), .click)
    }

    func testFourPointsStartsTheDragOnce() {
        var press = BarPress(x: 10, y: 10, canDrag: true)
        XCTAssertTrue(press.moved(toX: 14, y: 10))
        XCTAssertTrue(press.isDragging)
        XCTAssertFalse(press.moved(toX: 30, y: 10), "the drag starts only once")
        // Back over the start: still a drag, never a click.
        _ = press.moved(toX: 10, y: 10)
        XCTAssertEqual(press.released(atX: 10, y: 10, insideTile: true), .drop)
    }

    func testTileThatCantBeDraggedStillClicks() {
        var press = BarPress(x: 10, y: 10, canDrag: false)
        XCTAssertFalse(press.moved(toX: 20, y: 10))
        XCTAssertFalse(press.isDragging)
        XCTAssertEqual(press.released(atX: 20, y: 10, insideTile: true), .click)
        // Released away from the tile, as a button does: nothing.
        XCTAssertEqual(press.released(atX: 60, y: 10, insideTile: false), .nothing)
    }

    func testClickNearTheEdgeIsNotSwallowed() {
        let press = BarPress(x: 1, y: 10, canDrag: true)
        // Released just outside the tile, but the pointer hardly moved: a click.
        XCTAssertEqual(press.released(atX: -1, y: 10, insideTile: false), .click)
    }

    func testEscCancels() {
        var press = BarPress(x: 10, y: 10, canDrag: true)
        _ = press.moved(toX: 30, y: 10)
        press.cancel()
        XCTAssertFalse(press.isDragging)
        XCTAssertFalse(press.moved(toX: 40, y: 10), "no new drag after a cancel")
        XCTAssertEqual(press.released(atX: 10, y: 10, insideTile: true), .nothing)
    }
}

final class BarDropIndexTests: XCTestCase {
    /// Tiles 30 pt wide with 2 pt gaps, `perLine` to a line, lines 24 pt high with 2 pt between them.
    func frames(_ count: Int, perLine: Int = 100, top: Double = 20) -> [Rect] {
        (0..<count).map { i in
            Rect(x: 6 + Double(i % perLine) * 32, y: top + Double(i / perLine) * 26, width: 30, height: 24)
        }
    }

    func testIndexFollowsTileCentres() {
        let f = frames(4) // centres at 21, 53, 85, 117
        XCTAssertEqual(BarDrag.dropIndex(frames: f, x: 0, y: 30), 0)
        XCTAssertEqual(BarDrag.dropIndex(frames: f, x: 20, y: 30), 0)
        XCTAssertEqual(BarDrag.dropIndex(frames: f, x: 22, y: 30), 1)
        XCTAssertEqual(BarDrag.dropIndex(frames: f, x: 100, y: 30), 3)
        XCTAssertEqual(BarDrag.dropIndex(frames: f, x: 200, y: 30), 4)
        // Above or below the row: the row still decides.
        XCTAssertEqual(BarDrag.dropIndex(frames: f, x: 60, y: 0), 2)
        XCTAssertEqual(BarDrag.dropIndex(frames: f, x: 60, y: 90), 2)
    }

    func testIndexOnWrappedLines() {
        let f = frames(7, perLine: 3) // lines [0,1,2] [3,4,5] [6]
        XCTAssertEqual(BarDrag.lines(f), [0..<3, 3..<6, 6..<7])
        XCTAssertEqual(BarDrag.dropIndex(frames: f, x: 0, y: 25), 0)
        XCTAssertEqual(BarDrag.dropIndex(frames: f, x: 0, y: 50), 3, "start of the second line")
        XCTAssertEqual(BarDrag.dropIndex(frames: f, x: 60, y: 50), 5)
        XCTAssertEqual(BarDrag.dropIndex(frames: f, x: 200, y: 25), 3, "end of the first line")
        XCTAssertEqual(BarDrag.dropIndex(frames: f, x: 200, y: 50), 6)
        XCTAssertEqual(BarDrag.dropIndex(frames: f, x: 200, y: 80), 7, "after the last tile")
        XCTAssertEqual(BarDrag.dropIndex(frames: f, x: 0, y: 200), 6, "below everything: the last line")
    }

    func testEmptyGroup() {
        XCTAssertEqual(BarDrag.dropIndex(frames: [], x: 10, y: 10), 0)
        XCTAssertNil(BarDrag.insertionMarker(frames: [], gap: 0, y: 10))
    }

    func testInsertionMarker() {
        let f = frames(7, perLine: 3)
        // Before tile 1: centred in the 2 pt gap left of it.
        XCTAssertEqual(BarDrag.insertionMarker(frames: f, gap: 1, y: 25), Rect(x: 36, y: 20, width: 2, height: 24))
        // Gap 3 is the end of line one and the start of line two; the pointer's line decides.
        XCTAssertEqual(BarDrag.insertionMarker(frames: f, gap: 3, y: 25)?.minX, f[2].maxX)
        XCTAssertEqual(BarDrag.insertionMarker(frames: f, gap: 3, y: 50)?.maxX, f[3].minX)
        XCTAssertEqual(BarDrag.insertionMarker(frames: f, gap: 3, y: 50)?.minY, f[3].minY)
        // After the last tile.
        XCTAssertEqual(BarDrag.insertionMarker(frames: f, gap: 7, y: 80)?.minX, f[6].maxX)
        XCTAssertNil(BarDrag.insertionMarker(frames: f, gap: 8, y: 80))
    }

    func testGroupUnderThePointer() {
        let frames: [BarGroupKind: Rect] = [
            .hidden: Rect(x: 6, y: 6, width: 200, height: 40),
            .alwaysHidden: Rect(x: 6, y: 52, width: 200, height: 40),
        ]
        XCTAssertEqual(BarDrag.group(atX: 50, y: 20, frames: frames), .hidden)
        XCTAssertEqual(BarDrag.group(atX: 50, y: 60, frames: frames), .alwaysHidden)
        // Between them, within the slop of both: the nearer.
        XCTAssertEqual(BarDrag.group(atX: 50, y: 47, frames: frames), .hidden)
        XCTAssertEqual(BarDrag.group(atX: 50, y: 51, frames: frames), .alwaysHidden)
        // Away from the bar: nowhere (the drop is cancelled).
        XCTAssertNil(BarDrag.group(atX: 50, y: 140, frames: frames))
        XCTAssertNil(BarDrag.group(atX: 400, y: 20, frames: frames))
    }
}

final class BarDropOutcomeTests: XCTestCase {
    let positions: [String: Double] = [
        "status:com.example.a::Item-0": 900, "status:com.example.b::Item-0": 800, "status:com.example.c::Item-0": 700,
        "status:com.example.x::Item-0": 600, "status:com.example.y::Item-0": 500,
    ]

    func tile(_ app: String) -> BarTile {
        BarTile(items: [Fixtures.item("status:com.example.\(app)::Item-0", bundle: "com.example.\(app)", app: app.uppercased())])
    }

    func placeholder(_ app: String) -> BarTile {
        BarTile(items: [ItemCatalog.placeholder(bundleID: "com.example.\(app)", appName: app.uppercased())])
    }

    func testSectionsOfGroups() {
        XCTAssertEqual(BarDrag.section(of: .hidden, swapped: false), .hidden)
        XCTAssertNil(BarDrag.section(of: .hidden, swapped: true), "swapped, Hidden lists Shown's apps")
        XCTAssertEqual(BarDrag.section(of: .alwaysHidden, swapped: true), .alwaysHidden)
        XCTAssertNil(BarDrag.section(of: .didntFit, swapped: false))
    }

    func testReorderWithinGroup() {
        let row = [tile("a"), tile("b"), tile("c")]
        // Drag a to the end.
        XCTAssertEqual(BarDrag.outcome(dragging: row[0], from: .hidden, onto: .hidden, gap: 3, row: row, positions: positions),
                       .reorder(.hidden, order: ["status:com.example.b::Item-0", "status:com.example.c::Item-0", "status:com.example.a::Item-0"], appsIn: []))
        // Drag c to the front.
        XCTAssertEqual(BarDrag.outcome(dragging: row[2], from: .hidden, onto: .hidden, gap: 0, row: row, positions: positions),
                       .reorder(.hidden, order: ["status:com.example.c::Item-0", "status:com.example.a::Item-0", "status:com.example.b::Item-0"], appsIn: []))
        // Dropped either side of itself: nothing changes.
        XCTAssertEqual(BarDrag.outcome(dragging: row[1], from: .hidden, onto: .hidden, gap: 1, row: row, positions: positions), .none)
        XCTAssertEqual(BarDrag.outcome(dragging: row[1], from: .hidden, onto: .hidden, gap: 2, row: row, positions: positions), .none)
    }

    func testDropOnOtherGroupMovesTheAppThereAtTheDropPosition() {
        let always = [tile("x"), tile("y")]
        XCTAssertEqual(BarDrag.outcome(dragging: tile("b"), from: .hidden, onto: .alwaysHidden, gap: 1, row: always, positions: positions),
                       .reorder(.alwaysHidden, order: ["status:com.example.x::Item-0", "status:com.example.b::Item-0", "status:com.example.y::Item-0"],
                                appsIn: ["com.example.b"]))
        XCTAssertEqual(BarDrag.outcome(dragging: tile("y"), from: .alwaysHidden, onto: .hidden, gap: 0, row: [tile("a")], positions: positions),
                       .reorder(.hidden, order: ["status:com.example.y::Item-0", "status:com.example.a::Item-0"], appsIn: ["com.example.y"]))
    }

    func testAppTileMovesAllItsItems() {
        let p = positions.merging(["status:com.example.m::One": 400, "status:com.example.m::Two": 300]) { a, _ in a }
        let app = BarTile(items: [Fixtures.item("status:com.example.m::One", bundle: "com.example.m", app: "M"),
                                  Fixtures.item("status:com.example.m::Two", bundle: "com.example.m", app: "M")])
        XCTAssertEqual(BarDrag.outcome(dragging: app, from: .hidden, onto: .hidden, gap: 0, row: [tile("a"), app], positions: p),
                       .reorder(.hidden, order: ["status:com.example.m::One", "status:com.example.m::Two", "status:com.example.a::Item-0"], appsIn: []))
    }

    func testNotAllowed() {
        let row = [tile("a"), tile("b")]
        // Without Menu Bar folder access.
        XCTAssertEqual(BarDrag.outcome(dragging: row[0], from: .hidden, onto: .hidden, gap: 2, row: row, positions: nil), .notAllowed)
        // From or onto "Didn't fit" (no section) or the swapped Hidden group.
        let didntFit = BarDrag.section(of: .didntFit, swapped: false)
        XCTAssertEqual(BarDrag.outcome(dragging: tile("c"), from: didntFit, onto: .hidden, gap: 0, row: row, positions: positions), .notAllowed)
        XCTAssertEqual(BarDrag.outcome(dragging: row[0], from: .hidden, onto: didntFit, gap: 0, row: [tile("c")], positions: positions), .notAllowed)
        XCTAssertEqual(BarDrag.outcome(dragging: row[0], from: .shown, onto: .hidden, gap: 0, row: row, positions: positions), .notAllowed)
        // A placeholder the order file has no key for.
        XCTAssertEqual(BarDrag.outcome(dragging: placeholder("q"), from: .hidden, onto: .hidden, gap: 0, row: row + [placeholder("q")], positions: positions), .notAllowed)
    }

    func testWhichTilesCanBeDragged() {
        XCTAssertTrue(BarDrag.canDrag(tile("a"), in: .hidden, swapped: false, positions: positions))
        XCTAssertTrue(BarDrag.canDrag(tile("x"), in: .alwaysHidden, swapped: true, positions: positions))
        XCTAssertFalse(BarDrag.canDrag(tile("a"), in: .hidden, swapped: false, positions: nil), "no access")
        XCTAssertFalse(BarDrag.canDrag(tile("a"), in: .didntFit, swapped: false, positions: positions))
        XCTAssertFalse(BarDrag.canDrag(tile("a"), in: .hidden, swapped: true, positions: positions))
        XCTAssertFalse(BarDrag.canDrag(placeholder("q"), in: .hidden, swapped: false, positions: positions))
        // A placeholder whose app the order file knows under its real key (fallback ID resolves).
        let known = ["status:com.example.q::Item-0": 100.0]
        XCTAssertTrue(BarDrag.canDrag(placeholder("q"), in: .hidden, swapped: false, positions: known))
    }
}
