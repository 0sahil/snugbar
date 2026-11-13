import CoreGraphics
import Foundation

/// Synthetic mouse input in global top-left coordinates. Posting to MenuBarAgent's pid does nothing on macOS 27,
/// so events go to the HID tap, and the pointer is put back afterwards.
enum SyntheticInput {
    static var pointer: CGPoint { CGEvent(source: nil)?.location ?? .zero }

    static func restorePointer(_ point: CGPoint) {
        CGWarpMouseCursorPosition(point)
        // Re-couple the pointer to the mouse right away (warping briefly decouples it).
        CGAssociateMouseAndMouseCursorPosition(1)
    }

    static func click(at point: CGPoint) {
        let source = CGEventSource(stateID: .hidSystemState)
        CGEvent(mouseEventSource: source, mouseType: .leftMouseDown, mouseCursorPosition: point, mouseButton: .left)?
            .post(tap: .cghidEventTap)
        CGEvent(mouseEventSource: source, mouseType: .leftMouseUp, mouseCursorPosition: point, mouseButton: .left)?
            .post(tap: .cghidEventTap)
    }

    /// ⌘-drag from `start` to `end` in `steps` moves.
    @MainActor
    static func commandDrag(from start: CGPoint, to end: CGPoint, steps: Int = 12) async {
        let source = CGEventSource(stateID: .hidSystemState)
        func post(_ type: CGEventType, _ point: CGPoint) {
            guard let event = CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: point, mouseButton: .left) else {
                return
            }
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
