import XCTest
@testable import SnugBarCore

/// Reduced mode once saved fallback IDs (`<bundle>#0`, `com.apple.menuextra.wifi#0`) of items Shown's order already had
/// under order-file keys. Adoption ignores them, a reconcile without the reader saves nothing, and loading removes them.
final class LayoutDuplicateTests: XCTestCase {
    let chat = "status:com.example.chat::Item-0"
    let clipboard = "status:org.example.clipboard::Item-0"
    let cpu = "status:com.example.meters::CPU_mini"
    let ram = "status:com.example.meters::RAM_mini"
    /// An app the order file has no key for: its fallback ID is the only name it has.
    let tunnel = "com.example.tunnel#0"

    var saved: [String] { [chat, "spacer:S", clipboard, "module:WiFi", cpu, ram, tunnel, "module:Battery"] }

    // MARK: - Cleanup

    func testShadowedFallbacksAreRemovedAndTheRestKeepsItsOrder() {
        let polluted = saved + ["com.example.chat#0", "com.apple.menuextra.wifi#0", "com.example.meters#0",
                                "com.example.meters#1", "com.apple.menuextra.battery#0"]
        XCTAssertEqual(DesiredOrder.removingShadowedFallbacks(polluted), saved)
    }

    func testDuplicatesInTheMiddleAreRemovedInPlace() {
        let polluted = [chat, "com.example.chat#0", clipboard, "com.apple.menuextra.wifi#0", "module:WiFi", tunnel]
        XCTAssertEqual(DesiredOrder.removingShadowedFallbacks(polluted), [chat, clipboard, "module:WiFi", tunnel])
    }

    func testGenuineFallbackIDsAreKept() {
        // No order-file key for these apps or Apple items: nothing is a duplicate.
        let order = [tunnel, "com.example.vpn#0", "com.example.vpn#1", "com.apple.menuextra.focusmode#0", chat]
        XCTAssertEqual(DesiredOrder.removingShadowedFallbacks(order), order)
        // `module:FocusModes` matches `focusmode` with the plural tolerated, as the resolver does.
        XCTAssertEqual(DesiredOrder.removingShadowedFallbacks(order + ["module:FocusModes"]),
                       [tunnel, "com.example.vpn#0", "com.example.vpn#1", chat, "module:FocusModes"])
    }

    func testAllThreeOrdersAreCleaned() {
        var layout = DesiredLayout(shownOrder: [chat, "com.example.chat#0"], hiddenOrder: ["com.example.meters#0", cpu],
                                   alwaysHiddenOrder: [tunnel])
        XCTAssertTrue(layout.removeShadowedFallbacks())
        XCTAssertEqual(layout.shownOrder, [chat])
        XCTAssertEqual(layout.hiddenOrder, [cpu])
        XCTAssertEqual(layout.alwaysHiddenOrder, [tunnel])
        XCTAssertFalse(layout.removeShadowedFallbacks(), "idempotent")
    }

    /// The settings file as reduced mode left it: loading repairs it.
    func testLoadingASettingsFileRemovesTheDuplicates() throws {
        let json = """
        {"schemaVersion": 2, "layout": {"shownOrder": [
          "status:com.example.chat::Item-0", "spacer:S", "status:org.example.clipboard::Item-0", "module:WiFi",
          "com.example.tunnel#0", "com.example.chat#0", "org.example.clipboard#0", "com.apple.menuextra.wifi#0"
        ], "spacers": [{"id": "S", "width": 16}]}}
        """
        let settings = try SettingsStore.decode(Data(json.utf8))
        XCTAssertEqual(settings.layout.shownOrder, [chat, "spacer:S", clipboard, "module:WiFi", tunnel])
        XCTAssertEqual(settings.layout.spacers, [LayoutSpacer(id: "S", width: 16)])
    }

    func testAFileWithoutDuplicatesLoadsUnchanged() throws {
        var s = Settings()
        s.layout = DesiredLayout(shownOrder: saved, spacers: [LayoutSpacer(id: "S")])
        XCTAssertEqual(try SettingsStore.decode(SettingsStore.encode(s)).layout, s.layout)
    }

    // MARK: - Adoption

    func testAdoptionIgnoresFallbackIDsOfItemsSavedUnderOrderFileKeys() {
        // Read without the order file: every item has a fallback ID.
        let live = ["org.example.clipboard#0", "com.example.chat#0", "com.apple.menuextra.wifi#0", tunnel]
        XCTAssertEqual(DesiredOrder.adopting(live: live, into: saved), saved)
        XCTAssertEqual(DesiredOrder.unshadowed(live: live, desired: saved), [tunnel])
    }

    func testAdoptionStillAddsNewApps() {
        let live = [chat, "com.example.notes#0", clipboard]
        let adopted = DesiredOrder.adopting(live: live, into: [chat, clipboard])
        XCTAssertEqual(adopted, [chat, "com.example.notes#0", clipboard])
    }

    // MARK: - Reconcile

    func testWithoutTheReaderNothingIsPlannedWrittenOrSaved() {
        let layout = DesiredLayout(shownOrder: [chat, clipboard], hiddenOrder: [ram, cpu])
        for explicit in [false, true] {
            let e = LayoutReconcile.evaluate(
                layout: layout, live: ["com.example.chat#0", "org.example.clipboard#0", "com.example.notes#0"],
                positions: Fixtures.positions, ownBundleID: "app.example.SnugBar",
                sectionKeys: [.hidden: [cpu, ram]], readerAvailable: false, explicit: explicit
            )
            XCTAssertEqual(e.decision.action, .skipped)
            XCTAssertEqual(e.decision.reasons, [LayoutReconcile.noReaderReason])
            XCTAssertNil(e.orderToSave)
            XCTAssertEqual(e.sectionOrdersToSave, [:])
            XCTAssertEqual(e.fileChanges, [:])
        }
        XCTAssertTrue(LayoutReconcile.noReaderReason.contains("Device Control and Data Access"))
    }

    func testReconcileDoesNotMergeFallbackIDsOfSavedItems() {
        // No order file: items can't be named by their keys. The saved order must not gain duplicates.
        let layout = DesiredLayout(shownOrder: [chat, clipboard, "module:WiFi"])
        let live = ["com.example.chat#0", "org.example.clipboard#0", "com.apple.menuextra.wifi#0"]
        let e = LayoutReconcile.evaluate(layout: layout, live: live, positions: nil, ownBundleID: "x", explicit: true)
        XCTAssertNil(e.orderToSave)
    }
}
