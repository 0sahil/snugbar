import AppKit
import SnugBarCore
import SnugBarEngine
import SwiftUI

/// `bar-snapshot --fake --out <png> [--dragging] [--onto-other] [--no-access] [--width <pt>] [--appearance light|dark]`:
/// renders the SnugBar Bar offscreen with made-up items in Hidden, Always Hidden and Didn't fit. `--dragging` shows
/// it mid-drag (a Hidden tile carried further along Hidden; with `--onto-other`, over Always Hidden). `--width` caps
/// the width so the rows wrap. Never creates status items or touches the hider.
extension DebugRunner {
    struct BarSnapshotResult: Encodable {
        var image: String
        var size: [Double]
        var imagePixels: [Int]
        var groups: [String: [String]]
        var draggable: [String]
        var dragging: String?
        var target: String?
        var gap: Int?
        var marker: [Double]?
        var drop: String?
    }

    func barSnapshot() async throws -> BarSnapshotResult {
        let usage = "usage: bar-snapshot --fake --out <png> [--dragging] [--onto-other] [--no-access] [--width <pt>] [--appearance light|dark]"
        guard invocation.arguments.contains("--fake"), let out = invocation.outputURL else { throw Failure(usage) }
        let access = !invocation.arguments.contains("--no-access")
        let maxWidth = invocation.value(after: "--width").flatMap(Double.init).map { CGFloat($0) } ?? 800

        let model = SnugBarBarController.Model()
        let demo = Self.demoBar(access: access)
        model.groups = demo.groups
        // Hosted and sized as the live bar is (`SnugBarBarController.layout`): the width it wants (capped), and the
        // height for that width, measured once the view is in its window. The window background stands in for the
        // menu material, which doesn't draw offscreen.
        let controller = NSHostingController(rootView: BarView(model: model, onClick: { _ in }, onHover: { _, _ in }))
        controller.sizingOptions = []
        let window = OffscreenWindow(contentRect: NSRect(x: 0, y: 0, width: maxWidth, height: 200), styleMask: [.borderless],
                                     backing: .buffered, defer: false)
        window.backgroundColor = .windowBackgroundColor
        switch invocation.value(after: "--appearance") {
        case "dark": window.appearance = NSAppearance(named: .darkAqua)
        case "light": window.appearance = NSAppearance(named: .aqua)
        default: break
        }
        let backdrop = BackdropView()
        controller.view.translatesAutoresizingMaskIntoConstraints = false
        backdrop.addSubview(controller.view)
        NSLayoutConstraint.activate([
            controller.view.leadingAnchor.constraint(equalTo: backdrop.leadingAnchor),
            controller.view.trailingAnchor.constraint(equalTo: backdrop.trailingAnchor),
            controller.view.topAnchor.constraint(equalTo: backdrop.topAnchor),
            controller.view.bottomAnchor.constraint(equalTo: backdrop.bottomAnchor),
        ])
        window.contentView = backdrop
        let fitting = controller.sizeThatFits(in: NSSize(width: maxWidth, height: 10_000))
        let width = min(max(fitting.width, BarView.minWidth), maxWidth)
        let height = controller.sizeThatFits(in: NSSize(width: width, height: 10_000)).height
        window.setFrame(NSRect(x: -30000, y: -30000, width: width, height: height), display: false)
        // The PNG is of the backdrop (it draws the background; the window's own isn't part of a view's cache).
        let hosting = backdrop
        window.orderFront(nil)
        defer { window.orderOut(nil) }
        try? await Task.sleep(nanoseconds: 800_000_000)

        var request: SnugBarBarController.DropRequest?
        if invocation.arguments.contains("--dragging") {
            guard let hidden = model.groups.first(where: { $0.kind == .hidden }), hidden.entries.count >= 4,
                  let start = model.tileFrames[hidden.entries[1].id]
            else { throw Failure("the demo bar has no Hidden tiles to drag") }
            let point: CGPoint
            if invocation.arguments.contains("--onto-other"),
               let always = model.groups.first(where: { $0.kind == .alwaysHidden }), let f = model.tileFrames[always.entries[0].id] {
                point = CGPoint(x: f.maxX + 2, y: f.midY + 3)
            } else if let f = model.tileFrames[hidden.entries[3].id] {
                point = CGPoint(x: f.maxX + 2, y: f.midY + 3)
            } else {
                throw Failure("no tile frames were laid out")
            }
            // As if the tile had been pressed near its centre and carried there.
            model.beginDrag(hidden.entries[1].id, at: CGPoint(x: start.midX, y: start.midY))
            model.moveDrag(to: point)
            request = model.dropRequest()
            try? await Task.sleep(nanoseconds: 400_000_000)
        }
        hosting.layoutSubtreeIfNeeded()
        window.displayIfNeeded()

        guard let rep = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else { throw Failure("could not make a bitmap") }
        hosting.cacheDisplay(in: hosting.bounds, to: rep)
        guard let png = rep.representation(using: .png, properties: [:]) else { throw Failure("could not encode the PNG") }
        try FileManager.default.createDirectory(at: out.deletingLastPathComponent(), withIntermediateDirectories: true)
        try png.write(to: out, options: .atomic)

        var groups: [String: [String]] = [:]
        for group in model.groups { groups[group.kind.rawValue] = group.entries.map { $0.tile.helpText } }
        let drop = request.map { r in
            BarDrag.outcome(dragging: r.tile, from: r.from, onto: r.onto, gap: r.gap, row: r.row, positions: access ? demo.positions : nil)
        }
        let marker = model.insertionMarker.map { [Double($0.minX), Double($0.minY), Double($0.width), Double($0.height)] }
        return BarSnapshotResult(
            image: out.path, size: [Double(hosting.bounds.width), Double(hosting.bounds.height)], imagePixels: [rep.pixelsWide, rep.pixelsHigh],
            groups: groups, draggable: model.groups.flatMap(\.entries).filter(\.canDrag).map(\.tile.helpText),
            dragging: model.drag.flatMap { model.entry($0.id)?.tile.helpText }, target: model.drag?.target?.rawValue, gap: model.drag?.gap,
            marker: marker, drop: drop.map { String(describing: $0) }
        )
    }

    /// Made-up apps (example bundle IDs) with SF Symbols standing in for captured pictures.
    static func demoBar(access: Bool) -> (groups: [SnugBarBarController.Group], positions: [String: Double]) {
        func item(_ app: String, _ name: String) -> MenuBarItem {
            MenuBarItem(id: ItemID(rawValue: "status:com.example.\(app)::Item-0"), ownerBundleID: "com.example.\(app)", ownerPID: 0,
                        appName: name, displayName: name, frame: Rect(x: 0, y: 0, width: 24, height: 24),
                        isAppleItem: false, isOverflowed: false, axIdentifier: nil)
        }
        let hidden: [(String, String, String)] = [
            ("chat", "Chat", "bubble.left"), ("weather", "Weather", "cloud.sun"), ("timer", "Timer", "timer"),
            ("sync", "Sync", "arrow.triangle.2.circlepath"), ("music", "Music Bar", "music.note"), ("notes", "Notes Bar", "note.text"),
            ("worldclock", "World Clock", ""),
        ]
        // Captured pictures as the live bar gives them (with its top edge in the crop); one is a wide item.
        let captures: [String: NSImage] = [
            "sync": fakeCapture(symbol: "arrow.triangle.2.circlepath", width: 30),
            "worldclock": fakeCapture(text: "NYC 09:05   LON 14:05", width: 150),
        ]
        let always: [(String, String, String)] = [("tunnel", "Tunnel", "network"), ("backup", "Backup", "externaldrive")]
        let didntFit: [(String, String, String)] = [("meters", "Meters", "cpu")]
        var positions: [String: Double] = [:]
        for (i, (app, _, _)) in (hidden + always).enumerated() { positions["status:com.example.\(app)::Item-0"] = Double(1000 - i * 10) }
        let filePositions = access ? positions : nil
        func group(_ kind: BarGroupKind, _ list: [(String, String, String)]) -> SnugBarBarController.Group {
            let entries = list.map { app, name, symbol -> SnugBarBarController.Entry in
                let image = captures[app] ?? NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
                    .withSymbolConfiguration(.init(pointSize: 14, weight: .regular)) ?? NSImage()
                if captures[app] == nil { image.isTemplate = true }
                let tile = BarTile(items: [item(app, name)])
                return .init(tile: tile, image: image, key: nil,
                             canDrag: BarDrag.canDrag(tile, in: kind, swapped: false, positions: filePositions))
            }
            return SnugBarBarController.Group(kind: kind, entries: entries, section: BarDrag.section(of: kind, swapped: false))
        }
        return ([group(.hidden, hidden), group(.alwaysHidden, always), group(.didntFit, didntFit)], positions)
    }
}

extension DebugRunner {
    /// A made-up capture of a menu bar item as the live bar gives it (white content on a dark bar, with the bar's top
    /// highlight row across the crop), keyed the way the app keys captures. For offscreen renders.
    static func fakeCapture(symbol: String? = nil, text: String? = nil, width: CGFloat) -> NSImage {
        let scale: CGFloat = 2, height: CGFloat = 33
        let w = Int(width * scale), h = Int(height * scale)
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return NSImage() }
        ctx.setFillColor(CGColor(srgbRed: 0.12, green: 0.12, blue: 0.13, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        // The highlight row, one pixel below the top (CoreGraphics counts rows from the bottom).
        ctx.setFillColor(CGColor(srgbRed: 0.34, green: 0.34, blue: 0.35, alpha: 1))
        ctx.fill(CGRect(x: 0, y: h - 2, width: w, height: 1))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
        let bounds = NSRect(x: 0, y: 0, width: w, height: h)
        if let symbol, let image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 14 * scale, weight: .regular)
                .applying(NSImage.SymbolConfiguration(paletteColors: [.white]))) {
            let size = image.size
            image.draw(in: NSRect(x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2,
                                  width: size.width, height: size.height))
        }
        if let text {
            let string = NSAttributedString(string: text, attributes: [
                .font: NSFont.systemFont(ofSize: 13 * scale, weight: .medium), .foregroundColor: NSColor.white,
            ])
            let size = string.size()
            string.draw(at: NSPoint(x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2))
        }
        NSGraphicsContext.restoreGraphicsState()
        guard let raw = ctx.makeImage(), let keyed = GlyphImage.keyed(raw) else { return NSImage() }
        let image = NSImage(cgImage: keyed.image, size: NSSize(width: CGFloat(keyed.image.width) / scale,
                                                                height: CGFloat(keyed.image.height) / scale))
        image.isTemplate = keyed.isTemplate
        return image
    }
}

/// Draws the window background colour in its appearance, under the bar's content, for offscreen renders.
private final class BackdropView: NSView {
    override func draw(_ dirtyRect: NSRect) {
        NSColor.windowBackgroundColor.setFill()
        dirtyRect.fill()
    }
}
