import Foundation

/// The pages of the setup window (feature 85), in order.
public enum SetupStep: String, CaseIterable, Codable, Sendable {
    case welcome
    case accessibility
    case screenRecording
    case menuBarFolder
    case done

    /// The permission a page asks for.
    public var permission: PermissionKind? {
        switch self {
        case .accessibility: return .accessibility
        case .screenRecording: return .screenRecording
        case .menuBarFolder: return .menuBarFolder
        case .welcome, .done: return nil
        }
    }

    /// Pages that can be skipped (Continue is called Skip there until the permission is given).
    public var isOptional: Bool { permission.map { !$0.isRequired } ?? false }

    public var title: String {
        switch self {
        case .welcome: return "Welcome to SnugBar"
        case .accessibility, .screenRecording, .menuBarFolder: return permission?.title ?? ""
        case .done: return "Ready"
        }
    }

    /// Parses `welcome`, `accessibility`, `screenRecording` (also `screen-recording`), `menuBarFolder`, `done`.
    public init?(name: String) {
        let key = name.lowercased().filter { $0.isLetter }
        guard let step = Self.allCases.first(where: { $0.rawValue.lowercased() == key }) else { return nil }
        self = step
    }
}

/// Where the setup window is and what its buttons say.
public struct SetupFlow: Equatable, Sendable {
    public private(set) var step: SetupStep

    public init(step: SetupStep = .welcome) {
        self.step = step
    }

    /// The pages counted in "Step 2 of 4": every page but the last.
    public static let countedSteps: [SetupStep] = SetupStep.allCases.filter { $0 != .done }

    /// "Step 2 of 4", or nil on the last page.
    public var progressText: String? {
        guard let i = Self.countedSteps.firstIndex(of: step) else { return nil }
        return "Step \(i + 1) of \(Self.countedSteps.count)"
    }

    public var canGoBack: Bool { step != .welcome }

    public var isLast: Bool { step == .done }

    /// "Continue", or "Skip" on an optional page whose permission isn't given. Nil on the last page (it has its own
    /// buttons).
    public func forwardTitle(grants: PermissionGrants) -> String? {
        guard !isLast else { return nil }
        if step.isOptional, let permission = step.permission, !grants.has(permission) { return "Skip" }
        return "Continue"
    }

    /// Continue always works, even without Accessibility (SnugBar then runs in reduced mode).
    public mutating func forward() {
        guard let i = SetupStep.allCases.firstIndex(of: step), i + 1 < SetupStep.allCases.count else { return }
        step = SetupStep.allCases[i + 1]
    }

    public mutating func back() {
        guard let i = SetupStep.allCases.firstIndex(of: step), i > 0 else { return }
        step = SetupStep.allCases[i - 1]
    }

    public mutating func go(to step: SetupStep) {
        self.step = step
    }

    /// Pages after the Accessibility page say SnugBar runs in reduced mode when Accessibility is still missing.
    public func showsReducedModeNote(grants: PermissionGrants) -> Bool {
        guard !grants.accessibility, let i = SetupStep.allCases.firstIndex(of: step),
              let ax = SetupStep.allCases.firstIndex(of: .accessibility) else { return false }
        return i > ax
    }
}

/// Whether to show the setup window at launch.
public enum SetupLaunchDecision {
    public struct Decision: Equatable, Sendable {
        public var show: Bool
        /// A value to store in `Settings.setupCompleted` now, when it changes.
        public var store: Bool?
    }

    /// - Parameters:
    ///   - setupCompleted: the setting; nil when the settings file doesn't have it.
    ///   - settingsFileExists: the settings file was there before this launch.
    ///   - accessibility: Accessibility is granted now.
    ///
    /// A settings file from before the setup window existed (no key) with Accessibility already granted counts as
    /// set up, so existing users aren't greeted again. A fresh install, or an existing one without Accessibility,
    /// shows it; the setting is then stored as false so a later launch keeps showing it until it is finished.
    public static func decide(setupCompleted: Bool?, settingsFileExists: Bool, accessibility: Bool) -> Decision {
        switch setupCompleted {
        case true?: return Decision(show: false, store: nil)
        case false?: return Decision(show: true, store: nil)
        case nil:
            if settingsFileExists && accessibility { return Decision(show: false, store: true) }
            return Decision(show: true, store: false)
        }
    }
}

/// Continuous sliders rounded in code, so no tick marks are drawn (1 s and 0.1 s steps in Settings > General).
public enum SliderStep {
    public static func rounded(_ value: Double, step: Double, in range: ClosedRange<Double>) -> Double {
        guard step > 0, value.isFinite else { return min(max(value.isFinite ? value : range.lowerBound, range.lowerBound), range.upperBound) }
        let clamped = min(max(value, range.lowerBound), range.upperBound)
        let steps = (clamped / step).rounded()
        // Divide by the inverse for steps like 0.1, so 3 steps is 0.3 rather than 0.30000000000000004.
        let inverse = 1 / step
        let result = abs(inverse - inverse.rounded()) < 1e-9 ? steps / inverse.rounded() : steps * step
        return min(max(result, range.lowerBound), range.upperBound)
    }
}
