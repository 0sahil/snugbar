import Foundation

/// Turns a captured menu bar item (a glyph on the menu bar's background) into a transparent image.
///
/// Menu bar items are almost always one colour (white on a dark bar, black on a light one) drawn on the bar's
/// background, which a capture includes. The background colour is taken from the image's border pixels (the colour
/// most of them agree on, so a glyph touching an edge doesn't shift it). Each pixel's opacity is its distance from
/// that colour, proportional and scaled so the glyph's full-strength pixels are opaque: anti-aliased edges and thin
/// strokes keep their partial coverage, and only differences within the bar's own noise fade out (smoothly, without a
/// cut-off). Grey results are template images (the app tints them with the label colour, so they suit light and dark
/// bars); images with a coloured part (a whole coloured icon, or a coloured badge on a grey glyph) keep their colours.
/// Transparent margins are trimmed.
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

    /// Differences around this (0...1, RGB distance) are the background's own noise (wallpaper tint showing through
    /// the bar, compression). Opacity fades in smoothly from half of it to one and a half times it; above that it is
    /// exactly proportional to the distance.
    public static let noiseFloor = 0.06
    /// Border pixels this close (0...1, RGB distance) to a candidate background colour count as agreeing with it.
    static let borderTolerance = 0.08
    /// The glyph's full strength is this percentile of the inked pixels' distances, so one stray pixel (or a badge
    /// further from the background than the glyph) doesn't make the glyph itself translucent.
    static let fullStrengthPercentile = 0.98
    /// A pixel this far from grey (0...255, max minus min channel) counts as coloured.
    static let chromaThreshold = 48.0
    /// The image keeps its colours when this share of its solid pixels is coloured…
    static let colouredShare = 0.15
    /// …or when at least this many are (a notification badge or dot on a one-colour glyph: a few percent of the
    /// picture, but flattening it to the label colour would lose what it says).
    static let colouredPixelsForBadge = 6

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
            // Two measures of how far each pixel is from the background, 0...1: the RGB distance, and the least
            // opacity that explains the pixel as some colour over the background (per channel: how much of the room
            // between the background and black or white it uses). They agree for grey glyphs; the second also sees a
            // saturated colour (a red badge on a dark bar) as fully there, where the distance would make it translucent.
            var distance = [Double](repeating: 0, count: count)
            var reach = [Double](repeating: 0, count: count)
            for i in 0..<count {
                let p = rgb(input, i)
                distance[i] = self.distance(p, bg)
                reach[i] = self.reach(p, bg)
            }
            guard let full = fullStrength(distance, inked: distance) else { return nil }
            let fullReach = fullStrength(reach, inked: distance) ?? 1
            for i in 0..<count {
                let byReach = min(reach[i] / fullReach, 1) * noiseGate(distance[i])
                alpha[i] = max(opacity(distance: distance[i], fullStrength: full), byReach)
            }
            // Colour of each pixel with the background unmixed: p = a·f + (1 − a)·bg, so a·f = p − (1 − a)·bg.
            var solid = 0
            var coloured = 0
            for i in 0..<count where alpha[i] > 0.5 {
                let p = rgb(input, i)
                let a = alpha[i]
                let f = RGB(r: bg.r + (p.r - bg.r) / a, g: bg.g + (p.g - bg.g) / a, b: bg.b + (p.b - bg.b) / a)
                solid += 1
                if chroma(f) > chromaThreshold { coloured += 1 }
            }
            isTemplate = !keepsColours(coloured: coloured, solid: solid)
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
                if chroma(f) > chromaThreshold { coloured += 1 }
            }
            guard solid > 0 || alpha.contains(where: { $0 > 0.05 }) else { return nil }
            isTemplate = !keepsColours(coloured: coloured, solid: solid)
            if isTemplate {
                for i in 0..<count { out[i * 4] = 0; out[i * 4 + 1] = 0; out[i * 4 + 2] = 0 }
            }
        }

        guard let trimmed = trim(Bitmap(width: input.width, height: input.height, pixels: out)) else { return nil }
        return Result(bitmap: trimmed, isTemplate: isTemplate, background: bg)
    }

    /// The background, from the border pixels only (the outermost row and column on each side). Nil when most of
    /// them are transparent (the image has already been keyed).
    ///
    /// A glyph may run into an edge (tall icons touch the top and bottom, wide ones the sides), so a plain median of
    /// the border can land on the glyph. Each side's median and the whole border's median are candidates; the one most
    /// border pixels agree with wins, and the result is the per-channel median of the pixels that agree with it.
    public static func backgroundColor(of bitmap: Bitmap) -> RGB? {
        let w = bitmap.width, h = bitmap.height
        guard w > 0, h > 0 else { return nil }
        var sides: [[RGB]] = [[], [], [], []] // top, bottom, left, right
        var transparent = 0
        var total = 0
        func sample(_ x: Int, _ y: Int, side: Int) {
            let p = bitmap.pixel(x: x, y: y)
            total += 1
            if p.a < 128 { transparent += 1; return }
            sides[side].append(RGB(r: Double(p.r), g: Double(p.g), b: Double(p.b)))
        }
        // Each border pixel once: corners belong to the top and bottom rows.
        for x in 0..<w {
            sample(x, 0, side: 0)
            if h > 1 { sample(x, h - 1, side: 1) }
        }
        if h > 2 {
            for y in 1..<(h - 1) {
                sample(0, y, side: 2)
                if w > 1 { sample(w - 1, y, side: 3) }
            }
        }
        let border = sides.flatMap { $0 }
        guard total > 0, transparent * 2 < total, !border.isEmpty else { return nil }

        let candidates = ([border] + sides.filter { !$0.isEmpty }).map(median)
        func agreeing(_ c: RGB) -> [RGB] { border.filter { distance($0, c) <= borderTolerance } }
        var best = candidates[0]
        var bestCount = agreeing(best).count
        for c in candidates.dropFirst() {
            let n = agreeing(c).count
            if n > bestCount { best = c; bestCount = n }
        }
        let agree = agreeing(best)
        return agree.isEmpty ? best : median(agree)
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

    /// Opacity of a pixel `distance` (0...1) from the background when the glyph's full-strength pixels are
    /// `fullStrength` away. Proportional to the distance (a pixel half-covered by the glyph is half opaque), times a
    /// smooth gate that only fades out differences at the level of the bar's noise. Continuous and non-decreasing:
    /// no threshold where a faint anti-aliased edge or thin stroke suddenly drops out.
    public static func opacity(distance d: Double, fullStrength: Double) -> Double {
        guard fullStrength > 0 else { return 0 }
        return min(max(d / fullStrength, 0), 1) * noiseGate(d)
    }

    // MARK: - Private

    /// 0 for differences at the bar's noise level, 1 above it, with a smooth ramp between.
    private static func noiseGate(_ d: Double) -> Double {
        smoothstep(noiseFloor * 0.5, noiseFloor * 1.5, d)
    }

    /// RGB distance, 0...1.
    private static func distance(_ a: RGB, _ b: RGB) -> Double {
        let dr = a.r - b.r, dg = a.g - b.g, db = a.b - b.b
        return ((dr * dr + dg * dg + db * db) / 3).squareRoot() / 255
    }

    /// Least opacity of any colour over `bg` that gives `p`, 0...1: per channel, the share of the room between the
    /// background and the end the pixel moved towards (0 or 255). The room is never taken as less than a quarter of
    /// the range, so on a near-white or near-black bar a few levels of noise don't count as a lot.
    private static func reach(_ p: RGB, _ bg: RGB) -> Double {
        func channel(_ v: Double, _ b: Double) -> Double {
            let room = max(v >= b ? 255 - b : b, 64)
            return abs(v - b) / room
        }
        return min(max(channel(p.r, bg.r), channel(p.g, bg.g), channel(p.b, bg.b)), 1)
    }

    /// The glyph's full strength on `measure`: a high percentile over the inked pixels (those whose distance from the
    /// background is clearly above the noise). Nil when nothing is inked (a blank capture).
    private static func fullStrength(_ measure: [Double], inked distance: [Double]) -> Double? {
        let inked = zip(measure, distance).filter { $0.1 > noiseFloor * 2 }.map(\.0).sorted()
        guard !inked.isEmpty, let top = inked.last, top > 0 else { return nil }
        let index = min(Int((Double(inked.count - 1) * fullStrengthPercentile).rounded()), inked.count - 1)
        return inked[index] > 0 ? inked[index] : top
    }

    private static func keepsColours(coloured: Int, solid: Int) -> Bool {
        guard solid > 0, coloured > 0 else { return false }
        return Double(coloured) / Double(solid) >= colouredShare || coloured >= colouredPixelsForBadge
    }

    private static func chroma(_ c: RGB) -> Double {
        max(c.r, c.g, c.b) - min(c.r, c.g, c.b)
    }

    private static func smoothstep(_ edge0: Double, _ edge1: Double, _ x: Double) -> Double {
        let t = min(max((x - edge0) / (edge1 - edge0), 0), 1)
        return t * t * (3 - 2 * t)
    }

    private static func rgb(_ bitmap: Bitmap, _ i: Int) -> RGB {
        RGB(r: Double(bitmap.pixels[i * 4]), g: Double(bitmap.pixels[i * 4 + 1]), b: Double(bitmap.pixels[i * 4 + 2]))
    }

    private static func byte(_ v: Double) -> UInt8 {
        UInt8(min(max(v.rounded(), 0), 255))
    }

    /// Per-channel median.
    private static func median(_ values: [RGB]) -> RGB {
        func m(_ channel: [Double]) -> Double { channel.sorted()[channel.count / 2] }
        return RGB(r: m(values.map(\.r)), g: m(values.map(\.g)), b: m(values.map(\.b)))
    }
}
