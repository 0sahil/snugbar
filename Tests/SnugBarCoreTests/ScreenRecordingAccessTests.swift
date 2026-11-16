import XCTest
@testable import SnugBarCore

/// Screen Recording while SnugBar runs: the fresh system check, this process's captures, and the restart line.
final class ScreenRecordingAccessTests: XCTestCase {
    private let t0 = Date(timeIntervalSinceReferenceDate: 1_000_000)

    func testLaunchStates() {
        let granted = ScreenRecordingAccess(preflight: true)
        XCTAssertEqual(granted.state, .granted)
        XCTAssertTrue(granted.isUsable)
        XCTAssertTrue(granted.needsProbe, "allowed but not tried yet")

        let denied = ScreenRecordingAccess(preflight: false)
        XCTAssertEqual(denied.state, .notGranted)
        XCTAssertFalse(denied.isUsable)
        XCTAssertFalse(denied.needsRestart)
        XCTAssertFalse(denied.needsProbe, "never probe without the permission: it could prompt")
    }

    /// The on-device bug: switched off in System Settings while running.
    func testRevokeWhileRunningIsSeenByTheFreshCheck() {
        var access = ScreenRecordingAccess(preflight: true)
        access.noteCapture(.succeeded)
        XCTAssertEqual(access.state, .granted)
        access.noteSystemCheck(granted: false)
        XCTAssertEqual(access.state, .notGranted)
        XCTAssertFalse(access.isUsable)
        XCTAssertFalse(access.needsRestart)
    }

    /// Granted after launch: allowed by the system, but this process can't capture until it restarts.
    func testGrantAfterLaunchNeedsRestartUntilACaptureWorks() {
        var access = ScreenRecordingAccess(preflight: false)
        access.noteSystemCheck(granted: true)
        XCTAssertEqual(access.state, .grantedNeedsRestart)
        XCTAssertTrue(access.needsRestart)
        XCTAssertFalse(access.isUsable, "app icons until it works")
        XCTAssertTrue(access.needsProbe)
        access.noteProbe(.refused)
        XCTAssertEqual(access.state, .grantedNeedsRestart)
        access.noteProbe(.failed)
        XCTAssertEqual(access.state, .grantedNeedsRestart, "an unrelated failure says nothing")
        // macOS applied it without a restart after all.
        access.noteProbe(.succeeded)
        XCTAssertEqual(access.state, .granted)
        XCTAssertFalse(access.needsProbe)
    }

    func testRevokeThenRegrantShowsTheRestartLine() {
        var access = ScreenRecordingAccess(preflight: true)
        access.noteCapture(.succeeded)
        access.noteSystemCheck(granted: false)
        access.noteSystemCheck(granted: true)
        XCTAssertEqual(access.state, .grantedNeedsRestart)
        XCTAssertTrue(access.needsProbe)
    }

    func testARefusedCaptureTurnsPicturesOffAndMakesTheCheckDue() {
        var access = ScreenRecordingAccess(preflight: true)
        access.noteCheckStarted(at: t0)
        access.noteSystemCheck(granted: true)
        XCTAssertFalse(access.checkIsDue(at: t0.addingTimeInterval(0.5)))
        access.noteCapture(.refused)
        XCTAssertEqual(access.state, .notGranted, "app icons at once")
        XCTAssertTrue(access.checkIsDue(at: t0.addingTimeInterval(0.5)), "the next check tells revoked from needs restart")
        // Still allowed in System Settings: this process needs a restart.
        access.noteSystemCheck(granted: true)
        XCTAssertEqual(access.state, .grantedNeedsRestart)
        // Or really revoked.
        var revoked = ScreenRecordingAccess(preflight: true)
        revoked.noteCapture(.refused)
        revoked.noteSystemCheck(granted: false)
        XCTAssertEqual(revoked.state, .notGranted)
    }

    func testAFailedCaptureChangesNothing() {
        var access = ScreenRecordingAccess(preflight: true)
        access.noteCapture(.failed)
        XCTAssertEqual(access.state, .granted)
        XCTAssertNil(access.lastCheck)
    }

    func testASuccessfulCaptureProvesThePermission() {
        var access = ScreenRecordingAccess(state: .notGranted)
        access.noteCapture(.succeeded)
        XCTAssertEqual(access.state, .granted)
        XCTAssertFalse(access.needsProbe)
    }

    func testTheCheckRunsAtMostEveryTwoSeconds() {
        XCTAssertEqual(ScreenRecordingAccess.checkInterval, 2)
        var access = ScreenRecordingAccess(preflight: true)
        XCTAssertTrue(access.checkIsDue(at: t0), "never checked")
        access.noteCheckStarted(at: t0)
        XCTAssertFalse(access.checkIsDue(at: t0))
        XCTAssertFalse(access.checkIsDue(at: t0.addingTimeInterval(1.9)))
        XCTAssertTrue(access.checkIsDue(at: t0.addingTimeInterval(2)))
        XCTAssertTrue(access.checkIsDue(at: t0.addingTimeInterval(-5)), "the clock went back")
    }

    func testPreviewStates() {
        for state in [ScreenRecordingState.notGranted, .granted, .grantedNeedsRestart] {
            XCTAssertEqual(ScreenRecordingAccess(state: state).state, state)
        }
        XCTAssertTrue(ScreenRecordingAccess(state: .grantedNeedsRestart).systemGranted)
    }

    func testHelperOutput() {
        XCTAssertEqual(ScreenRecordingAccess.preflightFlag, "--preflight-screen-recording")
        XCTAssertEqual(ScreenRecordingAccess.parsePreflight(ScreenRecordingAccess.preflightOutput(true)), true)
        XCTAssertEqual(ScreenRecordingAccess.parsePreflight(ScreenRecordingAccess.preflightOutput(false)), false)
        XCTAssertEqual(ScreenRecordingAccess.parsePreflight("granted\n"), true)
        XCTAssertNil(ScreenRecordingAccess.parsePreflight(""))
        XCTAssertNil(ScreenRecordingAccess.parsePreflight("usage: snugbar <command>"))
    }
}
