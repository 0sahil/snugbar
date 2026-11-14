import XCTest
@testable import SnugBarCore

final class SearchLayoutTests: XCTestCase {
    let layout = SearchLayout(rowHeight: 30, maxVisibleRows: 8, listPadding: 8)
    let header = 63.0

    func testOneResultMakesRoomForExactlyOneRow() {
        // The panel holds the header, even padding and the whole row: nothing is cut off.
        XCTAssertEqual(layout.visibleRows(resultCount: 1), 1)
        XCTAssertEqual(layout.listHeight(resultCount: 1), 30)
        XCTAssertEqual(layout.panelHeight(header: header, resultCount: 1), 63 + 8 + 30 + 8)
    }

    func testThePanelGrowsWithEachResultUpToTheLimit() {
        for n in 1...8 {
            XCTAssertEqual(layout.panelHeight(header: header, resultCount: n), header + 16 + 30 * Double(n))
            XCTAssertFalse(layout.scrolls(resultCount: n))
        }
        XCTAssertEqual(layout.visibleRows(resultCount: 9), 8)
        XCTAssertEqual(layout.panelHeight(header: header, resultCount: 40), header + 16 + 240)
        XCTAssertTrue(layout.scrolls(resultCount: 9))
    }

    func testNoResultsKeepOneRowForNoMatches() {
        XCTAssertEqual(layout.visibleRows(resultCount: 0), 1)
        XCTAssertEqual(layout.panelHeight(header: header, resultCount: 0), layout.panelHeight(header: header, resultCount: 1))
        XCTAssertFalse(layout.scrolls(resultCount: 0))
    }
}
