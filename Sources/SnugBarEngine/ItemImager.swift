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
        /// A one-colour glyph to draw tinted with the label colour (captured pictures only; app icons are never
        /// templates).
        public let isTemplate: Bool
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

    /// Keyed pictures (bar background removed), by the ID they were captured or loaded under.
    private var cache: [ItemID: GlyphImage.Keyed] = [:]
    /// IDs whose picture holds nothing once the background is keyed out (a blank capture).
    private var blank: Set<ItemID> = []
    /// Duration of the last strip capture, for diagnostics.
    public private(set) var lastCaptureDuration: TimeInterval?
    /// When set, captured images are also kept here as PNG files (one per item), so hidden items keep their image
    /// across launches. Hidden items can't be captured, so without this they would show app icons after a relaunch.
    /// Files hold the raw crop, bar background included; the background is keyed out when a file is loaded, so files
    /// written by earlier versions work unchanged.
    public let cacheDirectory: URL?

    public init(cacheDirectory: URL? = nil) {
        self.cacheDirectory = cacheDirectory
    }

    /// `~/Library/Caches/<bundle id>/ItemImages`.
    public static var defaultCacheDirectory: URL {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Caches")
        return base.appendingPathComponent(Bundle.main.bundleIdentifier ?? "app.snugbar.SnugBar", isDirectory: true)
            .appendingPathComponent("ItemImages", isDirectory: true)
    }

    /// Captures the strip and refreshes the cache for every visible item. Returns the IDs captured.
    ///
    /// A picture is only kept when `MenuBarGeometry.isCleanCapture` accepts it (the item didn't move during the
    /// capture, is fully on screen and clear of the notch) and `CaptureValidation` does (as wide as the item now, not
    /// blank); otherwise the item keeps its earlier picture. Callers decide when items have settled enough to be
    /// captured at all (`CaptureSettleGate`).
    /// - Parameter framesAfterCapture: reads the items' frames again once the capture is done. Without it the frames
    ///   are assumed unchanged.
    @discardableResult
    public func refresh(
        _ items: [MenuBarItem], framesAfterCapture: (@MainActor () -> [ItemID: CGRect])? = nil
    ) async throws -> [ItemID] {
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

        let after = framesAfterCapture?()
        let notch = MenuBarScreens.strips().first { $0.frame.intersects(display.frame) }?.notch
        let pxPerPt = CGFloat(strip.width) / CGFloat(display.width)
        var captured: [ItemID] = []
        for item in visible {
            let frame = item.frame.cgRect
            // No second read: assume it stayed. A second read without the item: it went away, so the crop is suspect.
            let frameAfter: CGRect? = after == nil ? frame : after?[item.id]
            guard MenuBarGeometry.isCleanCapture(frame: frame, frameAfter: frameAfter, display: display.frame, notch: notch)
            else { continue }
            let f = frame.offsetBy(dx: -display.frame.minX, dy: -display.frame.minY)
            let crop = CGRect(x: f.minX * pxPerPt, y: f.minY * pxPerPt, width: f.width * pxPerPt, height: f.height * pxPerPt)
                .integral
                .intersection(CGRect(x: 0, y: 0, width: strip.width, height: strip.height))
            guard !crop.isEmpty, let image = strip.cropping(to: crop) else { continue }
            let keyed = GlyphImage.keyed(image)
            // A picture replaces the cached one only when it is the item: as wide as the item is now and not just
            // the bar's background. Otherwise the last good picture stays.
            guard CaptureValidation.accepts(
                capturedWidth: Double(crop.width / pxPerPt), currentWidth: frameAfter.map { Double($0.width) }, isBlank: keyed == nil
            ) else { continue }
            store(keyed, for: item.id)
            captured.append(item.id)
            if let url = diskURL(for: item.id), let png = image.pngData() {
                try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try? png.write(to: url, options: .atomic)
            }
        }
        return captured
    }

    /// Best available image: captured this round, else cached, else the app icon.
    /// - Parameter orderPositions: the order file, so a picture saved under the item's other ID is found too (see
    ///   `ItemIdentityResolver.equivalentIDs`).
    /// - Parameter iconsOnly: the app icon even when a picture is cached (without Screen Recording, feature 86).
    public func image(for item: MenuBarItem, capturedNow: Set<ItemID> = [], orderPositions: [String: Double]? = nil,
                      iconsOnly: Bool = false) -> ItemImage? {
        if !iconsOnly, let (id, keyed) = keyedImage(for: item.id, orderPositions: orderPositions) {
            let fresh = capturedNow.contains(item.id) || capturedNow.contains(id)
            return ItemImage(image: keyed.image, source: fresh ? .captured : .cached, isTemplate: keyed.isTemplate)
        }
        guard let icon = Self.appIcon(for: item) else { return nil }
        return ItemImage(image: icon, source: .appIcon, isTemplate: false)
    }

    /// The cached picture (memory, then disk) under the ID or one of its equivalents, with the ID it was found
    /// under. Never captures.
    public func keyedImage(for id: ItemID, orderPositions: [String: Double]? = nil) -> (ItemID, GlyphImage.Keyed)? {
        for candidate in [id] + ItemIdentityResolver.equivalentIDs(of: id, orderPositions: orderPositions) {
            if let keyed = load(candidate) { return (candidate, keyed) }
        }
        return nil
    }

    /// Whether a picture is cached for the item (under any of its IDs), without loading it.
    public func hasCachedImage(for id: ItemID, orderPositions: [String: Double]? = nil) -> Bool {
        ([id] + ItemIdentityResolver.equivalentIDs(of: id, orderPositions: orderPositions)).contains { candidate in
            if cache[candidate] != nil { return true }
            if blank.contains(candidate) { return false }
            guard let url = diskURL(for: candidate) else { return false }
            return FileManager.default.fileExists(atPath: url.path)
        }
    }

    /// Clears the memory cache (files on disk stay).
    public func clearCache() {
        cache.removeAll()
        blank.removeAll()
    }

    private func load(_ id: ItemID) -> GlyphImage.Keyed? {
        if let keyed = cache[id] { return keyed }
        guard !blank.contains(id), let url = diskURL(for: id), let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let raw = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else { return nil }
        let keyed = GlyphImage.keyed(raw)
        store(keyed, for: id)
        return keyed
    }

    private func store(_ keyed: GlyphImage.Keyed?, for id: ItemID) {
        if let keyed {
            cache[id] = keyed
            blank.remove(id)
        } else {
            cache.removeValue(forKey: id)
            blank.insert(id)
        }
    }

    private func diskURL(for id: ItemID) -> URL? {
        guard let cacheDirectory else { return nil }
        let safe = String(id.rawValue.map { $0.isLetter || $0.isNumber || $0 == "." || $0 == "-" || $0 == "_" ? $0 : "_" })
        return cacheDirectory.appendingPathComponent(safe + ".png")
    }

    /// The owning app's icon (running app first, else the installed app).
    public static func appIcon(for item: MenuBarItem, size: CGFloat = 64) -> CGImage? {
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

extension MenuBarReader {
    /// The items' frames now, by ID: the second read for `ItemImager.refresh(_:framesAfterCapture:)`.
    public func currentFrames(orderPositions: [String: Double]? = nil) -> [ItemID: CGRect] {
        Dictionary(snapshot(orderPositions: orderPositions).items.map { ($0.id, $0.frame.cgRect) }, uniquingKeysWith: { a, _ in a })
    }
}

extension CGImage {
    /// PNG data for saving.
    public func pngData() -> Data? {
        NSBitmapImageRep(cgImage: self).representation(using: .png, properties: [:])
    }
}
