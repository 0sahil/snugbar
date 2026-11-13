import AppKit
import SnugBarCore

/// Keeps the clock's click working while `AssessmentHider` hides items.
///
/// While the assertion is active, a click on the clock doesn't open Notification Center. The guard watches for a
/// left mouse-down on the clock's frame, lifts the hide, and re-applies it as soon as a Notification Center window
/// appears (the panel stays open). The original click never gets through, so the guard replays it on the clock after
/// `pressDelay`, and once more after `retryDelay` if needed. A click that closes an already open panel is left alone.
/// Cost: hidden icons flash briefly while the hide is lifted.
@MainActor
public final class NotificationCenterGuard {
    public struct Event: Codable, Sendable {
        public var time: Date
        public var message: String
    }

    public private(set) var events: [Event] = []
    public private(set) var isRunning = false

    /// Wait this long for the panel before replaying the click. The user's own click never gets through while hidden
    /// (verified on 27.2), so this only needs to cover the time the system takes to lift the hide.
    public var pressDelay: TimeInterval = 0.06
    /// If the panel still hasn't appeared (the hide was lifted late), replay once more at this point.
    public var retryDelay: TimeInterval = 0.5
    /// Give up and re-hide after this long.
    public var giveUpAfter: TimeInterval = 2.0

    private let hider: AssessmentHider
    private let reader: MenuBarReader
    private var monitor: Any?
    private var clockFrame: CGRect?
    private var screenObserver: NSObjectProtocol?
    private var refreshTimer: Timer?
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
            MainActor.assumeIsolated { self?.refreshClockFrame() }
        }
        // Reading the menu bar takes tens of milliseconds, so keep the clock's frame fresh off the click path.
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshClockFrame() }
        }
        log(monitor == nil ? "global mouse monitor not installed" : "started; clock frame \(clockFrame.map { "\($0)" } ?? "unknown")")
    }

    public func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        if let screenObserver { NotificationCenter.default.removeObserver(screenObserver) }
        refreshTimer?.invalidate()
        monitor = nil
        screenObserver = nil
        refreshTimer = nil
        isRunning = false
    }

    // MARK: - Private

    private func refreshClockFrame() {
        guard !handling else { return }
        let snapshot = reader.snapshot()
        if let frame = snapshot.items.first(where: { $0.axIdentifier == AppleItems.clockIdentifier })?.frame.cgRect {
            clockFrame = frame
        }
    }

    private func mouseDown(at location: CGPoint?) {
        guard hider.isHiding, !hider.isSuspended, !handling else { return }
        let point = location ?? MenuBarGeometry.topLeftPoint(
            fromCocoa: NSEvent.mouseLocation, primaryScreenHeight: NSScreen.screens.first?.frame.height ?? 0
        )
        if clockFrame == nil { refreshClockFrame() }
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
        var replays = [pressDelay, retryDelay]
        while Date().timeIntervalSince(start) < giveUpAfter {
            if NotificationCenterDetector.isPanelOpenNow() {
                hider.resume()
                log(String(format: "panel open after %.0f ms; hide re-applied", Date().timeIntervalSince(start) * 1000))
                return
            }
            if let next = replays.first, Date().timeIntervalSince(start) >= next {
                replays.removeFirst()
                replayClick(after: next)
            }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        hider.resume()
        log("no panel within \(giveUpAfter) s; hide re-applied")
    }

    private func replayClick(after delay: TimeInterval) {
        guard let frame = clockFrame else {
            log("no panel after \(Int(delay * 1000)) ms; clock frame unknown")
            return
        }
        // AXPress on the clock is rejected on macOS 27.2 (-25206), so replay the click. The user's pointer is already
        // on the clock (that is how we got here); the guard's own monitor ignores it because `handling` is set.
        let before = SyntheticInput.pointer
        let target = MenuBarGeometry.hit(before, in: frame) ? before : CGPoint(x: frame.midX, y: frame.midY)
        SyntheticInput.click(at: target)
        if target != before { SyntheticInput.restorePointer(before) }
        log("no panel after \(Int(delay * 1000)) ms; replayed the click on the clock")
    }

    private func log(_ message: String) {
        events.append(Event(time: Date(), message: message))
        if events.count > 200 { events.removeFirst(events.count - 200) }
    }
}
