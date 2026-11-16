// Draws the DMG window background ("Drag SnugBar to Applications").
// Usage: swiftc -O -o make-dmg-background scripts/make-dmg-background.swift && ./make-dmg-background <out-dir>
// Writes background.png (660×400) and background@2x.png (1320×800); combine them with
//   tiffutil -cathidpicheck background.png background@2x.png -out background.tiff
// Icon centres in the DMG window are at (165, 185) and (495, 185) from the top left, 128 pt icons.
import AppKit

let width: CGFloat = 660
let height: CGFloat = 400

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
}

func render(scale: CGFloat) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(width * scale), pixelsHigh: Int(height * scale),
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = NSSize(width: width, height: height)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    defer { NSGraphicsContext.restoreGraphicsState() }

    // Light paper, so Finder's dark icon labels stay readable.
    NSGradient(starting: color(0xFBFAF7), ending: color(0xEDEBE6))!
        .draw(in: NSRect(x: 0, y: 0, width: width, height: height), angle: -90)

    // Three chevrons between the two icons (centred at y = 185 from the top), fading in towards Applications.
    let cy = height - 185
    for (i, x) in [292.0, 330.0, 368.0].enumerated() {
        let chevron = NSBezierPath()
        chevron.move(to: NSPoint(x: x, y: cy + 20))
        chevron.line(to: NSPoint(x: x + 20, y: cy))
        chevron.line(to: NSPoint(x: x, y: cy - 20))
        chevron.lineWidth = 8
        chevron.lineCapStyle = .round
        chevron.lineJoinStyle = .round
        color(0xFA9E4D, [0.4, 0.7, 1.0][i]).setStroke()
        chevron.stroke()
    }

    // Caption, centred about 330 pt from the top.
    let paragraph = NSMutableParagraphStyle()
    paragraph.alignment = .center
    let caption = NSAttributedString(string: "Drag SnugBar to Applications", attributes: [
        .font: NSFont.systemFont(ofSize: 14),
        .foregroundColor: color(0x595C66),
        .paragraphStyle: paragraph,
    ])
    let lineHeight = caption.size().height
    caption.draw(in: NSRect(x: 0, y: height - 330 - lineHeight / 2, width: width, height: lineHeight))

    return rep.representation(using: .png, properties: [:])!
}

let outDir = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : ".")
try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
try render(scale: 1).write(to: outDir.appendingPathComponent("background.png"))
try render(scale: 2).write(to: outDir.appendingPathComponent("background@2x.png"))
print("wrote \(outDir.path)/background.png and background@2x.png")
