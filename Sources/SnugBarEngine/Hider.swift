import Foundation

public enum HiderBackend: String, Codable, Sendable {
    /// Per-app hiding by the system (see `AssessmentHider`).
    case assessment
    /// Public API: a divider status item pushes everything left of it into the system overflow.
    case overflowDivider
}

/// Hides menu bar items. Implementations never crash when their mechanism is missing; they report it through
/// `isAvailable` and `lastError` so the app can fall back.
@MainActor
public protocol Hider: AnyObject {
    var backend: HiderBackend { get }
    var isAvailable: Bool { get }
    var lastError: String? { get }
    /// True while hiding is requested.
    var isHiding: Bool { get }
    /// Whether `hide(allowing:)` honours the allow-list. The divider hider can't: it hides by position.
    var supportsAllowList: Bool { get }

    /// Hides every third-party app's items except those of `allowedBundleIDs`.
    func hide(allowing allowedBundleIDs: Set<String>) throws
    /// Stops hiding.
    func show()
}

public enum HiderError: Error, CustomStringConvertible {
    case unavailable(String)

    public var description: String {
        switch self {
        case let .unavailable(why): return "hider unavailable: \(why)"
        }
    }
}
