import XCTest
@testable import SnugBarCore

final class SectionOrderTests: XCTestCase {
    let h1 = "status:com.example.alpha::Item-0"
    let h2 = "status:com.example.beta::Item-0"
    let h3 = "status:com.example.gamma::Item-0"
    let s1 = "status:com.example.shown::Item-0"

    /// Hidden items interleaved with a Shown one.
    var positions: [String: Double] { [h1: 500, s1: 450, h2: 400, h3: 300, "module:WiFi": 100] }

    func testLeftToRightByValueSkippingUnknownKeys() {
        XCTAssertEqual(SectionOrder.leftToRight([h3, h1, "status:com.example.gone::X", h2, h1], positions: positions), [h1, h2, h3])
    }

    func testPlanHandsOutTheSectionsOwnValuesInTheNewOrder() {
        let plan = SectionOrder.plan(desired: [h3, h1, h2], keys: [h1, h2, h3], positions: positions)
        XCTAssertEqual(plan.liveOrder, [h1, h2, h3])
        XCTAssertEqual(plan.targetOrder, [h3, h1, h2])
        XCTAssertEqual(plan.changes, [h3: 500, h1: 400, h2: 300])
        // Other sections' items keep their values.
        XCTAssertNil(plan.changes[s1])
        let after = positions.merging(plan.changes) { _, new in new }
        XCTAssertEqual(OrderPlanner.leftToRight(after).filter { [h1, h2, h3].contains($0) }, [h3, h1, h2])
        XCTAssertEqual(after[s1], 450)
    }

    func testPlanIsANoOpWhenInOrder() {
        let plan = SectionOrder.plan(desired: [h1, h2, h3], keys: [h3, h2, h1], positions: positions)
        XCTAssertTrue(plan.isNoOp)
        XCTAssertFalse(plan.desiredChanged)
    }

    func testUnknownKeysAreMergedInWhereTheyAre() {
        let plan = SectionOrder.plan(desired: [h3, h1], keys: [h1, h2, h3], positions: positions)
        XCTAssertEqual(plan.desiredOrder, [h3, h1, h2])
        XCTAssertTrue(plan.desiredChanged)
        XCTAssertEqual(plan.targetOrder, [h3, h1, h2])
    }

    func testEqualValuesAreNotPlanned() {
        let tied = [h1: 400.0, h2: 400, h3: 300]
        XCTAssertTrue(SectionOrder.plan(desired: [h3, h2, h1], keys: [h1, h2, h3], positions: tied).isNoOp)
    }

    func testFileKeyResolvesFallbackIDs() {
        XCTAssertEqual(SectionOrder.fileKey(for: ItemID(rawValue: h1), positions: positions), h1)
        XCTAssertEqual(SectionOrder.fileKey(for: .indexed(owner: "com.example.beta", index: 0), positions: positions), h2)
        XCTAssertNil(SectionOrder.fileKey(for: ItemID(rawValue: "status:com.example.gone::X"), positions: positions))
    }

    func item(_ id: String, _ bundle: String) -> MenuBarItem { Fixtures.item(id, bundle: bundle, app: bundle) }

    func testArrangedOrdersHiddenItemsAndLeavesOthersInTheirSlots() {
        let items = [item(h3, "com.example.gamma"), item(s1, "com.example.shown"), item(h1, "com.example.alpha"),
                     item("com.example.beta#0", "com.example.beta")]
        let sections = AppSectionMap(apps: ["com.example.shown": .shown], defaultSection: .hidden)
        // By the order file: alpha, beta, gamma (beta's fallback ID is matched to its key).
        let byFile = SectionOrder.arranged(items, sections: sections, layout: DesiredLayout(), positions: positions)
        XCTAssertEqual(byFile.map(\.id.rawValue), [h1, s1, "com.example.beta#0", h3])
        // The saved order decides where it has the keys; alpha, which it lacks, stays left of its file neighbour beta.
        let saved = SectionOrder.arranged(items, sections: sections, layout: DesiredLayout(hiddenOrder: [h3, h2]), positions: positions)
        XCTAssertEqual(saved.map(\.id.rawValue), [h3, s1, h1, "com.example.beta#0"])
        // Without the order file, only the saved order applies (beta stays right of alpha, its neighbour in the list).
        let noFile = SectionOrder.arranged(items, sections: sections, layout: DesiredLayout(hiddenOrder: [h1, h3]), positions: nil)
        XCTAssertEqual(noFile.map(\.id.rawValue), [h1, s1, "com.example.beta#0", h3])
    }

    func testEditorRowsFollowTheSectionOrder() {
        let items = [item(h3, "com.example.gamma"), item(h1, "com.example.alpha"), item(h2, "com.example.beta")]
        let rows = LayoutEditorRows.rows(items: items, liveShown: [], sections: AppSectionMap(), layout: DesiredLayout(hiddenOrder: [h3, h2, h1]),
                                         positions: positions) { _ in true }
        XCTAssertEqual(rows[.hidden]?.map(\.key), [h3, h2, h1])
        // Without a saved order the file's order is used.
        let byFile = LayoutEditorRows.rows(items: items, liveShown: [], sections: AppSectionMap(), layout: DesiredLayout(),
                                           positions: positions) { _ in true }
        XCTAssertEqual(byFile[.hidden]?.map(\.key), [h1, h2, h3])
    }

    // MARK: - Reconcile

    func testEvaluatePlansSectionsThroughTheOrderFile() {
        let layout = DesiredLayout(hiddenOrder: [h3, h1, h2])
        let e = LayoutReconcile.evaluate(layout: layout, live: [s1], positions: positions, ownBundleID: "app.example.SnugBar",
                                         sectionKeys: [.hidden: [h1, h2, h3]])
        XCTAssertEqual(e.sectionPlans["hidden"]?.changes, [h3: 500, h1: 400, h2: 300])
        XCTAssertEqual(e.fileChanges, [h3: 500, h1: 400, h2: 300])
        XCTAssertTrue(e.sectionOrdersToSave.isEmpty)
    }

    func testSectionsAreLeftAloneWithoutTheOrderFileOrWhileDragging() {
        let layout = DesiredLayout(hiddenOrder: [h3, h1, h2])
        let keys: [Section: [String]] = [.hidden: [h1, h2, h3]]
        let noFile = LayoutReconcile.evaluate(layout: layout, live: [s1], positions: nil, ownBundleID: "x", sectionKeys: keys)
        XCTAssertTrue(noFile.sectionPlans.isEmpty)
        let dragging = LayoutReconcile.evaluate(layout: layout, live: [s1], positions: positions, ownBundleID: "x", sectionKeys: keys,
                                                userDragging: true)
        XCTAssertTrue(dragging.fileChanges.isEmpty)
        let editor = LayoutReconcile.evaluate(layout: layout, live: [s1], positions: positions, ownBundleID: "x", sectionKeys: keys,
                                              editorDragging: true)
        XCTAssertTrue(editor.fileChanges.isEmpty)
    }

    func testSavedSectionOrderIsNormalizedAndMergedWhenItChanges() {
        let layout = DesiredLayout(hiddenOrder: ["com.example.gamma#0", h1])
        let e = LayoutReconcile.evaluate(layout: layout, live: [], positions: positions, ownBundleID: "x", sectionKeys: [.hidden: [h1, h2, h3]])
        XCTAssertEqual(e.sectionOrdersToSave["hidden"], [h3, h1, h2])
    }

    func testShownAndSectionChangesAreWrittenTogether() {
        // Shown: move the shown item right of WiFi; Hidden: reverse. Both land in one dictionary.
        let layout = DesiredLayout(shownOrder: ["module:WiFi", s1], hiddenOrder: [h3, h2, h1])
        let e = LayoutReconcile.evaluate(layout: layout, live: [s1, "module:WiFi"], positions: positions, ownBundleID: "x",
                                         sectionKeys: [.hidden: [h1, h2, h3]])
        XCTAssertEqual(e.decision.action, .writeOrderFile)
        let after = positions.merging(e.fileChanges) { _, new in new }
        let order = OrderPlanner.leftToRight(after)
        XCTAssertEqual(order.filter { [h1, h2, h3].contains($0) }, [h3, h2, h1])
        XCTAssertLessThan(order.firstIndex(of: "module:WiFi")!, order.firstIndex(of: s1)!)
    }

    func testEnforcesAnyOrder() {
        XCTAssertFalse(DesiredLayout().enforcesAnyOrder)
        XCTAssertTrue(DesiredLayout(alwaysHiddenOrder: ["a"]).enforcesAnyOrder)
        var layout = DesiredLayout()
        layout.setOrder(["x"], for: .hidden)
        XCTAssertEqual(layout.order(for: .hidden), ["x"])
        XCTAssertEqual(layout.hiddenOrder, ["x"])
    }

    // MARK: - Settings and backups

    func testOldSettingsLayoutDecodesWithoutSectionOrders() throws {
        let json = #"{"shownOrder":["a"],"spacers":[{"id":"S","width":20}]}"#
        let layout = try JSONDecoder().decode(DesiredLayout.self, from: Data(json.utf8))
        XCTAssertEqual(layout, DesiredLayout(shownOrder: ["a"], spacers: [LayoutSpacer(id: "S", width: 20)]))
        XCTAssertEqual(layout.hiddenOrder, [])
        XCTAssertEqual(layout.alwaysHiddenOrder, [])
    }

    func testSectionOrdersRoundTripThroughSettingsAndBackups() throws {
        var settings = Settings.default
        settings.layout = DesiredLayout(shownOrder: ["a"], hiddenOrder: [h1, h2], alwaysHiddenOrder: [h3])
        let decoded = try JSONDecoder().decode(Settings.self, from: JSONEncoder().encode(settings))
        XCTAssertEqual(decoded.layout, settings.layout)

        let backup = LayoutBackup.Layout(settings: settings)
        let restored = try JSONDecoder().decode(LayoutBackup.Layout.self, from: JSONEncoder().encode(backup))
        var target = Settings.default
        restored.apply(to: &target)
        XCTAssertEqual(target.layout.hiddenOrder, [h1, h2])
        XCTAssertEqual(target.layout.alwaysHiddenOrder, [h3])
        // Backups written before section orders existed still decode.
        let old = try JSONDecoder().decode(LayoutBackup.Layout.self, from: Data(#"{"shownOrder":["a"]}"#.utf8))
        XCTAssertEqual(old.hiddenOrder, [])
    }

    func testResetClearsSectionOrders() {
        var settings = Settings.default
        settings.layout = DesiredLayout(hiddenOrder: [h1])
        XCTAssertEqual(LayoutReset.reset(settings).layout.hiddenOrder, [])
    }
}

final class SectionDropTests: XCTestCase {
    func tile(_ key: String, _ bundle: String, _ section: Section = .hidden) -> LayoutTile {
        LayoutTile(key: key, items: [Fixtures.item(key, bundle: bundle, app: bundle)], section: section)
    }

    func spacer(_ id: String) -> LayoutTile {
        let s = LayoutSpacer(id: id)
        return LayoutTile(key: s.key, items: [], spacer: s, section: .shown)
    }

    func testReorderWithinHidden() {
        let row = [tile("a", "A"), tile("b", "B"), tile("c", "C")]
        let outcome = LayoutDrop.outcome(dragging: LayoutDragContents(tiles: [row[2]]), onto: .hidden, gap: 0, row: row)
        XCTAssertEqual(outcome, .reorder(.hidden, order: ["c", "a", "b"], appsIn: []))
        XCTAssertEqual(LayoutDrop.outcome(dragging: LayoutDragContents(tiles: [row[0]]), onto: .hidden, gap: 1, row: row), .none(nil))
    }

    func testReorderWithinAlwaysHiddenCarriesEveryItemOfAGroupedTile() {
        let grouped = LayoutTile(key: "m1", items: [Fixtures.item("m1", bundle: "M", app: "M"), Fixtures.item("m2", bundle: "M", app: "M")],
                                 section: .alwaysHidden)
        let row = [tile("a", "A", .alwaysHidden), grouped]
        let outcome = LayoutDrop.outcome(dragging: LayoutDragContents(tiles: [grouped]), onto: .alwaysHidden, gap: 0, row: row)
        XCTAssertEqual(outcome, .reorder(.alwaysHidden, order: ["m1", "m2", "a"], appsIn: []))
    }

    func testWithoutOrderFileHiddenCantBeReorderedButAppsCanStillMoveIn() {
        let row = [tile("a", "A"), tile("b", "B")]
        let same = LayoutDrop.outcome(dragging: LayoutDragContents(tiles: [row[1]]), onto: .hidden, gap: nil, row: row)
        guard case let .none(reason?) = same else { return XCTFail("expected a reason, got \(same)") }
        XCTAssertTrue(reason.contains("Menu Bar folder access"))
        let incoming = LayoutDrop.outcome(dragging: LayoutDragContents(tiles: [tile("s", "S", .shown)]), onto: .hidden, gap: nil, row: row)
        XCTAssertEqual(incoming, .moveApps(["S"], to: .hidden))
    }

    func testDropIntoHiddenAtAPlaceMovesAndPlacesTheApp() {
        let row = [tile("a", "A"), tile("b", "B")]
        let outcome = LayoutDrop.outcome(dragging: LayoutDragContents(tiles: [tile("s", "S", .shown), spacer("X")]), onto: .hidden, gap: 1, row: row)
        // The spacer stays in Shown; the app goes between a and b.
        XCTAssertEqual(outcome, .reorder(.hidden, order: ["a", "s", "b"], appsIn: ["S"]))
    }
}
