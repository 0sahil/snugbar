import AppKit

/// Fallback hider using public API only.
///
/// SnugBar adds a divider status item. While hiding, the divider is widened to fill the free space between it and
/// the left end of the status area (the notch, when there is one), which pushes every item to its left into the
/// system overflow behind «. Showing shrinks it back. The divider's place is stored by AppKit under
/// `NSStatusItem Preferred Position <autosaveName>` in SnugBar's own defaults; the user moves it with ⌘-drag.
/// It hides by position, not per app, and the system « stays visible.
@MainActor
public final class OverflowDividerHider: Hider {
    public let backend: HiderBackend = .overflowDivider
    public let supportsAllowList = false
    public let isAvailable = true
    public private(set) var lastError: String?
    public private(set) var isHiding = false

    public static let autosaveName = "snugbar.divider"
    /// Initial distance from the right edge for a fresh install, so the divider starts left of Apple's items.
    public var initialPreferredPosition: Double = 380
    public var collapsedWidth: CGFloat = 10
    /// Space left free next to the notch so the divider itself doesn't overflow.
    public var notchMargin: CGFloat = 40

    private var item: NSStatusItem?

    public init() {}

    /// Shows the divider without hiding anything.
    public func install() {
        guard item == nil else { return }
        let key = "NSStatusItem Preferred Position \(Self.autosaveName)"
        if UserDefaults.standard.object(forKey: key) == nil {
            UserDefaults.standard.set(initialPreferredPosition, forKey: key)
        }
        let statusItem = NSStatusBar.system.statusItem(withLength: collapsedWidth)
        statusItem.autosaveName = Self.autosaveName
        statusItem.button?.image = NSImage(systemSymbolName: "line.diagonal", accessibilityDescription: "SnugBar divider")
        statusItem.button?.imageScaling = .scaleProportionallyDown
        item = statusItem
    }

    public func uninstall() {
        if let item { NSStatusBar.system.removeStatusItem(item) }
        item = nil
        isHiding = false
    }

    /// The allow-list is ignored: this backend hides everything left of the divider.
    public func hide(allowing allowedBundleIDs: Set<String>) throws {
        install()
        guard let item, let window = item.button?.window else {
            lastError = "divider has no window yet"
            throw HiderError.unavailable(lastError!)
        }
        let screen = window.screen ?? NSScreen.main
        // Status items are anchored on the right, so the divider's right edge stays put as it widens.
        let dividerRight = window.frame.maxX
        let leftLimit: CGFloat
        if let notch = screen?.auxiliaryTopRightArea {
            leftLimit = notch.minX
        } else if let screen {
            // No notch: leave the left part of the bar to the active app's menus.
            leftLimit = screen.frame.minX + screen.frame.width * 0.4
        } else {
            leftLimit = 0
        }
        item.length = max(collapsedWidth * 2, dividerRight - leftLimit - notchMargin)
        isHiding = true
        lastError = nil
    }

    public func show() {
        item?.length = collapsedWidth
        isHiding = false
    }
}
