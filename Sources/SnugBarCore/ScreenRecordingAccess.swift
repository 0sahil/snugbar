import Foundation

/// Where Screen Recording stands for the running app (feature 86).
public enum ScreenRecordingState: String, Codable, Sendable {
    case notGranted
    case granted
    /// Allowed in System Settings, but this process still can't capture: macOS applies the grant only after a
    /// restart. Settings and the setup window offer "Restart SnugBar".
    case grantedNeedsRestart
}

/// Tracks Screen Recording while SnugBar runs.
///
/// `CGPreflightScreenCaptureAccess()` keeps returning its first answer for the life of a process, so the running app
/// can't use it to notice a revoke or a grant. Two other facts are used instead:
/// - the system's answer from a fresh process (`snugbar --preflight-screen-recording`, the app's own helper, which
///   TCC attributes to SnugBar), at most every `checkInterval`, where the status matters (Settings > Permissions or
///   the setup window open, the menu opening, `status`, before a capture round);
/// - whether this process's own captures work: a capture or a probe that succeeds, or one refused for permission.
///
/// Allowed by the system and refused here is the "needs restart" state. A capture refused for permission counts as
/// not allowed until the next system check says otherwise (that check is due at once).
public struct ScreenRecordingAccess: Equatable, Sendable {
    /// What this process's own captures did last.
    public enum Capture: String, Codable, Sendable {
        /// Not tried since the system last allowed it.
        case unknown
        case works
        /// Refused for permission.
        case refused
    }

    /// What a capture or a probe in this process did.
    public enum Outcome: Equatable, Sendable {
        case succeeded
        /// Refused for permission (ScreenCaptureKit's TCC error).
        case refused
        /// Failed for another reason (no display, nothing to capture): says nothing about the permission.
        case failed
    }

    /// The fresh check runs at most this often.
    public static let checkInterval: TimeInterval = 2

    /// The hidden flag of the bundled `snugbar` helper that prints the system's answer.
    public static let preflightFlag = "--preflight-screen-recording"
    public static let preflightGranted = "granted"
    public static let preflightDenied = "denied"

    /// The system's answer as last checked.
    public private(set) var systemGranted: Bool
    public private(set) var capture: Capture
    /// When the last fresh check started; nil forces the next one.
    public private(set) var lastCheck: Date?

    /// - Parameter preflight: this process's `CGPreflightScreenCaptureAccess()` at launch. It is right at launch;
    ///   only later answers are stale. Without it, captures in this process are refused until it restarts.
    public init(preflight: Bool) {
        systemGranted = preflight
        capture = preflight ? .unknown : .refused
    }

    /// A given state, for previews and tests.
    public init(state: ScreenRecordingState) {
        switch state {
        case .notGranted: self.init(preflight: false)
        case .granted: self.init(preflight: true)
        case .grantedNeedsRestart:
            self.init(preflight: false)
            systemGranted = true
        }
    }

    public var state: ScreenRecordingState {
        guard systemGranted else { return .notGranted }
        return capture == .refused ? .grantedNeedsRestart : .granted
    }

    /// Pictures may be captured and shown; otherwise app icons.
    public var isUsable: Bool { state == .granted }

    /// The "needs restart" line and button are shown.
    public var needsRestart: Bool { state == .grantedNeedsRestart }

    /// The fresh check is due: never run, forced, or `checkInterval` since the last one.
    public func checkIsDue(at now: Date) -> Bool {
        guard let lastCheck else { return true }
        let elapsed = now.timeIntervalSince(lastCheck)
        return elapsed >= Self.checkInterval || elapsed < 0
    }

    /// A fresh check starts now (so a second caller within `checkInterval` waits for this one).
    public mutating func noteCheckStarted(at now: Date) {
        lastCheck = now
    }

    /// The fresh check's answer. A revoke takes this process's capture with it, so after a later grant the restart
    /// line shows until a capture or probe here works.
    public mutating func noteSystemCheck(granted: Bool) {
        if !granted { capture = .refused }
        systemGranted = granted
    }

    /// Whether to try this process's own capture: allowed by the system, not known to work here. Only then: a
    /// probe without the permission could prompt.
    public var needsProbe: Bool { systemGranted && capture != .works }

    /// A probe of this process's capture (no picture taken) finished. Unlike a capture, a refused probe doesn't
    /// overrule the system check it followed.
    public mutating func noteProbe(_ outcome: Outcome) {
        switch outcome {
        case .succeeded: capture = .works
        case .refused: capture = .refused
        case .failed: break
        }
    }

    /// A capture round finished. Success proves the permission; a refusal turns pictures off at once and makes the
    /// next system check due, which tells "revoked" from "needs restart".
    public mutating func noteCapture(_ outcome: Outcome) {
        switch outcome {
        case .succeeded:
            capture = .works
            systemGranted = true
        case .refused:
            capture = .refused
            systemGranted = false
            lastCheck = nil
        case .failed:
            break
        }
    }

    /// Reads the helper's output: true for `granted`, false for `denied`, nil for anything else.
    public static func parsePreflight(_ output: String) -> Bool? {
        switch output.trimmingCharacters(in: .whitespacesAndNewlines) {
        case preflightGranted: return true
        case preflightDenied: return false
        default: return nil
        }
    }

    /// The helper's output for an answer.
    public static func preflightOutput(_ granted: Bool) -> String {
        granted ? preflightGranted : preflightDenied
    }
}
