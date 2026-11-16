import CoreGraphics
import Foundation

/// The look of SnugBar's own icon in the menu bar ("Menu bar icon" in Settings > General).
///
/// Adding a style: add a case here (with its title and, for SF Symbol styles, `symbolName(for:)`), then give it a
/// glyph provider in the app (`MenuBarIconRenderer`). The switches over this enum make the compiler point at both.
public enum MenuBarIconStyle: String, CaseIterable, Codable, Sendable, Identifiable {
    /// SF Symbols: a left chevron when collapsed, a right chevron when expanded. The default, and the only look before
    /// the setting existed.
    case chevrons
    /// Glyphs drawn in code: a small capsule (the menu bar) with dots (its items).
    case capsule

    public static let `default` = MenuBarIconStyle.chevrons

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .chevrons: return "Chevrons"
        case .capsule: return "Capsule"
        }
    }

    /// The SF Symbol for a state, for styles made of system symbols; nil for styles drawn in code.
    public func symbolName(for state: MenuBarIconState) -> String? {
        switch self {
        case .chevrons:
            switch state {
            case .collapsed: return "chevron.left"
            case .expanded: return "chevron.right"
            case .all: return "chevron.right.2"
            case .swapped: return "arrow.left.arrow.right"
            case .zen: return "eye.slash"
            case .warning: return "exclamationmark.triangle"
            }
        case .capsule:
            return nil
        }
    }

    /// Unknown values (a file from a newer SnugBar with a style this one doesn't have) fall back to the default
    /// instead of failing the whole settings file.
    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = MenuBarIconStyle(rawValue: raw) ?? .default
    }
}

/// What SnugBar's icon shows, derived from the bar state, the permissions and the last error.
public enum MenuBarIconState: String, CaseIterable, Sendable {
    /// Hidden items are hidden.
    case collapsed
    /// Hidden items are shown.
    case expanded
    /// Always Hidden items are shown too.
    case all
    /// Shown and Hidden have traded places, and nothing extra is revealed.
    case swapped
    /// Zen mode.
    case zen
    /// Accessibility is missing or something failed: the icon asks for attention.
    case warning

    /// The state for the icon. A warning wins over everything, then Zen, then a swapped collapsed bar.
    public static func resolve(_ state: BarState, accessibilityGranted: Bool, hasError: Bool) -> MenuBarIconState {
        if !accessibilityGranted || hasError { return .warning }
        if state.zen { return .zen }
        if state.swapped && state.reveal == .collapsed { return .swapped }
        switch state.reveal {
        case .collapsed: return .collapsed
        case .expanded: return .expanded
        case .all: return .all
        }
    }
}

/// Geometry of the Capsule style's glyphs, in points, origin bottom-left (AppKit drawing). The renderer draws these
/// shapes; keeping the numbers here lets them be tested.
public struct CapsuleGlyphGeometry: Equatable, Sendable {
    /// The image size: the usual square status item glyph canvas.
    public static let canvas = CGSize(width: 18, height: 18)
    public static let capsuleSize = CGSize(width: 17, height: 9)
    public static let strokeWidth: CGFloat = 1.4
    public static let dotDiameter: CGFloat = 2.6
    /// Centre-to-centre distance of the three dots.
    public static let dotSpacing: CGFloat = 4.2

    /// The capsule's outline path rect: centred, inset by half the stroke so the outer edge is exactly 17×9 pt.
    public let capsule: CGRect
    /// The capsule's outer edge.
    public let outer: CGRect
    public let corner: CGFloat

    public init() {
        let c = Self.canvas, s = Self.capsuleSize
        outer = CGRect(x: (c.width - s.width) / 2, y: (c.height - s.height) / 2, width: s.width, height: s.height)
        capsule = outer.insetBy(dx: Self.strokeWidth / 2, dy: Self.strokeWidth / 2)
        corner = capsule.height / 2
    }

    /// Dot rects: one (centred) or three (centred row).
    public func dots(_ count: Int) -> [CGRect] {
        let d = Self.dotDiameter
        let centres: [CGFloat]
        switch count {
        case 1: centres = [outer.midX]
        default: centres = [-1, 0, 1].map { outer.midX + $0 * Self.dotSpacing }
        }
        return centres.map { CGRect(x: $0 - d / 2, y: outer.midY - d / 2, width: d, height: d) }
    }

    /// The Zen slash: a diagonal from the capsule's lower left to its upper right, a little past the outline.
    public var slash: (from: CGPoint, to: CGPoint) {
        (CGPoint(x: outer.minX + 3.5, y: outer.minY - 1.5), CGPoint(x: outer.maxX - 3.5, y: outer.maxY + 1.5))
    }

    /// The Swapped glyph fills this half of the capsule (the left one).
    public var swappedFill: CGRect {
        CGRect(x: outer.minX, y: outer.minY, width: outer.width / 2, height: outer.height)
    }
}
