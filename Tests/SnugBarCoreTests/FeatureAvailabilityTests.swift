import XCTest
@testable import SnugBarCore

/// What works with each set of permissions (features 86, 87), the shared wording, and the reduced mode on the control
/// surface.
@MainActor
final class FeatureAvailabilityTests: XCTestCase {
    private let readerFeatures: [AppFeature] = [
        .snugBarBar, .search, .openByLetter, .layoutEditor, .revealGestures, .notificationCenter, .openItems,
        .fitHandling, .keepOrder,
    ]

    func testAllEightCombinations() {
        let combos = PermissionGrants.allCombinations
        XCTAssertEqual(combos.count, 8)
        XCTAssertEqual(Set(combos).count, 8)
        for grants in combos {
            let a = FeatureAvailability(grants: grants)
            let name = grants.listDescription
            // Basic hide and show and shortcuts always work.
            XCTAssertTrue(a.isAvailable(.hideAndShow), name)
            XCTAssertTrue(a.isAvailable(.keyboardShortcuts), name)
            for feature in readerFeatures {
                XCTAssertEqual(a.isAvailable(feature), grants.accessibility, "\(feature) with \(name)")
            }
            XCTAssertEqual(a.isAvailable(.itemPictures), grants.accessibility && grants.screenRecording, name)
            XCTAssertEqual(a.showsItemPictures, grants.accessibility && grants.screenRecording, name)
            XCTAssertEqual(a.isAvailable(.reorderWithoutPointer), grants.accessibility && grants.orderFile, name)
            XCTAssertEqual(a.isReduced, !grants.accessibility, name)
            XCTAssertEqual(a.unavailable, AppFeature.allCases.filter { !a.isAvailable($0) }, name)
            for entry in a.entries {
                XCTAssertEqual(entry.available, entry.reason == nil, "\(entry.feature) with \(name)")
                XCTAssertEqual(entry.title, entry.feature.title)
            }
        }
    }

    func testEverythingWithAllGrants() {
        let a = FeatureAvailability(grants: .all)
        XCTAssertEqual(a.unavailable, [])
        XCTAssertFalse(a.isReduced)
    }

    func testReasonsNameTheMissingPermissions() {
        let none = FeatureAvailability(grants: .none)
        XCTAssertEqual(none.reason(.search), "Needs Accessibility")
        XCTAssertEqual(none.reason(.itemPictures), "Needs Accessibility and Screen Recording")
        XCTAssertEqual(none.reason(.reorderWithoutPointer), "Needs Accessibility and Menu Bar folder")
        XCTAssertNil(none.reason(.hideAndShow))
        let axOnly = FeatureAvailability(accessibility: true, screenRecording: false, orderFile: false)
        XCTAssertEqual(axOnly.reason(.itemPictures), "Needs Screen Recording")
        XCTAssertEqual(axOnly.reason(.reorderWithoutPointer), "Needs Menu Bar folder")
        XCTAssertNil(axOnly.reason(.search))
    }

    func testGrantsParsing() {
        XCTAssertEqual(PermissionGrants(list: "none"), PermissionGrants.none)
        XCTAssertEqual(PermissionGrants(list: "accessibility,screenRecording,orderFile"), PermissionGrants.all)
        XCTAssertEqual(PermissionGrants(list: "all"), PermissionGrants.all)
        XCTAssertEqual(PermissionGrants(list: "Accessibility, menuBarFolder"),
                       PermissionGrants(accessibility: true, screenRecording: false, orderFile: true))
        XCTAssertNil(PermissionGrants(list: "accessibility,camera"))
        for grants in PermissionGrants.allCombinations {
            XCTAssertEqual(PermissionGrants(list: grants.listDescription), grants)
        }
    }

    // MARK: - Shared wording

    func testPermissionWording() {
        XCTAssertEqual(PermissionKind.accessibility.buttonTitle, "Open Accessibility Settings")
        XCTAssertEqual(PermissionKind.screenRecording.buttonTitle, "Open Screen Recording Settings")
        XCTAssertEqual(PermissionKind.menuBarFolder.buttonTitle, "Choose Folder…")
        XCTAssertTrue(PermissionKind.accessibility.isRequired)
        XCTAssertFalse(PermissionKind.screenRecording.isRequired)
        XCTAssertTrue(PermissionKind.accessibility.purpose.contains("reads the menu bar") || PermissionKind.accessibility.purpose.contains("read the menu bar"))
        XCTAssertTrue(PermissionKind.accessibility.withoutIt.contains("only basic hide and show"))
        XCTAssertTrue(PermissionKind.screenRecording.withoutIt.contains("app icons"))
        XCTAssertTrue(PermissionKind.menuBarFolder.withoutIt.contains("moves the pointer"))
        XCTAssertEqual(PermissionKind.accessibility.statusText(granted: true), "Allowed")
        XCTAssertEqual(PermissionKind.screenRecording.statusText(granted: false), "Not allowed")
        XCTAssertEqual(PermissionKind.menuBarFolder.statusText(granted: false), "Not chosen")
    }

    func testMenuAndErrorWording() {
        XCTAssertEqual(PermissionText.accessibilityNeededMenuTitle, "Accessibility Needed…")
        XCTAssertEqual(PermissionText.setUpMenuTitle, "Set Up SnugBar…")
        XCTAssertEqual(PermissionText.showSetupAgain, "Show Setup Again…")
        XCTAssertEqual(PermissionText.restartForScreenRecording, "If you just allowed it, SnugBar needs to restart to use it.")
        XCTAssertTrue(PermissionText.needsAccessibility("Opening an item").hasPrefix("Opening an item needs Accessibility permission."))
        XCTAssertTrue(PermissionText.reducedMode.contains("reduced mode"))
        // No exclamation marks or emoji anywhere in the wording.
        let all = PermissionKind.allCases.flatMap { [$0.title, $0.purpose, $0.withoutIt, $0.buttonTitle] }
            + AppFeature.allCases.map(\.title)
            + [PermissionText.welcome, PermissionText.welcomeDetail, PermissionText.reducedMode, PermissionText.doneIntro,
               PermissionText.doneChangeLater, PermissionText.privacyTelemetry, PermissionText.privacyNetwork, PermissionText.privacyServer,
               PermissionText.privacySettings, PermissionText.layoutEditorNoFolder, PermissionText.noScreenRecordingPictures]
        for text in all {
            XCTAssertFalse(text.contains("!"), text)
            XCTAssertFalse(text.unicodeScalars.contains { $0.properties.isEmojiPresentation }, text)
        }
    }

    // MARK: - Control surface

    private func engine(accessibility: Bool, screenRecording: Bool = false, folder: Bool = true) -> InMemoryControlEngine {
        let engine = InMemoryControlEngine.demo()
        engine.status.permissions = ControlPermissions(accessibility: accessibility, screenRecording: screenRecording, menuBarFolder: folder)
        return engine
    }

    func testStatusReportsReducedModeAndUnavailableFeatures() async {
        let r = await CommandRouter(engine: engine(accessibility: false, folder: false)).handle(ControlRequest(.status))
        XCTAssertTrue(r.ok)
        XCTAssertEqual(r.reducedMode, true)
        XCTAssertEqual(r.unavailable, FeatureAvailability(grants: .none).unavailable.map(\.rawValue))
        XCTAssertTrue(r.unavailable?.contains("search") ?? false)
        XCTAssertFalse(r.unavailable?.contains("hideAndShow") ?? true)
        // Existing fields are still there.
        XCTAssertEqual(r.permissions?.accessibility, false)
        XCTAssertNotNil(r.hider)
        XCTAssertNotNil(r.version)
        XCTAssertNotNil(r.state)

        let json = String(decoding: r.prettyJSON(), as: UTF8.self)
        XCTAssertTrue(json.contains(#""reducedMode" : true"#))
        XCTAssertTrue(json.contains(#""unavailable" : ["#))

        let text = CLIFormatter.status(r)
        XCTAssertTrue(text.contains("Reduced mode:"), text)
        XCTAssertTrue(text.contains("Unavailable: "), text)
        XCTAssertTrue(text.contains("Search"), text)
    }

    func testStatusWithEveryPermissionHasNothingUnavailable() async {
        let r = await CommandRouter(engine: engine(accessibility: true, screenRecording: true, folder: true)).handle(ControlRequest(.status))
        XCTAssertEqual(r.reducedMode, false)
        XCTAssertEqual(r.unavailable, [])
        let text = CLIFormatter.status(r)
        XCTAssertFalse(text.contains("Reduced mode"))
        XCTAssertFalse(text.contains("Unavailable"))
    }

    func testStatusWithoutScreenRecordingListsOnlyPictures() async {
        let r = await CommandRouter(engine: engine(accessibility: true, screenRecording: false, folder: true)).handle(ControlRequest(.status))
        XCTAssertEqual(r.reducedMode, false)
        XCTAssertEqual(r.unavailable, ["itemPictures"])
    }

    func testClickAndOrderNeedAccessibility() async {
        let e = engine(accessibility: false)
        let router = CommandRouter(engine: e)
        let click = await router.handle(ControlRequest(.click, ControlArguments(item: "chat")))
        XCTAssertFalse(click.ok)
        XCTAssertEqual(click.error?.code, .unavailable)
        XCTAssertTrue(click.error?.message.contains("needs Accessibility permission") ?? false, click.error?.message ?? "")
        let order = await router.handle(ControlRequest(.order, ControlArguments(item: "Meters: CPU", after: "clipboard")))
        XCTAssertFalse(order.ok)
        XCTAssertEqual(order.error?.code, .unavailable)
        XCTAssertTrue(order.error?.message.contains("needs Accessibility permission") ?? false)
        XCTAssertEqual(e.actions, [], "nothing was clicked or moved")
    }

    func testBasicHideAndShowWorkWithoutAccessibility() async {
        let e = engine(accessibility: false)
        let router = CommandRouter(engine: e)
        for command in [ControlCommand.expand, .collapse, .toggle, .swap] {
            let r = await router.handle(ControlRequest(command))
            XCTAssertTrue(r.ok, "\(command): \(r.error?.message ?? "")")
        }
        let zen = await router.handle(ControlRequest(.zen, ControlArguments(state: "on")))
        XCTAssertTrue(zen.ok)
        let off = await router.handle(ControlRequest(.zen, ControlArguments(state: "off")))
        XCTAssertTrue(off.ok)
        let move = await router.handle(ControlRequest(.move, ControlArguments(item: "chat", section: "shown")))
        XCTAssertTrue(move.ok)
        // `list` answers with what SnugBar knows.
        let list = await router.handle(ControlRequest(.list))
        XCTAssertTrue(list.ok)
    }

    func testClickWorksWithAccessibility() async {
        let r = await CommandRouter(engine: engine(accessibility: true)).handle(ControlRequest(.click, ControlArguments(item: "chat")))
        XCTAssertTrue(r.ok, r.error?.message ?? "")
    }
}
