import CoreGraphics
import Foundation

/// Pure geometry used by the reader, activator and guards. Kept free of AX calls so it can be unit-tested.
public enum MenuBarGeometry {
    /// Overflowed items are stacked under the « button, so their frames overlap it. Visible items sit beside it
    /// and never overlap it by more than a rounding error.
    public static func isOverflowed(_ item: CGRect, indicator: CGRect?) -> Bool {
        guard let indicator, indicator.width > 0 else { return false }
        let overlap = min(item.maxX, indicator.maxX) - max(item.minX, indicator.minX)
        return overlap > 1
    }

    /// Converts a point from AppKit coordinates (bottom-left origin of the primary screen) to the global top-left
    /// coordinates used by Accessibility and Quartz events.
    public static func topLeftPoint(fromCocoa point: CGPoint, primaryScreenHeight: CGFloat) -> CGPoint {
        CGPoint(x: point.x, y: primaryScreenHeight - point.y)
    }

    /// Converts a rect from AppKit coordinates to global top-left coordinates.
    public static func topLeftRect(fromCocoa rect: CGRect, primaryScreenHeight: CGFloat) -> CGRect {
        CGRect(x: rect.minX, y: primaryScreenHeight - rect.maxY, width: rect.width, height: rect.height)
    }

    /// The menu bar strip of a screen, in global top-left coordinates. The bar's height is the gap between the screen's
    /// top and its visible frame; when the bar auto-hides that gap is zero, so `fallbackHeight` is used.
    public static func menuBarStrip(
        screenFrame: CGRect, visibleFrame: CGRect, primaryScreenHeight: CGFloat, fallbackHeight: CGFloat
    ) -> CGRect {
        let gap = screenFrame.maxY - visibleFrame.maxY
        let height = gap > 0 ? gap : fallbackHeight
        return CGRect(x: screenFrame.minX, y: primaryScreenHeight - screenFrame.maxY, width: screenFrame.width, height: height)
    }

    /// Hit test with a small tolerance, in top-left coordinates.
    public static func hit(_ point: CGPoint, in frame: CGRect, tolerance: CGFloat = 2) -> Bool {
        frame.insetBy(dx: -tolerance, dy: -tolerance).contains(point)
    }

    /// Picks which of an app's `AXExtrasMenuBar` children corresponds to one of its menu bar items.
    ///
    /// - Parameters:
    ///   - target: the item's frame from MenuBarAgent.
    ///   - indexInApp: the item's index among the app's items, left to right.
    ///   - appItemCount: how many items the app has in MenuBarAgent's tree.
    ///   - candidates: frames of the app's extras children (nil when the element reports none).
    /// - Returns: index into `candidates`, or nil.
    public static func matchExtrasItem(target: CGRect, indexInApp: Int, appItemCount: Int, candidates: [CGRect?]) -> Int? {
        guard !candidates.isEmpty else { return nil }
        // 1. Frame match: same centre within a few points.
        var best: (index: Int, distance: CGFloat)?
        for (i, frame) in candidates.enumerated() {
            guard let frame else { continue }
            let d = abs(frame.midX - target.midX)
            let tolerance = max(4, min(frame.width, target.width) / 2)
            if d <= tolerance, abs(frame.width - target.width) <= max(6, target.width * 0.25), d < (best?.distance ?? .infinity) {
                best = (i, d)
            }
        }
        if let best { return best.index }
        // 2. One item each: they must be the same.
        if candidates.count == 1, appItemCount == 1 { return 0 }
        // 3. Same count: match by left-to-right order.
        if candidates.count == appItemCount, candidates.allSatisfy({ $0 != nil }) {
            let order = candidates.enumerated().sorted { $0.element!.minX < $1.element!.minX }.map(\.offset)
            if indexInApp < order.count { return order[indexInApp] }
        }
        return nil
    }
}

/// Recognises the Notification Center panel in a `CGWindowListCopyWindowInfo` result.
public enum NotificationCenterDetector {
    /// The owner name is localised ("Notification Center", "Notification Centre"); match the shared prefix.
    public static let ownerPrefix = "Notification Cent"
    public static let minimumPanelWidth: Double = 100

    public static func isPanelOpen(windowList: [[String: Any]]) -> Bool {
        windowList.contains { window in
            guard let owner = window[kCGWindowOwnerName as String] as? String, owner.hasPrefix(ownerPrefix) else {
                return false
            }
            // Desktop widgets are Notification Center windows too, on a negative desktop layer; the panel itself sits
            // on a positive layer (23 on macOS 27.2).
            let layer = (window[kCGWindowLayer as String] as? NSNumber)?.intValue ?? 0
            guard layer > 0 else { return false }
            let bounds = window[kCGWindowBounds as String] as? [String: Any]
            let width = (bounds?["Width"] as? NSNumber)?.doubleValue ?? 0
            return width > minimumPanelWidth
        }
    }

    public static func isPanelOpenNow() -> Bool {
        let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
            as? [[String: Any]] ?? []
        return isPanelOpen(windowList: list)
    }
}
