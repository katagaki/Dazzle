import Foundation

/// A cell's place in a table.
struct TableCellPosition: Equatable, Hashable, Sendable {
    var row: Int
    var column: Int
}

/// Adding and removing rows and columns, keeping merged cells whole.
///
/// A merge is one anchor cell, which says how many rows and columns it
/// spans, and the cells it covers, which say only that they are covered.
/// Inserting inside a merge widens it; deleting through one narrows it, or
/// if the anchor goes, hands the anchor's content on to the cell after it.
extension SlideTable {
    var columnCount: Int { columnWidths.count }

    func cell(at position: TableCellPosition) -> Cell? {
        guard rows.indices.contains(position.row), rows[position.row].cells.indices.contains(position.column) else { return nil }
        return rows[position.row].cells[position.column]
    }

    /// The cell whose merge covers `position`, or `position` itself.
    func anchor(of position: TableCellPosition) -> TableCellPosition {
        var row = position.row
        var column = position.column
        while row > 0, cell(at: TableCellPosition(row: row, column: column))?.isVerticalMerge == true { row -= 1 }
        while column > 0, cell(at: TableCellPosition(row: row, column: column))?.isHorizontalMerge == true { column -= 1 }
        return TableCellPosition(row: row, column: column)
    }

    /// An empty cell formatted as `template` is.
    private static func blank(like template: Cell) -> Cell {
        var cell = template
        cell.columnSpan = 1
        cell.rowSpan = 1
        cell.isHorizontalMerge = false
        cell.isVerticalMerge = false
        if var body = template.text {
            let first = body.paragraphs.first ?? Paragraph(runs: [])
            var empty = Paragraph(properties: first.properties, runs: [], endProperties: first.runs.first?.properties ?? first.endProperties)
            empty.sourceProperties = first.sourceProperties
            empty.sourceEndProperties = first.sourceEndProperties ?? first.runs.first?.sourceProperties
            body.paragraphs = [empty]
            cell.text = body
        }
        return cell
    }

    // MARK: - Rows

    /// Adds a row at `index`, formatted as the row at `template`.
    mutating func insertRow(at index: Int, copying template: Int) {
        guard rows.indices.contains(template) else { return }
        let index = min(max(index, 0), rows.count)
        var row = Row(height: rows[template].height, cells: rows[template].cells.map(Self.blank(like:)))
        for column in row.cells.indices {
            // Inside a vertical merge, the new cell joins it.
            guard index > 0, index < rows.count, rows[index].cells.indices.contains(column),
                  rows[index].cells[column].isVerticalMerge else { continue }
            let anchor = anchor(of: TableCellPosition(row: index, column: column))
            row.cells[column].isVerticalMerge = true
            row.cells[column].isHorizontalMerge = column != anchor.column
            if column == anchor.column { rows[anchor.row].cells[anchor.column].rowSpan += 1 }
        }
        rows.insert(row, at: index)
    }

    mutating func deleteRow(at index: Int) {
        guard rows.count > 1, rows.indices.contains(index) else { return }
        for column in rows[index].cells.indices {
            let cell = rows[index].cells[column]
            if cell.isVerticalMerge {
                let anchor = anchor(of: TableCellPosition(row: index, column: column))
                if column == anchor.column { rows[anchor.row].cells[anchor.column].rowSpan -= 1 }
            } else if index + 1 < rows.count, rows[index + 1].cells.indices.contains(column),
                      rows[index + 1].cells[column].isVerticalMerge {
                // The merge's first row goes; the row below becomes its first,
                // the anchor's content and the rest of its span going with it.
                if cell.rowSpan > 1 {
                    var heir = cell
                    heir.rowSpan = cell.rowSpan - 1
                    rows[index + 1].cells[column] = heir
                } else {
                    rows[index + 1].cells[column].isVerticalMerge = false
                }
            }
        }
        rows.remove(at: index)
    }

    // MARK: - Columns

    /// Adds a column at `index`, formatted and as wide as the column at `template`.
    mutating func insertColumn(at index: Int, copying template: Int) {
        guard columnWidths.indices.contains(template) else { return }
        let index = min(max(index, 0), columnWidths.count)
        columnWidths.insert(columnWidths[template], at: index)
        for row in rows.indices {
            guard rows[row].cells.indices.contains(template) else { continue }
            var cell = Self.blank(like: rows[row].cells[template])
            if index > 0, index < rows[row].cells.count, rows[row].cells[index].isHorizontalMerge {
                let anchor = anchor(of: TableCellPosition(row: row, column: index))
                cell.isHorizontalMerge = true
                cell.isVerticalMerge = row != anchor.row
                if row == anchor.row { rows[anchor.row].cells[anchor.column].columnSpan += 1 }
            }
            rows[row].cells.insert(cell, at: min(index, rows[row].cells.count))
        }
    }

    mutating func deleteColumn(at index: Int) {
        guard columnWidths.count > 1, columnWidths.indices.contains(index) else { return }
        for row in rows.indices where rows[row].cells.indices.contains(index) {
            let cell = rows[row].cells[index]
            if cell.isHorizontalMerge {
                let anchor = anchor(of: TableCellPosition(row: row, column: index))
                if row == anchor.row { rows[anchor.row].cells[anchor.column].columnSpan -= 1 }
            } else if index + 1 < rows[row].cells.count, rows[row].cells[index + 1].isHorizontalMerge {
                if cell.columnSpan > 1 {
                    var heir = cell
                    heir.columnSpan = cell.columnSpan - 1
                    rows[row].cells[index + 1] = heir
                } else {
                    rows[row].cells[index + 1].isHorizontalMerge = false
                }
            }
        }
        columnWidths.remove(at: index)
        for row in rows.indices where rows[row].cells.indices.contains(index) {
            rows[row].cells.remove(at: index)
        }
    }

    // MARK: - Size

    /// The table's natural size, from its columns and rows, in EMU.
    var gridSize: (width: Int, height: Int) {
        (columnWidths.reduce(0, +), rows.map(\.height).reduce(0, +))
    }

    /// Columns and rows stretched to a new overall size, in EMU.
    mutating func scale(toWidth width: Int, height: Int) {
        let size = gridSize
        if size.width > 0, width > 0 {
            let factor = Double(width) / Double(size.width)
            columnWidths = columnWidths.map { Int((Double($0) * factor).rounded()) }
        }
        if size.height > 0, height > 0 {
            let factor = Double(height) / Double(size.height)
            for index in rows.indices { rows[index].height = Int((Double(rows[index].height) * factor).rounded()) }
        }
    }

    /// A new table of empty cells, `columns` wide and `rows` deep, filling `width` by `height` EMU.
    static func empty(rows rowCount: Int, columns: Int, width: Int, height: Int) -> SlideTable {
        let cell = Cell(text: TextBody(paragraphs: [Paragraph(runs: [])]))
        let rowHeight = height / max(rowCount, 1)
        return SlideTable(
            columnWidths: Array(repeating: width / max(columns, 1), count: columns),
            rows: Array(repeating: Row(height: rowHeight, cells: Array(repeating: cell, count: columns)), count: rowCount),
            hasHeaderRow: true, hasBandedRows: true,
            // Medium Style 2, Accent 1: what PowerPoint gives a new table.
            styleID: "{5C22544A-7EE6-4342-B048-85BDC9FD1C3A}"
        )
    }
}
