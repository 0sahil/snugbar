import AppKit
import ScreenCaptureKit
import SnugBarCore

/// Images of menu bar items.
///
/// With Screen Recording, one ScreenCaptureKit capture of the menu bar strip is cropped by each item's frame.
/// Hidden and overflowed items can't be captured (their windows refuse capture), so they get the last captured
/// image, else the owning app's icon.
@MainActor
public final class ItemImager {
    public enum Source: String, Codable, Sendable {
        case captured
        case cached
        case appIcon
    }

    public struct ItemImage {
        public let image: CGImage
        public let source: Source
    }

    public enum CaptureError: Error, CustomStringConvertible {
        case noPermission
        case noDisplay
        case failed(String)

        public var description: String {
            switch self {
            case .noPermission: return "screen recording not granted"
            case .noDisplay: return "no display found for the menu bar"
            case let .failed(why): return "capture failed: \(why)"
            }
        }
    }

    private var cache: [ItemID: CGImage] = [:]
    /// Duration of the last strip capture, for diagnostics.
    public private(set) var lastCaptureDuration: TimeInterval?

    public init() {}

    /// Captures the strip and refreshes the cache for every visible item. Returns the IDs captured.
    @discardableResult
    public func refresh(_ items: [MenuBarItem]) async throws -> [ItemID] {
        guard CGPreflightScreenCaptureAccess() else { throw CaptureError.noPermission }
        let visible = items.filter { !$0.isOverflowed && $0.frame.width > 0 }
        guard !visible.isEmpty else { return [] }

        let content: SCShareableContent
        do {
            content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        } catch {
            throw CaptureError.failed(error.localizedDescription)
        }
        // Use the display holding the first visible item (global top-left coordinates, like AX frames).
        let probe = visible[0].frame.cgRect
        guard let display = content.displays.first(where: { $0.frame.intersects(probe) })
            ?? content.displays.first(where: { $0.displayID == CGMainDisplayID() })
        else { throw CaptureError.noDisplay }

        let stripHeight = ceil(visible.map { $0.frame.maxY - Double(display.frame.minY) }.max() ?? 24)
        let scale = NSScreen.screens.first { ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == display.displayID }?
            .backingScaleFactor ?? 2

        let config = SCStreamConfiguration()
        config.sourceRect = CGRect(x: 0, y: 0, width: CGFloat(display.width), height: stripHeight)
        config.width = Int(CGFloat(display.width) * scale)
        config.height = Int(stripHeight * scale)
        config.showsCursor = false
        let filter = SCContentFilter(display: display, excludingWindows: [])

        let started = Date()
        let strip: CGImage
        do {
            strip = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
        } catch {
            throw CaptureError.failed(error.localizedDescription)
        }
        lastCaptureDuration = Date().timeIntervalSince(started)

        let pxPerPt = CGFloat(strip.width) / CGFloat(display.width)
        var captured: [ItemID] = []
        for item in visible {
            let f = item.frame.cgRect.offsetBy(dx: -display.frame.minX, dy: -display.frame.minY)
            let crop = CGRect(x: f.minX * pxPerPt, y: f.minY * pxPerPt, width: f.width * pxPerPt, height: f.height * pxPerPt)
                .integral
                .intersection(CGRect(x: 0, y: 0, width: strip.width, height: strip.height))
            guard !crop.isEmpty, let image = strip.cropping(to: crop) else { continue }
            cache[item.id] = image
            captured.append(item.id)
        }
        return captured
    }

    /// Best available image: captured this round, else cached, else the app icon.
    public func image(for item: MenuBarItem, capturedNow: Set<ItemID> = []) -> ItemImage? {
        if let image = cache[item.id] {
            return ItemImage(image: image, source: capturedNow.contains(item.id) ? .captured : .cached)
        }
        guard let icon = Self.appIcon(for: item) else { return nil }
        return ItemImage(image: icon, source: .appIcon)
    }

    public func clearCache() { cache.removeAll() }

    static func appIcon(for item: MenuBarItem, size: CGFloat = 64) -> CGImage? {
        var icon: NSImage?
        if item.ownerPID > 0 { icon = NSRunningApplication(processIdentifier: item.ownerPID)?.icon }
        if icon == nil, !item.ownerBundleID.isEmpty,
           let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: item.ownerBundleID) {
            icon = NSWorkspace.shared.icon(forFile: url.path)
        }
        guard let icon else { return nil }
        var rect = CGRect(x: 0, y: 0, width: size, height: size)
        return icon.cgImage(forProposedRect: &rect, context: nil, hints: nil)
    }
}

extension CGImage {
    /// PNG data for saving.
    public func pngData() -> Data? {
        NSBitmapImageRep(cgImage: self).representation(using: .png, properties: [:])
    }
}
