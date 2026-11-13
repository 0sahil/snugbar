import Foundation

/// When a revealed menu bar collapses again by itself (features 4–6).
public struct AutoCollapseSettings: Codable, Equatable, Sendable {
    public var enabled: Bool
    /// Seconds after revealing.
    public var delay: Double
    /// Collapse when the user clicks outside the menu bar.
    public var onClickOutside: Bool
    /// Collapse when another app becomes active (unless it's an app that was just revealed).
    public var onAppSwitch: Bool

    public init(enabled: Bool = true, delay: Double = 10, onClickOutside: Bool = true, onAppSwitch: Bool = true) {
        self.enabled = enabled
        self.delay = delay
        self.onClickOutside = onClickOutside
        self.onAppSwitch = onAppSwitch
    }

    public static let delayRange: ClosedRange<Double> = 1...120

    public init(from decoder: Decoder) throws {
        let d = AutoCollapseSettings()
        let c = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? d.enabled
        delay = try c.decodeIfPresent(Double.self, forKey: .delay) ?? d.delay
        onClickOutside = try c.decodeIfPresent(Bool.self, forKey: .onClickOutside) ?? d.onClickOutside
        onAppSwitch = try c.decodeIfPresent(Bool.self, forKey: .onAppSwitch) ?? d.onAppSwitch
    }
}

public enum AutoCollapsePolicy {
    public enum TimerDecision: Equatable, Sendable {
        case collapse
        /// Check again later: the user is still using the revealed items.
        case postpone
        /// Nothing to do (already collapsed or auto-collapse off).
        case ignore
    }

    /// What to do when the auto-collapse timer fires.
    /// - Parameters:
    ///   - menuOpen: a revealed item's menu or popover is open (feature 6).
    ///   - pointerInMenuBar: the pointer is over the menu bar, e.g. heading for a revealed item.
    public static func onTimer(
        state: BarState, settings: AutoCollapseSettings, menuOpen: Bool, pointerInMenuBar: Bool
    ) -> TimerDecision {
        guard settings.enabled, !state.isCollapsed else { return .ignore }
        if menuOpen || pointerInMenuBar { return .postpone }
        return .collapse
    }

    /// Whether a click outside the menu bar collapses. A click while a revealed item's menu is open is the user
    /// choosing a menu entry or dismissing it, so the collapse waits for the timer instead.
    public static func onClickOutside(state: BarState, settings: AutoCollapseSettings, menuOpen: Bool) -> Bool {
        settings.enabled && settings.onClickOutside && !state.isCollapsed && !menuOpen
    }

    /// Whether an app switch collapses. Clicking a revealed item often activates its app; that must not collapse.
    public static func onAppActivated(
        bundleID: String?, state: BarState, settings: AutoCollapseSettings, revealedBundleIDs: Set<String>, ownBundleID: String?
    ) -> Bool {
        guard settings.enabled, settings.onAppSwitch, !state.isCollapsed else { return false }
        guard let bundleID else { return true }
        if bundleID == ownBundleID { return false }
        return !revealedBundleIDs.contains(bundleID)
    }
}

/// Ways to reveal the Hidden section with the pointer (features 10–12).
public struct RevealSettings: Codable, Equatable, Sendable {
    /// Click an empty part of the menu bar to expand or collapse.
    public var clickEmptyBar: Bool
    /// Rest the pointer on an empty part of the menu bar to expand.
    public var hover: Bool
    public var hoverDelay: Double
    /// Scroll or swipe down on the menu bar to expand, up to collapse.
    public var scroll: Bool

    public init(clickEmptyBar: Bool = true, hover: Bool = false, hoverDelay: Double = 0.4, scroll: Bool = false) {
        self.clickEmptyBar = clickEmptyBar
        self.hover = hover
        self.hoverDelay = hoverDelay
        self.scroll = scroll
    }

    public static let hoverDelayRange: ClosedRange<Double> = 0.1...3

    public init(from decoder: Decoder) throws {
        let d = RevealSettings()
        let c = try decoder.container(keyedBy: CodingKeys.self)
        clickEmptyBar = try c.decodeIfPresent(Bool.self, forKey: .clickEmptyBar) ?? d.clickEmptyBar
        hover = try c.decodeIfPresent(Bool.self, forKey: .hover) ?? d.hover
        hoverDelay = try c.decodeIfPresent(Double.self, forKey: .hoverDelay) ?? d.hoverDelay
        scroll = try c.decodeIfPresent(Bool.self, forKey: .scroll) ?? d.scroll
    }
}

/// Scroll gestures over the menu bar, accumulated until they pass a threshold so a light touch does nothing.
public struct ScrollGesture: Sendable {
    public enum Direction: Equatable, Sendable { case down, up }

    public var threshold: Double
    private var accumulated: Double = 0
    private var lastEventAt: Double = -.infinity

    public init(threshold: Double = 6) {
        self.threshold = threshold
    }

    /// Feed one scroll event. `deltaY` > 0 means content moves down (fingers swipe down with natural scrolling).
    /// Returns a direction once per gesture, when the threshold is crossed. Pauses over 0.3 s start a new gesture.
    public mutating func feed(deltaY: Double, at time: Double) -> Direction? {
        if time - lastEventAt > 0.3 { accumulated = 0 }
        lastEventAt = time
        guard accumulated.isFinite else { return nil }
        accumulated += deltaY
        if accumulated >= threshold {
            accumulated = .infinity // fire once until the gesture ends
            return .down
        }
        if accumulated <= -threshold {
            accumulated = .infinity
            return .up
        }
        return nil
    }
}
