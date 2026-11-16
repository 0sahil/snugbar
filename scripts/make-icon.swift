// Draws SnugBar's app icon: a white outlined capsule (the menu bar) on a dark ink squircle, with an orange left
// chevron and three white dots (its items).
// Usage: swiftc -O -o make-icon scripts/make-icon.swift && ./make-icon <output.iconset> [--png <file> <pixels>]
// Writes every size iconutil needs; build-app.sh turns the folder into AppIcon.icns. `--png` also writes one PNG
// (the README header uses the 1024 px one).
import AppKit

let args = CommandLine.arguments
guard args.count == 2 || (args.count == 5 && args[2] == "--png"), let pixelsArg = args.count == 5 ? Int(args[4]) : 0 else {
    FileHandle.standardError.write(Data("usage: make-icon <output.iconset> [--png <file> <pixels>]\n".utf8))
    exit(2)
}

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
}

let orange = color(0xFA9E4D)

func render(pixels: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = NSSize(width: pixels, height: pixels)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    defer { NSGraphicsContext.restoreGraphicsState() }
    let s = CGFloat(pixels)

    // macOS icon grid: the squircle is 80% of the canvas, corner radius 22.5% of its width.
    let inset = s * 0.1
    let r = NSRect(x: inset, y: inset, width: s - inset * 2, height: s - inset * 2)
    let u = r.width
    let squircle = NSBezierPath(roundedRect: r, xRadius: u * 0.225, yRadius: u * 0.225)

    // Soft drop shadow.
    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.28)
    shadow.shadowBlurRadius = s * 0.025
    shadow.shadowOffset = NSSize(width: 0, height: -s * 0.01)
    shadow.set()
    color(0x12141F).setFill()
    squircle.fill()
    NSGraphicsContext.restoreGraphicsState()

    // Dark ink gradient, top to bottom, and a subtle highlight over the top half.
    NSGradient(starting: color(0x333B4D), ending: color(0x12141F))!.draw(in: squircle, angle: -90)
    NSGraphicsContext.saveGraphicsState()
    squircle.addClip()
    NSGradient(starting: NSColor.white.withAlphaComponent(0.18), ending: NSColor.white.withAlphaComponent(0))!
        .draw(in: NSRect(x: r.minX, y: r.midY, width: r.width, height: r.height / 2), angle: -90)
    NSGraphicsContext.restoreGraphicsState()

    // Small sizes: thin strokes fade into the background, so they get a little heavier.
    let weight: CGFloat = pixels <= 16 ? 1.6 : pixels <= 32 ? 1.3 : 1

    // The capsule.
    let cap = NSRect(x: r.minX + 0.13 * u, y: r.midY - 0.13 * u, width: 0.74 * u, height: 0.26 * u)
    let capsule = NSBezierPath(roundedRect: cap, xRadius: cap.height / 2, yRadius: cap.height / 2)
    capsule.lineWidth = 0.045 * u * weight
    NSColor.white.setStroke()
    capsule.stroke()

    // The orange left chevron in its left part.
    let cx = cap.minX + 0.30 * cap.width
    let h = 0.30 * cap.height
    let chevron = NSBezierPath()
    chevron.move(to: NSPoint(x: cx + 0.6 * h, y: cap.midY + h))
    chevron.line(to: NSPoint(x: cx - 0.4 * h, y: cap.midY))
    chevron.line(to: NSPoint(x: cx + 0.6 * h, y: cap.midY - h))
    chevron.lineWidth = 0.05 * u * weight
    chevron.lineCapStyle = .round
    chevron.lineJoinStyle = .round
    orange.setStroke()
    chevron.stroke()

    // Three white dots on the right.
    let d = 0.24 * cap.height * (pixels <= 16 ? 1.2 : 1)
    NSColor.white.setFill()
    for i in 0..<3 {
        let x = cap.minX + cap.width * (0.52 + CGFloat(i) * 0.13)
        NSBezierPath(ovalIn: NSRect(x: x - d / 2, y: cap.midY - d / 2, width: d, height: d)).fill()
    }

    return rep.representation(using: .png, properties: [:])!
}

let outDir = URL(fileURLWithPath: args[1])
try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
let sizes: [(String, Int)] = [
    ("icon_16x16.png", 16), ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32), ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128), ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256), ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512), ("icon_512x512@2x.png", 1024),
]
for (name, px) in sizes {
    try render(pixels: px).write(to: outDir.appendingPathComponent(name))
}
if args.count == 5 {
    try render(pixels: pixelsArg).write(to: URL(fileURLWithPath: args[3]))
}
print("wrote \(sizes.count) icon images to \(outDir.path)")
