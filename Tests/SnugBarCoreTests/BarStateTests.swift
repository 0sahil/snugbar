import XCTest
@testable import SnugBarCore

final class BarStateTests: XCTestCase {
    private let own = "app.snugbar.SnugBar"

    private var sections: AppSectionMap {
        var s = AppSectionMap()
        s.set(.shown, forBundleID: Fixtures.clipboard)
        s.set(.alwaysHidden, forBundleID: Fixtures.chat)
        return s
    }

    private func plan(_ state: BarState, _ sections: AppSectionMap, candidates: Set<String>) -> VisibilityPlanner.Plan {
        VisibilityPlanner.plan(state: state, sections: sections, candidates: candidates, alwaysAllowed: [own])
    }

    func testVisibleSections() {
        XCTAssertEqual(BarState(reveal: .collapsed).visibleSections, [.shown])
        XCTAssertEqual(BarState(reveal: .expanded).visibleSections, [.shown, .hidden])
        XCTAssertEqual(BarState(reveal: .all).visibleSections, [.shown, .hidden, .alwaysHidden])
        XCTAssertEqual(BarState(reveal: .collapsed, swapped: true).visibleSections, [.hidden])
        XCTAssertEqual(BarState(reveal: .expanded, swapped: true).visibleSections, [.shown, .hidden])
    }

    func testCollapsedAllowsShownAppsAndSelf() {
        let p = plan(.initial, sections, candidates: [Fixtures.meters, Fixtures.clipboard, Fixtures.chat, own])
        XCTAssertEqual(p, .allow([Fixtures.clipboard, own]))
    }

    func testExpandedLetsUnlistedAppsThroughButNotAlwaysHidden() {
        let p = plan(BarState(reveal: .expanded), sections, candidates: [Fixtures.meters, Fixtures.clipboard, Fixtures.chat])
        XCTAssertEqual(p, .allow([Fixtures.clipboard, Fixtures.meters, own]))
    }

    func testExpandedWithNothingAlwaysHiddenShowsEverything() {
        var s = AppSectionMap()
        s.set(.shown, forBundleID: Fixtures.clipboard)
        XCTAssertEqual(plan(BarState(reveal: .expanded), s, candidates: [Fixtures.meters]), .showEverything)
    }

    func testAllShowsEverything() {
        XCTAssertEqual(plan(BarState(reveal: .all), sections, candidates: [Fixtures.meters]), .showEverything)
    }

    func testSwappedCollapsedShowsHiddenAppsOnly() {
        let p = plan(BarState(reveal: .collapsed, swapped: true), sections, candidates: [Fixtures.meters, Fixtures.clipboard, Fixtures.chat])
        XCTAssertEqual(p, .allow([Fixtures.meters, own]))
    }

    func testDefaultAlwaysHiddenHidesUnlistedAppsEvenWhenExpanded() {
        var s = AppSectionMap(defaultSection: .alwaysHidden)
        s.set(.hidden, forBundleID: Fixtures.clipboard)
        let p = plan(BarState(reveal: .expanded), s, candidates: [Fixtures.meters, Fixtures.clipboard])
        XCTAssertEqual(p, .allow([Fixtures.clipboard, own]))
    }

    func testCollapsedWithEverythingShownNeedsNoHide() {
        let s = AppSectionMap(defaultSection: .shown)
        XCTAssertEqual(plan(.initial, s, candidates: [Fixtures.meters, Fixtures.chat]), .showEverything)
    }

    func testOnlySelfUnlistedNeedsNoHide() {
        // A fresh install with nothing else running: SnugBar alone is always allowed, so nothing to hide.
        XCTAssertEqual(plan(.initial, AppSectionMap(), candidates: [own]), .showEverything)
    }
}

final class AutoCollapsePolicyTests: XCTestCase {
    private let on = AutoCollapseSettings()
    private let expanded = BarState(reveal: .expanded)

    func testTimer() {
        XCTAssertEqual(AutoCollapsePolicy.onTimer(state: expanded, settings: on, menuOpen: false, pointerInMenuBar: false), .collapse)
        XCTAssertEqual(AutoCollapsePolicy.onTimer(state: expanded, settings: on, menuOpen: true, pointerInMenuBar: false), .postpone)
        XCTAssertEqual(AutoCollapsePolicy.onTimer(state: expanded, settings: on, menuOpen: false, pointerInMenuBar: true), .postpone)
        XCTAssertEqual(AutoCollapsePolicy.onTimer(state: .initial, settings: on, menuOpen: false, pointerInMenuBar: false), .ignore)
        var off = on
        off.enabled = false
        XCTAssertEqual(AutoCollapsePolicy.onTimer(state: expanded, settings: off, menuOpen: false, pointerInMenuBar: false), .ignore)
    }

    func testClickOutside() {
        XCTAssertTrue(AutoCollapsePolicy.onClickOutside(state: expanded, settings: on, menuOpen: false))
        XCTAssertFalse(AutoCollapsePolicy.onClickOutside(state: expanded, settings: on, menuOpen: true))
        var s = on
        s.onClickOutside = false
        XCTAssertFalse(AutoCollapsePolicy.onClickOutside(state: expanded, settings: s, menuOpen: false))
    }

    func testAppSwitchIgnoresRevealedAppsAndSelf() {
        func check(_ bundle: String?) -> Bool {
            AutoCollapsePolicy.onAppActivated(
                bundleID: bundle, state: expanded, settings: on, revealedBundleIDs: [Fixtures.chat], ownBundleID: "own"
            )
        }
        XCTAssertTrue(check("com.example.editor"))
        XCTAssertFalse(check(Fixtures.chat))
        XCTAssertFalse(check("own"))
        var s = on
        s.onAppSwitch = false
        XCTAssertFalse(AutoCollapsePolicy.onAppActivated(
            bundleID: "x", state: expanded, settings: s, revealedBundleIDs: [], ownBundleID: nil
        ))
    }

    func testScrollGestureFiresOncePerGesture() {
        var g = ScrollGesture(threshold: 6)
        XCTAssertNil(g.feed(deltaY: 3, at: 0))
        XCTAssertEqual(g.feed(deltaY: 4, at: 0.05), .down)
        XCTAssertNil(g.feed(deltaY: 10, at: 0.1), "same gesture keeps going")
        XCTAssertEqual(g.feed(deltaY: -8, at: 1.0), .up, "pause starts a new gesture")
        XCTAssertNil(g.feed(deltaY: -2, at: 2.0))
    }
}

final class HotkeyTests: XCTestCase {
    func testDescriptionAndValidity() {
        let h = Hotkey(keyCode: 0x04, modifiers: [.command, .control, .option])
        XCTAssertEqual(h.description, "⌃⌥⌘H")
        XCTAssertTrue(h.isValidGlobalHotkey)
        XCTAssertFalse(Hotkey(keyCode: 0x04, modifiers: [.shift]).isValidGlobalHotkey)
        XCTAssertTrue(Hotkey(keyCode: 0x69, modifiers: []).isValidGlobalHotkey, "F13 alone is fine")
    }

    func testModifiersEncodeAsNames() throws {
        let h = Hotkey(keyCode: 0x01, modifiers: [.shift, .option])
        let json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(h)) as? [String: Any]
        XCTAssertEqual(json?["modifiers"] as? [String], ["option", "shift"])
        XCTAssertEqual(try JSONDecoder().decode(Hotkey.self, from: JSONEncoder().encode(h)), h)
    }

    func testConflicts() {
        let h = Hotkey(keyCode: 0x04, modifiers: [.control, .option])
        var s = HotkeySettings(toggleHidden: h, swap: h)
        XCTAssertEqual(s.conflicts(for: .toggleHidden), [.swap])
        s[.swap] = nil
        XCTAssertEqual(s.conflicts(for: .toggleHidden), [])
    }
}

final class SettingsFieldsTests: XCTestCase {
    func testOldFileGetsDefaultsForNewFields() throws {
        let old = #"{"schemaVersion": 1, "hider": "automatic", "sections": {"apps": {}, "defaultSection": "hidden"}}"#
        let s = try SettingsStore.decode(Data(old.utf8))
        XCTAssertTrue(s.showIcon)
        XCTAssertEqual(s.autoCollapse, AutoCollapseSettings())
        XCTAssertEqual(s.reveal, RevealSettings())
        XCTAssertEqual(s.hotkeys, HotkeySettings())
        XCTAssertTrue(s.knownApps.isEmpty)
    }

    func testPartialNestedObjectsKeepOtherDefaults() throws {
        let json = #"{"schemaVersion": 1, "autoCollapse": {"delay": 30}, "reveal": {"hover": true}}"#
        let s = try SettingsStore.decode(Data(json.utf8))
        XCTAssertEqual(s.autoCollapse.delay, 30)
        XCTAssertTrue(s.autoCollapse.enabled)
        XCTAssertTrue(s.reveal.hover)
        XCTAssertTrue(s.reveal.clickEmptyBar)
    }

    func testRoundTripWithEverythingSet() throws {
        var s = Settings()
        s.showIcon = false
        s.autoCollapse.delay = 5
        s.reveal.scroll = true
        s.hotkeys[.toggleHidden] = Hotkey(keyCode: 0x04, modifiers: [.control, .option])
        s.noteApps([(bundleID: Fixtures.chat, name: "Chat"), (bundleID: "", name: "ignored")])
        XCTAssertEqual(try SettingsStore.decode(SettingsStore.encode(s)), s)
        XCTAssertEqual(s.knownApps, [Fixtures.chat: "Chat"])
        XCTAssertFalse(s.noteApps([(bundleID: Fixtures.chat, name: "Chat")]))
    }
}
