import XCTest
@testable import SnugBarCore

final class LayoutSelectionTests: XCTestCase {
    let rows = [["s1", "s2", "s3", "s4"], ["h1", "h2", "h3"], ["a1"]]

    func testClickSelectsOne() {
        var sel = LayoutSelection()
        sel.click("s2", modifier: .none, rows: rows)
        sel.click("h1", modifier: .none, rows: rows)
        XCTAssertEqual(sel.keys, ["h1"])
    }

    func testCommandClickToggles() {
        var sel = LayoutSelection()
        sel.click("s1", modifier: .none, rows: rows)
        sel.click("h2", modifier: .command, rows: rows)
        sel.click("a1", modifier: .command, rows: rows)
        XCTAssertEqual(sel.keys, ["s1", "h2", "a1"])
        sel.click("h2", modifier: .command, rows: rows)
        XCTAssertEqual(sel.keys, ["s1", "a1"])
    }

    func testShiftClickExtendsWithinASection() {
        var sel = LayoutSelection()
        sel.click("s3", modifier: .none, rows: rows)
        sel.click("s1", modifier: .shift, rows: rows)
        XCTAssertEqual(sel.keys, ["s1", "s2", "s3"])
        // Another section: the range can't cross, so it starts over there.
        sel.click("h3", modifier: .shift, rows: rows)
        XCTAssertEqual(sel.keys, ["h3"])
        sel.click("h1", modifier: .shift, rows: rows)
        XCTAssertEqual(sel.keys, ["h1", "h2", "h3"])
    }

    func testShiftClickWithoutAnchorSelectsOne() {
        var sel = LayoutSelection()
        sel.click("h2", modifier: .shift, rows: rows)
        XCTAssertEqual(sel.keys, ["h2"])
    }

    func testSelectAllAndClear() {
        var sel = LayoutSelection()
        sel.selectAll(rows)
        XCTAssertEqual(sel.keys.count, 8)
        sel.clear()
        XCTAssertTrue(sel.isEmpty)
        XCTAssertNil(sel.anchor)
    }

    func testRetainDropsVanishedTiles() {
        var sel = LayoutSelection(keys: ["s1", "gone"], anchor: "gone")
        sel.retain(rows)
        XCTAssertEqual(sel.keys, ["s1"])
        XCTAssertNil(sel.anchor)
    }

    func testDraggingASelectedTileDragsTheSelectionInRowOrder() {
        let sel = LayoutSelection(keys: ["h3", "s2", "h1"])
        XCTAssertEqual(sel.dragged(from: "h1", rows: rows), ["s2", "h1", "h3"])
        XCTAssertEqual(sel.dragged(from: "s4", rows: rows), ["s4"])
    }
}

final class LayoutDragTests: XCTestCase {
    func tile(_ key: String, _ bundle: String, _ section: Section = .hidden) -> LayoutTile {
        LayoutTile(key: key, items: [Fixtures.item(key, bundle: bundle, app: bundle)], section: section)
    }

    func spacer(_ id: String) -> LayoutTile {
        let s = LayoutSpacer(id: id)
        return LayoutTile(key: s.key, items: [], spacer: s, section: .shown)
    }

    func testAppsAreDeduplicated() {
        let contents = LayoutDragContents(tiles: [
            tile("m1", "com.example.meters", .shown), tile("m2", "com.example.meters", .shown), tile("c", "com.example.chat"),
            tile("w", "com.example.weather"),
        ])
        XCTAssertEqual(contents.bundleIDs, ["com.example.meters", "com.example.chat", "com.example.weather"])
        XCTAssertEqual(contents.label, "3 apps")
    }

    func testLabels() {
        XCTAssertNil(LayoutDragContents(tiles: [tile("c", "com.example.chat")]).label)
        XCTAssertEqual(LayoutDragContents(tiles: [tile("m1", "com.example.meters"), tile("m2", "com.example.meters")]).label, "2 items")
        XCTAssertEqual(LayoutDragContents(tiles: [tile("c", "com.example.chat"), spacer("S")]).label, "1 app, 1 spacer")
        XCTAssertEqual(LayoutDragContents(tiles: [spacer("S"), spacer("T")]).label, "2 spacers")
        XCTAssertEqual(LayoutDragContents(tiles: [tile("c", "a"), tile("d", "b"), spacer("S"), spacer("T")]).label, "2 apps, 2 spacers")
    }

    func testDropOnAnotherSectionMovesWholeApps() {
        let contents = LayoutDragContents(tiles: [tile("m1", "com.example.meters", .shown), tile("c", "com.example.chat", .shown), spacer("S")])
        XCTAssertEqual(LayoutDrop.outcome(dragging: contents, onto: .alwaysHidden, gap: nil, row: []),
                       .moveApps(["com.example.meters", "com.example.chat"], to: .alwaysHidden))
    }

    func testSpacersAndAppleItemsStayInShown() {
        let wifi = LayoutTile(key: "module:WiFi", items: [Fixtures.item("module:WiFi", bundle: "com.apple.controlcenter", app: "CC", apple: true)], section: .shown)
        let outcome = LayoutDrop.outcome(dragging: LayoutDragContents(tiles: [spacer("S"), wifi]), onto: .hidden, gap: nil, row: [])
        XCTAssertEqual(outcome, .none("Spacers and Apple’s items always stay in Shown."))
    }

    func testReorderWithinShown() {
        let row = [tile("a", "A", .shown), tile("b", "B", .shown), spacer("S"), tile("c", "C", .shown),
                   LayoutTile(key: "clock", items: [Fixtures.item("clock", bundle: "com.apple.controlcenter", app: "CC", apple: true)], section: .shown, isLocked: true)]
        // Drag a and the spacer to the end (gap past the locked clock counts as the end of the movable tiles).
        let outcome = LayoutDrop.outcome(dragging: LayoutDragContents(tiles: [row[0], row[2]]), onto: .shown, gap: 5, row: row)
        XCTAssertEqual(outcome, .reorder(.shown, order: ["b", "c", "a", "spacer:S"], appsIn: []))
        // Dropping where it already is changes nothing.
        XCTAssertEqual(LayoutDrop.outcome(dragging: LayoutDragContents(tiles: [row[1]]), onto: .shown, gap: 1, row: row), .none(nil))
        // Locked tiles can't be dragged.
        XCTAssertEqual(LayoutDrop.outcome(dragging: LayoutDragContents(tiles: [row[4]]), onto: .shown, gap: 0, row: row), .none(nil))
    }

    func testDropFromHiddenIntoShownMovesAppsAndPlacesThem() {
        let row = [tile("a", "A", .shown), tile("b", "B", .shown)]
        let hidden = LayoutTile(key: "h1", items: [Fixtures.item("h1", bundle: "H", app: "H"), Fixtures.item("h2", bundle: "H", app: "H")], section: .hidden)
        let outcome = LayoutDrop.outcome(dragging: LayoutDragContents(tiles: [hidden]), onto: .shown, gap: 1, row: row)
        XCTAssertEqual(outcome, .reorder(.shown, order: ["a", "h1", "h2", "b"], appsIn: ["H"]))
    }
}

final class LayoutEditorRowsTests: XCTestCase {
    func testRowsFollowTheSavedOrderWithLockedItemsLast() {
        let items = [
            Fixtures.item("status:com.example.meters::CPU", bundle: "com.example.meters", app: "Meters", name: "Meters: CPU"),
            Fixtures.item("status:org.example.clipboard::Item-0", bundle: "org.example.clipboard", app: "Clipboard"),
            Fixtures.item("status:com.example.chat::Item-0", bundle: "com.example.chat", app: "Chat"),
            Fixtures.item("com.example.tunnel#0", bundle: "com.example.tunnel", app: "Tunnel"),
            Fixtures.item("module:Clock", bundle: "com.apple.controlcenter", app: "Control Center", name: "Clock", apple: true, axID: AppleItems.clockIdentifier),
            Fixtures.item("module:WiFi", bundle: "com.apple.controlcenter", app: "Control Center", name: "Wi-Fi", apple: true, axID: "com.apple.menuextra.wifi"),
        ]
        let sections = AppSectionMap(apps: [
            "com.example.meters": .shown, "org.example.clipboard": .shown, "com.example.tunnel": .alwaysHidden,
        ], defaultSection: .hidden)
        let spacer = LayoutSpacer(id: "S", width: 20)
        let layout = DesiredLayout(shownOrder: ["status:org.example.clipboard::Item-0", "spacer:S", "status:com.example.gone::Item-0",
                                                "status:com.example.meters::CPU", "module:WiFi"], spacers: [spacer])
        let live = ["status:com.example.meters::CPU", "status:org.example.clipboard::Item-0", "module:WiFi"]
        let rows = LayoutEditorRows.rows(items: items, liveShown: live, sections: sections, layout: layout) { _ in false }
        XCTAssertEqual(rows[.shown]?.map(\.key), ["status:org.example.clipboard::Item-0", "spacer:S", "status:com.example.meters::CPU", "module:WiFi", "module:Clock"])
        XCTAssertEqual(rows[.shown]?.last?.isLocked, true)
        XCTAssertEqual(rows[.hidden]?.map(\.key), ["status:com.example.chat::Item-0"])
        XCTAssertEqual(rows[.alwaysHidden]?.map(\.key), ["com.example.tunnel#0"])
        XCTAssertEqual(rows[.shown]?[1].helpText, "Spacer, 20 pt")
        XCTAssertEqual(rows[.shown]?[2].helpText, "Meters: CPU")
        XCTAssertTrue(rows[.shown]?.last?.helpText.contains("can’t be moved") ?? false)
    }

    func testAppTileTooltipNamesTheCount() {
        let items = [
            Fixtures.item("status:com.example.chat::A", bundle: "com.example.chat", app: "Chat"),
            Fixtures.item("status:com.example.chat::B", bundle: "com.example.chat", app: "Chat"),
        ]
        let rows = LayoutEditorRows.rows(items: items, liveShown: [], sections: AppSectionMap(), layout: DesiredLayout()) { _ in false }
        XCTAssertEqual(rows[.hidden]?.count, 1)
        XCTAssertEqual(rows[.hidden]?.first?.helpText, "Chat (2 items)")
        XCTAssertEqual(rows[.hidden]?.first?.orderKeys.count, 2)
    }
}

final class LayoutBackupStoreTests: XCTestCase {
    var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("snugbar-backup-tests-\(UUID().uuidString)")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    func testOldFormatDecodes() throws {
        let json = #"{"createdAt":"2026-11-13T17:11:02Z","positions":{"module:WiFi":160},"schemaVersion":1,"systemBuild":"27C100"}"#
        let backup = try LayoutBackup.decode(Data(json.utf8))
        XCTAssertEqual(backup.positions, ["module:WiFi": 160])
        XCTAssertNil(backup.layout)
        XCTAssertNil(backup.reason)
        XCTAssertEqual(backup.itemCount, 1)
    }

    func testNewFormatRoundTrips() throws {
        var settings = Settings()
        settings.sections.set(.shown, forBundleID: "com.example.chat")
        settings.layout = DesiredLayout(shownOrder: ["spacer:S", "status:com.example.chat::Item-0"], spacers: [LayoutSpacer(id: "S")])
        let backup = LayoutBackup(createdAt: Date(timeIntervalSince1970: 1_800_000_000), systemBuild: "27C100", positions: [:],
                                  layout: .init(settings: settings), reason: "reset")
        let decoded = try LayoutBackup.decode(backup.encoded())
        XCTAssertEqual(decoded, backup)
        XCTAssertEqual(decoded.itemCount, 2)
        var restored = Settings()
        decoded.layout?.apply(to: &restored)
        XCTAssertEqual(restored.sections, settings.sections)
        XCTAssertEqual(restored.layout, settings.layout)
    }

    func testStoreSavesListsAndPrunes() throws {
        let store = LayoutBackupStore(directory: dir, keep: 3)
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        for i in 0..<5 {
            try store.save(LayoutBackup(createdAt: start.addingTimeInterval(Double(i)), systemBuild: "B\(i)", positions: ["k\(i)": 1]))
        }
        try Data("not a backup".utf8).write(to: dir.appendingPathComponent("notes.txt"))
        try Data("{}".utf8).write(to: dir.appendingPathComponent("20200101-000000-000.json"))
        // Same millisecond: a second file, not an overwrite. The undecodable old file is pruned as the oldest.
        try store.save(LayoutBackup(createdAt: start.addingTimeInterval(4), systemBuild: "B4b", positions: [:]))
        let list = store.list()
        XCTAssertEqual(list.map(\.systemBuild), ["B4b", "B4", "B3"])
        XCTAssertEqual(list.first?.hasLayout, false)
        let names = try FileManager.default.contentsOfDirectory(atPath: dir.path)
        XCTAssertTrue(names.contains("notes.txt"))
        XCTAssertEqual(names.filter { $0.hasSuffix(".json") }.count, 3)
    }
}

final class SettingsTransferTests: XCTestCase {
    func testBadJSON() {
        XCTAssertThrowsError(try SettingsTransfer.decodeImport(Data("hello".utf8))) {
            XCTAssertEqual($0 as? SettingsTransfer.ImportError, .notJSON)
        }
        XCTAssertThrowsError(try SettingsTransfer.decodeImport(Data("[1,2]".utf8))) {
            XCTAssertEqual($0 as? SettingsTransfer.ImportError, .notJSON)
        }
    }

    func testMissingAndNewerSchemaVersion() {
        XCTAssertThrowsError(try SettingsTransfer.decodeImport(Data(#"{"showIcon":true}"#.utf8))) {
            XCTAssertEqual($0 as? SettingsTransfer.ImportError, .missingSchemaVersion)
        }
        XCTAssertThrowsError(try SettingsTransfer.decodeImport(Data(#"{"schemaVersion":99}"#.utf8))) { error in
            XCTAssertEqual(error as? SettingsTransfer.ImportError, .newerSchemaVersion(99))
            XCTAssertTrue(String(describing: error).contains("newer SnugBar"))
        }
    }

    func testWrongTypeIsExplained() {
        XCTAssertThrowsError(try SettingsTransfer.decodeImport(Data(#"{"schemaVersion":1,"showIcon":"yes"}"#.utf8))) { error in
            guard case let .invalid(why)? = error as? SettingsTransfer.ImportError else { return XCTFail("\(error)") }
            XCTAssertTrue(why.contains("showIcon"), why)
        }
    }

    func testOldJSONTakesDefaults() throws {
        let s = try SettingsTransfer.decodeImport(Data(#"{"schemaVersion":1,"showIcon":false}"#.utf8))
        XCTAssertFalse(s.showIcon)
        XCTAssertEqual(s.layout, DesiredLayout())
        XCTAssertEqual(s.hotkeys, HotkeySettings())
    }

    func testExportRoundTripsWithoutSecrets() throws {
        var s = Settings()
        s.layout.spacers = [LayoutSpacer(id: "S")]
        let data = try SettingsTransfer.export(s)
        XCTAssertEqual(try SettingsTransfer.decodeImport(data), s)
        let text = String(decoding: data, as: UTF8.self)
        XCTAssertFalse(text.contains("\"token\""))
        XCTAssertFalse(text.contains("Bookmark"))
        XCTAssertTrue(text.contains("\n  "), "pretty-printed")
    }

    func testResetLayout() {
        var s = Settings()
        s.sections = AppSectionMap(apps: ["com.example.chat": .shown, "com.example.vpn": .alwaysHidden], defaultSection: .alwaysHidden)
        s.layout = DesiredLayout(shownOrder: ["a"], spacers: [LayoutSpacer(id: "S")])
        s.knownApps = ["com.example.chat": "Chat"]
        s.showIcon = false
        let r = LayoutReset.reset(s)
        XCTAssertEqual(r.sections.apps, [:])
        XCTAssertEqual(r.sections.defaultSection, .alwaysHidden)
        XCTAssertEqual(r.layout, DesiredLayout())
        XCTAssertEqual(r.knownApps, s.knownApps)
        XCTAssertFalse(r.showIcon)
        XCTAssertEqual(r.sections.section(forBundleID: "com.example.chat"), .alwaysHidden)
    }
}
