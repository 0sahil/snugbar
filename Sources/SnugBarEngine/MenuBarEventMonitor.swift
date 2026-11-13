import AppKit
import ApplicationServices
import SnugBarCore

/// Watches the pointer over the menu bar for the reveal gestures (features 5, 10–12): a click on an empty part of the
/// bar, resting on it, scrolling on it, and clicks outside it. Uses global event monitors, so it only sees events that
/// go to other apps; clicks on SnugBar's own icon are handled by the icon.
@MainActor
public final class MenuBarEventMonitor {
    public struct Options: Equatable, Sendable {
        public var clickEmptyBar = false
        public var hover = false
        public var hoverDelay: TimeInterval = 0.4
        public var scroll = false
        /// Report clicks outside the menu bar (for auto-collapse).
        public var clicksOutside = false

        public init() {}
    }

    public var onEmptyBarClick: (() -> Void)?
    public var onHover: (() -> Void)?
    public var onScroll: ((ScrollGesture.Direction) -> Void)?
    public var onClickOutside: (() -> Void)?
    /// Bundle IDs whose items are currently on screen. Hidden apps' items can linger in the Accessibility tree with
    /// stale frames, so items of other apps don't count when deciding whether a point is empty. Nil means all count.
    public var visibleBundleFilter: ((String) -> Bool)?
    /// While this returns true no gesture is reported (an item is being opened: the pointer and the bar are SnugBar's).
    public var isPaused: (() -> Bool)?

    public private(set) var options = Options()

    private let reader: MenuBarReader
    private var monitors: [Any] = []
    private var hoverTimer: Timer?
    private var scroll = ScrollGesture()
    /// Set after a collapse so a pointer still resting on the bar doesn't reveal again at once.
    private var hoverSuppressed = false

    public init(reader: MenuBarReader) {
        self.reader = reader
    }

    public func apply(_ options: Options) {
        guard options != self.options || monitors.isEmpty else { return }
        self.options = options
        stop()
        var mask: NSEvent.EventTypeMask = []
        if options.clickEmptyBar || options.clicksOutside { mask.insert(.leftMouseDown) }
        if options.hover { mask.insert(.mouseMoved) }
        if options.scroll { mask.insert(.scrollWheel) }
        guard !mask.isEmpty else { return }
        if let m = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: { [weak self] event in
            // SnugBar's own synthetic clicks (opening an item) are not gestures.
            if SyntheticInput.isOwn(event.cgEvent) { return }
            let type = event.type
            let location = event.cgEvent?.location
            // Scroll properties raise an exception on other event types (and AppKit swallows it silently).
            let deltaY = type == .scrollWheel ? Double(event.scrollingDeltaY) : 0
            let time = event.timestamp
            MainActor.assumeIsolated { self?.handle(type, location: location, deltaY: deltaY, time: time) }
        }) {
            monitors.append(m)
        }
    }

    public func stop() {
        monitors.forEach(NSEvent.removeMonitor)
        monitors = []
        hoverTimer?.invalidate()
        hoverTimer = nil
    }

    /// Ignores hovering until the pointer leaves the menu bar. Call after collapsing.
    public func suppressHoverUntilPointerLeaves() {
        hoverTimer?.invalidate()
        hoverTimer = nil
        hoverSuppressed = MenuBarScreens.strip(containing: SyntheticInput.pointer) != nil
    }

    /// True when the pointer is over a menu bar right now.
    public static var pointerInMenuBar: Bool {
        MenuBarScreens.strip(containing: SyntheticInput.pointer) != nil
    }

    // MARK: - Events

    private func handle(_ type: NSEvent.EventType, location: CGPoint?, deltaY: Double, time: TimeInterval) {
        if isPaused?() == true {
            hoverTimer?.invalidate()
            hoverTimer = nil
            return
        }
        let point = location ?? SyntheticInput.pointer
        let strip = MenuBarScreens.strip(containing: point)
        switch type {
        case .leftMouseDown:
            if strip == nil {
                if options.clicksOutside { onClickOutside?() }
            } else if options.clickEmptyBar, isEmpty(point) {
                onEmptyBarClick?()
            }
        case .mouseMoved:
            if strip == nil {
                hoverTimer?.invalidate()
                hoverTimer = nil
                hoverSuppressed = false
            } else if hoverTimer == nil, !hoverSuppressed {
                hoverTimer = Timer.scheduledTimer(withTimeInterval: options.hoverDelay, repeats: false) { [weak self] _ in
                    MainActor.assumeIsolated { self?.hoverTimerFired() }
                }
            }
        case .scrollWheel:
            guard strip != nil, deltaY != 0, let direction = scroll.feed(deltaY: deltaY, at: time) else { return }
            onScroll?(direction)
        default:
            break
        }
    }

    private func hoverTimerFired() {
        hoverTimer = nil
        guard !hoverSuppressed, isPaused?() != true else { return }
        let point = SyntheticInput.pointer
        guard MenuBarScreens.strip(containing: point) != nil, isEmpty(point) else { return }
        onHover?()
    }

    /// A point on the menu bar that isn't on a status item, the « button, the notch, or the active app's menus.
    public func isEmpty(_ point: CGPoint) -> Bool {
        guard let strip = MenuBarScreens.strip(containing: point) else { return false }
        if let notch = strip.notch, notch.contains(point) { return false }
        if let menusEnd = Self.appMenusMaxX(), point.x <= menusEnd + 4, point.x >= strip.frame.minX,
           NSScreen.screens.count == 1 || strip.isPrimary {
            return false
        }
        let snapshot = reader.snapshot()
        if let indicator = snapshot.overflowIndicatorFrame, MenuBarGeometry.hit(point, in: indicator) { return false }
        for item in snapshot.items {
            if !item.isAppleItem, let filter = visibleBundleFilter, !filter(item.ownerBundleID) { continue }
            if MenuBarGeometry.hit(point, in: item.frame.cgRect) { return false }
        }
        return true
    }

    /// Right edge of the frontmost app's menus (Apple menu through Help), in global coordinates.
    public static func appMenusMaxX() -> CGFloat? {
        guard let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier else { return nil }
        let app = AXUIElementCreateApplication(pid)
        guard let bar = AX.element(AX.attribute(app, kAXMenuBarAttribute)) else { return nil }
        return AX.children(bar).compactMap { AX.frame($0)?.maxX }.max()
    }
}

/// Menu bar strips of the connected screens, in global top-left coordinates.
public enum MenuBarScreens {
    public struct Strip: Equatable {
        public var frame: CGRect
        /// The camera housing, when the screen has one.
        public var notch: CGRect?
        public var isPrimary: Bool
    }

    @MainActor
    public static func strips() -> [Strip] {
        let screens = NSScreen.screens
        guard let primary = screens.first else { return [] }
        let primaryHeight = primary.frame.height
        return screens.map { screen in
            let notch: CGRect?
            if let left = screen.auxiliaryTopLeftArea, let right = screen.auxiliaryTopRightArea {
                notch = MenuBarGeometry.topLeftRect(
                    fromCocoa: CGRect(x: left.maxX, y: left.minY, width: right.minX - left.maxX, height: left.height),
                    primaryScreenHeight: primaryHeight
                )
            } else {
                notch = nil
            }
            return Strip(
                frame: MenuBarGeometry.menuBarStrip(
                    screenFrame: screen.frame, visibleFrame: screen.visibleFrame, primaryScreenHeight: primaryHeight,
                    fallbackHeight: max(NSStatusBar.system.thickness, screen.safeAreaInsets.top)
                ),
                notch: notch,
                isPrimary: screen == primary
            )
        }
    }

    @MainActor
    public static func strip(containing point: CGPoint) -> Strip? {
        strips().first { $0.frame.contains(point) }
    }
}

/// Recognises an open menu or popover in a `CGWindowListCopyWindowInfo` result (feature 6).
public enum OpenMenuDetector {
    /// `kCGPopUpMenuWindowLevel`.
    public static let popUpMenuLayer = 101
    /// MenuBarAgent's own bar windows.
    static let menuBarLayers: Set<Int> = [24, 25]

    /// - Parameters:
    ///   - ownerPIDs: pids of the apps whose items were revealed; any of their windows above the normal layer counts
    ///     (menus, popovers, panels opened from the item).
    ///   - excludingPID: SnugBar's own pid.
    public static func isMenuOpen(windowList: [[String: Any]], ownerPIDs: Set<Int32>, excludingPID: Int32) -> Bool {
        windowList.contains { window in
            let pid = (window[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value ?? -1
            guard pid != excludingPID else { return false }
            let layer = (window[kCGWindowLayer as String] as? NSNumber)?.intValue ?? 0
            if layer == popUpMenuLayer { return true }
            return ownerPIDs.contains(pid) && layer > 0 && layer < 1000 && !menuBarLayers.contains(layer)
        }
    }

    public static func isMenuOpenNow(ownerPIDs: Set<Int32>) -> Bool {
        let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
            as? [[String: Any]] ?? []
        return isMenuOpen(windowList: list, ownerPIDs: ownerPIDs, excludingPID: ProcessInfo.processInfo.processIdentifier)
    }
}

