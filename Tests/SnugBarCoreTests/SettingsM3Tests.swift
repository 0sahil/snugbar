import XCTest
@testable import SnugBarCore

final class SettingsNewKeysTests: XCTestCase {
    /// A file as the previous version wrote it: no revealIn, moveItemsThatDontFit, recentItems or new hotkeys.
    private let olderFile = #"""
    {
      "autoCollapse" : { "delay" : 20, "enabled" : true, "onAppSwitch" : true, "onClickOutside" : true },
      "hider" : "automatic",
      "hotkeys" : { "toggleHidden" : { "keyCode" : 4, "modifiers" : [ "control", "option" ] } },
      "knownApps" : { "com.example.meters" : "Meters" },
      "reveal" : { "clickEmptyBar" : true, "hover" : false, "hoverDelay" : 0.4, "scroll" : true },
      "schemaVersion" : 1,
      "sections" : { "apps" : { "com.example.meters" : "shown" }, "defaultSection" : "hidden" },
      "showIcon" : true
    }
    """#

    func testOlderFileLoadsWithNewDefaults() throws {
        let s = try SettingsStore.decode(Data(olderFile.utf8))
        XCTAssertEqual(s.revealIn, .snugBarBar)
        XCTAssertTrue(s.moveItemsThatDontFit)
        XCTAssertEqual(s.recentItems, [])
        XCTAssertNil(s.hotkeys.search)
        XCTAssertNil(s.hotkeys.openByLetter)
        XCTAssertNil(s.hotkeys.zen)
        // Existing values are kept.
        XCTAssertEqual(s.hotkeys.toggleHidden, Hotkey(keyCode: 4, modifiers: [.control, .option]))
        XCTAssertEqual(s.autoCollapse.delay, 20)
        XCTAssertTrue(s.reveal.scroll)
        XCTAssertEqual(s.sections.apps[Fixtures.meters], .shown)
    }

    func testDefaults() {
        XCTAssertEqual(Settings.default.revealIn, .snugBarBar)
        XCTAssertTrue(Settings.default.moveItemsThatDontFit)
        XCTAssertTrue(Settings.default.recentItems.isEmpty)
        for action in HotkeyAction.allCases { XCTAssertNil(Settings.default.hotkeys[action], "\(action) unbound") }
    }

    func testNewKeysRoundTrip() throws {
        var s = Settings()
        s.revealIn = .menuBar
        s.moveItemsThatDontFit = false
        s.recentItems = [ItemID(rawValue: "status:com.example.meters::CPU_mini"), ItemID(rawValue: "com.example.chat#0")]
        s.hotkeys.search = Hotkey(keyCode: 0x31, modifiers: [.option])
        s.hotkeys.openByLetter = Hotkey(keyCode: 0x25, modifiers: [.control, .option])
        s.hotkeys.zen = Hotkey(keyCode: 0x06, modifiers: [.command, .shift, .option])
        let data = try SettingsStore.encode(s)
        XCTAssertEqual(try SettingsStore.decode(data), s)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        XCTAssertEqual(json?["revealIn"] as? String, "menuBar")
        XCTAssertEqual(json?["moveItemsThatDontFit"] as? Bool, false)
        XCTAssertEqual(json?["recentItems"] as? [String], ["status:com.example.meters::CPU_mini", "com.example.chat#0"])
        XCTAssertNotNil((json?["hotkeys"] as? [String: Any])?["zen"])
    }

    func testHotkeySubscriptCoversNewActions() {
        var h = HotkeySettings()
        let key = Hotkey(keyCode: 0x01, modifiers: [.control])
        h[.search] = key
        h[.zen] = key
        XCTAssertEqual(h.search, key)
        XCTAssertEqual(h.conflicts(for: .search), [.zen])
        h[.openByLetter] = Hotkey(keyCode: 0x02, modifiers: [.control])
        XCTAssertEqual(h.conflicts(for: .openByLetter), [])
    }
}
