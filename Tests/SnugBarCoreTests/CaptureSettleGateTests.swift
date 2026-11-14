import XCTest
@testable import SnugBarCore

final class CaptureSettleGateTests: XCTestCase {
    let t0 = Date(timeIntervalSince1970: 1_000_000)
    let a = Rect(x: 100, y: 0, width: 30, height: 24)
    let b = Rect(x: 140, y: 0, width: 22, height: 24)

    func at(_ seconds: Double) -> Date { t0.addingTimeInterval(seconds) }

    func testOneReadIsNotEnough() {
        var gate = CaptureSettleGate()
        gate.record(["a": a], at: t0)
        XCTAssertEqual(gate.decision(for: "a", at: t0), .wait(until: at(0.3)))
    }

    func testSameFrameOnTwoReadsAFewHundredMillisecondsApartCaptures() {
        var gate = CaptureSettleGate()
        gate.record(["a": a], at: t0)
        gate.record(["a": a], at: at(0.2))
        XCTAssertEqual(gate.decision(for: "a", at: at(0.2)), .wait(until: at(0.3)))
        gate.record(["a": a], at: at(0.35))
        XCTAssertEqual(gate.decision(for: "a", at: at(0.35)), .captureNow)
    }

    func testAFrameThatMovedStartsOver() {
        var gate = CaptureSettleGate()
        gate.record(["a": a], at: t0)
        var moved = a
        moved.x += 12
        gate.record(["a": moved], at: at(0.5))
        XCTAssertEqual(gate.decision(for: "a", at: at(0.5)), .wait(until: at(0.8)))
        gate.record(["a": moved], at: at(0.8))
        XCTAssertEqual(gate.decision(for: "a", at: at(0.8)), .captureNow)
        // Rounding noise doesn't count as moving.
        var jitter = moved
        jitter.width += 0.3
        gate.record(["a": jitter], at: at(1.0))
        XCTAssertEqual(gate.decision(for: "a", at: at(1.0)), .captureNow)
    }

    func testABarChangeMakesEarlierReadsStaleAndWaitsAQuietPeriod() {
        var gate = CaptureSettleGate()
        gate.record(["a": a], at: t0)
        gate.record(["a": a], at: at(1))
        XCTAssertEqual(gate.decision(for: "a", at: at(1)), .captureNow)
        // SnugBar wrote the order file: Accessibility may already report the final frame while items animate.
        gate.noteBarChange(at: at(2))
        XCTAssertEqual(gate.decision(for: "a", at: at(2)), .wait(until: at(2.8)))
        gate.record(["a": a], at: at(2.1))
        gate.record(["a": a], at: at(2.5))
        // Stable for 0.4 s, but the quiet period after the change isn't over.
        XCTAssertEqual(gate.decision(for: "a", at: at(2.5)), .wait(until: at(2.8)))
        gate.record(["a": a], at: at(2.8))
        XCTAssertEqual(gate.decision(for: "a", at: at(2.8)), .captureNow)
    }

    func testItemsMissingFromAReadAreForgotten() {
        var gate = CaptureSettleGate()
        gate.record(["a": a, "b": b], at: t0)
        gate.record(["a": a], at: at(0.5))
        gate.record(["a": a, "b": b], at: at(1))
        XCTAssertEqual(gate.decision(for: "a", at: at(1)), .captureNow)
        XCTAssertEqual(gate.decision(for: "b", at: at(1)), .wait(until: at(1.3)))
    }

    func testSplitGivesTheReadyKeysAndTheEarliestTimeToReadAgain() {
        var gate = CaptureSettleGate()
        gate.record(["a": a], at: t0)
        gate.record(["a": a, "b": b], at: at(0.4))
        let split = gate.split(["a", "b", "c"], at: at(0.4))
        XCTAssertEqual(split.ready, ["a"])
        XCTAssertEqual(split.readAgainAt?.timeIntervalSince(t0) ?? 0, 0.7, accuracy: 1e-6)
        XCTAssertFalse(gate.isSettled(["a", "b"], at: at(0.4)))
        XCTAssertTrue(gate.isSettled(["a"], at: at(0.4)))
    }

    func testValidation() {
        XCTAssertTrue(CaptureValidation.accepts(capturedWidth: 30, currentWidth: 30.6, isBlank: false))
        // Cut or shifted: the crop doesn't match the item's width now.
        XCTAssertFalse(CaptureValidation.accepts(capturedWidth: 15, currentWidth: 30, isBlank: false))
        // Only the bar's background.
        XCTAssertFalse(CaptureValidation.accepts(capturedWidth: 30, currentWidth: 30, isBlank: true))
        // The item went away.
        XCTAssertFalse(CaptureValidation.accepts(capturedWidth: 30, currentWidth: nil, isBlank: false))
    }
}
