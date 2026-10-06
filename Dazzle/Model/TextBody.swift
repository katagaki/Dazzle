import Foundation

/// The text inside a shape: how it sits in the shape, and its paragraphs.
struct TextBody: Equatable, Hashable, Sendable {
    var properties: BodyProperties
    var listStyle: ListStyle
    var paragraphs: [Paragraph]

    init(properties: BodyProperties = BodyProperties(), listStyle: ListStyle = ListStyle(), paragraphs: [Paragraph]) {
        self.properties = properties
        self.listStyle = listStyle
        self.paragraphs = paragraphs
    }

    /// The text as one string, a line per paragraph — how it is edited.
    var plainText: String {
        paragraphs.map(\.plainText).joined(separator: "\n")
    }

    var isEmpty: Bool { paragraphs.allSatisfy { $0.plainText.isEmpty } }

    /// Replaces the text, keeping the formatting of every paragraph whose
    /// text did not change, and lending new paragraphs the formatting of the
    /// paragraph that was in their place.
    mutating func setPlainText(_ text: String) {
        let lines = text.components(separatedBy: "\n")
        let old = paragraphs
        paragraphs = lines.enumerated().map { index, line in
            if old.indices.contains(index), old[index].plainText == line { return old[index] }
            let template = old.isEmpty ? Paragraph(runs: []) : old[min(index, old.count - 1)]
            return template.replacingText(line)
        }
    }

    /// Applies a change to every run's properties, and to each paragraph's
    /// end-of-paragraph properties so text typed later matches.
    mutating func updateRuns(_ change: (inout RunProperties) -> Void) {
        for paragraphIndex in paragraphs.indices {
            for runIndex in paragraphs[paragraphIndex].runs.indices {
                change(&paragraphs[paragraphIndex].runs[runIndex].properties)
            }
            var end = paragraphs[paragraphIndex].endProperties ?? RunProperties()
            change(&end)
            paragraphs[paragraphIndex].endProperties = end
        }
    }

    mutating func updateParagraphs(_ change: (inout ParagraphProperties) -> Void) {
        for index in paragraphs.indices {
            change(&paragraphs[index].properties)
        }
    }
}

/// `a:bodyPr`: insets, anchoring and fitting.
struct BodyProperties: Equatable, Hashable, Sendable {
    enum Anchor: String, Sendable {
        case top = "t"
        case center = "ctr"
        case bottom = "b"
    }

    enum Autofit: Equatable, Hashable, Sendable {
        case none
        /// Shrink text on overflow, by the scale PowerPoint last worked out.
        case normal(fontScale: Double, lineSpacingReduction: Double)
        /// Grow the shape to fit the text.
        case shape
    }

    var anchor: Anchor?
    var leftInset: Int?
    var topInset: Int?
    var rightInset: Int?
    var bottomInset: Int?
    var wraps: Bool?
    var autofit: Autofit?
    /// `vert`, when the text runs other than horizontally.
    var vertical: String?

    init() {
        // Every property unsaid: inherited.
    }

    init(element: XMLElement?) {
        guard let element else { return }
        anchor = element.attribute("anchor").flatMap(Anchor.init(rawValue:))
        leftInset = element.attribute("lIns").flatMap(Int.init)
        topInset = element.attribute("tIns").flatMap(Int.init)
        rightInset = element.attribute("rIns").flatMap(Int.init)
        bottomInset = element.attribute("bIns").flatMap(Int.init)
        wraps = element.attribute("wrap").map { $0 != "none" }
        vertical = element.attribute("vert").flatMap { $0 == "horz" ? nil : $0 }
        if let normal = element.firstChild(named: "normAutofit") {
            autofit = .normal(
                fontScale: Double(normal.attribute("fontScale").flatMap(Int.init) ?? 100_000) / 100_000,
                lineSpacingReduction: Double(normal.attribute("lnSpcReduction").flatMap(Int.init) ?? 0) / 100_000
            )
        } else if element.firstChild(named: "spAutoFit") != nil {
            autofit = .shape
        } else if element.firstChild(named: "noAutofit") != nil {
            autofit = Autofit.none
        }
    }

    /// Values left unsaid here are taken from `base`.
    func merged(over base: BodyProperties) -> BodyProperties {
        var result = self
        result.anchor = anchor ?? base.anchor
        result.leftInset = leftInset ?? base.leftInset
        result.topInset = topInset ?? base.topInset
        result.rightInset = rightInset ?? base.rightInset
        result.bottomInset = bottomInset ?? base.bottomInset
        result.wraps = wraps ?? base.wraps
        result.autofit = autofit ?? base.autofit
        result.vertical = vertical ?? base.vertical
        return result
    }
}

/// A paragraph of runs.
struct Paragraph: Equatable, Hashable, Sendable {
    var properties: ParagraphProperties
    var runs: [TextRun]
    /// `a:endParaRPr`: what an empty paragraph, or text typed at its end, looks like.
    var endProperties: RunProperties?
    /// The paragraph's `a:pPr` as the file wrote it, so what Dazzle does not
    /// model survives being written back.
    var sourceProperties: String?
    var sourceEndProperties: String?

    init(
        properties: ParagraphProperties = ParagraphProperties(), runs: [TextRun],
        endProperties: RunProperties? = nil
    ) {
        self.properties = properties
        self.runs = runs
        self.endProperties = endProperties
    }

    var plainText: String { runs.map(\.text).joined() }

    /// This paragraph's formatting holding different text, in the formatting
    /// of its first run.
    func replacingText(_ text: String) -> Paragraph {
        var paragraph = self
        let first = runs.first { $0.kind == .text }
        var run = first ?? TextRun(text: "", properties: endProperties ?? RunProperties())
        run.kind = .text
        run.text = text
        if first == nil { run.sourceProperties = sourceEndProperties }
        paragraph.runs = text.isEmpty ? [] : [run]
        if paragraph.endProperties == nil { paragraph.endProperties = run.properties }
        return paragraph
    }
}

/// A run of text sharing one set of properties.
struct TextRun: Equatable, Hashable, Sendable {
    enum Kind: Equatable, Hashable, Sendable {
        case text
        /// `a:br`: a line break within the paragraph.
        case lineBreak
        /// `a:fld`: text PowerPoint fills in, such as the slide number.
        case field(type: String)
    }

    var kind: Kind = .text
    var text: String
    var properties: RunProperties
    /// The run's `a:rPr` as the file wrote it.
    var sourceProperties: String?
    /// A field's `id`, which PowerPoint wants kept.
    var fieldID: String?

    init(kind: Kind = .text, text: String, properties: RunProperties = RunProperties()) {
        self.kind = kind
        self.text = text
        self.properties = properties
    }
}

enum ParagraphAlignment: String, CaseIterable, Sendable {
    case left = "l"
    case center = "ctr"
    case right = "r"
    case justified = "just"

    init?(attribute: String?) {
        guard let attribute else { return nil }
        switch attribute {
        case "dist", "justLow", "thaiDist": self = .justified
        default: self.init(rawValue: attribute)
        }
    }

    var symbolName: String {
        switch self {
        case .left: "text.alignleft"
        case .center: "text.aligncenter"
        case .right: "text.alignright"
        case .justified: "text.justify"
        }
    }
}

/// A paragraph's bullet.
enum Bullet: Equatable, Hashable, Sendable {
    case none
    case character(String)
    case autoNumber(scheme: String, startAt: Int)
}

/// Line or paragraph spacing.
enum Spacing: Equatable, Hashable, Sendable {
    /// A multiple of single spacing, 1 being single.
    case percent(Double)
    case points(Double)

    init?(element: XMLElement?) {
        guard let element else { return nil }
        if let percent = element.firstChild(named: "spcPct")?.attribute("val").flatMap(Int.init) {
            self = .percent(Double(percent) / 100_000)
        } else if let points = element.firstChild(named: "spcPts")?.attribute("val").flatMap(Int.init) {
            self = .points(Double(points) / 100)
        } else {
            return nil
        }
    }
}

/// Paragraph properties, as `a:pPr` or a list style level gives them. Every
/// property is optional, because unsaid means inherited.
struct ParagraphProperties: Equatable, Hashable, Sendable {
    var level: Int?
    var alignment: ParagraphAlignment?
    /// EMU.
    var marginLeft: Int?
    /// EMU; negative for a hanging indent.
    var indent: Int?
    var bullet: Bullet?
    var bulletColor: DrawingColor?
    /// A fraction of the text size.
    var bulletSize: Double?
    var bulletFont: String?
    var lineSpacing: Spacing?
    var spaceBefore: Spacing?
    var spaceAfter: Spacing?
    var defaultRun = RunProperties()

    init() {
        // Every property unsaid: inherited.
    }

    init(element: XMLElement?) {
        guard let element else { return }
        level = element.attribute("lvl").flatMap(Int.init)
        alignment = ParagraphAlignment(attribute: element.attribute("algn"))
        marginLeft = element.attribute("marL").flatMap(Int.init)
        indent = element.attribute("indent").flatMap(Int.init)
        lineSpacing = Spacing(element: element.firstChild(named: "lnSpc"))
        spaceBefore = Spacing(element: element.firstChild(named: "spcBef"))
        spaceAfter = Spacing(element: element.firstChild(named: "spcAft"))
        if element.firstChild(named: "buNone") != nil {
            bullet = Bullet.none
        } else if let character = element.firstChild(named: "buChar")?.attribute("char") {
            bullet = .character(character)
        } else if let number = element.firstChild(named: "buAutoNum") {
            bullet = .autoNumber(
                scheme: number.attribute("type") ?? "arabicPeriod",
                startAt: number.attribute("startAt").flatMap(Int.init) ?? 1
            )
        }
        bulletColor = DrawingColor.first(in: element.firstChild(named: "buClr"))
        bulletSize = element.firstChild(named: "buSzPct")?.attribute("val").flatMap(Int.init).map { Double($0) / 100_000 }
        bulletFont = element.firstChild(named: "buFont")?.attribute("typeface")
        defaultRun = RunProperties(element: element.firstChild(named: "defRPr"))
    }

    /// Values left unsaid here are taken from `base`.
    func merged(over base: ParagraphProperties) -> ParagraphProperties {
        var result = self
        result.level = level ?? base.level
        result.alignment = alignment ?? base.alignment
        result.marginLeft = marginLeft ?? base.marginLeft
        result.indent = indent ?? base.indent
        result.bullet = bullet ?? base.bullet
        result.bulletColor = bulletColor ?? base.bulletColor
        result.bulletSize = bulletSize ?? base.bulletSize
        result.bulletFont = bulletFont ?? base.bulletFont
        result.lineSpacing = lineSpacing ?? base.lineSpacing
        result.spaceBefore = spaceBefore ?? base.spaceBefore
        result.spaceAfter = spaceAfter ?? base.spaceAfter
        result.defaultRun = defaultRun.merged(over: base.defaultRun)
        return result
    }
}

/// Character properties, as `a:rPr` and its relatives give them.
struct RunProperties: Equatable, Hashable, Sendable {
    /// Hundredths of a point.
    var size: Int?
    var isBold: Bool?
    var isItalic: Bool?
    var isUnderlined: Bool?
    var isStruckThrough: Bool?
    var color: DrawingColor?
    /// A typeface name, or a theme font such as `+mn-lt`.
    var latinFont: String?
    var eastAsianFont: String?
    /// Thousandths of a percent; positive for superscript.
    var baseline: Int?
    /// `all` or `small` capitals.
    var capitalization: String?

    init() {
        // Every property unsaid: inherited.
    }

    init(element: XMLElement?) {
        guard let element else { return }
        func flag(_ key: String) -> Bool? {
            element.attribute(key).map { $0 == "1" || $0 == "true" }
        }
        size = element.attribute("sz").flatMap(Int.init)
        isBold = flag("b")
        isItalic = flag("i")
        isUnderlined = element.attribute("u").map { $0 != "none" }
        isStruckThrough = element.attribute("strike").map { $0 != "noStrike" }
        baseline = element.attribute("baseline").flatMap(Int.init)
        capitalization = element.attribute("cap").flatMap { $0 == "none" ? nil : $0 }
        if let fill = element.firstChild(named: "solidFill") {
            color = DrawingColor.first(in: fill)
        } else if let gradient = element.firstChild(named: "gradFill") {
            // Gradient text is drawn in its first colour.
            color = DrawingColor.first(in: gradient.firstChild(named: "gsLst")?.firstChild(named: "gs"))
        }
        latinFont = element.firstChild(named: "latin")?.attribute("typeface")
        eastAsianFont = element.firstChild(named: "ea")?.attribute("typeface")
    }

    /// Values left unsaid here are taken from `base`.
    func merged(over base: RunProperties) -> RunProperties {
        var result = self
        result.size = size ?? base.size
        result.isBold = isBold ?? base.isBold
        result.isItalic = isItalic ?? base.isItalic
        result.isUnderlined = isUnderlined ?? base.isUnderlined
        result.isStruckThrough = isStruckThrough ?? base.isStruckThrough
        result.color = color ?? base.color
        result.latinFont = latinFont ?? base.latinFont
        result.eastAsianFont = eastAsianFont ?? base.eastAsianFont
        result.baseline = baseline ?? base.baseline
        result.capitalization = capitalization ?? base.capitalization
        return result
    }
}

/// `a:lstStyle` and the master's text styles: paragraph properties per
/// outline level, 1 through 9.
struct ListStyle: Equatable, Hashable, Sendable {
    var levels: [Int: ParagraphProperties] = [:]

    init() {
        // No levels: everything inherited.
    }

    init(element: XMLElement?) {
        guard let element else { return }
        for level in 1...9 {
            if let properties = element.firstChild(named: "lvl\(level)pPr") {
                levels[level] = ParagraphProperties(element: properties)
            }
        }
        // `defPPr` applies beneath every level.
        if let defaults = element.firstChild(named: "defPPr") {
            let base = ParagraphProperties(element: defaults)
            for level in 1...9 {
                levels[level] = (levels[level] ?? ParagraphProperties()).merged(over: base)
            }
        }
    }

    /// The properties at a zero-based outline level.
    func level(_ index: Int) -> ParagraphProperties {
        levels[min(max(index, 0), 8) + 1] ?? ParagraphProperties()
    }

    /// Each level's values left unsaid here are taken from `base`.
    func merged(over base: ListStyle) -> ListStyle {
        var result = ListStyle()
        for level in Set(levels.keys).union(base.levels.keys) {
            result.levels[level] = (levels[level] ?? ParagraphProperties())
                .merged(over: base.levels[level] ?? ParagraphProperties())
        }
        return result
    }
}
