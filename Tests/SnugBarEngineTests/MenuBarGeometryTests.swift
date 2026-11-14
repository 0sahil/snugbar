import CoreGraphics
import XCTest
@testable import SnugBarEngine

final class MenuBarGeometryTests: XCTestCase {
    // A notched 1470 pt wide screen: the « button sits just right of the notch.
    let indicator = CGRect(x: 830, y: 0, width: 28, height: 33)

    func testOverflowedItemsOverlapTheIndicator() {
        XCTAssertTrue(MenuBarGeometry.isOverflowed(CGRect(x: 830, y: 0, width: 28, height: 33), indicator: indicator))
        XCTAssertTrue(MenuBarGeometry.isOverflowed(CGRect(x: 822, y: 0, width: 40, height: 33), indicator: indicator))
    }

    func testAdjacentVisibleItemsAreNotOverflowed() {
        XCTAssertFalse(MenuBarGeometry.isOverflowed(CGRect(x: 858, y: 0, width: 30, height: 33), indicator: indicator))
        XCTAssertFalse(MenuBarGeometry.isOverflowed(CGRect(x: 858.5, y: 0, width: 30, height: 33), indicator: indicator))
        // Rounding overlap of under a point is ignored.
        XCTAssertFalse(MenuBarGeometry.isOverflowed(CGRect(x: 857.5, y: 0, width: 30, height: 33), indicator: indicator))
    }

    func testNoIndicatorMeansNothingOverflowed() {
        XCTAssertFalse(MenuBarGeometry.isOverflowed(CGRect(x: 830, y: 0, width: 28, height: 33), indicator: nil))
    }

    func testCocoaToTopLeft() {
        let p = MenuBarGeometry.topLeftPoint(fromCocoa: CGPoint(x: 1372, y: 947), primaryScreenHeight: 956)
        XCTAssertEqual(p, CGPoint(x: 1372, y: 9))
    }

    func testHitTolerance() {
        let clock = CGRect(x: 1340, y: 0, width: 120, height: 33)
        XCTAssertTrue(MenuBarGeometry.hit(CGPoint(x: 1372, y: 9), in: clock))
        XCTAssertTrue(MenuBarGeometry.hit(CGPoint(x: 1339, y: 9), in: clock))
        XCTAssertFalse(MenuBarGeometry.hit(CGPoint(x: 1300, y: 9), in: clock))
        XCTAssertFalse(MenuBarGeometry.hit(CGPoint(x: 1372, y: 60), in: clock))
    }

    func testExtrasMatchByFrame() {
        let target = CGRect(x: 1000, y: 0, width: 30, height: 33)
        let candidates: [CGRect?] = [CGRect(x: 960, y: 0, width: 30, height: 24), CGRect(x: 1001, y: 0, width: 30, height: 24)]
        XCTAssertEqual(MenuBarGeometry.matchExtrasItem(target: target, indexInApp: 0, appItemCount: 2, candidates: candidates), 1)
    }

    func testExtrasSingleItemMatchesEvenWhenFramesDiffer() {
        // An overflowed item: MenuBarAgent reports it stacked at «, the app reports somewhere else.
        let target = CGRect(x: 830, y: 0, width: 28, height: 33)
        let candidates: [CGRect?] = [CGRect(x: -500, y: 0, width: 30, height: 24)]
        XCTAssertEqual(MenuBarGeometry.matchExtrasItem(target: target, indexInApp: 0, appItemCount: 1, candidates: candidates), 0)
    }

    func testExtrasFallBackToOrder() {
        let target = CGRect(x: 830, y: 0, width: 28, height: 33)
        let candidates: [CGRect?] = [CGRect(x: -400, y: 0, width: 30, height: 24), CGRect(x: -500, y: 0, width: 30, height: 24)]
        // Index 1 left to right is the one at x = -400 (candidate 0).
        XCTAssertEqual(MenuBarGeometry.matchExtrasItem(target: target, indexInApp: 1, appItemCount: 2, candidates: candidates), 0)
    }

    func testExtrasNoMatch() {
        let target = CGRect(x: 1000, y: 0, width: 30, height: 33)
        XCTAssertNil(MenuBarGeometry.matchExtrasItem(target: target, indexInApp: 0, appItemCount: 2, candidates: []))
        XCTAssertNil(MenuBarGeometry.matchExtrasItem(
            target: target, indexInApp: 0, appItemCount: 3, candidates: [CGRect(x: 0, y: 0, width: 30, height: 24)]
        ))
    }
}

final class NotificationCenterDetectorTests: XCTestCase {
    func testIgnoresDesktopWidgets() {
        // Desktop widgets (Forecast, Up Next) are Notification Center windows on a negative desktop layer.
        let widget: [String: Any] = [
            kCGWindowOwnerName as String: "Notification Centre",
            kCGWindowLayer as String: -2147483601,
            kCGWindowBounds as String: ["X": 258, "Y": 41, "Width": 180, "Height": 180],
        ]
        XCTAssertFalse(NotificationCenterDetector.isPanelOpen(windowList: [widget]))
    }

    private func window(_ owner: String, width: Double) -> [String: Any] {
        [
            kCGWindowOwnerName as String: owner,
            kCGWindowLayer as String: 23,
            kCGWindowBounds as String: ["X": 1100, "Y": 0, "Width": width, "Height": 900],
        ]
    }

    func testDetectsPanelInEitherSpelling() {
        XCTAssertTrue(NotificationCenterDetector.isPanelOpen(windowList: [window("Notification Centre", width: 360)]))
        XCTAssertTrue(NotificationCenterDetector.isPanelOpen(windowList: [window("Notification Center", width: 360)]))
    }

    func testIgnoresSmallWindowsAndOtherOwners() {
        XCTAssertFalse(NotificationCenterDetector.isPanelOpen(windowList: [window("Notification Centre", width: 20)]))
        XCTAssertFalse(NotificationCenterDetector.isPanelOpen(windowList: [window("Window Server", width: 1470)]))
        XCTAssertFalse(NotificationCenterDetector.isPanelOpen(windowList: []))
    }
}

final class OrderFileLocationTests: XCTestCase {
    func testAcceptsTheContainerFolders() {
        let base = URL(fileURLWithPath: "/tmp/home/Library/Group Containers/com.apple.MenuBar")
        let expected = base.appendingPathComponent("Library/Preferences/com.apple.MenuBar.plist").path
        XCTAssertEqual(OrderFileAccess.plistURL(forPicked: base)?.path, expected)
        XCTAssertEqual(OrderFileAccess.plistURL(forPicked: base.appendingPathComponent("Library"))?.path, expected)
        XCTAssertEqual(OrderFileAccess.plistURL(forPicked: base.appendingPathComponent("Library/Preferences"))?.path, expected)
    }

    func testRejectsOtherFolders() {
        XCTAssertNil(OrderFileAccess.plistURL(forPicked: URL(fileURLWithPath: "/tmp/home/Library")))
        XCTAssertNil(OrderFileAccess.plistURL(forPicked: URL(fileURLWithPath: "/tmp/home/Library/Preferences")))
    }
}

final class ClickOutsideTests: XCTestCase {
    // AppKit coordinates on a 1470×956 pt screen: SnugBar's icon in the menu bar, the bar just below it.
    let icon = CGRect(x: 1180, y: 923, width: 28, height: 33)
    let bar = CGRect(x: 900, y: 860, width: 312, height: 59)

    func testAPressOnSnugBarsOwnIconIsNotOutside() {
        // The icon's action closes the bar; counting the press as outside closed it first and the action reopened it.
        XCTAssertFalse(MenuBarGeometry.isClickOutside(CGPoint(x: 1194, y: 940), panel: bar, ownIcon: icon))
        XCTAssertFalse(MenuBarGeometry.isClickOutside(CGPoint(x: 1181, y: 924), panel: bar, ownIcon: icon), "near the icon's corner")
    }

    func testAPressInTheBarIsNotOutside() {
        XCTAssertFalse(MenuBarGeometry.isClickOutside(CGPoint(x: 1000, y: 880), panel: bar, ownIcon: icon))
    }

    func testPressesElsewhereAreOutside() {
        XCTAssertTrue(MenuBarGeometry.isClickOutside(CGPoint(x: 400, y: 500), panel: bar, ownIcon: icon), "the desktop")
        XCTAssertTrue(MenuBarGeometry.isClickOutside(CGPoint(x: 1150, y: 940), panel: bar, ownIcon: icon), "another menu bar item")
        XCTAssertTrue(MenuBarGeometry.isClickOutside(CGPoint(x: 1194, y: 921), panel: bar, ownIcon: icon), "between the bar and the icon")
    }

    func testWithoutAnIconOnlyThePanelCounts() {
        // The icon can be turned off (or not placed yet).
        XCTAssertTrue(MenuBarGeometry.isClickOutside(CGPoint(x: 1194, y: 940), panel: bar, ownIcon: nil))
        XCTAssertTrue(MenuBarGeometry.isClickOutside(CGPoint(x: 1194, y: 940), panel: bar, ownIcon: .zero))
        XCTAssertFalse(MenuBarGeometry.isClickOutside(CGPoint(x: 1000, y: 880), panel: bar, ownIcon: nil))
    }
}

final class CleanCaptureTests: XCTestCase {
    // Global top-left coordinates: a 1470 pt wide display whose notch spans 645.5...824.5.
    let display = CGRect(x: 0, y: 0, width: 1470, height: 956)
    let notch = CGRect(x: 645.5, y: 0, width: 179, height: 33)
    let item = CGRect(x: 900, y: 0, width: 32, height: 33)

    func testAStillItemClearOfTheNotchIsKept() {
        XCTAssertTrue(MenuBarGeometry.isCleanCapture(frame: item, frameAfter: item, display: display, notch: notch))
        XCTAssertTrue(MenuBarGeometry.isCleanCapture(frame: item, frameAfter: item.offsetBy(dx: 0.5, dy: 0), display: display, notch: notch),
                      "sub-point rounding isn't movement")
        XCTAssertTrue(MenuBarGeometry.isCleanCapture(frame: item, frameAfter: item, display: display, notch: nil))
    }

    func testAnItemThatMovedDuringTheCaptureIsDropped() {
        // Items still sliding after a hide changed: the crop holds part of the glyph.
        XCTAssertFalse(MenuBarGeometry.isCleanCapture(frame: item, frameAfter: item.offsetBy(dx: -16, dy: 0), display: display, notch: notch))
        XCTAssertFalse(MenuBarGeometry.isCleanCapture(
            frame: item, frameAfter: CGRect(x: 900, y: 0, width: 40, height: 33), display: display, notch: notch), "width changed")
        XCTAssertFalse(MenuBarGeometry.isCleanCapture(frame: item, frameAfter: nil, display: display, notch: notch), "gone")
    }

    func testAnItemPartlyBehindTheNotchIsDropped() {
        let underRightEdge = CGRect(x: 810, y: 0, width: 32, height: 33)
        let underLeftEdge = CGRect(x: 630, y: 0, width: 32, height: 33)
        XCTAssertFalse(MenuBarGeometry.isCleanCapture(frame: underRightEdge, frameAfter: underRightEdge, display: display, notch: notch))
        XCTAssertFalse(MenuBarGeometry.isCleanCapture(frame: underLeftEdge, frameAfter: underLeftEdge, display: display, notch: notch))
        // Touching the notch's edge (rounding) is fine.
        let beside = CGRect(x: 824.5, y: 0, width: 32, height: 33)
        XCTAssertTrue(MenuBarGeometry.isCleanCapture(frame: beside, frameAfter: beside, display: display, notch: notch))
    }

    func testAnItemOffTheDisplayIsDropped() {
        let offRight = CGRect(x: 1450, y: 0, width: 32, height: 33)
        XCTAssertFalse(MenuBarGeometry.isCleanCapture(frame: offRight, frameAfter: offRight, display: display, notch: nil))
        XCTAssertFalse(MenuBarGeometry.isCleanCapture(frame: .zero, frameAfter: .zero, display: display, notch: nil), "no frame")
    }
}
