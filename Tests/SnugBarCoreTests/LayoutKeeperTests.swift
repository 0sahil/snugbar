import XCTest
@testable import SnugBarCore

final class LayoutReconcileTests: XCTestCase {
    let chat = "status:com.example.chat::Item-0"
    let clipboard = "status:org.example.clipboard::Item-0"
    let cpu = "status:com.example.meters::CPU_mini"

    var inOrder: [String] { [chat, clipboard, cpu] }
    var moved: [String] { [cpu, chat, clipboard] }

    func testNoOpWhenInOrder() {
        let d = LayoutReconcile.decide(.init(desired: inOrder, live: inOrder, positions: Fixtures.positions))
        XCTAssertEqual(d.action, .none)
    }

    func testNoSavedOrderDoesNothing() {
        let d = LayoutReconcile.decide(.init(desired: [], live: inOrder, positions: Fixtures.positions))
        XCTAssertEqual(d.action, .none)
        XCTAssertNil(d.plan)
    }

    func testChangesAreWrittenThroughTheOrderFile() {
        let d = LayoutReconcile.decide(.init(desired: moved, live: inOrder, positions: Fixtures.positions))
        XCTAssertEqual(d.action, .writeOrderFile)
        XCTAssertFalse(d.plan?.changes.isEmpty ?? true)
    }

    func testAutomaticWithoutAccessIsSkippedNeverDragged() {
        let d = LayoutReconcile.decide(.init(desired: moved, live: inOrder, positions: nil))
        XCTAssertEqual(d.action, .skipped)
        XCTAssertTrue(d.reasons.joined().contains("never move the pointer"))
    }

    func testExplicitWithoutAccessDrags() {
        let d = LayoutReconcile.decide(.init(desired: moved, live: inOrder, positions: nil, explicit: true))
        XCTAssertEqual(d.action, .dragMoves)
        XCTAssertEqual(d.plan.map { OrderPlanner.applying($0.moves, to: inOrder) }, moved)
    }

    func testSkippedWhileTheUserDrags() {
        XCTAssertEqual(LayoutReconcile.decide(.init(desired: moved, live: inOrder, positions: Fixtures.positions, userDragging: true)).action, .skipped)
        XCTAssertEqual(LayoutReconcile.decide(.init(desired: moved, live: inOrder, positions: Fixtures.positions, editorDragging: true)).action, .skipped)
        // Explicit actions wait too.
        XCTAssertEqual(LayoutReconcile.decide(.init(desired: moved, live: inOrder, positions: nil, userDragging: true, explicit: true)).action, .skipped)
    }

    func testOutOfPlaceKeysWithoutOrderFileKeyAreNotDraggedAutomatically() {
        let a = "com.example.alpha#0", b = "com.example.beta#0"
        let auto = LayoutReconcile.decide(.init(desired: [b, a], live: [a, b], positions: Fixtures.positions))
        XCTAssertEqual(auto.action, .skipped)
        let explicit = LayoutReconcile.decide(.init(desired: [b, a], live: [a, b], positions: Fixtures.positions, explicit: true))
        XCTAssertEqual(explicit.action, .dragMoves)
    }

    func testLiveKeysKeepShownAppsAppleItemsAndSpacers() {
        let own = "app.example.SnugBar"
        let items = [
            Fixtures.item("com.example.chat#0", bundle: "com.example.chat", app: "Chat"),
            Fixtures.item("status:com.example.meters::CPU", bundle: "com.example.meters", app: "Meters"),
            Fixtures.item("\(own)#0", bundle: own, app: "SnugBar", x: 10),
            Fixtures.item("\(own)#1", bundle: own, app: "SnugBar", x: 20),
            Fixtures.item("module:WiFi", bundle: "com.apple.controlcenter", app: "Control Center", apple: true, axID: "com.apple.menuextra.wifi"),
            Fixtures.item("module:Clock", bundle: "com.apple.controlcenter", app: "Control Center", apple: true, axID: AppleItems.clockIdentifier),
            Fixtures.item("module:ControlCenter", bundle: "com.apple.controlcenter", app: "Control Center", apple: true, axID: AppleItems.controlCenterIdentifier),
        ]
        let sections = AppSectionMap(apps: ["com.example.meters": .shown], defaultSection: .hidden)
        let keys = LayoutReconcile.liveKeys(items, sections: sections, ownBundleID: own) { $0.frame.x == 10 ? "spacer:S" : nil }
        XCTAssertEqual(keys, ["status:com.example.meters::CPU", "spacer:S", "module:WiFi"])
    }

    func testEvaluateNormalizesAndSavesMergedOrder() {
        // The saved order has a fallback ID for the meters' RAM item; the file knows it as RAM_mini.
        let layout = DesiredLayout(shownOrder: ["com.example.meters#1", chat])
        let live = [chat, clipboard, cpu, "status:com.example.meters::RAM_mini"]
        let e = LayoutReconcile.evaluate(layout: layout, live: live, positions: Fixtures.positions, ownBundleID: "app.example.SnugBar")
        XCTAssertEqual(e.decision.action, .writeOrderFile)
        XCTAssertEqual(e.orderToSave, ["status:com.example.meters::RAM_mini", chat, clipboard, cpu])
    }

    func testEvaluateSkippedSavesNothing() {
        let layout = DesiredLayout(shownOrder: ["com.example.meters#1", chat])
        let e = LayoutReconcile.evaluate(layout: layout, live: [chat], positions: Fixtures.positions, ownBundleID: "x", userDragging: true)
        XCTAssertEqual(e.decision.action, .skipped)
        XCTAssertNil(e.orderToSave)
    }

    func testEvaluateKeepsSpacerKeysInTheSavedOrder() {
        let own = "app.example.SnugBar"
        let spacer = LayoutSpacer(id: "S")
        var positions = Fixtures.positions
        positions[spacer.orderFileKey(ownBundleID: own)] = 500
        let layout = DesiredLayout(shownOrder: [chat, spacer.key], spacers: [spacer])
        let e = LayoutReconcile.evaluate(layout: layout, live: [spacer.key, chat, clipboard], positions: positions, ownBundleID: own)
        XCTAssertEqual(e.spacerKeys, [spacer.key: spacer.orderFileKey(ownBundleID: own)])
        XCTAssertEqual(e.orderToSave, [chat, clipboard, spacer.key])
        XCTAssertNotNil(e.decision.plan?.changes[spacer.orderFileKey(ownBundleID: own)])
    }

    func testTriggers() {
        XCTAssertTrue(LayoutTrigger.wake.forcesVisibility)
        XCTAssertFalse(LayoutTrigger.spaceChanged.forcesVisibility)
        XCTAssertFalse(LayoutTrigger.userOrder.forcesVisibility)
    }

    func testSystemBuildCheck() {
        XCTAssertEqual(SystemBuildCheck.check(lastSeen: nil, current: "27C100"), .firstSeen("27C100"))
        XCTAssertEqual(SystemBuildCheck.check(lastSeen: "27C100", current: "27C100"), .unchanged)
        XCTAssertEqual(SystemBuildCheck.check(lastSeen: "27C100", current: "27D20"), .changed(from: "27C100", to: "27D20"))
        XCTAssertEqual(SystemBuildCheck.check(lastSeen: "27C100", current: nil), .unknown)
    }
}

final class NewAppRuleTests: XCTestCase {
    let own = "app.example.SnugBar"

    func settings() -> Settings {
        var s = Settings()
        s.knownApps = ["com.example.chat": "Chat"]
        return s
    }

    func testDetectsOnlyUnseenApps() {
        var s = settings()
        s.sections.set(.shown, forBundleID: "com.example.assigned")
        let seen = [("com.example.chat", "Chat"), ("com.example.assigned", "Assigned"), ("com.example.new", "New One"),
                    (own, "SnugBar"), ("", "Nameless"), ("com.example.new", "New One")].map { (bundleID: $0.0, name: $0.1) }
        let found = NewAppRule.detect(seen: seen, settings: s, ownBundleID: own)
        XCTAssertEqual(found, [NewApp(bundleID: "com.example.new", name: "New One", section: .hidden)])
    }

    func testFirstRunReportsNothing() {
        let found = NewAppRule.detect(seen: [(bundleID: "com.example.new", name: "New")], settings: Settings(), ownBundleID: own)
        XCTAssertEqual(found, [])
    }

    func testDefaultSectionIsUsedAndPinned() {
        var s = settings()
        s.sections.defaultSection = .alwaysHidden
        let found = NewAppRule.detect(seen: [(bundleID: "com.example.new", name: "New")], settings: s, ownBundleID: own)
        XCTAssertEqual(found.first?.section, .alwaysHidden)
        NewAppRule.apply(found, keys: [:], to: &s)
        XCTAssertEqual(s.sections.apps["com.example.new"], .alwaysHidden)
        XCTAssertEqual(s.knownApps["com.example.new"], "New")
        s.sections.defaultSection = .shown
        XCTAssertEqual(s.sections.section(forBundleID: "com.example.new"), .alwaysHidden)
    }

    func testShownNewAppGoesToTheEndOfTheOrder() {
        var s = settings()
        s.sections.defaultSection = .shown
        s.layout.shownOrder = ["status:com.example.chat::Item-0", "module:WiFi"]
        let app = NewApp(bundleID: "com.example.new", name: "New", section: .shown)
        NewAppRule.apply([app], keys: ["com.example.new": ["status:com.example.new::A", "status:com.example.new::B"]], to: &s)
        XCTAssertEqual(s.layout.shownOrder, ["status:com.example.chat::Item-0", "status:com.example.new::A", "status:com.example.new::B", "module:WiFi"])
    }

    func testShownNewAppWithoutKeptOrderLeavesOrderEmpty() {
        var s = settings()
        let app = NewApp(bundleID: "com.example.new", name: "New", section: .shown)
        NewAppRule.apply([app], keys: ["com.example.new": ["status:com.example.new::A"]], to: &s)
        XCTAssertEqual(s.layout.shownOrder, [])
    }

    func testNotices() {
        var notices = NewAppNotices()
        let a = NewApp(bundleID: "com.example.a", name: "Alpha", section: .hidden)
        let b = NewApp(bundleID: "com.example.b", name: "Beta", section: .shown)
        notices.add([a, b, a])
        XCTAssertEqual(notices.pending.map(\.bundleID), ["com.example.b", "com.example.a"])
        XCTAssertEqual(NewAppNotices.title(for: a), "New: Alpha was put in Hidden")
        notices.appsMoved(["com.example.b"])
        XCTAssertEqual(notices.pending, [a])
        XCTAssertEqual(notices.takeForMenu(), [a])
        XCTAssertEqual(notices.takeForMenu(), [])
    }
}

final class SpacerTests: XCTestCase {
    func testWidthIsClamped() {
        XCTAssertEqual(LayoutSpacer(id: "a").width, 16)
        XCTAssertEqual(LayoutSpacer(id: "a", width: 0).width, 1)
        XCTAssertEqual(LayoutSpacer(id: "a", width: 500).width, 64)
        XCTAssertEqual(LayoutSpacer(id: "a", width: 20.4).width, 20)
        XCTAssertEqual(LayoutSpacer(id: "a", width: .nan).width, 16)
        var layout = DesiredLayout(spacers: [LayoutSpacer(id: "a")])
        layout.setSpacerWidth(id: "a", 100)
        XCTAssertEqual(layout.spacers[0].width, 64)
    }

    func testDecodedWidthIsClamped() throws {
        let spacer = try JSONDecoder().decode(LayoutSpacer.self, from: Data(#"{"id":"x","width":0}"#.utf8))
        XCTAssertEqual(spacer.width, 1)
        let noWidth = try JSONDecoder().decode(LayoutSpacer.self, from: Data(#"{"id":"x"}"#.utf8))
        XCTAssertEqual(noWidth.width, 16)
    }

    func testKeys() {
        let s = LayoutSpacer(id: "1234")
        XCTAssertEqual(s.key, "spacer:1234")
        XCTAssertEqual(s.autosaveName, "snugbar.spacer.1234")
        XCTAssertEqual(s.orderFileKey(ownBundleID: "app.example.SnugBar"), "status:app.example.SnugBar::snugbar.spacer.1234")
        XCTAssertTrue(LayoutSpacer.isSpacerKey(s.key))
        XCTAssertEqual(LayoutSpacer.id(fromKey: s.key), "1234")
        XCTAssertNil(LayoutSpacer.id(fromKey: "status:x::y"))
        XCTAssertEqual(LayoutSpacer.orderKeyMap([s], ownBundleID: "app.example.SnugBar", positions: nil), [:])
    }

    func testAddAndRemove() {
        var layout = DesiredLayout()
        let s = LayoutSpacer(id: "S")
        layout.addSpacer(s, live: ["a", "b"])
        XCTAssertEqual(layout.shownOrder, ["spacer:S", "a", "b"])
        layout.removeSpacer(id: "S")
        XCTAssertEqual(layout.shownOrder, ["a", "b"])
        XCTAssertEqual(layout.spacers, [])
    }

    /// Spacers are SnugBar's own status items: they never reach the SnugBar Bar, search, letters, `list` or the hider.
    func testSpacerItemsAreExcludedEverywhere() {
        let own = "app.example.SnugBar"
        let spacerItem = Fixtures.item("\(own)#1", bundle: own, app: "SnugBar")
        let other = Fixtures.item("status:com.example.chat::Item-0", bundle: "com.example.chat", app: "Chat")
        let sections = AppSectionMap(defaultSection: .hidden)
        let groups = BarListing.groups(items: [spacerItem, other], sections: sections, state: BarState(reveal: .expanded),
                                       overflowHidden: [], excluding: [own])
        XCTAssertEqual(groups.flatMap(\.items).map(\.ownerBundleID), ["com.example.chat"])
        XCTAssertEqual(LetterAssigner.assign(groups.flatMap(\.items)).count, 1)
        // The hider only ever gets SnugBar's bundle as "always allowed", never a spacer as something to hide.
        let plan = VisibilityPlanner.plan(state: .initial, sections: sections, candidates: ["com.example.chat", own], alwaysAllowed: [own])
        XCTAssertEqual(plan, .allow([own]))
        // The control commands' items come from the same filtered list.
        XCTAssertFalse(ItemQuery.find("SnugBar", in: [other]).isSuccess)
    }

    func testOldSettingsWithoutLayoutDecodeWithDefaults() throws {
        let json = #"{"schemaVersion":1,"sections":{"apps":{"com.example.chat":"shown"},"defaultSection":"hidden"}}"#
        let s = try SettingsStore.decode(Data(json.utf8))
        XCTAssertEqual(s.layout, DesiredLayout())
        XCTAssertFalse(s.layout.enforcesOrder)
        XCTAssertNil(s.lastSystemBuild)
        XCTAssertEqual(s.sections.apps["com.example.chat"], .shown)
    }

    func testLayoutRoundTrips() throws {
        var s = Settings()
        s.layout = DesiredLayout(shownOrder: ["spacer:S", "module:WiFi"], spacers: [LayoutSpacer(id: "S", width: 24)])
        s.lastSystemBuild = "27C100"
        XCTAssertEqual(try SettingsStore.decode(SettingsStore.encode(s)), s)
    }
}

private extension Result {
    var isSuccess: Bool { if case .success = self { return true } else { return false } }
}
