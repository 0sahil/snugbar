import AppKit
import SwiftUI

/// A hovered tile: its label text, its rect in AppKit screen coordinates, and the window it is in.
struct BarHover {
    let text: String
    let rect: NSRect
    let window: NSWindow?
}

/// A tooltip-like name label for the SnugBar Bar's tiles.
///
/// The system tooltip (`toolTip` / `.help`) only appears in the active app, and SnugBar is an accessory app that never
/// activates, so the bar draws its own: a small borderless child window on the tooltip material, shown just below the
/// hovered tile after a short delay. Moving straight on to another tile shows its label at once, as system tooltips do.
@MainActor
final class HoverLabel {
    static let delay: TimeInterval = 0.3
    /// After a label hides, entering another tile within this time shows its label without the delay.
    static let warmPeriod: TimeInterval = 0.5

    private var window: NSPanel?
    private var field: NSTextField?
    private var pending: DispatchWorkItem?
    private var warmUntil: Date = .distantPast

    var isVisible: Bool { window?.isVisible == true }

    /// The pointer entered a tile. `tileRect` is in AppKit screen coordinates; `parent` is the bar's panel.
    func pointerEntered(text: String, tileRect: NSRect, parent: NSWindow?) {
        cancelPending()
        guard let parent, parent.isVisible, !text.isEmpty else { return }
        if isVisible || Date() < warmUntil {
            show(text: text, below: tileRect, parent: parent)
            return
        }
        let work = DispatchWorkItem { [weak self, weak parent] in
            MainActor.assumeIsolated {
                guard let self, let parent, parent.isVisible else { return }
                self.pending = nil
                self.show(text: text, below: tileRect, parent: parent)
            }
        }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.delay, execute: work)
    }

    /// The pointer left the tile: hide at once.
    func pointerExited() {
        let wasVisible = isVisible
        hide()
        if wasVisible { warmUntil = Date().addingTimeInterval(Self.warmPeriod) }
    }

    /// Hides the label and drops any pending one (click, bar closing).
    func hide() {
        cancelPending()
        warmUntil = .distantPast
        guard let window else { return }
        window.parent?.removeChildWindow(window)
        window.orderOut(nil)
    }

    private func cancelPending() {
        pending?.cancel()
        pending = nil
    }

    private func show(text: String, below tileRect: NSRect, parent: NSWindow) {
        let (window, field) = makeWindowIfNeeded()
        field.stringValue = text
        let padding = NSSize(width: 6, height: 3)
        let textSize = field.fittingSize
        let size = NSSize(width: ceil(textSize.width + padding.width * 2), height: ceil(textSize.height + padding.height * 2))

        let screen = NSScreen.containing(NSPoint(x: tileRect.midX, y: tileRect.midY)) ?? parent.screen ?? NSScreen.main
        var x = tileRect.midX - size.width / 2
        var y = tileRect.minY - 4 - size.height
        if let frame = screen?.frame {
            x = min(max(x, frame.minX + 4), frame.maxX - 4 - size.width)
            y = max(y, frame.minY + 4)
        }
        window.setFrame(NSRect(origin: NSPoint(x: x, y: y), size: size), display: true)
        if window.parent !== parent {
            window.parent?.removeChildWindow(window)
            parent.addChildWindow(window, ordered: .above)
        }
        window.orderFront(nil)
    }

    private func makeWindowIfNeeded() -> (NSPanel, NSTextField) {
        if let window, let field { return (window, field) }
        let window = HoverLabelPanel(
            contentRect: NSRect(x: 0, y: 0, width: 40, height: 18),
            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true
        )
        window.isFloatingPanel = true
        window.level = .floating
        window.hidesOnDeactivate = false
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = true
        window.ignoresMouseEvents = true
        window.isReleasedWhenClosed = false
        window.animationBehavior = .none
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]

        let effect = NSVisualEffectView()
        effect.material = .toolTip
        effect.blendingMode = .behindWindow
        effect.state = .active
        effect.maskImage = OverlayPanel.roundedMask(radius: 4)

        let field = NSTextField(labelWithString: "")
        field.font = NSFont.toolTipsFont(ofSize: 0)
        field.textColor = .labelColor
        field.lineBreakMode = .byTruncatingTail
        field.maximumNumberOfLines = 1
        field.translatesAutoresizingMaskIntoConstraints = false
        effect.addSubview(field)
        NSLayoutConstraint.activate([
            field.centerXAnchor.constraint(equalTo: effect.centerXAnchor),
            field.centerYAnchor.constraint(equalTo: effect.centerYAnchor),
        ])
        window.contentView = effect
        self.window = window
        self.field = field
        return (window, field)
    }
}

/// Never takes focus, so showing the label leaves the bar's key state alone.
private final class HoverLabelPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// Reports the pointer entering and leaving the view it backs, even while SnugBar is not the active app (SwiftUI's
/// hover and the system tooltip only track in the active app). Passes clicks through to the view above it.
struct HoverTracker: NSViewRepresentable {
    /// Called with the tracked area in AppKit screen coordinates and the window it is in.
    let onEnter: (NSRect, NSWindow?) -> Void
    let onExit: () -> Void

    func makeNSView(context: Context) -> TrackingView {
        let view = TrackingView()
        view.onEnter = onEnter
        view.onExit = onExit
        return view
    }

    func updateNSView(_ view: TrackingView, context: Context) {
        view.onEnter = onEnter
        view.onExit = onExit
    }

    static func dismantleNSView(_ view: TrackingView, coordinator: ()) {
        view.endHover()
    }

    final class TrackingView: NSView {
        var onEnter: ((NSRect, NSWindow?) -> Void)?
        var onExit: (() -> Void)?
        private var inside = false

        override init(frame: NSRect) {
            super.init(frame: frame)
            addTrackingArea(NSTrackingArea(
                rect: .zero, options: [.activeAlways, .mouseEnteredAndExited, .inVisibleRect], owner: self, userInfo: nil
            ))
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func mouseEntered(with event: NSEvent) {
            guard let window else { return }
            inside = true
            onEnter?(window.convertToScreen(convert(bounds, to: nil)), window)
        }

        override func mouseExited(with event: NSEvent) { endHover() }

        override func viewWillMove(toWindow newWindow: NSWindow?) {
            super.viewWillMove(toWindow: newWindow)
            if newWindow == nil { endHover() }
        }

        func endHover() {
            guard inside else { return }
            inside = false
            onExit?()
        }
    }
}
