import AppKit
import SnugBarCore

/// Notices the user ⌘-dragging items in the real menu bar (feature 33), so SnugBar holds back its own order writes
/// while it happens and can adopt the new order afterwards. A drag starts with a left mouse-down with ⌘ held on a
/// menu bar strip and ends with the next left mouse-up. SnugBar's own synthetic drags are ignored.
@MainActor
public final class CommandDragWatcher {
    /// A drag began.
    public var onBegin: (() -> Void)?
    /// The drag ended (the button came up).
    public var onEnd: (() -> Void)?

    public private(set) var isDragging = false
    /// A drag that never reports its mouse-up (a missed event) stops counting after this long.
    public var timeout: TimeInterval = 30

    private var monitor: Any?
    private var startedAt: Date?

    public init() {}

    /// True while a drag is in progress (or the button is held with ⌘ right now).
    public var userIsDragging: Bool {
        if isDragging, let startedAt, Date().timeIntervalSince(startedAt) > timeout { finish() }
        return isDragging || OrderFileAccess.userIsCommandDragging
    }

    public func start() {
        guard monitor == nil else { return }
        monitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .leftMouseUp]) { [weak self] event in
            if SyntheticInput.isOwn(event.cgEvent) { return }
            let type = event.type
            let command = event.modifierFlags.contains(.command)
            let location = event.cgEvent?.location
            MainActor.assumeIsolated { self?.handle(type, command: command, location: location) }
        }
    }

    public func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        isDragging = false
        startedAt = nil
    }

    private func handle(_ type: NSEvent.EventType, command: Bool, location: CGPoint?) {
        switch type {
        case .leftMouseDown:
            guard command, let location, MenuBarScreens.strip(containing: location) != nil else { return }
            isDragging = true
            startedAt = Date()
            onBegin?()
        case .leftMouseUp:
            guard isDragging else { return }
            finish()
        default:
            break
        }
    }

    private func finish() {
        isDragging = false
        startedAt = nil
        onEnd?()
    }
}
