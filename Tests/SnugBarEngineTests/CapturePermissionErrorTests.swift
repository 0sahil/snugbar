import Foundation
import ScreenCaptureKit
import XCTest
@testable import SnugBarEngine

/// A capture refused for lack of Screen Recording turns pictures off; other capture failures don't.
final class CapturePermissionErrorTests: XCTestCase {
    func testScreenCaptureKitRefusalIsAPermissionError() {
        let declined = NSError(domain: SCStreamErrorDomain, code: SCStreamError.Code.userDeclined.rawValue)
        XCTAssertTrue(ItemImager.isPermissionError(declined))
        let wrapped = NSError(domain: "com.example.wrapper", code: 1, userInfo: [NSUnderlyingErrorKey: declined])
        XCTAssertTrue(ItemImager.isPermissionError(wrapped))
        XCTAssertTrue(ItemImager.isPermissionError(ItemImager.CaptureError.noPermission))
    }

    func testOtherFailuresAreNot() {
        XCTAssertFalse(ItemImager.isPermissionError(NSError(domain: SCStreamErrorDomain, code: SCStreamError.Code.noDisplayList.rawValue)))
        XCTAssertFalse(ItemImager.isPermissionError(NSError(domain: NSCocoaErrorDomain, code: SCStreamError.Code.userDeclined.rawValue)))
        XCTAssertFalse(ItemImager.isPermissionError(ItemImager.CaptureError.noDisplay))
        XCTAssertFalse(ItemImager.isPermissionError(ItemImager.CaptureError.failed("x")))
    }
}
