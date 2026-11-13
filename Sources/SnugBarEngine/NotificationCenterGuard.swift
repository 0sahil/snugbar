import AppKit
import SnugBarCore

/// Keeps the clock's click working while `AssessmentHider` hides items.
///
/// While the assertion is active, a click on the clock doesn't open Notification Center. The guard watches for a
/// left mouse-down on the clock's frame, lifts the hide, and re-applies it as soon as a Notification Center window
/// appears (the panel stays open). If no panel appears within 400 ms, it presses the clock through Accessibility.
/// A click that closes an already open panel is left alone. Cost: hidden icons flash for about 0.3 s.
@MainActor
public final class NotificationCenterGuard {
    public struct Event: Codable, Sendable {
        public var time: Date
        public var message: String
    }

    public private(set) var events: [Event] = []
    public private(set) var isRunning = false

    /// Wait this long for the panel before pressing the clock.
    public var pressDelay: TimeInterval = 0.4
    /// Give up and re-hide after this long.
    public var giveUpAfter: TimeInterval = 2.0

    private let hider: AssessmentHider
    private let reader: MenuBarReader
    private var monitor: Any?
    private var clockFrame: CGRect?
    private var clockFrameReadAt = Date.distantPast
    private var screenObserver: NSObjectProtocol?
    private var handling = false

    public init(hider: AssessmentHider, reader: MenuBarReader) {
        self.hider = hider
        self.reader = reader
    }

    public func start() {
        guard !isRunning else { return }
        isRunning = true
        refreshClockFrame()
        monitor = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseDown) { [weak self] event in
            let location = event.cgEvent?.location
            MainActor.assumeIsolated { self?.mouseDown(at: location) }
        }
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.clockFrameReadAt = .distantPast }
        }
        log(monitor == nil ? "global mouse monitor not installed" : "started; clock frame \(clockFrame.map { "\($0)" } ?? "unknown")")
    }

    public func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        if let screenObserver { NotificationCenter.default.removeObserver(screenObserver) }
        monitor = nil
        screenObserver = nil
        isRunning = false
    }

    // MARK: - Private

    private func refreshClockFrame() {
        let snapshot = reader.snapshot()
        clockFrame = snapshot.items.first { $0.axIdentifier == AppleItems.clockIdentifier }?.frame.cgRect
        clockFrameReadAt = Date()
    }

    private func mouseDown(at location: CGPoint?) {
        guard hider.isHiding, !hider.isSuspended, !handling else { return }
        let point = location ?? MenuBarGeometry.topLeftPoint(
            fromCocoa: NSEvent.mouseLocation, primaryScreenHeight: NSScreen.screens.first?.frame.height ?? 0
        )
        // The clock rarely moves; re-read its frame at most every 5 s, or after a screen change.
        if clockFrame == nil || Date().timeIntervalSince(clockFrameReadAt) > 5 { refreshClockFrame() }
        guard let frame = clockFrame, MenuBarGeometry.hit(point, in: frame) else { return }

        if NotificationCenterDetector.isPanelOpenNow() {
            log("clock click closes the open panel; hide kept")
            return
        }
        handling = true
        hider.suspend()
        log("clock click; hide lifted")
        Task { @MainActor in
            await self.waitForPanel()
            self.handling = false
        }
    }

    private func waitForPanel() async {
        let start = Date()
        var pressed = false
        while Date().timeIntervalSince(start) < giveUpAfter {
            if NotificationCenterDetector.isPanelOpenNow() {
                hider.resume()
                log(String(format: "panel open after %.0f ms; hide re-applied", Date().timeIntervalSince(start) * 1000))
                return
            }
            if !pressed, Date().timeIntervalSince(start) >= pressDelay {
                pressed = true
                pressClock()
            }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        hider.resume()
        log("no panel within \(giveUpAfter) s; hide re-applied")
    }

    private func pressClock() {
        guard let entry = reader.snapshot().entries.first(where: { $0.item.axIdentifier == AppleItems.clockIdentifier }) else {
            log("no panel after \(Int(pressDelay * 1000)) ms; clock element not found")
            return
        }
        let result = AX.perform(entry.element, kAXPressAction)
        log("no panel after \(Int(pressDelay * 1000)) ms; AXPress clock -> \(result.rawValue)")
    }

    private func log(_ message: String) {
        events.append(Event(time: Date(), message: message))
        if events.count > 200 { events.removeFirst(events.count - 200) }
    }
}
