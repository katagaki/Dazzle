import CoreGraphics
import Foundation

/// A DrawingML colour as the file states it: a base colour, which may be a
/// theme slot rather than a value, and the adjustments stacked on top of it.
///
/// Kept unresolved so a colour that says "Accent 1, 40% lighter" is still
/// that when it is written back, and follows the theme if the theme changes.
struct DrawingColor: Equatable, Hashable, Sendable {
    enum Base: Equatable, Hashable, Sendable {
        /// `RRGGBB`.
        case rgb(UInt32)
        /// A theme slot or a colour-map alias: `accent1`, `tx1`, `bg2`, `phClr`…
        case scheme(String)
        /// A system colour, with the value the authoring machine last saw.
        case system(String, lastColor: UInt32?)
    }

    struct Transform: Equatable, Hashable, Sendable {
        var name: String
        var value: Int
    }

    var base: Base
    var transforms: [Transform] = []

    static func rgb(_ value: UInt32) -> DrawingColor { DrawingColor(base: .rgb(value)) }
    static func scheme(_ name: String) -> DrawingColor { DrawingColor(base: .scheme(name)) }
}

extension DrawingColor {
    /// Reads a colour element: `srgbClr`, `schemeClr`, `sysClr`, `prstClr`,
    /// `scrgbClr` or `hslClr`.
    init?(element: XMLElement) {
        switch element.name {
        case "srgbClr":
            guard let value = element.attribute("val").flatMap({ UInt32($0, radix: 16) }) else { return nil }
            base = .rgb(value)
        case "schemeClr":
            guard let value = element.attribute("val") else { return nil }
            base = .scheme(value)
        case "sysClr":
            base = .system(
                element.attribute("val") ?? "windowText",
                lastColor: element.attribute("lastClr").flatMap { UInt32($0, radix: 16) }
            )
        case "prstClr":
            base = .rgb(Self.presetColors[element.attribute("val") ?? ""] ?? 0)
        case "scrgbClr":
            // Linear percentages; near enough to store as sRGB once.
            func channel(_ key: String) -> UInt32 {
                let linear = Double(element.attribute(key).flatMap(Int.init) ?? 0) / 100_000
                let encoded = linear <= 0.003_130_8 ? linear * 12.92 : 1.055 * pow(linear, 1 / 2.4) - 0.055
                return UInt32((min(max(encoded, 0), 1) * 255).rounded())
            }
            base = .rgb(channel("r") << 16 | channel("g") << 8 | channel("b"))
        case "hslClr":
            let hue = Double(element.attribute("hue").flatMap(Int.init) ?? 0) / 21_600_000
            let saturation = Double(element.attribute("sat").flatMap(Int.init) ?? 0) / 100_000
            let luminance = Double(element.attribute("lum").flatMap(Int.init) ?? 0) / 100_000
            base = .rgb(RGBAColor(hue: hue, saturation: saturation, luminance: luminance).hexValue)
        default:
            return nil
        }
        transforms = element.children.compactMap { child in
            child.attribute("val").flatMap(Int.init).map { Transform(name: child.name, value: $0) }
                ?? (["inv", "gray", "comp"].contains(child.name) ? Transform(name: child.name, value: 0) : nil)
        }
    }

    /// The first colour among an element's children, if any.
    static func first(in parent: XMLElement?) -> DrawingColor? {
        parent?.children.lazy.compactMap(DrawingColor.init(element:)).first
    }

    /// The colour written back as DrawingML.
    var xml: String {
        let inner = transforms.map { transform in
            ["inv", "gray", "comp"].contains(transform.name)
                ? "<a:\(transform.name)/>"
                : "<a:\(transform.name) val=\"\(transform.value)\"/>"
        }.joined()
        let open: String
        let close: String
        switch base {
        case .rgb(let value):
            open = "<a:srgbClr val=\"\(String(format: "%06X", value))\""
            close = "</a:srgbClr>"
        case .scheme(let name):
            open = "<a:schemeClr val=\"\(XMLLite.escape(name))\""
            close = "</a:schemeClr>"
        case .system(let name, let last):
            let lastAttribute = last.map { " lastClr=\"\(String(format: "%06X", $0))\"" } ?? ""
            open = "<a:sysClr val=\"\(XMLLite.escape(name))\"\(lastAttribute)"
            close = "</a:sysClr>"
        }
        return inner.isEmpty ? open + "/>" : open + ">" + inner + close
    }

    /// The handful of named colours files actually use.
    private static let presetColors: [String: UInt32] = [
        "black": 0x000000, "white": 0xFFFFFF, "red": 0xFF0000, "green": 0x008000, "blue": 0x0000FF,
        "yellow": 0xFFFF00, "orange": 0xFFA500, "purple": 0x800080, "gray": 0x808080, "grey": 0x808080,
        "darkGray": 0xA9A9A9, "lightGray": 0xD3D3D3, "cyan": 0x00FFFF, "magenta": 0xFF00FF,
        "navy": 0x000080, "maroon": 0x800000, "teal": 0x008080, "silver": 0xC0C0C0,
    ]
}

/// A colour with everything resolved, ready to draw with.
struct RGBAColor: Equatable, Hashable, Sendable {
    var red: Double
    var green: Double
    var blue: Double
    var alpha: Double = 1

    static let black = RGBAColor(red: 0, green: 0, blue: 0)
    static let white = RGBAColor(red: 1, green: 1, blue: 1)

    init(red: Double, green: Double, blue: Double, alpha: Double = 1) {
        self.red = red
        self.green = green
        self.blue = blue
        self.alpha = alpha
    }

    init(hex: UInt32) {
        red = Double((hex >> 16) & 0xFF) / 255
        green = Double((hex >> 8) & 0xFF) / 255
        blue = Double(hex & 0xFF) / 255
    }

    init(hue: Double, saturation: Double, luminance: Double, alpha: Double = 1) {
        func component(_ p: Double, _ q: Double, _ t: Double) -> Double {
            var t = t
            if t < 0 { t += 1 }
            if t > 1 { t -= 1 }
            if t < 1 / 6 { return p + (q - p) * 6 * t }
            if t < 1 / 2 { return q }
            if t < 2 / 3 { return p + (q - p) * (2 / 3 - t) * 6 }
            return p
        }
        guard saturation > 0 else {
            self.init(red: luminance, green: luminance, blue: luminance, alpha: alpha)
            return
        }
        let q = luminance < 0.5 ? luminance * (1 + saturation) : luminance + saturation - luminance * saturation
        let p = 2 * luminance - q
        self.init(
            red: component(p, q, hue + 1 / 3), green: component(p, q, hue),
            blue: component(p, q, hue - 1 / 3), alpha: alpha
        )
    }

    var hexValue: UInt32 {
        func byte(_ value: Double) -> UInt32 { UInt32((min(max(value, 0), 1) * 255).rounded()) }
        return byte(red) << 16 | byte(green) << 8 | byte(blue)
    }

    var cgColor: CGColor {
        CGColor(srgbRed: red, green: green, blue: blue, alpha: alpha)
    }

    /// Hue, saturation and luminance, each 0…1.
    var hsl: (hue: Double, saturation: Double, luminance: Double) {
        let maximum = max(red, green, blue)
        let minimum = min(red, green, blue)
        let luminance = (maximum + minimum) / 2
        guard maximum != minimum else { return (0, 0, luminance) }
        let delta = maximum - minimum
        let saturation = luminance > 0.5 ? delta / (2 - maximum - minimum) : delta / (maximum + minimum)
        var hue: Double
        switch maximum {
        case red: hue = (green - blue) / delta + (green < blue ? 6 : 0)
        case green: hue = (blue - red) / delta + 2
        default: hue = (red - green) / delta + 4
        }
        hue /= 6
        return (hue, saturation, luminance)
    }

    /// Applies one DrawingML colour transform. Values are in thousandths of
    /// a percent, as the file stores them.
    func applying(_ transform: DrawingColor.Transform) -> RGBAColor {
        let amount = Double(transform.value) / 100_000
        var result = self
        switch transform.name {
        case "alpha": result.alpha = amount
        case "alphaMod": result.alpha *= amount
        case "alphaOff": result.alpha = min(max(alpha + amount, 0), 1)
        case "lumMod", "lumOff", "satMod", "satOff", "hueMod", "hueOff":
            var (hue, saturation, luminance) = hsl
            switch transform.name {
            case "lumMod": luminance *= amount
            case "lumOff": luminance += amount
            case "satMod": saturation *= amount
            case "satOff": saturation += amount
            case "hueMod": hue *= amount
            default: hue += Double(transform.value) / 21_600_000
            }
            hue = hue.truncatingRemainder(dividingBy: 1)
            result = RGBAColor(
                hue: hue < 0 ? hue + 1 : hue, saturation: min(max(saturation, 0), 1),
                luminance: min(max(luminance, 0), 1), alpha: alpha
            )
        case "tint":
            // "A 10% tint is 10% of the input colour combined with 90% white."
            result = RGBAColor(
                red: red * amount + (1 - amount), green: green * amount + (1 - amount),
                blue: blue * amount + (1 - amount), alpha: alpha
            )
        case "shade":
            result = RGBAColor(red: red * amount, green: green * amount, blue: blue * amount, alpha: alpha)
        case "inv":
            result = RGBAColor(red: 1 - red, green: 1 - green, blue: 1 - blue, alpha: alpha)
        case "gray":
            let grey = 0.299 * red + 0.587 * green + 0.114 * blue
            result = RGBAColor(red: grey, green: grey, blue: grey, alpha: alpha)
        case "comp":
            let (hue, saturation, luminance) = hsl
            result = RGBAColor(
                hue: (hue + 0.5).truncatingRemainder(dividingBy: 1), saturation: saturation,
                luminance: luminance, alpha: alpha
            )
        default:
            break
        }
        return result
    }
}
