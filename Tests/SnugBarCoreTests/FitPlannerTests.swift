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

    /// Fixed items 300 pt from the first one's left edge to the last one's right edge; third-party items edge to edge.
    private let span300 = FitPlanner.Geometry(fixedSpan: 300)

    func testNothingToMoveWhenItFits() {
        let plan = FitPlanner.plan(apps: apps([30, 30, 60]), geometry: span300, availableWidth: notched)
        XCTAssertEqual(plan.moved, [])
        XCTAssertEqual(plan.kept.count, 3)
        XCTAssertTrue(plan.fits)
        XCTAssertEqual(plan.requiredWidth, 300 + 120 + FitPlanner.defaultMargin)
    }

    func testMovesLeftmostAppsUntilItFitsBesideTheNotch() {
        // 300 fixed + 8 margin leaves 347 for apps: 100 + 120 + 90 + 60 = 370 is 23 too many.
        let plan = FitPlanner.plan(apps: apps([100, 120, 90, 60]), geometry: span300, availableWidth: notched)
        XCTAssertEqual(plan.moved, ["com.example.app0"])
        XCTAssertEqual(plan.kept, ["com.example.app1", "com.example.app2", "com.example.app3"])
        XCTAssertTrue(plan.fits)
        XCTAssertEqual(plan.keptWidth, 300 + 270 + 8)
    }

    func testSameAppsFitWithoutANotch() {
        let plan = FitPlanner.plan(apps: apps([100, 120, 90, 60]), geometry: span300, availableWidth: flat)
        XCTAssertEqual(plan.moved, [])
        XCTAssertTrue(plan.fits)
    }

    func testThirdPartyAndJunctionGapsCount() {
        // 4 items: 3 boundaries of 10 pt between them and one junction of 6 pt to the fixed items.
        let a = apps([50, 50, 50, 50])
        let tight = FitPlanner.Geometry(fixedSpan: 40)
        XCTAssertEqual(FitPlanner.plan(apps: a, geometry: tight, availableWidth: 240, margin: 0).moved, [])
        let spaced = FitPlanner.plan(apps: a, geometry: FitPlanner.Geometry(fixedSpan: 40, thirdPartyGap: 10, junctionGap: 6),
                                     availableWidth: 240, margin: 0)
        XCTAssertEqual(spaced.requiredWidth, 40 + 200 + 6 + 30)
        XCTAssertEqual(spaced.moved, ["com.example.app0"])
        XCTAssertEqual(spaced.keptWidth, 40 + 150 + 6 + 20)
        // The junction defaults to the third-party gap.
        XCTAssertEqual(FitPlanner.Geometry(fixedSpan: 40, thirdPartyGap: 3).junctionGap, 3)
    }

    func testMultiItemAppsMoveWhole() {
        let a = [FitPlanner.App(bundleID: "com.example.meters", width: 160, itemCount: 4), FitPlanner.App(bundleID: "com.example.chat", width: 30)]
        let plan = FitPlanner.plan(apps: a, geometry: FitPlanner.Geometry(fixedSpan: 100), availableWidth: 200, margin: 0)
        XCTAssertEqual(plan.moved, ["com.example.meters"])
        XCTAssertEqual(plan.kept, ["com.example.chat"])
    }

    func testEverythingTooWide() {
        let plan = FitPlanner.plan(apps: apps([40, 40]), geometry: FitPlanner.Geometry(fixedSpan: 700), availableWidth: notched)
        XCTAssertEqual(plan.moved, ["com.example.app0", "com.example.app1"])
        XCTAssertEqual(plan.kept, [])
        XCTAssertFalse(plan.fits)
    }

    func testUnknownRoomMovesNothing() {
        let plan = FitPlanner.plan(apps: apps([40, 40]), geometry: FitPlanner.Geometry(fixedSpan: 100), availableWidth: 0)
        XCTAssertEqual(plan.moved, [])
        XCTAssertFalse(plan.fits)
    }

    func testNoAppsFits() {
        let plan = FitPlanner.plan(apps: [], geometry: FitPlanner.Geometry(fixedSpan: 200, thirdPartyGap: 4), availableWidth: notched)
        XCTAssertEqual(plan.moved, [])
        XCTAssertTrue(plan.fits)
        XCTAssertEqual(plan.requiredWidth, 200 + 8, "no junction gap without third-party items")
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

/// The estimate on frames as a 14" notched MacBook reports them (made-up apps): third-party items edge to edge, then
/// SnugBar's icon, Wi-Fi, Bluetooth, Battery, a SnugBar spacer, Control Center and the clock.
final class FitGeometryTests: XCTestCase {
    private let available = FitPlanner.availableWidth(stripMinX: 0, stripMaxX: 1470, notchMaxX: 824.5, appMenusMaxX: nil)
    private let own = "app.snugbar.SnugBar"
    private let cc = "com.apple.controlcenter"

    private func item(_ bundle: String, _ name: String, x: Double, width: Double, apple: Bool = false) -> MenuBarItem {
        MenuBarItem(id: ItemID(rawValue: "status:\(bundle)::\(name)"), ownerBundleID: bundle, ownerPID: 1, appName: bundle,
                    displayName: name, frame: Rect(x: x, y: 0, width: width, height: 33), isAppleItem: apple, isOverflowed: false,
                    axIdentifier: nil)
    }

    private var thirdParty: [MenuBarItem] {
        [item("com.example.chat", "Chat", x: 928.5, width: 32), item("com.example.clipboard", "Clips", x: 960.5, width: 34),
         item("com.example.bar", "Bar", x: 994.5, width: 29), item("com.example.input", "Input", x: 1023.5, width: 44)]
    }

    private var fixed: [MenuBarItem] {
        [item(own, "Icon", x: 1067.5, width: 38), item(cc, "WiFi", x: 1113.5, width: 22, apple: true),
         item(cc, "Bluetooth", x: 1151.5, width: 16, apple: true), item(cc, "Battery", x: 1183.5, width: 26, apple: true),
         item(own, "Spacer", x: 1217.5, width: 32), item(cc, "ControlCenter", x: 1257.5, width: 26, apple: true),
         item(cc, "Clock", x: 1299.5, width: 150.5, apple: true)]
    }

    /// What the app does (`FitCheck`): measure the on-screen frames, plan the shown apps with their remembered widths.
    private func plan(_ items: [MenuBarItem], measurements: FitMeasurements, shown: Set<String>, movedNow: Set<String> = [],
                      onScreen: Set<String>? = nil) -> (FitPlanner.Geometry, FitPlanner.Plan) {
        let result = FitCheck.run(FitCheck.Input(
            items: items, measurements: measurements, shownApps: shown, ownBundleID: own,
            isOnScreen: { onScreen?.contains($0) ?? true }, movedNow: movedNow, availableWidth: available
        ))
        return (result.survey.geometry, result.plan!)
    }

    private func measured(_ items: [MenuBarItem]) -> FitMeasurements {
        var m = FitMeasurements()
        m.record(items, excluding: [own], isOnScreen: { _ in true })
        return m
    }

    func testMeasuredFramesFit() {
        XCTAssertEqual(available, 645.5)
        let items = thirdParty + fixed
        let shown = Set(thirdParty.map(\.ownerBundleID))
        let (geometry, plan) = plan(items, measurements: measured(items), shown: shown)
        XCTAssertEqual(geometry.fixedSpan, 1450 - 1067.5)
        XCTAssertEqual(geometry.thirdPartyGap, 0, "third-party frames sit edge to edge")
        XCTAssertEqual(geometry.junctionGap, 0)
        XCTAssertEqual(geometry.insideWidth, 0)
        // The real span of everything (1450 - 928.5) plus the margin; one Apple gap per item made it 617.5.
        XCTAssertEqual(plan.requiredWidth, 521.5 + FitPlanner.defaultMargin, accuracy: 0.001)
        XCTAssertEqual(plan.moved, [])
        XCTAssertTrue(plan.fits)
    }

    func testAddedAppsMoveOnlyTheLeftmostNeeded() {
        // 645.5 - 529.5 leaves 116 pt. Apps further left, measured earlier and off screen now (remembered widths).
        func run(_ extra: [(bundle: String, width: Double, count: Int)]) -> FitPlanner.Plan {
            var x = 300.0
            var earlier: [MenuBarItem] = []
            for app in extra {
                for n in 0..<app.count {
                    let w = app.width / Double(app.count)
                    earlier.append(item(app.bundle, "Item-\(n)", x: x, width: w))
                    x += w
                }
            }
            var m = measured(earlier)
            m.record(thirdParty, excluding: [own], isOnScreen: { _ in true })
            let onScreen = Set(thirdParty.map(\.ownerBundleID))
            return plan(thirdParty + fixed, measurements: m, shown: onScreen.union(extra.map(\.bundle)), onScreen: onScreen).1
        }
        let full = run([("com.example.meters", 60, 2), ("com.example.notes", 56, 1)])
        XCTAssertEqual(full.requiredWidth, 645.5, accuracy: 0.001)
        XCTAssertEqual(full.moved, [], "exactly full still fits")

        let one = run([("com.example.meters", 30, 1), ("com.example.notes", 40, 1), ("com.example.weather", 50, 1)])
        XCTAssertEqual(one.requiredWidth, 649.5, accuracy: 0.001)
        XCTAssertEqual(one.moved, ["com.example.meters"])
        XCTAssertEqual(one.keptWidth, 619.5, accuracy: 0.001)

        // Five meter items (one app) and two more apps: the meters and the next app go, nothing else.
        let two = run([("com.example.meters", 150, 5), ("com.example.notes", 40, 1), ("com.example.weather", 100, 1)])
        XCTAssertEqual(two.moved, ["com.example.meters", "com.example.notes"])
        XCTAssertEqual(two.kept.first, "com.example.weather")
        XCTAssertTrue(two.fits)
    }

    func testAppBetweenAppleItemsIsCountedOnce() {
        let items = [
            item("com.example.chat", "Chat", x: 928.5, width: 32), item("com.example.clipboard", "Clips", x: 960.5, width: 34),
            item(own, "Icon", x: 994.5, width: 38), item(cc, "WiFi", x: 1040.5, width: 22, apple: true),
            item("com.example.vpn", "VPN", x: 1070.5, width: 24), item(cc, "Bluetooth", x: 1102.5, width: 16, apple: true),
            item(cc, "Clock", x: 1126.5, width: 150.5, apple: true),
        ]
        let shown: Set<String> = ["com.example.chat", "com.example.clipboard", "com.example.vpn"]
        let (geometry, plan) = plan(items, measurements: measured(items), shown: shown)
        XCTAssertEqual(geometry.insideWidth, 24)
        XCTAssertEqual(geometry.fixedSpan, 1277 - 994.5 - 24)
        XCTAssertEqual(plan.requiredWidth, (1277 - 928.5) + FitPlanner.defaultMargin, accuracy: 0.001)
        // The app among the fixed items is the last to go.
        XCTAssertEqual(plan.kept.last, "com.example.vpn")
    }

    func testMeasuredGaps() {
        let tp = [Rect(x: 900, y: 0, width: 30, height: 33), Rect(x: 934, y: 0, width: 30, height: 33),
                  Rect(x: 968, y: 0, width: 30, height: 33)]
        let fx = [Rect(x: 1006, y: 0, width: 30, height: 33), Rect(x: 1052, y: 0, width: 40, height: 33)]
        let g = FitPlanner.Geometry.measure(fixed: fx, thirdParty: tp)
        XCTAssertEqual(g.thirdPartyGap, 4)
        XCTAssertEqual(g.junctionGap, 8)
        XCTAssertEqual(g.fixedSpan, 86)
        // Nothing third-party on screen: no gap to measure, and no fallback to Apple's gap.
        let alone = FitPlanner.Geometry.measure(fixed: fx, thirdParty: [])
        XCTAssertEqual(alone.thirdPartyGap, 0)
        XCTAssertEqual(alone.junctionGap, 0)
        // The nearest third-party item far from the fixed items: the junction falls back to the third-party gap.
        let far = FitPlanner.Geometry.measure(fixed: fx, thirdParty: Array(tp.prefix(2)))
        XCTAssertEqual(far.junctionGap, 4)
        XCTAssertEqual(FitPlanner.Geometry.measure(fixed: [], thirdParty: tp).fixedSpan, 0)
    }

    func testAppNearTheEdgeDoesNotFlipFlop() {
        // An app 112 pt wide: 641.5 needed, 4 pt to spare (less than the 8 pt return margin).
        var edge = [FitPlanner.App(bundleID: "com.example.meters", width: 112)]
            + thirdParty.map { FitPlanner.App(bundleID: $0.ownerBundleID, width: $0.frame.width) }
        let geometry = FitPlanner.Geometry(fixedSpan: 382.5)
        let shownNow = FitPlanner.plan(apps: edge, geometry: geometry, availableWidth: available)
        XCTAssertEqual(shownNow.moved, [], "on screen and it fits: it stays")
        let outNow = FitPlanner.plan(apps: edge, geometry: geometry, availableWidth: available, movedNow: ["com.example.meters"])
        XCTAssertEqual(outNow.moved, ["com.example.meters"], "already out: it needs 8 pt more to come back")
        XCTAssertEqual(outNow.heldBack, ["com.example.meters"])
        XCTAssertTrue(outNow.fits)
        // With room to spare it comes back.
        edge[0].width = 100
        let back = FitPlanner.plan(apps: edge, geometry: geometry, availableWidth: available, movedNow: ["com.example.meters"])
        XCTAssertEqual(back.moved, [])
        XCTAssertEqual(back.heldBack, [])
        // Once it doesn't fit at all it goes out.
        edge[0].width = 120
        let over = FitPlanner.plan(apps: edge, geometry: geometry, availableWidth: available)
        XCTAssertEqual(over.moved, ["com.example.meters"])
        XCTAssertEqual(over.heldBack, [])
    }

    func testNoNotchUsesTheSameEstimate() {
        let items = thirdParty + fixed
        let shown = Set(thirdParty.map(\.ownerBundleID))
        let apps = measured(items).ordered(shown)
        let geometry = FitPlanner.Geometry.measure(fixed: fixed.map(\.frame), thirdParty: thirdParty.map(\.frame))
        // 530 pt right of the app menus: everything (529.5) fits.
        let flat = FitPlanner.availableWidth(stripMinX: 0, stripMaxX: 1470, notchMaxX: nil, appMenusMaxX: 940)
        XCTAssertEqual(FitPlanner.plan(apps: apps, geometry: geometry, availableWidth: flat).moved, [])
        // 470 pt: the two leftmost apps (66 pt) go.
        let narrow = FitPlanner.availableWidth(stripMinX: 0, stripMaxX: 1470, notchMaxX: nil, appMenusMaxX: 1000)
        XCTAssertEqual(FitPlanner.plan(apps: apps, geometry: geometry, availableWidth: narrow).moved,
                       ["com.example.chat", "com.example.clipboard"])
        XCTAssertEqual(FitPlanner.plan(apps: apps, geometry: geometry, availableWidth: 0).moved, [], "unknown room")
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

    func testRememberedAndOffBarAppsAreLeftmost() {
        var m = FitMeasurements()
        m.record([item(Fixtures.meters, x: 830, width: 40, overflowed: true), item(Fixtures.chat, x: 900, width: 30),
                  item(Fixtures.clipboard, x: 940, width: 24)], isOnScreen: { _ in true })
        // Remembered items only fill apps never measured; zero-width remembered items don't count.
        m.adopt([Fixtures.chat: [item(Fixtures.chat, x: 0, width: 99)],
                 "com.example.notes": [item("com.example.notes", x: 1000, width: 20), item("com.example.notes", x: 0, width: 0, index: 1)]],
                for: [Fixtures.chat, "com.example.notes"])
        XCTAssertEqual(m.apps[Fixtures.chat]?.width, 30)
        XCTAssertEqual(m.apps["com.example.notes"]?.width, 20)
        XCTAssertEqual(m.apps["com.example.notes"]?.itemCount, 1)
        // The clipboard app went missing from the tree: off the bar like the remembered one (the two keep their
        // left-to-right order), left of the overflowed and on-screen apps. Marking twice changes nothing.
        m.markOffBar([Fixtures.clipboard, Fixtures.meters])
        m.markOffBar([Fixtures.clipboard])
        XCTAssertEqual(m.ordered([Fixtures.meters, Fixtures.chat, Fixtures.clipboard, "com.example.notes"]).map(\.bundleID),
                       [Fixtures.clipboard, "com.example.notes", Fixtures.meters, Fixtures.chat])
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
