import AppKit
import SnugBarCore

/// How much room a menu bar has for status items (feature 17), in global top-left coordinates.
public struct MenuBarSpace: Codable, Equatable, Sendable {
    public var screenName: String
    /// The menu bar strip of the screen.
    public var strip: Rect
    /// The camera housing, when the screen has one.
    public var notch: Rect?
    /// Right end of the frontmost app's menus; only used on screens without a notch.
    public var appMenusMaxX: Double?
    /// Room for status items: right of the notch, or right of the app menus without one.
    public var availableWidth: Double
    public var hasNotch: Bool { notch != nil }
}

@MainActor
public enum MenuBarSpaceProbe {
    /// The space of the menu bar that holds the status items: the screen under the clock (or another Apple item),
    /// else the screen with the menu bar's key focus, else the primary screen.
    public static func space(for items: [MenuBarItem]) -> MenuBarSpace? {
        let anchor = items.first { $0.axIdentifier == AppleItems.clockIdentifier }
            ?? items.first { $0.isAppleItem && $0.frame.width > 0 }
        let point = anchor.map { CGPoint(x: $0.frame.midX, y: $0.frame.midY) }
        return space(at: point)
    }

    /// The space of the screen whose menu bar contains `point` (global top-left), or of the main screen.
    public static func space(at point: CGPoint?) -> MenuBarSpace? {
        let screens = NSScreen.screens
        let strips = MenuBarScreens.strips()
        guard !strips.isEmpty else { return nil }
        var index = 0
        if let point, let i = strips.firstIndex(where: { $0.frame.contains(point) }) {
            index = i
        } else if let main = NSScreen.main, let i = screens.firstIndex(of: main), i < strips.count {
            index = i
        }
        let strip = strips[index]
        // App menus only limit a screen without a notch: with one, the room right of the notch is what counts.
        let menus = strip.notch == nil ? MenuBarEventMonitor.appMenusMaxX().map(Double.init) : nil
        let menusOnThisScreen = menus.flatMap { strip.frame.minX <= $0 && $0 <= strip.frame.maxX ? $0 : nil }
        let available = FitPlanner.availableWidth(
            stripMinX: strip.frame.minX, stripMaxX: strip.frame.maxX,
            notchMaxX: strip.notch.map { Double($0.maxX) }, appMenusMaxX: menusOnThisScreen
        )
        return MenuBarSpace(
            screenName: index < screens.count ? screens[index].localizedName : "screen \(index)",
            strip: strip.frame.coreRect,
            notch: strip.notch?.coreRect,
            appMenusMaxX: menusOnThisScreen,
            availableWidth: available
        )
    }
}
