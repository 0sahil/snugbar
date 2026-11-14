import AppKit

/// A borderless, non-activating panel for the SnugBar Bar and the search palette.
///
/// It can become the key window (to take typing) without activating SnugBar, so SnugBar stays an accessory app and the
/// frontmost app stays frontmost. (Switching to a regular app at runtime breaks pop-up menus on macOS 27.)
final class OverlayPanel: NSPanel {
    /// Sees key-down events first; return true to consume one.
    var keyHandler: ((NSEvent) -> Bool)?
    var onResignKey: (() -> Void)?
    /// Sees mouse-down events in the panel (they still go on to the view under the pointer).
    var onMouseDown: (() -> Void)?
    /// Sees left-button down, dragged and up events first; return true to consume one.
    var mouseHandler: ((NSEvent) -> Bool)?

    init(contentRect: NSRect = NSRect(x: 0, y: 0, width: 200, height: 40)) {
        super.init(contentRect: contentRect, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        isFloatingPanel = true
        // Above ordinary app windows, below everything system-level: the menu bar (24/25), other apps' status item
        // panels and popovers (often at the status level), and pop-up menus (101). So a menu opened from an item, or
        // anything another app floats over the bar, is never covered by SnugBar.
        level = .floating
        hidesOnDeactivate = false
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        isReleasedWhenClosed = false
        becomesKeyOnlyIfNeeded = false
        animationBehavior = .none
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func sendEvent(_ event: NSEvent) {
        if event.type == .keyDown, let keyHandler, keyHandler(event) { return }
        if [.leftMouseDown, .rightMouseDown, .otherMouseDown].contains(event.type) { onMouseDown?() }
        if [.leftMouseDown, .leftMouseDragged, .leftMouseUp].contains(event.type), let mouseHandler, mouseHandler(event) { return }
        super.sendEvent(event)
    }

    override func resignKey() {
        super.resignKey()
        onResignKey?()
    }

    /// Puts `content` on the system menu material with rounded corners.
    func setMaterialContent(_ content: NSView, cornerRadius: CGFloat = 10) {
        let effect = NSVisualEffectView()
        effect.material = .menu
        effect.blendingMode = .behindWindow
        effect.state = .active
        effect.maskImage = Self.roundedMask(radius: cornerRadius)
        content.translatesAutoresizingMaskIntoConstraints = false
        effect.addSubview(content)
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: effect.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: effect.trailingAnchor),
            content.topAnchor.constraint(equalTo: effect.topAnchor),
            content.bottomAnchor.constraint(equalTo: effect.bottomAnchor),
        ])
        contentView = effect
    }

    static func roundedMask(radius: CGFloat) -> NSImage {
        let edge = radius * 2 + 1
        let image = NSImage(size: NSSize(width: edge, height: edge), flipped: false) { rect in
            NSColor.black.setFill()
            NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
            return true
        }
        image.capInsets = NSEdgeInsets(top: radius, left: radius, bottom: radius, right: radius)
        image.resizingMode = .stretch
        return image
    }
}

extension NSEvent {
    /// True while a mouse button is down on SnugBar's icon (`iconFrame` in AppKit screen coordinates): the press
    /// that is about to become a click on the icon.
    @MainActor
    static func isPressingOnOwnIcon(_ iconFrame: NSRect?) -> Bool {
        guard let iconFrame, !iconFrame.isEmpty, pressedMouseButtons != 0 else { return false }
        return NSMouseInRect(mouseLocation, iconFrame, false)
    }
}

extension NSScreen {
    /// Height of the menu bar on this screen (falls back to the status bar thickness when the bar auto-hides).
    var menuBarHeight: CGFloat {
        let gap = frame.maxY - visibleFrame.maxY
        return gap > 0 ? gap : max(NSStatusBar.system.thickness, safeAreaInsets.top)
    }

    /// The screen containing a point in AppKit coordinates.
    static func containing(_ point: NSPoint) -> NSScreen? {
        screens.first { NSMouseInRect(point, $0.frame, false) }
    }
}
