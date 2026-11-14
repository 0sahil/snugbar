import XCTest
@testable import SnugBarCore

final class SettingsPaneTests: XCTestCase {
    func testSidebarOrder() {
        XCTAssertEqual(SettingsPane.allCases.map(\.title), ["General", "Sections", "Shortcuts", "Control", "Permissions"])
    }

    func testLookupByNameOrTitle() {
        XCTAssertEqual(SettingsPane(name: "control"), .control)
        XCTAssertEqual(SettingsPane(name: " General "), .general)
        XCTAssertEqual(SettingsPane(name: "PERMISSIONS"), .permissions)
        XCTAssertNil(SettingsPane(name: "advanced"))
        XCTAssertNil(SettingsPane(name: ""))
    }

    func testRawValuesRoundTrip() {
        for pane in SettingsPane.allCases {
            XCTAssertEqual(SettingsPane(rawValue: pane.rawValue), pane)
            XCTAssertFalse(pane.systemImage.isEmpty)
        }
    }
}
