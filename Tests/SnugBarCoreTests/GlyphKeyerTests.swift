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

    func testKeyingTwiceChangesNothing() throws {
        let once = try XCTUnwrap(GlyphKeyer.key(bitmap(bg: (30, 30, 30, 255), glyph: (240, 240, 240, 255))))
        let twice = try XCTUnwrap(GlyphKeyer.key(once.bitmap))
        XCTAssertEqual(twice.bitmap, once.bitmap)
        XCTAssertEqual(twice.isTemplate, once.isTemplate)
    }
}
