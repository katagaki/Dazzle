import Foundation

/// How the inside of a shape, or a background, is painted.
enum Fill: Equatable, Hashable, Sendable {
    case none
    case solid(DrawingColor)
    case gradient(Gradient)
    /// A picture, by its path inside the package, stretched over the area.
    case picture(path: String, opacity: Double = 1)
    /// A picture repeated at its own size across the area.
    case tiledPicture(path: String, opacity: Double = 1)
    /// Whatever the enclosing group is filled with.
    case group

    struct Gradient: Equatable, Hashable, Sendable {
        struct Stop: Equatable, Hashable, Sendable {
            /// 0…1 along the gradient.
            var position: Double
            var color: DrawingColor
        }

        var stops: [Stop]
        /// Degrees clockwise from left-to-right, for a linear gradient.
        var angle: Double
        var isRadial: Bool
        /// Where a radial gradient starts, as fractions of the area.
        var focusX = 0.5
        var focusY = 0.5
    }

    /// Names of the elements a fill can be written as; finding one of these
    /// among an element's children means that element states its own fill.
    static let elementNames: Set<String> = ["noFill", "solidFill", "gradFill", "blipFill", "pattFill", "grpFill"]

    /// Reads the fill element among `parent`'s children, if it has one.
    /// `image` turns a relationship id into a package path.
    static func parse(in parent: XMLElement?, image: (String) -> String?) -> Fill? {
        guard let parent else { return nil }
        for child in parent.children {
            if let fill = parse(element: child, image: image) { return fill }
        }
        return nil
    }

    static func parse(element: XMLElement, image: (String) -> String?) -> Fill? {
        switch element.name {
        case "noFill":
            return Fill.none
        case "solidFill":
            return DrawingColor.first(in: element).map(Fill.solid) ?? Fill.none
        case "gradFill":
            let stops = (element.firstChild(named: "gsLst")?.children(named: "gs") ?? []).compactMap { stop in
                DrawingColor.first(in: stop).map {
                    Gradient.Stop(position: Double(stop.attribute("pos").flatMap(Int.init) ?? 0) / 100_000, color: $0)
                }
            }.sorted { $0.position < $1.position }
            guard !stops.isEmpty else { return Fill.none }
            let angle = Double(element.firstChild(named: "lin")?.attribute("ang").flatMap(Int.init) ?? 0) / 60_000
            var gradient = Gradient(stops: stops, angle: angle, isRadial: element.firstChild(named: "path") != nil)
            // `fillToRect` insets the focus from each edge; its centre is where the gradient starts.
            if let focus = element.firstChild(named: "path")?.firstChild(named: "fillToRect") {
                func inset(_ key: String) -> Double { Double(focus.attribute(key).flatMap(Int.init) ?? 0) / 100_000 }
                gradient.focusX = (inset("l") + 1 - inset("r")) / 2
                gradient.focusY = (inset("t") + 1 - inset("b")) / 2
            }
            return .gradient(gradient)
        case "blipFill":
            guard let reference = element.firstChild(named: "blip")?.attribute("embed"),
                  let path = image(reference) else { return Fill.none }
            // `alphaModFix` makes the whole picture partly transparent.
            let opacity = element.firstChild(named: "blip")?.firstChild(named: "alphaModFix")?
                .attribute("amt").flatMap(Double.init).map { $0 / 100_000 } ?? 1
            return element.firstChild(named: "tile") != nil
                ? .tiledPicture(path: path, opacity: opacity) : .picture(path: path, opacity: opacity)
        case "pattFill":
            // A pattern is drawn as its foreground, which is what it reads as at a distance.
            return DrawingColor.first(in: element.firstChild(named: "fgClr")).map(Fill.solid) ?? Fill.none
        case "grpFill":
            return .group
        default:
            return nil
        }
    }

    /// The fill as DrawingML. Picture fills are never written by Dazzle, so
    /// they come back as nothing rather than as a dangling reference.
    var xml: String {
        switch self {
        case .none, .picture, .tiledPicture: return "<a:noFill/>"
        case .group: return "<a:grpFill/>"
        case .solid(let color): return "<a:solidFill>\(color.xml)</a:solidFill>"
        case .gradient(let gradient):
            let stops = gradient.stops.map { "<a:gs pos=\"\(Int($0.position * 100_000))\">\($0.color.xml)</a:gs>" }
            let shade = gradient.isRadial
                ? "<a:path path=\"circle\"><a:fillToRect l=\"50000\" t=\"50000\" r=\"50000\" b=\"50000\"/></a:path>"
                : "<a:lin ang=\"\(Int(gradient.angle * 60_000))\" scaled=\"0\"/>"
            return "<a:gradFill rotWithShape=\"1\"><a:gsLst>\(stops.joined())</a:gsLst>\(shade)</a:gradFill>"
        }
    }
}

/// The outline of a shape.
struct LineStyle: Equatable, Hashable, Sendable {
    /// `nil` when the line does not say, leaving it to the shape's style.
    var fill: Fill?
    /// EMU; `nil` when the line does not say.
    var width: Int?
    /// A preset dash name, such as `dash` or `sysDot`.
    var dash: String?
    /// Arrowhead types at either end, such as `triangle`.
    var head: String?
    var tail: String?

    init(fill: Fill? = nil, width: Int? = nil, dash: String? = nil, head: String? = nil, tail: String? = nil) {
        self.fill = fill
        self.width = width
        self.dash = dash
        self.head = head
        self.tail = tail
    }

    init(element: XMLElement) {
        fill = Fill.parse(in: element) { _ in nil }
        width = element.attribute("w").flatMap(Int.init)
        dash = element.firstChild(named: "prstDash")?.attribute("val")
        head = element.firstChild(named: "headEnd")?.attribute("type").flatMap { $0 == "none" ? nil : $0 }
        tail = element.firstChild(named: "tailEnd")?.attribute("type").flatMap { $0 == "none" ? nil : $0 }
    }

    /// Values this line leaves unsaid are taken from `base`.
    func merged(over base: LineStyle?) -> LineStyle {
        guard let base else { return self }
        return LineStyle(
            fill: fill ?? base.fill, width: width ?? base.width, dash: dash ?? base.dash,
            head: head ?? base.head, tail: tail ?? base.tail
        )
    }
}

/// A shape's `p:style`: which of the theme's fill, line and font styles it
/// uses, and the colour each is drawn in.
struct StyleReferences: Equatable, Hashable, Sendable {
    struct Reference: Equatable, Hashable, Sendable {
        var index: Int
        var color: DrawingColor?
    }

    var fill: Reference?
    var line: Reference?
    /// The font reference only ever matters for its colour.
    var fontColor: DrawingColor?

    init?(element: XMLElement?) {
        guard let element else { return nil }
        func reference(_ name: String) -> Reference? {
            element.firstChild(named: name).map { child in
                Reference(index: child.attribute("idx").flatMap(Int.init) ?? 0, color: DrawingColor.first(in: child))
            }
        }
        fill = reference("fillRef")
        line = reference("lnRef")
        fontColor = DrawingColor.first(in: element.firstChild(named: "fontRef"))
    }
}

/// A slide, layout or master background.
enum Background: Equatable, Hashable, Sendable {
    case fill(Fill)
    /// One of the theme's background fills, painted in the given colour.
    case reference(index: Int, color: DrawingColor?)

    init?(element: XMLElement?, image: (String) -> String?) {
        guard let element else { return nil }
        if let properties = element.firstChild(named: "bgPr") {
            self = .fill(Fill.parse(in: properties, image: image) ?? .none)
        } else if let reference = element.firstChild(named: "bgRef") {
            self = .reference(
                index: reference.attribute("idx").flatMap(Int.init) ?? 0,
                color: DrawingColor.first(in: reference)
            )
        } else {
            return nil
        }
    }
}
