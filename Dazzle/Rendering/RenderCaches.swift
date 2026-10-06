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
        if bold { traits.insert(.traitBold) }
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
