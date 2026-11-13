import CoreGraphics
import XCTest
@testable import SnugBarEngine

final class MenuBarStripTests: XCTestCase {
    func testPrimaryScreenStripFromVisibleFrameGap() {
        // 1470x956 notched screen, 37 pt menu bar, Dock at the bottom.
        let strip = MenuBarGeometry.menuBarStrip(
            screenFrame: CGRect(x: 0, y: 0, width: 1470, height: 956),
            visibleFrame: CGRect(x: 0, y: 70, width: 1470, height: 849),
            primaryScreenHeight: 956, fallbackHeight: 24
        )
        XCTAssertEqual(strip, CGRect(x: 0, y: 0, width: 1470, height: 37))
    }

    func testAutoHiddenBarUsesFallbackAndSecondaryScreenOffset() {
        // A 1920x1080 screen above the primary one.
        let strip = MenuBarGeometry.menuBarStrip(
            screenFrame: CGRect(x: -200, y: 956, width: 1920, height: 1080),
            visibleFrame: CGRect(x: -200, y: 956, width: 1920, height: 1080),
            primaryScreenHeight: 956, fallbackHeight: 24
        )
        XCTAssertEqual(strip, CGRect(x: -200, y: -1080, width: 1920, height: 24))
    }

    func testTopLeftRect() {
        let r = MenuBarGeometry.topLeftRect(fromCocoa: CGRect(x: 600, y: 920, width: 200, height: 36), primaryScreenHeight: 956)
        XCTAssertEqual(r, CGRect(x: 600, y: 0, width: 200, height: 36))
    }
}

final class OpenMenuDetectorTests: XCTestCase {
    private func window(pid: Int32, layer: Int) -> [String: Any] {
        [kCGWindowOwnerPID as String: NSNumber(value: pid), kCGWindowLayer as String: NSNumber(value: layer)]
    }

    func testPopUpMenuOfAnyAppCounts() {
        XCTAssertTrue(OpenMenuDetector.isMenuOpen(windowList: [window(pid: 50, layer: 101)], ownerPIDs: [], excludingPID: 1))
    }

    func testOwnMenuDoesNotCount() {
        XCTAssertFalse(OpenMenuDetector.isMenuOpen(windowList: [window(pid: 1, layer: 101)], ownerPIDs: [], excludingPID: 1))
    }

    func testRevealedAppPopoverCountsButNormalWindowsDoNot() {
        XCTAssertTrue(OpenMenuDetector.isMenuOpen(windowList: [window(pid: 7, layer: 8)], ownerPIDs: [7], excludingPID: 1))
        XCTAssertFalse(OpenMenuDetector.isMenuOpen(windowList: [window(pid: 7, layer: 0)], ownerPIDs: [7], excludingPID: 1))
        XCTAssertFalse(OpenMenuDetector.isMenuOpen(windowList: [window(pid: 8, layer: 8)], ownerPIDs: [7], excludingPID: 1))
        XCTAssertFalse(OpenMenuDetector.isMenuOpen(windowList: [window(pid: 7, layer: 25)], ownerPIDs: [7], excludingPID: 1))
    }
}
