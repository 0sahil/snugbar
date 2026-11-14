import Foundation

/// Decides when a menu bar item may be captured (SPEC 3.5).
///
/// Right after the bar changes (SnugBar wrote the order file, changed the hider's allow-list, added or resized a
/// spacer, or the user ⌘-dragged) macOS animates items into their new places for a moment. Accessibility already
/// reports the new frames while the pixels are still moving, so a strip captured then and cropped by those frames
/// shows half an item, a shifted one, or part of a neighbour. The gate lets an item be captured only when its frame
/// has been the same on two consecutive reads at least `stableInterval` apart, both after the last bar change, and
/// `quietAfterBarChange` has passed since that change. Until then the item keeps its last good picture.
public struct CaptureSettleGate: Sendable {
    public static let stableInterval: TimeInterval = 0.3
    public static let quietAfterBarChange: TimeInterval = 0.8
    /// Frames within this many points count as the same.
    public static let tolerance: Double = 0.5

    public enum Decision: Equatable, Sendable {
        case captureNow
        /// Read the frames again at this time (or later) and ask again.
        case wait(until: Date)
    }

    private struct Seen: Sendable {
        var frame: Rect
        /// The first read that showed this frame (after the last bar change).
        var since: Date
        /// The latest read that showed it.
        var lastRead: Date
    }

    private var seen: [String: Seen] = [:]
    public private(set) var lastBarChange: Date?

    public init() {}

    /// The bar is changing now: every frame read before counts as stale.
    public mutating func noteBarChange(at time: Date) {
        lastBarChange = max(lastBarChange ?? time, time)
        seen.removeAll()
    }

    /// One read of the frames of the items in the bar, by key. Items missing from the read are forgotten.
    public mutating func record(_ frames: [String: Rect], at time: Date) {
        var next: [String: Seen] = [:]
        for (key, frame) in frames {
            if var s = seen[key], Self.same(s.frame, frame) {
                s.lastRead = time
                next[key] = s
            } else {
                next[key] = Seen(frame: frame, since: time, lastRead: time)
            }
        }
        seen = next
    }

    public func decision(for key: String, at now: Date) -> Decision {
        let quietUntil = lastBarChange.map { $0.addingTimeInterval(Self.quietAfterBarChange) } ?? .distantPast
        guard let s = seen[key] else {
            return .wait(until: max(now.addingTimeInterval(Self.stableInterval), quietUntil))
        }
        let stableAt = s.since.addingTimeInterval(Self.stableInterval)
        if s.lastRead >= stableAt, now >= quietUntil { return .captureNow }
        return .wait(until: max(stableAt, quietUntil, now))
    }

    /// The keys to capture now, and when to read again for the others (nil when none is waiting).
    public func split(_ keys: [String], at now: Date) -> (ready: [String], readAgainAt: Date?) {
        var ready: [String] = []
        var next: Date?
        for key in keys {
            switch decision(for: key, at: now) {
            case .captureNow: ready.append(key)
            case let .wait(until): next = min(next ?? until, until)
            }
        }
        return (ready, next)
    }

    /// Whether every key may be captured now: the bar has settled (used after a ⌘-drag before reading its order).
    public func isSettled(_ keys: [String], at now: Date) -> Bool {
        split(keys, at: now).readAgainAt == nil
    }

    static func same(_ a: Rect, _ b: Rect) -> Bool {
        abs(a.x - b.x) <= tolerance && abs(a.y - b.y) <= tolerance
            && abs(a.width - b.width) <= tolerance && abs(a.height - b.height) <= tolerance
    }
}

/// Whether a new capture of an item may replace its cached picture.
public enum CaptureValidation {
    /// - Parameters:
    ///   - capturedWidth: the crop's width in points.
    ///   - currentWidth: the item's frame width read after capturing (nil when it was gone).
    ///   - isBlank: nothing but the bar's background was left after keying.
    public static func accepts(capturedWidth: Double, currentWidth: Double?, isBlank: Bool, tolerance: Double = 1) -> Bool {
        guard !isBlank, let currentWidth, currentWidth > 0, capturedWidth > 0 else { return false }
        return abs(capturedWidth - currentWidth) <= tolerance
    }
}
