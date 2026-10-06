import Foundation

/// A DrawingML table, as much of it as Dazzle draws.
struct SlideTable: Equatable, Hashable, Sendable {
    struct Cell: Equatable, Hashable, Sendable {
        var text: TextBody?
        var fill: Fill?
        var columnSpan = 1
        var rowSpan = 1
        /// Covered by a neighbour's span, so not drawn on its own.
        var isMerged = false
        var anchor: BodyProperties.Anchor?
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
}
