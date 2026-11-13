import XCTest
@testable import SnugBarCore

final class FitPlannerTests: XCTestCase {
    // A made-up notched screen 1470 pt wide whose notch ends at x = 815: 655 pt for status items.
    private let notched = FitPlanner.availableWidth(stripMinX: 0, stripMaxX: 1470, notchMaxX: 815, appMenusMaxX: 400)
    // A made-up 1920 pt screen without a notch, frontmost app's menus ending at x = 600.
    private let flat = FitPlanner.availableWidth(stripMinX: 0, stripMaxX: 1920, notchMaxX: nil, appMenusMaxX: 600)

    private func apps(_ widths: [Double]) -> [FitPlanner.App] {
        widths.enumerated().map { FitPlanner.App(bundleID: "com.example.app\($0.offset)", width: $0.element) }
    }

    func testAvailableWidth() {
        XCTAssertEqual(notched, 655, "the notch, not the app menus, limits a notched screen")
        XCTAssertEqual(flat, 1320)
        XCTAssertEqual(FitPlanner.availableWidth(stripMinX: 1920, stripMaxX: 3840, notchMaxX: nil, appMenusMaxX: nil), 1920)
        XCTAssertEqual(FitPlanner.availableWidth(stripMinX: 0, stripMaxX: 100, notchMaxX: 200, appMenusMaxX: nil), 0)
    }

    func testNothingToMoveWhenItFits() {
        let plan = FitPlanner.plan(apps: apps([30, 30, 60]), fixedWidth: 300, fixedItemCount: 6, availableWidth: notched)
        XCTAssertEqual(plan.moved, [])
        XCTAssertEqual(plan.kept.count, 3)
        XCTAssertTrue(plan.fits)
        XCTAssertEqual(plan.requiredWidth, 300 + 120 + FitPlanner.defaultMargin)
    }

    func testMovesLeftmostAppsUntilItFitsBesideTheNotch() {
        // 300 fixed + 8 margin leaves 347 for apps: 100 + 120 + 90 + 60 = 370 is 23 too many.
        let plan = FitPlanner.plan(apps: apps([100, 120, 90, 60]), fixedWidth: 300, fixedItemCount: 6, availableWidth: notched)
        XCTAssertEqual(plan.moved, ["com.example.app0"])
        XCTAssertEqual(plan.kept, ["com.example.app1", "com.example.app2", "com.example.app3"])
        XCTAssertTrue(plan.fits)
        XCTAssertEqual(plan.keptWidth, 300 + 270 + 8)
    }

    func testSameAppsFitWithoutANotch() {
        let plan = FitPlanner.plan(apps: apps([100, 120, 90, 60]), fixedWidth: 300, fixedItemCount: 6, availableWidth: flat)
        XCTAssertEqual(plan.moved, [])
        XCTAssertTrue(plan.fits)
    }

    func testSpacingCounts() {
        // 4 items + 1 fixed = 4 gaps of 10 pt push it over.
        let a = apps([50, 50, 50, 50])
        XCTAssertEqual(FitPlanner.plan(apps: a, fixedWidth: 40, fixedItemCount: 1, availableWidth: 260, itemSpacing: 0, margin: 0).moved, [])
        let spaced = FitPlanner.plan(apps: a, fixedWidth: 40, fixedItemCount: 1, availableWidth: 260, itemSpacing: 10, margin: 0)
        XCTAssertEqual(spaced.moved, ["com.example.app0"])
        XCTAssertEqual(spaced.keptWidth, 40 + 150 + 30)
    }

    func testMultiItemAppsMoveWhole() {
        let a = [FitPlanner.App(bundleID: "com.example.meters", width: 160, itemCount: 4), FitPlanner.App(bundleID: "com.example.chat", width: 30)]
        let plan = FitPlanner.plan(apps: a, fixedWidth: 100, fixedItemCount: 2, availableWidth: 200, margin: 0)
        XCTAssertEqual(plan.moved, ["com.example.meters"])
        XCTAssertEqual(plan.kept, ["com.example.chat"])
    }

    func testEverythingTooWide() {
        let plan = FitPlanner.plan(apps: apps([40, 40]), fixedWidth: 700, fixedItemCount: 8, availableWidth: notched)
        XCTAssertEqual(plan.moved, ["com.example.app0", "com.example.app1"])
        XCTAssertEqual(plan.kept, [])
        XCTAssertFalse(plan.fits)
    }

    func testUnknownRoomMovesNothing() {
        let plan = FitPlanner.plan(apps: apps([40, 40]), fixedWidth: 100, fixedItemCount: 2, availableWidth: 0)
        XCTAssertEqual(plan.moved, [])
        XCTAssertFalse(plan.fits)
    }

    func testNoAppsFits() {
        let plan = FitPlanner.plan(apps: [], fixedWidth: 200, fixedItemCount: 5, availableWidth: notched)
        XCTAssertEqual(plan.moved, [])
        XCTAssertTrue(plan.fits)
    }

    func testTypicalGap() {
        let frames = [
            Rect(x: 1000, y: 0, width: 30, height: 33), Rect(x: 1034, y: 0, width: 30, height: 33),
            Rect(x: 1068, y: 0, width: 40, height: 33), Rect(x: 1112, y: 0, width: 30, height: 33),
            Rect(x: 1300, y: 0, width: 30, height: 33), // far away: ignored
        ]
        XCTAssertEqual(FitPlanner.typicalGap(frames), 4)
        XCTAssertEqual(FitPlanner.typicalGap([]), 0)
    }
}

final class FitMeasurementsTests: XCTestCase {
    private func item(_ bundle: String, x: Double, width: Double, overflowed: Bool = false, index: Int = 0) -> MenuBarItem {
        MenuBarItem(
            id: .indexed(owner: bundle, index: index), ownerBundleID: bundle, ownerPID: 1, appName: bundle, displayName: bundle,
            frame: Rect(x: x, y: 0, width: width, height: 33), isAppleItem: false, isOverflowed: overflowed, axIdentifier: nil
        )
    }

    func testRecordsVisibleAppsAndOrdersOverflowedFirst() {
        var m = FitMeasurements()
        m.record([
            item(Fixtures.meters, x: 830, width: 40, overflowed: true),
            item(Fixtures.chat, x: 900, width: 30),
            item(Fixtures.clipboard, x: 940, width: 24, index: 0),
            item(Fixtures.clipboard, x: 970, width: 26, index: 1),
            Fixtures.item("module:Clock", bundle: "com.apple.controlcenter", app: "Clock", x: 1300, apple: true),
        ], isOnScreen: { _ in true })
        let ordered = m.ordered([Fixtures.meters, Fixtures.chat, Fixtures.clipboard, "com.example.unmeasured"])
        XCTAssertEqual(ordered.map(\.bundleID), [Fixtures.meters, Fixtures.chat, Fixtures.clipboard])
        XCTAssertEqual(ordered.last?.width, 50)
        XCTAssertEqual(ordered.last?.itemCount, 2)
        XCTAssertNil(m.apps["com.apple.controlcenter"], "Apple's items are fixed, not measured")
    }

    func testHiddenAppsKeepTheirLastMeasure() {
        var m = FitMeasurements()
        m.record([item(Fixtures.chat, x: 900, width: 30)], isOnScreen: { _ in true })
        // Now hidden: a stale lingering frame must not overwrite the measure.
        m.record([item(Fixtures.chat, x: 0, width: 0)], isOnScreen: { $0 != Fixtures.chat })
        XCTAssertEqual(m.apps[Fixtures.chat]?.width, 30)
        m.keepOnly([])
        XCTAssertTrue(m.apps.isEmpty)
    }
}
