import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import SnugBarCore
@testable import SnugBarEngine

/// Synthetic captures: a light glyph on a dark menu bar, as `ItemImager` crops them.
enum SyntheticCapture {
    /// A 2x capture: `width`×`height` pixels of a dark bar with a white 8×8 square in the middle.
    static func image(width: Int = 32, height: Int = 24, bar: CGColor = CGColor(srgbRed: 0.12, green: 0.12, blue: 0.13, alpha: 1)) -> CGImage {
        let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        context.setFillColor(bar)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.setFillColor(CGColor(srgbRed: 0.96, green: 0.96, blue: 0.96, alpha: 1))
        context.fill(CGRect(x: (width - 8) / 2, y: (height - 8) / 2, width: 8, height: 8))
        return context.makeImage()!
    }

    static func writePNG(_ image: CGImage, to url: URL) throws {
        let dest = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(dest, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(dest))
    }
}

final class GlyphImageTests: XCTestCase {
    func testCapturedGlyphLosesItsBlackBackground() throws {
        let keyed = try XCTUnwrap(GlyphImage.keyed(SyntheticCapture.image()))
        XCTAssertTrue(keyed.isTemplate)
        XCTAssertEqual(keyed.image.width, 10, "trimmed to the glyph plus a 1-pixel margin")
        XCTAssertEqual(keyed.image.height, 10)
        let bitmap = try XCTUnwrap(GlyphImage.bitmap(from: keyed.image))
        XCTAssertEqual(bitmap.pixel(x: 0, y: 0).a, 0, "no opaque square around the glyph")
        XCTAssertEqual(bitmap.pixel(x: 5, y: 5).a, 255)
    }

    func testBitmapRoundTrip() throws {
        let source = SyntheticCapture.image(width: 6, height: 4)
        let bitmap = try XCTUnwrap(GlyphImage.bitmap(from: source))
        let back = try XCTUnwrap(GlyphImage.cgImage(from: bitmap))
        XCTAssertEqual(try XCTUnwrap(GlyphImage.bitmap(from: back)), bitmap)
    }

    func testPlainBarCaptureGivesNoImage() {
        let context = CGContext(data: nil, width: 8, height: 8, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(srgbRed: 0.1, green: 0.1, blue: 0.1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 8, height: 8))
        XCTAssertNil(GlyphImage.keyed(context.makeImage()!))
    }
}

@MainActor
final class ItemImagerCacheTests: XCTestCase {
    private var directory: URL!

    override func setUp() async throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("snugbar-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func item(_ id: ItemID, bundle: String) -> MenuBarItem {
        MenuBarItem(id: id, ownerBundleID: bundle, ownerPID: 0, appName: "Clipper", displayName: "Clipper", frame: .zero,
                    isAppleItem: false, isOverflowed: false, axIdentifier: nil)
    }

    func testPictureSavedUnderTheOrderFileIDIsFoundForTheFallbackID() throws {
        // Captured while visible, under its order-file ID (the file name an earlier version wrote, raw crop).
        try SyntheticCapture.writePNG(SyntheticCapture.image(), to: directory.appendingPathComponent("status_com.example.clipper__Item-1.png"))
        let positions: [String: Double] = ["status:com.example.clipper::Item-1": 400, "module:Battery": 200]
        let imager = ItemImager(cacheDirectory: directory)
        let hidden = item(.indexed(owner: "com.example.clipper", index: 0), bundle: "com.example.clipper")

        XCTAssertFalse(imager.hasCachedImage(for: hidden.id), "without the order file the IDs can't be matched")
        XCTAssertTrue(imager.hasCachedImage(for: hidden.id, orderPositions: positions))
        let found = try XCTUnwrap(imager.keyedImage(for: hidden.id, orderPositions: positions))
        XCTAssertEqual(found.0.rawValue, "status:com.example.clipper::Item-1")

        let image = try XCTUnwrap(imager.image(for: hidden, orderPositions: positions))
        XCTAssertEqual(image.source, .cached)
        XCTAssertTrue(image.isTemplate, "an old raw cache file is keyed on load")
        let bitmap = try XCTUnwrap(GlyphImage.bitmap(from: image.image))
        XCTAssertEqual(bitmap.pixel(x: 0, y: 0).a, 0)
    }

    func testPictureSavedUnderTheFallbackIDIsFoundForTheOrderFileID() throws {
        try SyntheticCapture.writePNG(SyntheticCapture.image(), to: directory.appendingPathComponent("com.example.clipper_0.png"))
        let positions: [String: Double] = ["status:com.example.clipper::Item-1": 400]
        let imager = ItemImager(cacheDirectory: directory)
        let visible = item(ItemID(rawValue: "status:com.example.clipper::Item-1"), bundle: "com.example.clipper")
        XCTAssertEqual(imager.image(for: visible, orderPositions: positions)?.source, .cached)
    }

    func testCacheFilesAreLeftAsTheyWere() throws {
        let url = directory.appendingPathComponent("status_com.example.clipper__Item-1.png")
        try SyntheticCapture.writePNG(SyntheticCapture.image(), to: url)
        let before = try Data(contentsOf: url)
        let imager = ItemImager(cacheDirectory: directory)
        _ = imager.image(for: item(ItemID(rawValue: "status:com.example.clipper::Item-1"), bundle: "com.example.clipper"))
        XCTAssertEqual(try Data(contentsOf: url), before, "loading keys in memory only")
    }
}
