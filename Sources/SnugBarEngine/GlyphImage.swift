import CoreGraphics
import Foundation
import SnugBarCore

/// CoreGraphics side of `GlyphKeyer`: converts between `CGImage` and the keyer's RGBA bitmap.
public enum GlyphImage {
    /// A keyed menu bar item picture.
    public struct Keyed {
        public let image: CGImage
        /// Draw tinted with the label colour (only the alpha channel matters).
        public let isTemplate: Bool
    }

    /// Keys the bar background out of a captured item. Nil when the capture holds nothing but background.
    public static func keyed(_ image: CGImage) -> Keyed? {
        guard let bitmap = bitmap(from: image), let result = GlyphKeyer.key(bitmap),
              let keyed = cgImage(from: result.bitmap)
        else { return nil }
        return Keyed(image: keyed, isTemplate: result.isTemplate)
    }

    /// The image's pixels as 8-bit sRGB RGBA, premultiplied, top row first.
    public static func bitmap(from image: CGImage) -> GlyphKeyer.Bitmap? {
        let w = image.width, h = image.height
        guard w > 0, h > 0, let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        var pixels = [UInt8](repeating: 0, count: w * h * 4)
        let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(
                data: buffer.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4, space: space,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
            ) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        return drawn ? GlyphKeyer.Bitmap(width: w, height: h, pixels: pixels) : nil
    }

    public static func cgImage(from bitmap: GlyphKeyer.Bitmap) -> CGImage? {
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let provider = CGDataProvider(data: Data(bitmap.pixels) as CFData)
        else { return nil }
        return CGImage(
            width: bitmap.width, height: bitmap.height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: bitmap.width * 4,
            space: space,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue),
            provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent
        )
    }
}
