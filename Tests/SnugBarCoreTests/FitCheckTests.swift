import XCTest
@testable import SnugBarCore

/// A full menu bar beside the notch (1470 pt wide, notch right edge at 824.5, so 645.5 pt for status items), read
/// while a five-item system monitor had just been moved to Shown and macOS had put its items into its own overflow.
/// Frames as reported, left to right; the VPN and display apps are hidden by SnugBar, their frames are stale.
final class FitCheckTests: XCTestCase {
    private let own = "app.snugbar.SnugBar"
    private let notch = Rect(x: 645.5, y: 0, width: 179, height: 32)
    private let available = FitPlanner.availableWidth(stripMinX: 0, stripMaxX: 1470, notchMaxX: 824.5, appMenusMaxX: nil)

    private let monitor = "com.example.stats"
    private let vpn = "com.example.vpn"
    private let display = "com.example.display"
    private let others = ["com.example.flux", "com.example.jiggle", "com.example.chat", "com.example.clips",
                          "com.example.wick", "com.example.input"]
    private var hidden: Set<String> { [vpn, display] }

    private func item(_ bundle: String, _ n: Int, x: Double, width: Double, overflowed: Bool = false, apple: Bool = false) -> MenuBarItem {
        MenuBarItem(id: ItemID(rawValue: "\(bundle.isEmpty ? "apple" : bundle)#\(n)"), ownerBundleID: bundle, ownerPID: 1,
                    appName: bundle, displayName: bundle, frame: Rect(x: x, y: 0, width: width, height: 33),
                    isAppleItem: apple, isOverflowed: overflowed, axIdentifier: nil)
    }

    private var monitorItems: [MenuBarItem] {
        [item(monitor, 0, x: 802.5, width: 71, overflowed: true), item(monitor, 1, x: 826.5, width: 47, overflowed: true),
         item(monitor, 2, x: 826.5, width: 47, overflowed: true), item(monitor, 3, x: 826.5, width: 47, overflowed: true)]
    }
    /// The monitor's fifth item: a stale frame, not on screen (it overlaps the input item).
    private var monitorStale: MenuBarItem { item(monitor, 4, x: 1020.5, width: 47) }
    /// The hidden display app's stale frame.
    private var displayStale: MenuBarItem { item(display, 0, x: 1010.5, width: 36) }

    private var onScreenApps: [MenuBarItem] {
        [item(others[0], 0, x: 868.5, width: 31), item(others[1], 0, x: 899.5, width: 29),
         item(others[2], 0, x: 928.5, width: 32), item(others[3], 0, x: 960.5, width: 34),
         item(others[4], 0, x: 994.5, width: 29), item(others[5], 0, x: 1023.5, width: 44)]
    }

    private var fixed: [MenuBarItem] {
        [item(own, 0, x: 1067.5, width: 38), item("", 1, x: 1113.5, width: 22, apple: true),
         item("", 2, x: 1151.5, width: 16, apple: true), item("", 3, x: 1183.5, width: 26, apple: true),
         item(own, 1, x: 1217.5, width: 32), item("", 4, x: 1257.5, width: 26, apple: true),
         item("", 5, x: 1299.5, width: 150.5, apple: true)]
    }

    /// The whole table, left to right.
    private var table: [MenuBarItem] {
        monitorItems + [item(vpn, 0, x: 840.5, width: 38, overflowed: true)] + onScreenApps.prefix(5)
            + [displayStale, monitorStale] + onScreenApps.suffix(1) + fixed
    }

    private var shown: Set<String> { Set(others + [monitor]) }

    /// What the running app does on a check: remember widths of the apps let through, then plan.
    private func check(_ items: [MenuBarItem], shown: Set<String>? = nil, remembered: [String: [MenuBarItem]] = [:],
                       movedNow: Set<String> = [], indicator: Bool = false, shortfall: Double = 0,
                       measurements: FitMeasurements = FitMeasurements()) -> FitCheck.Result {
        let isOnScreen: (String) -> Bool = { [hidden] in !hidden.contains($0) && !movedNow.contains($0) }
        var m = measurements
        m.record(items, excluding: [own], isOnScreen: isOnScreen)
        return FitCheck.run(FitCheck.Input(
            items: items, measurements: m, remembered: remembered, shownApps: shown ?? self.shown, ownBundleID: own,
            isOnScreen: isOnScreen, movedNow: movedNow, notch: notch, overflowIndicator: indicator,
            availableWidth: available, shortfall: shortfall
        ))
    }

    // MARK: - The reported table

    func testReportedTableMovesExactlyTheMonitor() {
        XCTAssertEqual(available, 645.5)
        let result = check(table)
        XCTAssertEqual(result.survey.geometry, FitPlanner.Geometry(fixedSpan: 382.5, thirdPartyGap: 0, junctionGap: 0))
        XCTAssertEqual(result.apps.first?.bundleID, monitor, "the overflowed app is the leftmost")
        XCTAssertEqual(result.apps.first?.width, 259)
        let plan = try! XCTUnwrap(result.plan)
        XCTAssertEqual(plan.moved, [monitor])
        XCTAssertEqual(plan.kept, others)
        // What stays: 382.5 + 199 + 8.
        XCTAssertEqual(plan.keptWidth, 589.5, accuracy: 0.001)
        XCTAssertTrue(plan.fits)
        XCTAssertEqual(result.survey.overflowedApps, [monitor])
    }

    func testReportedTableWithoutTheMonitorMovesNothing() {
        let items = table.filter { $0.ownerBundleID != monitor }
        let result = check(items, shown: Set(others))
        let plan = try! XCTUnwrap(result.plan)
        XCTAssertEqual(plan.moved, [])
        XCTAssertEqual(plan.requiredWidth, 589.5, accuracy: 0.001)
        XCTAssertFalse(result.survey.overflowSeen, "the hidden VPN app's stale overflowed frame is not a sign")
        XCTAssertEqual(FitSafetyNet.verdict(survey: result.survey, plan: plan, movedNow: [], settled: true, userBusy: false), .quiet)
    }

    func testStaleFramesDoNotChangeTheResult() {
        let without = table.filter { $0 != monitorStale && $0 != displayStale }
        let a = check(table), b = check(without)
        XCTAssertEqual(a.survey.geometry, b.survey.geometry)
        // Same decision and the same room for what stays (the stale item still counts in its app's width).
        XCTAssertEqual(a.plan?.moved, b.plan?.moved)
        XCTAssertEqual(a.plan?.kept, b.plan?.kept)
        XCTAssertEqual(a.plan?.keptWidth, b.plan?.keptWidth)
        let reasons = Dictionary(a.survey.ignored.map { ($0.id, $0.reason) }, uniquingKeysWith: { x, _ in x })
        XCTAssertEqual(reasons[monitorStale.id.rawValue], .appOverflowed)
        XCTAssertEqual(reasons[displayStale.id.rawValue], .notAllowed)
        XCTAssertEqual(reasons["\(vpn)#0"], .notAllowed)
        for n in 0..<4 { XCTAssertEqual(reasons["\(monitor)#\(n)"], .overflowed) }
        XCTAssertNil(reasons["\(others[4])#0"], "the items the stale frames overlap still measure")
        XCTAssertNil(reasons["\(others[5])#0"])
    }

    func testStaleFrameOfAnAppMacOSLetsThroughIsDroppedAsAnOverlap() {
        // Without the monitor's overflowed items (so its app isn't known to be in the overflow), its stale frame is
        // the one overlapping its neighbours most; the neighbours keep measuring.
        let items = onScreenApps.prefix(5) + [monitorStale] + onScreenApps.suffix(1) + fixed
        let result = check(Array(items))
        let overlapped = result.survey.ignored.filter { $0.reason == .overlaps }.map(\.id)
        XCTAssertEqual(overlapped, [monitorStale.id.rawValue])
        XCTAssertEqual(result.survey.geometry, FitPlanner.Geometry(fixedSpan: 382.5, thirdPartyGap: 0, junctionGap: 0))
        // The display app let through by mistake overlaps too: both stale frames go, the real ones stay.
        let both = FitSurvey.make(items: Array(items) + [displayStale], ownBundleID: own, shownApps: shown,
                                  planned: shown.union([display]), isOnScreen: { _ in true }, notch: notch)
        XCTAssertEqual(Set(both.ignored.filter { $0.reason == .overlaps }.map(\.id)),
                       [monitorStale.id.rawValue, displayStale.id.rawValue])
        XCTAssertEqual(both.geometry, result.survey.geometry)
    }

    func testOverflowedAppWithStackedFramesCountsTheSumOfItsWidths() {
        var m = FitMeasurements()
        m.record(table, excluding: [own], isOnScreen: { [hidden] in !hidden.contains($0) })
        XCTAssertEqual(m.apps[monitor]?.width, 71 + 47 * 4)
        XCTAssertEqual(m.apps[monitor]?.itemCount, 5)
        XCTAssertEqual(m.ordered(shown).first?.bundleID, monitor)
        // No « button reported (nothing flagged overflowed): the stacked frames behind and beside the notch still
        // don't measure, and the app still counts whole, leftmost.
        let flat = table.map { item -> MenuBarItem in var i = item; i.isOverflowed = false; return i }
        let result = check(flat)
        XCTAssertEqual(result.survey.geometry, FitPlanner.Geometry(fixedSpan: 382.5, thirdPartyGap: 0, junctionGap: 0))
        XCTAssertEqual(result.survey.overflowedApps, [monitor], "an item behind the notch is off the bar")
        XCTAssertEqual(result.survey.ignored.first { $0.id == "\(monitor)#0" }?.reason, .behindNotch)
        XCTAssertEqual(result.survey.ignored.first { $0.id == "\(monitor)#1" }?.reason, .appOverflowed)
        XCTAssertEqual(result.plan?.moved, [monitor])
    }

    // MARK: - Root cause: the app missing from the tree

    /// The monitor's rows in the report were remembered ones (`visible` false even for the item not flagged
    /// overflowed): none of its items was in the menu bar's tree, and it had never been measured collapsed, so it
    /// wasn't a candidate and the plan said everything fits.
    func testShownAppMissingFromTheTreeCountsWithItsRememberedWidths() {
        let live = onScreenApps + fixed
        // Before: no remembered items, so the monitor is unmeasured and nothing moves.
        let blind = check(live)
        XCTAssertEqual(blind.unmeasured, [monitor])
        XCTAssertEqual(blind.plan?.moved, [])
        XCTAssertEqual(blind.plan?.requiredWidth ?? 0, 589.5, accuracy: 0.001)
        // Now: the items remembered from when it was last seen (revealed, or focused to open one) count.
        let result = check(live, remembered: [monitor: monitorItems + [monitorStale]])
        XCTAssertEqual(result.unmeasured, [])
        XCTAssertEqual(result.offBar, [monitor])
        XCTAssertEqual(result.apps.first, FitPlanner.App(bundleID: monitor, width: 259, itemCount: 5))
        XCTAssertEqual(result.plan?.moved, [monitor])
    }

    func testMeasuredAppMissingFromTheTreeIsLeftmost() {
        // Measured on screen earlier at the right of the other apps; now let through but not in the tree.
        var m = FitMeasurements()
        m.record([item(monitor, 0, x: 1030, width: 259)], excluding: [own], isOnScreen: { _ in true })
        let result = check(onScreenApps + fixed, measurements: m)
        XCTAssertEqual(result.offBar, [monitor])
        XCTAssertEqual(result.apps.first?.bundleID, monitor)
        XCTAssertEqual(result.plan?.moved, [monitor], "not the apps actually on screen")
    }

    // MARK: - Safety net

    func testSafetyNetFiresWhenMacOSOverflowsThoughThePlanFits() {
        // An app whose remembered width is far too small: the estimate says it fits, macOS overflows it.
        var m = FitMeasurements()
        m.record([item(monitor, 0, x: 840, width: 20)], excluding: [own], isOnScreen: { _ in true })
        var live = onScreenApps + fixed
        live.insert(item(monitor, 0, x: 826.5, width: 47, overflowed: true), at: 0)
        // The live record would fix the width; keep the wrong one to model a bad estimate.
        let result = FitCheck.run(FitCheck.Input(
            items: live, measurements: m, shownApps: shown, ownBundleID: own, isOnScreen: { _ in true }, notch: notch,
            availableWidth: available
        ))
        let plan = try! XCTUnwrap(result.plan)
        XCTAssertEqual(plan.moved, [])
        XCTAssertEqual(result.survey.overflowedApps, [monitor])

        var net = FitSafetyNet()
        let now = Date(timeIntervalSinceReferenceDate: 1000)
        XCTAssertEqual(net.decide(survey: result.survey, plan: plan, movedNow: [], settled: true, userBusy: true, now: now),
                       .userBusy, "never while the user ⌘-drags or opens an item")
        XCTAssertEqual(net.decide(survey: result.survey, plan: plan, movedNow: [], settled: false, userBusy: false, now: now),
                       .settling)
        XCTAssertEqual(net.shortfall, 0)
        XCTAssertEqual(net.decide(survey: result.survey, plan: plan, movedNow: [], settled: true, userBusy: false, now: now),
                       .fire(monitor), "the leftmost shown app")
        // The room the estimate thought was left is learnt: with it the app stays out, even with the return margin.
        let spare = plan.availableWidth - plan.keptWidth
        XCTAssertEqual(net.shortfall, spare + 1, accuracy: 0.001)
        let again = FitCheck.run(FitCheck.Input(
            items: onScreenApps + fixed, measurements: m, shownApps: shown, ownBundleID: own,
            isOnScreen: { $0 != self.monitor }, movedNow: [monitor], notch: notch, availableWidth: available,
            shortfall: net.shortfall
        ))
        XCTAssertEqual(again.plan?.moved, [monitor])
        XCTAssertEqual(FitSafetyNet.verdict(survey: again.survey, plan: again.plan, movedNow: [monitor], settled: true, userBusy: false),
                       .quiet)
    }

    func testSafetyNetIsBoundedAndKeyedToTheBar() {
        let survey = FitSurvey.make(items: [], ownBundleID: own, shownApps: [], planned: [], isOnScreen: { _ in true },
                                    overflowIndicator: true)
        XCTAssertTrue(survey.overflowSeen, "the « button alone is a sign")
        let plan = FitPlanner.plan(apps: [FitPlanner.App(bundleID: "com.example.a", width: 10)],
                                   geometry: FitPlanner.Geometry(fixedSpan: 100), availableWidth: 500)
        var net = FitSafetyNet()
        let t0 = Date(timeIntervalSinceReferenceDate: 0)
        _ = net.shortfall(for: "bar")
        for i in 0..<FitSafetyNet.maxRounds {
            XCTAssertEqual(net.decide(survey: survey, plan: plan, movedNow: [], settled: true, userBusy: false,
                                      now: t0.addingTimeInterval(Double(i))), .fire("com.example.a"))
        }
        XCTAssertEqual(net.decide(survey: survey, plan: plan, movedNow: [], settled: true, userBusy: false,
                                  now: t0.addingTimeInterval(10)), .roundLimit)
        XCTAssertEqual(net.decide(survey: survey, plan: plan, movedNow: [], settled: true, userBusy: false,
                                  now: t0.addingTimeInterval(FitSafetyNet.window + 1)), .fire("com.example.a"))
        XCTAssertGreaterThan(net.shortfall(for: "bar"), 0)
        XCTAssertEqual(net.shortfall(for: "another bar"), 0, "a different screen, room or set of apps starts afresh")
        // The plan moving apps itself, or nothing left to move: no extra move.
        let moving = FitPlanner.plan(apps: [FitPlanner.App(bundleID: "com.example.a", width: 900)],
                                     geometry: FitPlanner.Geometry(fixedSpan: 100), availableWidth: 500)
        XCTAssertEqual(FitSafetyNet.verdict(survey: survey, plan: moving, movedNow: [], settled: true, userBusy: false), .planMoves)
        XCTAssertEqual(FitSafetyNet.verdict(survey: survey, plan: moving, movedNow: ["com.example.a"], settled: true, userBusy: false),
                       .nothingToMove)
    }

    func testOverflowedItemsWithoutAnOwnerAreASign() {
        let items = [item("", 0, x: 826.5, width: 47, overflowed: true)] + onScreenApps + fixed
        let survey = FitSurvey.make(items: items, ownBundleID: own, shownApps: Set(others), planned: Set(others),
                                    isOnScreen: { _ in true }, notch: notch)
        XCTAssertEqual(survey.unattributedOverflow, 1)
        XCTAssertTrue(survey.overflowSeen)
        XCTAssertEqual(survey.ignored.map(\.reason), [.unknownOwner])
    }
}
