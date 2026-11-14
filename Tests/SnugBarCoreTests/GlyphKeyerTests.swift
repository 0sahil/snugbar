import XCTest
@testable import SnugBarCore

final class GlyphKeyerTests: XCTestCase {
    typealias Pixel = (r: UInt8, g: UInt8, b: UInt8, a: UInt8)

    /// A `width`×`height` opaque bitmap of `bg` with a `glyph`-coloured square from (gx, gy), `size` wide.
    private func bitmap(width: Int = 12, height: Int = 10, bg: Pixel, glyph: Pixel, gx: Int = 4, gy: Int = 3, size: Int = 4) -> GlyphKeyer.Bitmap {
        var pixels: [UInt8] = []
        for y in 0..<height {
            for x in 0..<width {
                let inside = x >= gx && x < gx + size && y >= gy && y < gy + size
                let p = inside ? glyph : bg
                pixels += [p.r, p.g, p.b, p.a]
            }
        }
        return GlyphKeyer.Bitmap(width: width, height: height, pixels: pixels)
    }

    func testWhiteGlyphOnDarkBarBecomesATrimmedTemplate() throws {
        let input = bitmap(bg: (30, 30, 32, 255), glyph: (245, 245, 245, 255))
        let result = try XCTUnwrap(GlyphKeyer.key(input))
        XCTAssertTrue(result.isTemplate)
        XCTAssertEqual(result.background, GlyphKeyer.RGB(r: 30, g: 30, b: 32))
        // Trimmed to the 4×4 glyph plus a 1-pixel margin.
        XCTAssertEqual(result.bitmap.width, 6)
        XCTAssertEqual(result.bitmap.height, 6)
        XCTAssertEqual(result.bitmap.pixel(x: 0, y: 0).a, 0, "the margin is the keyed-out background")
        XCTAssertEqual(result.bitmap.pixel(x: 1, y: 1).a, 255, "the glyph is opaque")
        XCTAssertEqual(result.bitmap.pixel(x: 3, y: 3).a, 255)
    }

    func testBlackGlyphOnLightBarIsKeyedTheSameWay() throws {
        let input = bitmap(bg: (236, 236, 236, 255), glyph: (20, 20, 20, 255))
        let result = try XCTUnwrap(GlyphKeyer.key(input))
        XCTAssertTrue(result.isTemplate)
        XCTAssertEqual(result.bitmap.pixel(x: 0, y: 0).a, 0)
        XCTAssertEqual(result.bitmap.pixel(x: 2, y: 2).a, 255)
    }

    func testAntialiasedEdgesGetPartialAlpha() throws {
        // A half-way grey between background and glyph, as at a glyph's anti-aliased edge.
        var input = bitmap(bg: (30, 30, 30, 255), glyph: (230, 230, 230, 255))
        let i = (3 * input.width + 3) * 4 // just left of the glyph's top-left corner
        input.pixels.replaceSubrange(i..<(i + 4), with: [130, 130, 130, 255])
        let result = try XCTUnwrap(GlyphKeyer.key(input))
        // The edge pixel widens the trimmed box by one column: it sits at (1, 1) after the 1-pixel margin.
        XCTAssertEqual(result.bitmap.width, 7)
        let alpha = Int(result.bitmap.pixel(x: 1, y: 1).a)
        XCTAssertGreaterThan(alpha, 90)
        XCTAssertLessThan(alpha, 160)
    }

    func testBackgroundNoiseStaysTransparent() throws {
        var input = bitmap(bg: (30, 30, 30, 255), glyph: (240, 240, 240, 255))
        // Slight variation in the bar (wallpaper tint) well below the noise floor.
        for i in stride(from: 0, to: input.pixels.count, by: 8) where input.pixels[i] == 30 {
            input.pixels[i] = 34
            input.pixels[i + 1] = 33
        }
        let result = try XCTUnwrap(GlyphKeyer.key(input))
        XCTAssertEqual(result.bitmap.width, 6, "noise doesn't widen the trimmed image")
        XCTAssertEqual(result.bitmap.pixel(x: 0, y: 0).a, 0)
    }

    func testBackgroundComesFromTheEdgesEvenWhenTheGlyphTouchesOne() {
        // The glyph runs into the top edge: the median of the edge pixels is still the bar.
        let input = bitmap(bg: (40, 42, 44, 255), glyph: (250, 250, 250, 255), gx: 4, gy: 0, size: 4)
        XCTAssertEqual(GlyphKeyer.backgroundColor(of: input), GlyphKeyer.RGB(r: 40, g: 42, b: 44))
    }

    func testColouredGlyphKeepsItsColours() throws {
        let input = bitmap(bg: (30, 30, 30, 255), glyph: (220, 40, 40, 255))
        let result = try XCTUnwrap(GlyphKeyer.key(input))
        XCTAssertFalse(result.isTemplate)
        let p = result.bitmap.pixel(x: 2, y: 2)
        XCTAssertEqual(p.a, 255)
        XCTAssertEqual(Int(p.r), 220, accuracy: 2)
        XCTAssertEqual(Int(p.g), 40, accuracy: 2)
    }

    func testBlankCaptureGivesNothing() {
        let input = bitmap(bg: (30, 30, 30, 255), glyph: (31, 31, 31, 255))
        XCTAssertNil(GlyphKeyer.key(input))
    }

    func testAlreadyTransparentImageIsKeptAndTrimmed() throws {
        // Earlier keyed output (transparent edges) passes through: same glyph, still a template.
        let input = bitmap(bg: (0, 0, 0, 0), glyph: (255, 255, 255, 255))
        let result = try XCTUnwrap(GlyphKeyer.key(input))
        XCTAssertNil(result.background)
        XCTAssertTrue(result.isTemplate)
        XCTAssertEqual(result.bitmap.width, 6)
        XCTAssertEqual(result.bitmap.pixel(x: 2, y: 2).a, 255)
    }

    /// A glyph drawn over `bg` as anti-aliased coverage: each entry is a pixel and how much of it the glyph covers.
    private func glyph(width: Int, height: Int, bg: Pixel, ink: Pixel, coverage: [Point: Double]) -> GlyphKeyer.Bitmap {
        var pixels: [UInt8] = []
        for y in 0..<height {
            for x in 0..<width {
                let c = coverage[Point(x: x, y: y)] ?? 0
                func mix(_ b: UInt8, _ f: UInt8) -> UInt8 { UInt8((Double(b) * (1 - c) + Double(f) * c).rounded()) }
                pixels += [mix(bg.r, ink.r), mix(bg.g, ink.g), mix(bg.b, ink.b), 255]
            }
        }
        return GlyphKeyer.Bitmap(width: width, height: height, pixels: pixels)
    }

    private struct Point: Hashable { var x: Int; var y: Int }

    func testThinStrokesAndAntialiasedEdgesKeepTheirShape() throws {
        // Like a menu bar glyph with fine detail: a solid body with soft edges, 1-px strokes (some only partly
        // covered by the glyph, as when a hairline falls between pixels) and gaps a pixel wide between parts.
        var coverage: [Point: Double] = [:]
        for y in 4..<10 { for x in 4..<10 { coverage[Point(x: x, y: y)] = 1 } } // body
        for y in 4..<10 { coverage[Point(x: 3, y: y)] = 0.5; coverage[Point(x: 10, y: y)] = 0.5 } // soft sides
        for x in 4..<10 { coverage[Point(x: x, y: 3)] = 0.35; coverage[Point(x: x, y: 10)] = 0.35 } // softer top, bottom
        var strokes: [Point: Double] = [:]
        for y in 2..<16 { strokes[Point(x: 12, y: y)] = 1 } // full 1-px vertical stroke, 1-px gap from the body's edge
        for x in 4..<18 where x != 12 { strokes[Point(x: x, y: 13)] = 0.6 } // hairline at 60% coverage, crossing it
        for i in 0..<5 { strokes[Point(x: 14 + i, y: 3 + i)] = i.isMultiple(of: 2) ? 0.55 : 0.8 } // anti-aliased diagonal
        coverage.merge(strokes) { max($0, $1) }
        let bg: Pixel = (28, 28, 30, 255)
        let input = glyph(width: 24, height: 20, bg: bg, ink: (242, 242, 242, 255), coverage: coverage)

        let result = try XCTUnwrap(GlyphKeyer.key(input))
        XCTAssertTrue(result.isTemplate)
        XCTAssertEqual(result.background, GlyphKeyer.RGB(r: 28, g: 28, b: 30))
        // The trimmed image starts one pixel before the glyph's top-left.
        let ox = coverage.keys.map(\.x).min()! - 1, oy = coverage.keys.map(\.y).min()! - 1
        func alpha(_ x: Int, _ y: Int) -> Double { Double(result.bitmap.pixel(x: x - ox, y: y - oy).a) / 255 }

        for (p, c) in strokes {
            XCTAssertGreaterThan(alpha(p.x, p.y), 0.5, "stroke pixel \(p) (coverage \(c)) keeps its opacity")
            XCTAssertEqual(alpha(p.x, p.y), c, accuracy: 0.05, "opacity follows coverage at \(p)")
        }
        XCTAssertEqual(alpha(3, 6), 0.5, accuracy: 0.05, "soft edge stays half opaque")
        XCTAssertEqual(alpha(6, 3), 0.35, accuracy: 0.05, "softer edge isn't cut off")
        XCTAssertEqual(alpha(6, 6), 1, accuracy: 0.01)
        // Everything else is background: transparent, including the 1-px gap between the body and the stroke.
        for y in 0..<input.height {
            for x in 0..<input.width where coverage[Point(x: x, y: y)] == nil {
                let tx = x - ox, ty = y - oy
                guard tx >= 0, ty >= 0, tx < result.bitmap.width, ty < result.bitmap.height else { continue }
                XCTAssertLessThan(alpha(x, y), 0.02, "background at (\(x), \(y)) is keyed out")
            }
        }
    }

    func testOpacityIsSmoothAndProportional() {
        let full = 0.8
        var previous = 0.0
        for step in 0...200 {
            let d = Double(step) / 200 * full
            let a = GlyphKeyer.opacity(distance: d, fullStrength: full)
            XCTAssertGreaterThanOrEqual(a, previous, "never decreases (d = \(d))")
            XCTAssertLessThan(a - previous, 0.03, "no jump (d = \(d))")
            previous = a
        }
        XCTAssertEqual(GlyphKeyer.opacity(distance: 0, fullStrength: full), 0)
        XCTAssertEqual(GlyphKeyer.opacity(distance: 0.4, fullStrength: full), 0.5, accuracy: 1e-9)
        XCTAssertEqual(GlyphKeyer.opacity(distance: 0.9, fullStrength: full), 1)
    }

    func testGreyGlyphWithAColouredBadgeKeepsItsColours() throws {
        // A 10×10 white glyph with a 3×3 red notification dot at its corner: under a tenth of the solid pixels.
        var input = bitmap(width: 18, height: 16, bg: (30, 30, 30, 255), glyph: (240, 240, 240, 255), gx: 3, gy: 3, size: 10)
        for y in 2..<5 {
            for x in 12..<15 {
                let i = (y * input.width + x) * 4
                input.pixels.replaceSubrange(i..<(i + 4), with: [235, 64, 52, 255])
            }
        }
        let result = try XCTUnwrap(GlyphKeyer.key(input))
        XCTAssertFalse(result.isTemplate, "the badge's colour isn't flattened to the label colour")
        // Trimmed from (2, 1): the badge pixel (13, 3) is at (11, 2).
        let badge = result.bitmap.pixel(x: 11, y: 2)
        XCTAssertGreaterThan(badge.a, 240, "the badge stays (nearly) opaque, not faded by its smaller distance from the bar")
        XCTAssertEqual(Int(badge.r), 235, accuracy: 2)
        XCTAssertEqual(Int(badge.g), 64, accuracy: 2)
        let body = result.bitmap.pixel(x: 4, y: 6)
        XCTAssertEqual(body.a, 255)
        XCTAssertEqual(Int(body.r), 240, accuracy: 2)
    }

    func testAFewOffGreyPixelsDontMakeAGlyphColoured() throws {
        // Tinted fringe pixels (a translucent bar over a colourful wallpaper) on a grey glyph stay a template.
        var input = bitmap(width: 18, height: 16, bg: (30, 30, 30, 255), glyph: (240, 240, 240, 255), gx: 3, gy: 3, size: 10)
        for x in [4, 9] {
            let i = (5 * input.width + x) * 4
            input.pixels.replaceSubrange(i..<(i + 4), with: [240, 190, 240, 255])
        }
        XCTAssertTrue(try XCTUnwrap(GlyphKeyer.key(input)).isTemplate)
    }

    func testBackgroundIgnoresAGlyphRunningAlongSeveralEdges() {
        // A tall glyph flush with the top, bottom and left edges, with anti-aliased pixels on the border too.
        let bg: Pixel = (22, 24, 26, 255)
        var coverage: [Point: Double] = [:]
        for y in 0..<14 { for x in 0..<5 { coverage[Point(x: x, y: y)] = 1 } }
        for y in 0..<14 { coverage[Point(x: 5, y: y)] = 0.5 }
        let input = glyph(width: 20, height: 14, bg: bg, ink: (250, 250, 250, 255), coverage: coverage)
        XCTAssertEqual(GlyphKeyer.backgroundColor(of: input), GlyphKeyer.RGB(r: 22, g: 24, b: 26))
    }

    func testKeyingTwiceChangesNothing() throws {
        let once = try XCTUnwrap(GlyphKeyer.key(bitmap(bg: (30, 30, 30, 255), glyph: (240, 240, 240, 255))))
        let twice = try XCTUnwrap(GlyphKeyer.key(once.bitmap))
        XCTAssertEqual(twice.bitmap, once.bitmap)
        XCTAssertEqual(twice.isTemplate, once.isTemplate)
    }
}
