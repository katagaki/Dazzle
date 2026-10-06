import CoreText
import Foundation
import ImageIO

/// Decoded pictures, kept so a slide is not decoded again on every redraw.
final class ImageCache: @unchecked Sendable {
    static let shared = ImageCache()

    // NSCache is thread-safe, which is what makes this class safe to share.
    private let cache = NSCache<NSString, CGImage>()

    private init() {
        cache.countLimit = 120
    }

    func image(for data: Data, path: String) -> CGImage? {
        let key = "\(path)#\(data.count)#\(data.hashValue)" as NSString
        if let cached = cache.object(forKey: key) { return cached }
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        // Pictures are drawn no larger than a slide on a big display, so
        // there is no use decoding a 50-megapixel photo at full size.
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: 3_000,
            kCGImageSourceCreateThumbnailWithTransform: true,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        cache.setObject(image, forKey: key)
        return image
    }

    /// A picture in grey, or mapped from dark to light onto two colours.
    func recolored(_ image: CGImage, key: String, isGreyscale: Bool, duotone: [RGBAColor]) -> CGImage? {
        let cacheKey = "recolored#\(key)" as NSString
        if let cached = cache.object(forKey: cacheKey) { return cached }
        let width = image.width
        let height = image.height
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4, space: space,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              ),
              let pixels = context.data?.bindMemory(to: UInt8.self, capacity: width * height * 4) else { return image }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        let dark = duotone.first
        let light = duotone.last
        for offset in stride(from: 0, to: width * height * 4, by: 4) {
            let alpha = Double(pixels[offset + 3]) / 255
            guard alpha > 0 else { continue }
            // Channels are premultiplied; take the colour out of the alpha first.
            let luminance = (0.299 * Double(pixels[offset]) + 0.587 * Double(pixels[offset + 1])
                + 0.114 * Double(pixels[offset + 2])) / 255 / alpha
            var red = luminance
            var green = luminance
            var blue = luminance
            if let dark, let light, !isGreyscale {
                red = dark.red + (light.red - dark.red) * luminance
                green = dark.green + (light.green - dark.green) * luminance
                blue = dark.blue + (light.blue - dark.blue) * luminance
            }
            pixels[offset] = UInt8(min(max(red, 0), 1) * alpha * 255)
            pixels[offset + 1] = UInt8(min(max(green, 0), 1) * alpha * 255)
            pixels[offset + 2] = UInt8(min(max(blue, 0), 1) * alpha * 255)
        }
        guard let recolored = context.makeImage() else { return image }
        cache.setObject(recolored, forKey: cacheKey)
        return recolored
    }
}

/// Fonts by family, size and style. Families iOS does not have — Calibri,
/// Aptos and the other Office faces — are drawn in the closest one it does.
final class FontResolver: @unchecked Sendable {
    static let shared = FontResolver()

    private let cache = NSCache<NSString, CTFont>()

    func font(family: String?, size: CGFloat, bold: Bool, italic: Bool) -> CTFont {
        let key = "\(family ?? "")|\(size)|\(bold)|\(italic)" as NSString
        if let cached = cache.object(forKey: key) { return cached }

        var font = base(family: family, size: size)
        var traits: CTFontSymbolicTraits = []
        // A heavy face iOS does not have is closest in the bold of the substitute.
        let lowered = family?.lowercased() ?? ""
        let isHeavyFamily = lowered.contains("black") || lowered.contains("heavy")
        if bold || (isHeavyFamily && (CTFontCopyFamilyName(font) as String).lowercased() != lowered) {
            traits.insert(.traitBold)
        }
        if italic { traits.insert(.traitItalic) }
        if !traits.isEmpty {
            font = CTFontCreateCopyWithSymbolicTraits(font, size, nil, traits, traits) ?? font
        }
        cache.setObject(font, forKey: key)
        return font
    }

    private func base(family: String?, size: CGFloat) -> CTFont {
        let system = CTFontCreateUIFontForLanguage(.system, size, nil) ?? CTFontCreateWithName("Helvetica" as CFString, size, nil)
        guard let family = family?.trimmed, !family.isEmpty else { return system }
        let lowered = family.lowercased()
        if let substitute = Self.substitutes.first(where: { lowered.hasPrefix($0.key) })?.value {
            return substitute.isEmpty ? system : CTFontCreateWithName(substitute as CFString, size, nil)
        }
        let candidate = CTFontCreateWithName(family as CFString, size, nil)
        let found = (CTFontCopyFamilyName(candidate) as String).lowercased()
        // CoreText answers an unknown name with some other font rather than
        // nothing; only keep what came back if it is what was asked for.
        if found == lowered || (CTFontCopyFullName(candidate) as String).lowercased() == lowered {
            return candidate
        }
        return system
    }

    /// Office typefaces mapped to what iOS ships. Empty means the system font.
    private static let substitutes: [String: String] = [
        "calibri": "", "aptos": "", "segoe": "", "arial nova": "", "tahoma": "", "candara": "",
        "corbel": "", "franklin gothic": "", "century gothic": "Avenir Next", "gill sans mt": "Gill Sans",
        "cambria": "Georgia", "constantia": "Georgia", "book antiqua": "Palatino", "garamond": "Baskerville",
        "consolas": "Menlo", "lucida console": "Menlo", "courier": "Courier New",
        "meiryo": "Hiragino Sans", "yu gothic": "Hiragino Sans", "ms gothic": "Hiragino Sans",
        "ms pgothic": "Hiragino Sans", "游ゴシック": "Hiragino Sans", "メイリオ": "Hiragino Sans",
        "ms mincho": "Hiragino Mincho ProN", "yu mincho": "Hiragino Mincho ProN",
    ]
}
