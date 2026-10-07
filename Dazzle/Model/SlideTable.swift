import Foundation

/// A DrawingML table, as much of it as Dazzle draws.
struct SlideTable: Equatable, Hashable, Sendable {
    struct Cell: Equatable, Hashable, Sendable {
        var text: TextBody?
        var fill: Fill?
        var columnSpan = 1
        var rowSpan = 1
        /// `hMerge`: covered by the span of the cell to its left.
        var isHorizontalMerge = false
        /// `vMerge`: covered by the span of the cell above.
        var isVerticalMerge = false
        /// Covered by a neighbour's span, so not drawn on its own.
        var isMerged: Bool { isHorizontalMerge || isVerticalMerge }
        var anchor: BodyProperties.Anchor?
        /// EMU; `nil` where the cell does not say.
        var marginLeft: Int?
        var marginRight: Int?
        var marginTop: Int?
        var marginBottom: Int?
        /// Borders the cell states itself.
        var borderLeft: LineStyle?
        var borderRight: LineStyle?
        var borderTop: LineStyle?
        var borderBottom: LineStyle?
        /// The cell's `a:tcPr` and `a:txBody` as the file wrote them, so
        /// what Dazzle does not model survives a rewrite.
        var sourceProperties: String?
        var sourceBody: String?
    }

    struct Row: Equatable, Hashable, Sendable {
        /// EMU.
        var height: Int
        var cells: [Cell]
    }

    /// EMU.
    var columnWidths: [Int]
    var rows: [Row]
    /// Whether the first row and the bands get the table style's emphasis.
    var hasHeaderRow: Bool
    var hasBandedRows: Bool
    /// `a:tableStyleId`; a table without one has no style at all.
    var styleID: String?
    /// `a:tblPr` as the file wrote it.
    var sourceProperties: String?
}

/// The parts of a table style Dazzle draws: fills, text colour and weight,
/// and borders, for the whole table, its banded rows and its header row.
struct TableStyle: Equatable, Hashable, Sendable {
    struct Part: Equatable, Hashable, Sendable {
        var fill: Fill?
        var textColor: DrawingColor?
        var isBold: Bool?
        /// By edge: `left`, `right`, `top`, `bottom`, and `insideH`/`insideV`
        /// for the lines between cells.
        var borders: [String: LineStyle] = [:]
    }

    var whole = Part()
    var bandedRow = Part()
    var headerRow = Part()

    init() {
        // An empty style: nothing filled.
    }

    init(element: XMLElement) {
        whole = Self.part(element.firstChild(named: "wholeTbl"))
        bandedRow = Self.part(element.firstChild(named: "band1H"))
        headerRow = Self.part(element.firstChild(named: "firstRow"))
    }

    private static func part(_ element: XMLElement?) -> Part {
        guard let element else { return Part() }
        let cell = element.firstChild(named: "tcStyle")
        let text = element.firstChild(named: "tcTxStyle")
        var part = Part()
        // A colour of the text style's own outranks its font reference's.
        part.textColor = DrawingColor.first(in: text) ?? DrawingColor.first(in: text?.firstChild(named: "fontRef"))
        part.isBold = text?.attribute("b").map { $0 == "on" }
        if let fill = Fill.parse(in: cell?.firstChild(named: "fill"), image: { _ in nil }) {
            part.fill = fill
        } else if let reference = cell?.firstChild(named: "fillRef"),
                  (reference.attribute("idx").flatMap(Int.init) ?? 0) > 0,
                  let color = DrawingColor.first(in: reference) {
            // A theme fill reference: drawn in its colour.
            part.fill = .solid(color)
        }
        for edge in cell?.firstChild(named: "tcBdr")?.children ?? [] {
            if let line = edge.firstChild(named: "ln") {
                part.borders[edge.name] = LineStyle(element: line)
            } else if let reference = edge.firstChild(named: "lnRef"), let color = DrawingColor.first(in: reference) {
                part.borders[edge.name] = LineStyle(fill: .solid(color), width: 12_700)
            }
        }
        return part
    }
}
