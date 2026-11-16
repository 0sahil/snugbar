import XCTest
@testable import SnugBarCore

final class ZenAndBarStateTests: XCTestCase {
    private let own = "app.snugbar.SnugBar"

    private var sections: AppSectionMap {
        var s = AppSectionMap()
        s.set(.shown, forBundleID: Fixtures.clipboard)
        s.set(.alwaysHidden, forBundleID: Fixtures.chat)
        return s
    }

    private let candidates: Set<String> = [Fixtures.meters, Fixtures.clipboard, Fixtures.chat, "app.snugbar.SnugBar"]

    func testZenAllowsOnlySnugBar() {
        for reveal in RevealLevel.allCases {
            for swapped in [false, true] {
                let state = BarState(reveal: reveal, swapped: swapped, zen: true)
                XCTAssertEqual(state.visibleSections, [])
                XCTAssertEqual(state.menuBarReveal, .collapsed)
                XCTAssertEqual(
                    VisibilityPlanner.plan(state: state, sections: sections, candidates: candidates, alwaysAllowed: [own]),
                    .allow([own])
                )
            }
        }
    }

    func testZenHidesEvenWhenEverythingIsShown() {
        let everythingShown = AppSectionMap(defaultSection: .shown)
        let plan = VisibilityPlanner.plan(state: BarState(zen: true), sections: everythingShown, candidates: candidates, alwaysAllowed: [own])
        XCTAssertEqual(plan, .allow([own]))
        XCTAssertEqual(VisibilityPlanner.plan(state: BarState(zen: true), sections: everythingShown, candidates: [], alwaysAllowed: []), .allow([]))
    }

    func testRevealInBarKeepsTheMenuBarCollapsed() {
        let inBar = BarState(reveal: .expanded, revealInBar: true)
        XCTAssertFalse(inBar.isCollapsed, "auto-collapse still sees a reveal")
        XCTAssertEqual(inBar.menuBarReveal, .collapsed)
        XCTAssertEqual(inBar.visibleSections, [.shown])
        let plan = VisibilityPlanner.plan(state: inBar, sections: sections, candidates: candidates, alwaysAllowed: [own])
        XCTAssertEqual(plan, .allow([Fixtures.clipboard, own]))
        let all = BarState(reveal: .all, revealInBar: true)
        XCTAssertEqual(VisibilityPlanner.plan(state: all, sections: sections, candidates: candidates, alwaysAllowed: [own]), plan)
    }

    func testOverflowHiddenAppsLeaveTheCollapsedBarOnly() {
        var s = sections
        s.set(.shown, forBundleID: Fixtures.meters)
        let overflow: Set<String> = [Fixtures.meters, own]
        let collapsed = VisibilityPlanner.plan(state: .initial, sections: s, candidates: candidates, alwaysAllowed: [own], overflowHidden: overflow)
        XCTAssertEqual(collapsed, .allow([Fixtures.clipboard, own]), "SnugBar itself is never dropped")
        let inBar = VisibilityPlanner.plan(state: BarState(reveal: .expanded, revealInBar: true), sections: s, candidates: candidates,
                                           alwaysAllowed: [own], overflowHidden: overflow)
        XCTAssertEqual(inBar, collapsed, "the SnugBar Bar lists them; the menu bar still lacks room")
        let expanded = VisibilityPlanner.plan(state: BarState(reveal: .expanded), sections: s, candidates: candidates,
                                              alwaysAllowed: [own], overflowHidden: overflow)
        XCTAssertEqual(expanded, .allow([Fixtures.clipboard, Fixtures.meters, own]))
    }

    func testOverflowWithEverythingShownStillHides() {
        let everythingShown = AppSectionMap(defaultSection: .shown)
        let plan = VisibilityPlanner.plan(state: .initial, sections: everythingShown, candidates: [Fixtures.meters, Fixtures.chat],
                                          alwaysAllowed: [own], overflowHidden: [Fixtures.meters])
        XCTAssertEqual(plan, .allow([Fixtures.chat, own]))
        XCTAssertEqual(VisibilityPlanner.plan(state: BarState(reveal: .all), sections: everythingShown, candidates: [Fixtures.meters],
                                              alwaysAllowed: [own], overflowHidden: [Fixtures.meters]), .showEverything)
    }

    func testCollapsedVisibleAppsIsSwapAware() {
        let s = sections
        let c: Set<String> = [Fixtures.meters, Fixtures.clipboard, Fixtures.chat, own]
        XCTAssertEqual(VisibilityPlanner.collapsedVisibleApps(state: .initial, sections: s, candidates: c, excluding: [own]), [Fixtures.clipboard])
        XCTAssertEqual(VisibilityPlanner.collapsedVisibleApps(state: BarState(swapped: true), sections: s, candidates: c, excluding: [own]),
                       [Fixtures.meters])
    }
}

final class BarListingTests: XCTestCase {
    private let own = "app.snugbar.SnugBar"
    private let notes = "com.example.notes"

    private var sections: AppSectionMap {
        var s = AppSectionMap() // default: hidden
        s.set(.shown, forBundleID: Fixtures.clipboard)
        s.set(.shown, forBundleID: notes)
        s.set(.alwaysHidden, forBundleID: Fixtures.chat)
        return s
    }

    private var items: [MenuBarItem] {
        [
            Fixtures.item("status:com.example.chat::Item-0", bundle: Fixtures.chat, app: "Chatter", x: 900),
            Fixtures.item("com.example.notes#0", bundle: notes, app: "Notes", x: 930),
            Fixtures.item("status:com.example.meters::CPU_mini", bundle: Fixtures.meters, app: "Meters", name: "Meters: CPU", x: 960),
            Fixtures.item("status:com.example.meters::RAM_mini", bundle: Fixtures.meters, app: "Meters", name: "Meters: RAM", x: 990),
            Fixtures.item("status:org.example.clipboard::Item-0", bundle: Fixtures.clipboard, app: "Clipboard", x: 1020),
            Fixtures.item("app.snugbar.SnugBar#0", bundle: own, app: "SnugBar", x: 1050),
            Fixtures.item("module:Clock", bundle: "com.apple.controlcenter", app: "Clock", x: 1300, apple: true),
        ]
    }

    private func listing(_ state: BarState, overflow: Set<String> = []) -> [(BarGroupKind, [String])] {
        BarListing.groups(items: items, sections: sections, state: state, overflowHidden: overflow, excluding: [own])
            .map { ($0.kind, $0.items.map(\.id.rawValue)) }
    }

    func testExpandedListsHiddenOnly() {
        let groups = listing(BarState(reveal: .expanded, revealInBar: true))
        XCTAssertEqual(groups.map(\.0), [.hidden])
        XCTAssertEqual(groups.first?.1, ["status:com.example.meters::CPU_mini", "status:com.example.meters::RAM_mini"])
    }

    func testAllAddsAlwaysHiddenAfterHidden() {
        let groups = listing(BarState(reveal: .all, revealInBar: true))
        XCTAssertEqual(groups.map(\.0), [.hidden, .alwaysHidden])
        XCTAssertEqual(groups.last?.1, ["status:com.example.chat::Item-0"])
    }

    func testDidntFitComesLast() {
        let groups = listing(BarState(reveal: .all, revealInBar: true), overflow: [notes])
        XCTAssertEqual(groups.map(\.0), [.hidden, .alwaysHidden, .didntFit])
        XCTAssertEqual(groups.last?.1, ["com.example.notes#0"])
        // Overflow only applies to apps the collapsed bar would show.
        let ignored = listing(BarState(reveal: .expanded, revealInBar: true), overflow: [Fixtures.meters])
        XCTAssertEqual(ignored.map(\.0), [.hidden])
    }

    func testSwappedListsShownApps() {
        let groups = listing(BarState(reveal: .expanded, swapped: true, revealInBar: true))
        XCTAssertEqual(groups.map(\.0), [.hidden])
        XCTAssertEqual(groups.first?.1, ["com.example.notes#0", "status:org.example.clipboard::Item-0"])
    }

    func testZenListsNothing() {
        XCTAssertTrue(listing(BarState(reveal: .all, revealInBar: true, zen: true)).isEmpty)
    }

    func testNeverListsAppleItemsOrSnugBar() {
        let all = listing(BarState(reveal: .all, revealInBar: true)).flatMap(\.1)
        XCTAssertFalse(all.contains("module:Clock"))
        XCTAssertFalse(all.contains("app.snugbar.SnugBar#0"))
    }
}

final class ItemCatalogTests: XCTestCase {
    func testMergesLiveRememberedAndPlaceholders() {
        let cpu = Fixtures.item("status:com.example.meters::CPU_mini", bundle: Fixtures.meters, app: "Meters")
        let chat = Fixtures.item("status:com.example.chat::Item-0", bundle: Fixtures.chat, app: "Chatter")
        var catalog = ItemCatalog()
        catalog.record([cpu, chat], isOnScreen: { _ in true })

        // Chatter is hidden now and missing from the tree; a known app runs with no item seen yet; a quit app is gone.
        let merged = catalog.merged(
            live: [cpu],
            running: [Fixtures.meters, Fixtures.chat, "com.example.later"],
            knownApps: ["com.example.later": "Later", "com.example.quit": "Quit"]
        )
        XCTAssertEqual(merged.map(\.id.rawValue), ["status:com.example.meters::CPU_mini", "status:com.example.chat::Item-0", "com.example.later#0"])
        XCTAssertEqual(merged.last?.appName, "Later")
    }

    func testRecordIgnoresAppsNotOnScreen() {
        var catalog = ItemCatalog()
        let chat = Fixtures.item("status:com.example.chat::Item-0", bundle: Fixtures.chat, app: "Chatter")
        catalog.record([chat], isOnScreen: { _ in false })
        XCTAssertTrue(catalog.itemsByApp.isEmpty)
        catalog.record([chat], isOnScreen: { _ in true })
        catalog.forget(Fixtures.chat)
        XCTAssertTrue(catalog.itemsByApp.isEmpty)
    }
}

final class TilePictureTests: XCTestCase {
    // The layout editor's tiles: a 20 pt box in a 36 pt tile.
    private func editor(_ w: Double, _ h: Double) -> Double { TilePicture.boxWidth(width: w, height: h, side: 20, chrome: 16) }

    func testSquareAndSmallPicturesKeepTheSquareBox() {
        XCTAssertEqual(editor(18, 14), 20, "Wi-Fi")
        XCTAssertEqual(editor(64, 64), 20, "app icon")
        XCTAssertEqual(editor(12, 30), 20, "tall")
        XCTAssertEqual(editor(0, 0), 20, "unknown size")
    }

    func testWidePicturesGetWiderBoxesWithoutBeingBlownUp() {
        XCTAssertEqual(editor(26, 12), 26, "a battery keeps its own width: drawn at its menu bar size")
        XCTAssertEqual(editor(60, 30), 40, "already taller than the box: as wide as it needs at the box's height")
    }

    func testVeryWidePicturesAreCappedAtThreeTiles() {
        // The clock's date and time, 125 × 11 pt: 3 × 36 = 108 pt tile, so a 92 pt box.
        XCTAssertEqual(editor(125, 11), 92)
        XCTAssertEqual(editor(125, 11) + 16, 3 * 36)
        // The SnugBar Bar's tiles: an 18 pt box in 30 pt.
        XCTAssertEqual(TilePicture.boxWidth(width: 125, height: 11, side: 18, chrome: 12) + 12, 90)
    }
}
