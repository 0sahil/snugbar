import XCTest
@testable import SnugBarCore

final class BulkSectionMoveTests: XCTestCase {
    func testTitleNamesTheCount() {
        XCTAssertEqual(BulkSectionMove.title(count: 0), "Move To…")
        XCTAssertEqual(BulkSectionMove.title(count: 1), "Move To…")
        XCTAssertEqual(BulkSectionMove.title(count: 3), "Move 3 Apps To…")
    }

    func testTargetsFollowListOrderAndDropUnlisted() {
        let rows = ["com.example.chat", "com.example.meters", "com.example.weather"]
        XCTAssertEqual(BulkSectionMove.targets(selection: ["com.example.weather", "com.example.chat"], rows: rows),
                       ["com.example.chat", "com.example.weather"])
        XCTAssertEqual(BulkSectionMove.targets(selection: ["com.example.gone", "com.example.meters"], rows: rows),
                       ["com.example.meters"])
        XCTAssertEqual(BulkSectionMove.targets(selection: [], rows: rows), [])
    }

    func testSetSeveralAppsAtOnce() {
        var map = AppSectionMap(apps: ["com.example.chat": .hidden, "com.example.meters": .shown], defaultSection: .hidden)
        map.set(.alwaysHidden, forBundleIDs: ["com.example.chat", "com.example.new"])
        XCTAssertEqual(map.apps, ["com.example.chat": .alwaysHidden, "com.example.meters": .shown, "com.example.new": .alwaysHidden])
        map.set(.shown, forBundleIDs: [])
        XCTAssertEqual(map.apps.count, 3)
    }
}
