import CoreGraphics
import Foundation

/// Synthetic mouse input in global top-left coordinates. Posting to MenuBarAgent's pid does nothing on macOS 27,
/// so events go to the HID tap, and the pointer is put back afterwards.
public enum SyntheticInput {
    /// Stamped into `eventSourceUserData` of every event SnugBar posts, so its own global monitors can tell them from
    /// the user's. (Without this, the click that opens a hidden item's menu looked like a click on an empty part of
    /// the menu bar while the item's app was focused, and reopened the SnugBar Bar on top of the menu.)
    public static let marker: Int64 = 0x534E_5547 // "SNUG"

    /// True for an event SnugBar posted itself.
    public static func isOwn(_ event: CGEvent?) -> Bool {
        event?.getIntegerValueField(.eventSourceUserData) == marker
    }

    static var pointer: CGPoint { CGEvent(source: nil)?.location ?? .zero }

    private static func mouseEvent(_ source: CGEventSource?, _ type: CGEventType, _ point: CGPoint) -> CGEvent? {
        let event = CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: point, mouseButton: .left)
        event?.setIntegerValueField(.eventSourceUserData, value: marker)
        return event
    }

    static func restorePointer(_ point: CGPoint) {
        CGWarpMouseCursorPosition(point)
        // Re-couple the pointer to the mouse right away (warping briefly decouples it).
        CGAssociateMouseAndMouseCursorPosition(1)
    }

    /// Hides the pointer even though SnugBar isn't the active app. PRIVATE API: the window server only honours
    /// `CGDisplayHideCursor` from a background app once its connection has `SetsCursorInBackground` set.
    /// Returns false (and hides nothing) if the symbols are missing. Set `SNUGBAR_SHOW_POINTER=1` to disable.
    static func hidePointer() -> Bool {
        guard ProcessInfo.processInfo.environment["SNUGBAR_SHOW_POINTER"] == nil,
              let connection = CGSPrivate.mainConnection?(), let setProperty = CGSPrivate.setConnectionProperty
        else { return false }
        _ = setProperty(connection, connection, "SetsCursorInBackground" as CFString, kCFBooleanTrue)
        return CGDisplayHideCursor(CGMainDisplayID()) == .success
    }

    static func showPointer() {
        CGDisplayShowCursor(CGMainDisplayID())
    }

    static func click(at point: CGPoint) {
        let source = CGEventSource(stateID: .hidSystemState)
        mouseEvent(source, .mouseMoved, point)?.post(tap: .cghidEventTap)
        usleep(30_000)
        mouseEvent(source, .leftMouseDown, point)?.post(tap: .cghidEventTap)
        let hold = ProcessInfo.processInfo.environment["SNUGBAR_CLICK_HOLD_MS"].flatMap(UInt32.init) ?? 0
        if hold > 0 { usleep(hold * 1000) }
        mouseEvent(source, .leftMouseUp, point)?.post(tap: .cghidEventTap)
    }

    /// ⌘-drag from `start` to `end` in `steps` moves.
    @MainActor
    static func commandDrag(from start: CGPoint, to end: CGPoint, steps: Int = 12) async {
        let source = CGEventSource(stateID: .hidSystemState)
        func post(_ type: CGEventType, _ point: CGPoint) {
            guard let event = mouseEvent(source, type, point) else { return }
            event.flags = .maskCommand
            event.post(tap: .cghidEventTap)
        }
        post(.leftMouseDown, start)
        try? await Task.sleep(nanoseconds: 150_000_000)
        for step in 1...max(1, steps) {
            let t = CGFloat(step) / CGFloat(max(1, steps))
            post(.leftMouseDragged, CGPoint(x: start.x + (end.x - start.x) * t, y: start.y + (end.y - start.y) * t))
            try? await Task.sleep(nanoseconds: 25_000_000)
        }
        post(.leftMouseUp, end)
    }
}

/// A pointer position for reports.
public struct PointerPosition: Codable, Equatable, Sendable {
    public var x: Double
    public var y: Double

    init(_ p: CGPoint) {
        x = Double(p.x)
        y = Double(p.y)
    }
}

/// Private CoreGraphics (SkyLight) calls, looked up at runtime so a macOS update that removes them only disables the
/// feature that uses them.
enum CGSPrivate {
    typealias Connection = Int32
    typealias MainConnection = @convention(c) () -> Connection
    typealias SetConnectionProperty = @convention(c) (Connection, Connection, CFString, CFTypeRef) -> Int32

    private static let handle = dlopen(nil, RTLD_NOW)

    static let mainConnection: MainConnection? = symbol("_CGSDefaultConnection")
    static let setConnectionProperty: SetConnectionProperty? = symbol("CGSSetConnectionProperty")

    private static func symbol<T>(_ name: String) -> T? {
        guard let pointer = dlsym(handle, name) else { return nil }
        return unsafeBitCast(pointer, to: T.self)
    }
}
