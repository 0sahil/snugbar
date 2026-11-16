import XCTest
@testable import SnugBarCore

/// The setup window's steps, the launch decision and slider rounding (Screen Recording's restart line:
/// ScreenRecordingAccessTests).
final class SetupTests: XCTestCase {
    // MARK: - Steps

    func testStepsAreInOrder() {
        XCTAssertEqual(SetupStep.allCases, [.welcome, .accessibility, .screenRecording, .menuBarFolder, .done])
        XCTAssertEqual(SetupStep.allCases.compactMap(\.permission), [.accessibility, .screenRecording, .menuBarFolder])
    }

    func testOnlyScreenRecordingAndFolderAreOptional() {
        XCTAssertEqual(SetupStep.allCases.filter(\.isOptional), [.screenRecording, .menuBarFolder])
    }

    func testContinueWalksEveryStepAndStopsAtTheEnd() {
        var flow = SetupFlow()
        var seen = [flow.step]
        for _ in 0..<10 {
            flow.forward()
            if seen.last != flow.step { seen.append(flow.step) }
        }
        XCTAssertEqual(seen, SetupStep.allCases)
        XCTAssertTrue(flow.isLast)
        XCTAssertNil(flow.forwardTitle(grants: .all))
    }

    func testBackWalksBackAndStopsAtWelcome() {
        var flow = SetupFlow(step: .done)
        flow.back()
        XCTAssertEqual(flow.step, .menuBarFolder)
        flow.back(); flow.back(); flow.back()
        XCTAssertEqual(flow.step, .welcome)
        XCTAssertFalse(flow.canGoBack)
        flow.back()
        XCTAssertEqual(flow.step, .welcome)
    }

    func testProgressCountsFourStepsAndNoneOnTheLastPage() {
        XCTAssertEqual(SetupFlow(step: .welcome).progressText, "Step 1 of 4")
        XCTAssertEqual(SetupFlow(step: .accessibility).progressText, "Step 2 of 4")
        XCTAssertEqual(SetupFlow(step: .menuBarFolder).progressText, "Step 4 of 4")
        XCTAssertNil(SetupFlow(step: .done).progressText)
    }

    func testOptionalStepsSayskipUntilGranted() {
        XCTAssertEqual(SetupFlow(step: .screenRecording).forwardTitle(grants: .none), "Skip")
        XCTAssertEqual(SetupFlow(step: .screenRecording).forwardTitle(grants: .init(accessibility: false, screenRecording: true, orderFile: false)), "Continue")
        XCTAssertEqual(SetupFlow(step: .menuBarFolder).forwardTitle(grants: .none), "Skip")
        XCTAssertEqual(SetupFlow(step: .menuBarFolder).forwardTitle(grants: .init(accessibility: false, screenRecording: false, orderFile: true)), "Continue")
    }

    func testAccessibilityIsRequiredButContinueStillWorks() {
        var flow = SetupFlow(step: .accessibility)
        XCTAssertEqual(flow.forwardTitle(grants: .none), "Continue")
        flow.forward()
        XCTAssertEqual(flow.step, .screenRecording)
        XCTAssertEqual(SetupFlow(step: .welcome).forwardTitle(grants: .none), "Continue")
    }

    func testReducedModeNoteOnlyAfterTheAccessibilityPageWithoutIt() {
        for step in SetupStep.allCases {
            let after = [.screenRecording, .menuBarFolder, .done].contains(step)
            XCTAssertEqual(SetupFlow(step: step).showsReducedModeNote(grants: .none), after, step.rawValue)
            XCTAssertFalse(SetupFlow(step: step).showsReducedModeNote(grants: .all), step.rawValue)
        }
    }

    func testGoToOpensAPage() {
        var flow = SetupFlow()
        flow.go(to: .accessibility)
        XCTAssertEqual(flow.step, .accessibility)
    }

    func testStepNames() {
        XCTAssertEqual(SetupStep(name: "screenRecording"), .screenRecording)
        XCTAssertEqual(SetupStep(name: "screen-recording"), .screenRecording)
        XCTAssertEqual(SetupStep(name: "MenuBarFolder"), .menuBarFolder)
        XCTAssertEqual(SetupStep(name: "done"), .done)
        XCTAssertNil(SetupStep(name: "privacy"))
    }

    // MARK: - When to show setup

    func testFreshInstallShowsSetupAndRemembersItIsNotDone() {
        XCTAssertEqual(SetupLaunchDecision.decide(setupCompleted: nil, settingsFileExists: false, accessibility: false),
                       .init(show: true, store: false))
        // A fresh install shows it even when Accessibility is already granted (from an earlier copy).
        XCTAssertEqual(SetupLaunchDecision.decide(setupCompleted: nil, settingsFileExists: false, accessibility: true),
                       .init(show: true, store: false))
    }

    func testExistingInstallWithAccessibilityIsNotGreetedAgain() {
        XCTAssertEqual(SetupLaunchDecision.decide(setupCompleted: nil, settingsFileExists: true, accessibility: true),
                       .init(show: false, store: true))
    }

    func testExistingInstallWithoutAccessibilityShowsSetup() {
        XCTAssertEqual(SetupLaunchDecision.decide(setupCompleted: nil, settingsFileExists: true, accessibility: false),
                       .init(show: true, store: false))
    }

    func testStoredValueWins() {
        for exists in [false, true] {
            for ax in [false, true] {
                XCTAssertEqual(SetupLaunchDecision.decide(setupCompleted: true, settingsFileExists: exists, accessibility: ax),
                               .init(show: false, store: nil))
                XCTAssertEqual(SetupLaunchDecision.decide(setupCompleted: false, settingsFileExists: exists, accessibility: ax),
                               .init(show: true, store: nil))
            }
        }
    }

    func testSetupCompletedRoundTripsAndIsAbsentFromOlderFiles() throws {
        let old = Data(#"{"schemaVersion": 1, "showIcon": true}"#.utf8)
        XCTAssertNil(try SettingsStore.decode(old).setupCompleted)
        XCTAssertNil(Settings.default.setupCompleted)
        let defaultJSON = String(decoding: try SettingsStore.encode(.default), as: UTF8.self)
        XCTAssertFalse(defaultJSON.contains("setupCompleted"))

        var settings = Settings.default
        settings.setupCompleted = true
        let data = try SettingsStore.encode(settings)
        XCTAssertTrue(String(decoding: data, as: UTF8.self).contains(#""setupCompleted" : true"#))
        XCTAssertEqual(try SettingsStore.decode(data).setupCompleted, true)
        settings.setupCompleted = false
        XCTAssertEqual(try SettingsStore.decode(try SettingsStore.encode(settings)).setupCompleted, false)
    }

    // MARK: - Sliders

    func testDelaySliderRoundsToWholeSeconds() {
        let range = 1.0...120.0
        XCTAssertEqual(SliderStep.rounded(9.4, step: 1, in: range), 9)
        XCTAssertEqual(SliderStep.rounded(9.5, step: 1, in: range), 10)
        XCTAssertEqual(SliderStep.rounded(0.2, step: 1, in: range), 1)
        XCTAssertEqual(SliderStep.rounded(130, step: 1, in: range), 120)
        XCTAssertEqual(SliderStep.rounded(119.7, step: 1, in: range), 120)
    }

    func testHoverSliderRoundsToTenthsExactly() {
        let range = 0.1...3.0
        XCTAssertEqual(SliderStep.rounded(0.3333, step: 0.1, in: range), 0.3)
        XCTAssertEqual(SliderStep.rounded(0.26, step: 0.1, in: range), 0.3)
        XCTAssertEqual(SliderStep.rounded(1.04, step: 0.1, in: range), 1.0)
        XCTAssertEqual(SliderStep.rounded(0.0, step: 0.1, in: range), 0.1)
        XCTAssertEqual(SliderStep.rounded(3.2, step: 0.1, in: range), 3.0)
        XCTAssertEqual(String(format: "%.1f", SliderStep.rounded(2.749, step: 0.1, in: range)), "2.7")
        // Every value is a whole number of tenths, without binary leftovers.
        for i in 1...30 {
            let v = SliderStep.rounded(Double(i) / 10 + 0.01, step: 0.1, in: range)
            XCTAssertEqual(v, Double(i) / 10)
        }
        XCTAssertEqual(SliderStep.rounded(.nan, step: 0.1, in: range), 0.1)
    }
}
