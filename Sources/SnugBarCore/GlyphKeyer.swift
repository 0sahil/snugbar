import Foundation

/// Turns a captured menu bar item (a glyph on the menu bar's background) into a transparent image.
///
/// Menu bar items are almost always one colour (white on a dark bar, black on a light one) drawn on the bar's
/// background, which a capture includes. The background colour is taken from the image's edge pixels; each pixel's
/// opacity is its distance from that colour, scaled so the strongest pixel is opaque. Grey results are template
/// images (the app tints them with the label colour, so they suit light and dark bars); clearly coloured ones keep
/// their colours. Transparent margins are trimmed.
///
/// Pure pixel math on an RGBA buffer, so it runs without a screen.
public enum GlyphKeyer {
    /// 8-bit RGBA pixels, row by row from the top, alpha premultiplied (the layout of a CoreGraphics
    /// `premultipliedLast` bitmap context).
    public struct Bitmap: Equatable, Sendable {
        public var width: Int
        public var height: Int
        public var pixels: [UInt8]

        public init(width: Int, height: Int, pixels: [UInt8]) {
            precondition(pixels.count == width * height * 4, "pixel buffer size doesn't match the dimensions")
            self.width = width
            self.height = height
            self.pixels = pixels
        }

        public func pixel(x: Int, y: Int) -> (r: UInt8, g: UInt8, b: UInt8, a: UInt8) {
            let i = (y * width + x) * 4
            return (pixels[i], pixels[i + 1], pixels[i + 2], pixels[i + 3])
        }
    }

    public struct RGB: Equatable, Sendable {
        public var r: Double
        public var g: Double
        public var b: Double

        public init(r: Double, g: Double, b: Double) {
            self.r = r
            self.g = g
            self.b = b
        }
    }

    public struct Result: Equatable, Sendable {
        public var bitmap: Bitmap
        /// True when only the alpha channel matters (a one-colour glyph).
        public var isTemplate: Bool
        /// The colour that was keyed out; nil when the input already had transparent edges.
        public var background: RGB?
    }

    /// Differences below this (0...1, RGB distance) are treated as the background's own noise.
    public static let noiseFloor = 0.06
    /// A pixel this far from grey (0...255, max minus min channel) counts as coloured.
    static let chromaThreshold = 48.0
    /// Share of solid pixels that must be coloured for the image to keep its colours.
    static let colouredShare = 0.15

    /// Keys out the background. Returns nil when nothing is left (a blank capture), so the caller can fall back to
    /// another picture.
    public static func key(_ input: Bitmap) -> Result? {
        guard input.width > 0, input.height > 0 else { return nil }
        let count = input.width * input.height
        var alpha = [Double](repeating: 0, count: count)
        var out = [UInt8](repeating: 0, count: count * 4)
        var isTemplate: Bool
        let bg = backgroundColor(of: input)

        if let bg {
            // Distance of each pixel from the background, 0...1.
            var distance = [Double](repeating: 0, count: count)
            var strongest = 0.0
            for i in 0..<count {
                let p = rgb(input, i)
                let d = (((p.r - bg.r) * (p.r - bg.r) + (p.g - bg.g) * (p.g - bg.g) + (p.b - bg.b) * (p.b - bg.b)) / 3)
                    .squareRoot() / 255
                distance[i] = d
                strongest = max(strongest, d)
            }
            guard strongest > noiseFloor * 2 else { return nil }
            for i in 0..<count {
                alpha[i] = min(max((distance[i] - noiseFloor) / (strongest - noiseFloor), 0), 1)
            }
            // Colour of each pixel with the background unmixed: p = a·f + (1 − a)·bg, so a·f = p − (1 − a)·bg.
            var solid = 0
            var coloured = 0
            for i in 0..<count where alpha[i] > 0.5 {
                let p = rgb(input, i)
                let a = alpha[i]
                let f = RGB(r: bg.r + (p.r - bg.r) / a, g: bg.g + (p.g - bg.g) / a, b: bg.b + (p.b - bg.b) / a)
                solid += 1
                if max(f.r, f.g, f.b) - min(f.r, f.g, f.b) > chromaThreshold { coloured += 1 }
            }
            isTemplate = solid == 0 || Double(coloured) / Double(solid) < colouredShare
            for i in 0..<count {
                let a = alpha[i]
                out[i * 4 + 3] = byte(a * 255)
                guard !isTemplate else { continue } // template: colour is ignored, keep it black
                let p = rgb(input, i)
                out[i * 4] = byte(min(p.r - (1 - a) * bg.r, a * 255))
                out[i * 4 + 1] = byte(min(p.g - (1 - a) * bg.g, a * 255))
                out[i * 4 + 2] = byte(min(p.b - (1 - a) * bg.b, a * 255))
            }
        } else {
            // Edges already transparent: keep the pixels, just decide whether it's a one-colour glyph.
            out = input.pixels
            var solid = 0
            var coloured = 0
            for i in 0..<count {
                let a = Double(input.pixels[i * 4 + 3])
                alpha[i] = a / 255
                guard a > 127 else { continue }
                let p = rgb(input, i) // premultiplied; unpremultiply for the chroma test
                let f = RGB(r: p.r * 255 / a, g: p.g * 255 / a, b: p.b * 255 / a)
                solid += 1
                if max(f.r, f.g, f.b) - min(f.r, f.g, f.b) > chromaThreshold { coloured += 1 }
            }
            guard solid > 0 || alpha.contains(where: { $0 > 0.05 }) else { return nil }
            isTemplate = solid == 0 || Double(coloured) / Double(solid) < colouredShare
            if isTemplate {
                for i in 0..<count { out[i * 4] = 0; out[i * 4 + 1] = 0; out[i * 4 + 2] = 0 }
            }
        }

        guard let trimmed = trim(Bitmap(width: input.width, height: input.height, pixels: out)) else { return nil }
        return Result(bitmap: trimmed, isTemplate: isTemplate, background: bg)
    }

    /// The background: the per-channel median of the opaque edge pixels. Nil when most edge pixels are transparent
    /// (the image has already been keyed).
    public static func backgroundColor(of bitmap: Bitmap) -> RGB? {
        var rs: [UInt8] = [], gs: [UInt8] = [], bs: [UInt8] = []
        var transparent = 0
        var total = 0
        func sample(_ x: Int, _ y: Int) {
            let p = bitmap.pixel(x: x, y: y)
            total += 1
            if p.a < 128 { transparent += 1; return }
            rs.append(p.r); gs.append(p.g); bs.append(p.b)
        }
        let w = bitmap.width, h = bitmap.height
        for x in 0..<w {
            sample(x, 0)
            if h > 1 { sample(x, h - 1) }
        }
        if h > 2 {
            for y in 1..<(h - 1) {
                sample(0, y)
                if w > 1 { sample(w - 1, y) }
            }
        }
        guard total > 0, transparent * 2 < total, !rs.isEmpty else { return nil }
        return RGB(r: median(rs), g: median(gs), b: median(bs))
    }

    /// Crops to the pixels that show (alpha above ~3%), keeping a 1-pixel margin. Nil when nothing shows.
    public static func trim(_ bitmap: Bitmap, threshold: UInt8 = 8) -> Bitmap? {
        var minX = bitmap.width, minY = bitmap.height, maxX = -1, maxY = -1
        for y in 0..<bitmap.height {
            for x in 0..<bitmap.width where bitmap.pixels[(y * bitmap.width + x) * 4 + 3] > threshold {
                minX = min(minX, x); maxX = max(maxX, x)
                minY = min(minY, y); maxY = max(maxY, y)
            }
        }
        guard maxX >= 0 else { return nil }
        minX = max(minX - 1, 0); minY = max(minY - 1, 0)
        maxX = min(maxX + 1, bitmap.width - 1); maxY = min(maxY + 1, bitmap.height - 1)
        let w = maxX - minX + 1, h = maxY - minY + 1
        var pixels = [UInt8](repeating: 0, count: w * h * 4)
        for y in 0..<h {
            let src = ((minY + y) * bitmap.width + minX) * 4
            pixels.replaceSubrange((y * w * 4)..<((y + 1) * w * 4), with: bitmap.pixels[src..<(src + w * 4)])
        }
        return Bitmap(width: w, height: h, pixels: pixels)
    }

    // MARK: - Private

    private static func rgb(_ bitmap: Bitmap, _ i: Int) -> RGB {
        RGB(r: Double(bitmap.pixels[i * 4]), g: Double(bitmap.pixels[i * 4 + 1]), b: Double(bitmap.pixels[i * 4 + 2]))
    }

    private static func byte(_ v: Double) -> UInt8 {
        UInt8(min(max(v.rounded(), 0), 255))
    }

    private static func median(_ values: [UInt8]) -> Double {
        let sorted = values.sorted()
        return Double(sorted[sorted.count / 2])
    }
}
