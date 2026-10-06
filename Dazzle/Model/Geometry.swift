import CoreGraphics

/// English Metric Units, the unit every length in a presentation is stored in.
enum EMU {
    static let perPoint = 12_700.0
    static let perInch = 914_400

    static func points(_ value: Int) -> Double { Double(value) / perPoint }
    static func from(points: Double) -> Int { Int((points * perPoint).rounded()) }
}

/// A slide's size, in EMU, as `p:sldSz` gives it.
struct EMUSize: Equatable, Hashable, Sendable {
    var width: Int
    var height: Int

    /// 13.333 × 7.5 inches: what PowerPoint makes a new presentation.
    static let widescreen = EMUSize(width: 12_192_000, height: 6_858_000)

    var points: CGSize { CGSize(width: EMU.points(width), height: EMU.points(height)) }
    var aspectRatio: Double { height == 0 ? 16.0 / 9.0 : Double(width) / Double(height) }
}

/// A rectangle in slide space, in EMU.
struct EMURect: Equatable, Hashable, Sendable {
    var x: Int
    var y: Int
    var width: Int
    var height: Int

    static let zero = EMURect(x: 0, y: 0, width: 0, height: 0)

    init(x: Int, y: Int, width: Int, height: Int) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    init(points rect: CGRect) {
        x = EMU.from(points: rect.minX)
        y = EMU.from(points: rect.minY)
        width = EMU.from(points: rect.width)
        height = EMU.from(points: rect.height)
    }

    /// The rectangle in points, which is the space slides are drawn in.
    var points: CGRect {
        CGRect(x: EMU.points(x), y: EMU.points(y), width: EMU.points(width), height: EMU.points(height))
    }
}
