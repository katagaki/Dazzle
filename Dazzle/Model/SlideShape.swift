import Foundation

/// Something on a slide: a shape, a picture, a group, a table, or an object
/// Dazzle keeps but cannot draw.
struct SlideShape: Identifiable, Equatable, Hashable, Sendable {
    /// What Dazzle has changed about a shape read from a file. Only these
    /// parts of its XML are rewritten; everything else is written back as read.
    enum Edit: Hashable, Sendable {
        case transform
        case fill
        case line
        case text
        /// A copy, which needs ids of its own.
        case identity
        /// No longer a placeholder: pasted where its layout has no place for it.
        case placeholder
        /// A table's rows, columns or cells.
        case table
        /// A picture's image or its crop.
        case picture
        /// The description read out in place of the shape.
        case altText
        /// Its shadow.
        case effects
        /// Where clicking it goes.
        case link
    }

    enum Kind: Equatable, Hashable, Sendable {
        case shape
        case connector
        case picture(Picture)
        case group(ShapeGroup)
        case table(SlideTable)
        /// A chart, or `nil` for one Dazzle cannot read.
        case chart(Chart?)
        /// SmartArt, drawn from the shapes PowerPoint saved alongside it.
        case diagram([SlideShape])
        /// Anything else: an embedded object, ink, a 3D model.
        case unsupported(String)
    }

    struct Picture: Equatable, Hashable, Sendable {
        /// Where the whole image lies when `frame` shows the cropped part, in points.
        static func imageRect(frame: CGRect, picture: Picture) -> CGRect {
            let visibleWidth = 1 - picture.cropLeft - picture.cropRight
            let visibleHeight = 1 - picture.cropTop - picture.cropBottom
            guard visibleWidth > 0.001, visibleHeight > 0.001 else { return frame }
            let width = frame.width / visibleWidth
            let height = frame.height / visibleHeight
            return CGRect(x: frame.minX - width * picture.cropLeft, y: frame.minY - height * picture.cropTop, width: width, height: height)
        }

        /// The image's path inside the package; `nil` for a linked image.
        var imagePath: String?
        /// Fractions of the image cut from each edge.
        var cropLeft = 0.0
        var cropTop = 0.0
        var cropRight = 0.0
        var cropBottom = 0.0
        var effects = BlipEffects()
        /// The video or sound the picture stands for, if it is one.
        var media: Media?
    }

    /// A video or sound, shown as a picture until it plays.
    struct Media: Equatable, Hashable, Sendable {
        enum Kind: Equatable, Hashable, Sendable {
            case video
            case audio
        }

        var kind: Kind
        /// The media's path inside the package; `nil` for a linked file.
        var path: String?
        /// Where a linked file is, outside the package.
        var url: String?
        /// Whether it starts as its slide does, rather than when tapped.
        var playsAutomatically = false
    }

    struct ShapeGroup: Equatable, Hashable, Sendable {
        /// The space the children's coordinates are in, which the group maps
        /// onto its own frame.
        var childFrame: EMURect
        var children: [SlideShape]
    }

    let id: UUID
    /// `cNvPr id`: unique within a slide, and what animations refer to.
    var shapeID: Int
    var name: String
    var kind: Kind
    /// Where the shape sits. For a placeholder that does not say, this is
    /// where its layout puts it.
    var frame: EMURect
    /// Whether the file gives the frame, rather than the layout.
    var hasOwnFrame: Bool
    /// Degrees clockwise.
    var rotation: Double = 0
    var flipsHorizontally = false
    var flipsVertically = false
    var placeholder: Placeholder?
    var geometry: ShapeGeometry = .preset("rect", adjustments: [:])
    var fill: Fill?
    var line: LineStyle?
    /// A shadow the shape's own properties cast.
    var shadow: Shadow?
    var style: StyleReferences?
    var text: TextBody?
    /// For SmartArt shapes, where the text goes when it is not the whole shape.
    var textFrame: EMURect?
    var isTextBox = false
    /// `descr`: what the shape shows, for people who cannot see it.
    var altText: String?
    /// Where clicking the shape goes, in a slideshow.
    var link: Hyperlink?
    /// Read from XML Dazzle can show but not safely rewrite, such as a shape
    /// offered in two forms for different versions of PowerPoint. It can be
    /// deleted, but not changed.
    var isLocked = false
    /// The shape's XML as read, or `nil` for one Dazzle made.
    var source: String?
    var edits: Set<Edit> = []

    init(
        id: UUID = UUID(), shapeID: Int, name: String, kind: Kind, frame: EMURect, hasOwnFrame: Bool = true
    ) {
        self.id = id
        self.shapeID = shapeID
        self.name = name
        self.kind = kind
        self.frame = frame
        self.hasOwnFrame = hasOwnFrame
    }

    /// Whether Dazzle can move, resize and restyle it without risk of
    /// writing back something PowerPoint would reject.
    var isEditable: Bool {
        guard !isLocked else { return false }
        return switch kind {
        case .shape, .connector, .picture, .group, .table, .chart, .diagram: true
        case .unsupported: false
        }
    }

    /// Whether it can be turned and flipped. PowerPoint keeps tables, charts
    /// and other graphic frames square to the slide.
    var canRotate: Bool {
        guard isEditable else { return false }
        return switch kind {
        case .shape, .connector, .picture, .group: true
        case .table, .chart, .diagram, .unsupported: false
        }
    }

    /// Degrees brought into 0..<360.
    static func normalized(_ degrees: Double) -> Double {
        let turned = degrees.truncatingRemainder(dividingBy: 360)
        return turned < 0 ? turned + 360 : turned
    }

    var canHoldText: Bool {
        switch kind {
        case .shape: true
        default: false
        }
    }

    var isPicture: Bool {
        if case .picture = kind { return true }
        return false
    }

    /// Every shape inside this one, depth first, including itself.
    var flattened: [SlideShape] {
        switch kind {
        case .group(let group): [self] + group.children.flatMap(\.flattened)
        case .diagram(let children): [self] + children.flatMap(\.flattened)
        default: [self]
        }
    }
}

/// `p:ph`: which of the layout's placeholders a shape stands in for.
struct Placeholder: Equatable, Hashable, Sendable {
    /// `title`, `body`, `ctrTitle`, `subTitle`, `dt`, `ftr`, `sldNum`, `pic`…
    /// `nil` means `obj`, the generic content placeholder.
    var type: String?
    var index: Int?

    init(type: String?, index: Int?) {
        self.type = type
        self.index = index
    }

    init?(element: XMLElement?) {
        guard let element else { return nil }
        type = element.attribute("type")
        index = element.attribute("idx").flatMap(Int.init)
    }

    var isTitle: Bool { type == "title" || type == "ctrTitle" }

    /// Placeholders that only ever hold furniture PowerPoint fills in.
    var isFurniture: Bool { ["dt", "ftr", "sldNum", "hdr"].contains(type ?? "") }

    /// Which of the master's text styles governs it.
    var textStyleCategory: TextStyleCategory {
        switch type {
        case "title", "ctrTitle": .title
        case nil, "body", "subTitle", "obj", "tbl", "chart", "dgm", "media", "clipArt", "pic": .body
        default: .other
        }
    }

    /// Whether `other`, a layout or master placeholder, is the one this inherits from.
    func matches(_ other: Placeholder, byIndex: Bool) -> Bool {
        if byIndex {
            guard let index, let otherIndex = other.index else { return false }
            return index == otherIndex
        }
        return Self.family(type) == Self.family(other.type)
    }

    /// Types the master treats as one kind of placeholder.
    private static func family(_ type: String?) -> String {
        switch type {
        case "title", "ctrTitle": "title"
        case nil, "body", "subTitle", "obj": "body"
        default: type ?? "body"
        }
    }
}

enum TextStyleCategory: Sendable {
    case title
    case body
    case other
}

/// The outline a shape is drawn with.
enum ShapeGeometry: Equatable, Hashable, Sendable {
    /// One of DrawingML's preset shapes, by name, with its adjust values.
    case preset(String, adjustments: [String: Int])
    /// A freeform outline, as paths in their own coordinate spaces.
    case custom([CustomPath])

    struct CustomPath: Equatable, Hashable, Sendable {
        enum Command: Equatable, Hashable, Sendable {
            case move(Double, Double)
            case line(Double, Double)
            case cubic(Double, Double, Double, Double, Double, Double)
            case quadratic(Double, Double, Double, Double)
            case arc(widthRadius: Double, heightRadius: Double, start: Double, sweep: Double)
            case close
        }

        var width: Double
        var height: Double
        var isFilled: Bool
        var isStroked: Bool
        var commands: [Command]
    }

    var presetName: String? {
        if case .preset(let name, _) = self { return name }
        return nil
    }

    var adjustments: [String: Int] {
        if case .preset(_, let adjustments) = self { return adjustments }
        return [:]
    }
}
