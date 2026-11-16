import AppKit
import SnugBarCore

/// `menubar-icons --out <png> [--scale N]`: draws every menu bar icon style in every state on light and dark
/// menu-bar-coloured chips, as the status item would show them (template images tinted black or white). Nothing is
/// started: no status item, no hiding, no updater.
extension DebugRunner {
    struct MenuBarIconsResult: Encodable {
        struct Glyph: Encodable {
            var style: String
            var state: String
            var symbol: String?
            var width: Double
            var height: Double
            var isTemplate: Bool
        }

        var image: String
        var scale: Double
        var styles: [String]
        var states: [String]
        var glyphs: [Glyph]
    }

    func menuBarIcons() throws -> MenuBarIconsResult {
        guard let out = invocation.outputURL else { throw Failure("usage: menubar-icons --out <png> [--scale N]") }
        let scale = CGFloat(Double(invocation.value(after: "--scale") ?? "4") ?? 4)
        let styles = MenuBarIconStyle.allCases
        let states = MenuBarIconState.allCases

        let labelWidth: CGFloat = 70, chip = NSSize(width: 46, height: 24), gap: CGFloat = 4, margin: CGFloat = 10
        let headerHeight: CGFloat = 16, blockTitle: CGFloat = 16
        let rowsHeight = CGFloat(styles.count) * (chip.height + gap)
        let blockHeight = blockTitle + rowsHeight
        let width = margin * 2 + labelWidth + CGFloat(states.count) * (chip.width + gap)
        let height = margin * 2 + headerHeight + blockHeight * 2 + 8
        let size = NSSize(width: width, height: height)

        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(width * scale), pixelsHigh: Int(height * scale),
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)
        else { throw Failure("could not make a bitmap") }
        rep.size = size
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSColor(white: 0.93, alpha: 1).setFill()
        NSRect(origin: .zero, size: size).fill()

        func text(_ s: String, at p: NSPoint, size: CGFloat = 10, weight: NSFont.Weight = .regular) {
            NSAttributedString(string: s, attributes: [
                .font: NSFont.systemFont(ofSize: size, weight: weight), .foregroundColor: NSColor(white: 0.25, alpha: 1),
            ]).draw(at: p)
        }

        // Column headers (top-left origin converted to AppKit's bottom-left).
        var y = height - margin - headerHeight
        for (i, state) in states.enumerated() {
            let label = NSAttributedString(string: state.rawValue, attributes: [.font: NSFont.systemFont(ofSize: 8)])
            let x = margin + labelWidth + CGFloat(i) * (chip.width + gap) + (chip.width - label.size().width) / 2
            text(state.rawValue, at: NSPoint(x: x, y: y + 2), size: 8)
        }

        var glyphs: [MenuBarIconsResult.Glyph] = []
        let appearances: [(String, NSColor, NSColor)] = [
            ("Light menu bar", NSColor(white: 0.965, alpha: 1), .black),
            ("Dark menu bar", NSColor(red: 0.16, green: 0.16, blue: 0.17, alpha: 1), .white),
        ]
        for (title, background, tint) in appearances {
            y -= blockTitle
            text(title, at: NSPoint(x: margin, y: y + 2), weight: .semibold)
            for style in styles {
                y -= chip.height + gap
                text(style.title, at: NSPoint(x: margin, y: y + 6))
                for (i, state) in states.enumerated() {
                    let rect = NSRect(x: margin + labelWidth + CGFloat(i) * (chip.width + gap), y: y, width: chip.width, height: chip.height)
                    background.setFill()
                    NSBezierPath(roundedRect: rect, xRadius: 4, yRadius: 4).fill()
                    guard let image = MenuBarIconRenderer.image(style, state) else { continue }
                    let tinted = Self.tinted(image, tint)
                    let s = image.size
                    tinted.draw(in: NSRect(x: (rect.midX - s.width / 2).rounded(), y: (rect.midY - s.height / 2).rounded(),
                                           width: s.width, height: s.height))
                    if title == appearances[0].0 {
                        glyphs.append(.init(style: style.rawValue, state: state.rawValue, symbol: style.symbolName(for: state),
                                            width: Double(s.width), height: Double(s.height), isTemplate: image.isTemplate))
                    }
                }
            }
            y -= 8
        }
        NSGraphicsContext.restoreGraphicsState()

        guard let png = rep.representation(using: .png, properties: [:]) else { throw Failure("could not encode the PNG") }
        try FileManager.default.createDirectory(at: out.deletingLastPathComponent(), withIntermediateDirectories: true)
        try png.write(to: out, options: .atomic)
        return MenuBarIconsResult(image: out.path, scale: Double(scale), styles: styles.map(\.rawValue),
                                  states: states.map(\.rawValue), glyphs: glyphs)
    }

    /// A template image drawn in one colour, as the menu bar does.
    private static func tinted(_ image: NSImage, _ color: NSColor) -> NSImage {
        NSImage(size: image.size, flipped: false) { rect in
            image.draw(in: rect)
            color.set()
            rect.fill(using: .sourceAtop)
            return true
        }
    }
}
