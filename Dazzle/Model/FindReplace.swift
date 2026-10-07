import Foundation

/// Finding text across a presentation, and replacing it while keeping the
/// formatting of the text it replaces.
struct FindQuery: Equatable, Sendable {
    var text: String
    var matchesCase = false
    var matchesWholeWords = false

    /// Where `text` occurs in `string`, as UTF-16 ranges.
    func ranges(in string: String) -> [NSRange] {
        guard !text.isEmpty else { return [] }
        let haystack = string as NSString
        var options: NSString.CompareOptions = []
        if !matchesCase { options.insert(.caseInsensitive) }
        var result: [NSRange] = []
        var location = 0
        while location < haystack.length {
            let found = haystack.range(of: text, options: options, range: NSRange(location: location, length: haystack.length - location))
            guard found.location != NSNotFound else { break }
            if !matchesWholeWords || Self.isWholeWord(found, in: haystack) { result.append(found) }
            location = found.location + max(found.length, 1)
        }
        return result
    }

    private static func isWholeWord(_ range: NSRange, in string: NSString) -> Bool {
        func isWordCharacter(at index: Int) -> Bool {
            guard index >= 0, index < string.length,
                  let scalar = UnicodeScalar(string.character(at: index)) else { return false }
            return CharacterSet.alphanumerics.contains(scalar)
        }
        return !isWordCharacter(at: range.location - 1) && !isWordCharacter(at: range.location + range.length)
    }
}

/// One place the query was found.
struct FindMatch: Identifiable, Equatable, Sendable {
    enum Place: Equatable, Hashable, Sendable {
        case shape(SlideShape.ID)
        case cell(SlideShape.ID, TableCellPosition)
        case notes
    }

    var slideID: Slide.ID
    var place: Place
    /// In the text's editing offsets: paragraphs joined by line breaks.
    var range: NSRange
    /// The match with a little of the text round it.
    var excerpt: String
    /// Where the match starts in `excerpt`.
    var excerptRange: NSRange

    var id: String { "\(slideID)|\(place)|\(range.location)" }
}

extension TextBody {
    /// The text as matched against: paragraphs joined by line breaks, the
    /// same offsets formatting by range uses.
    var searchableText: String { paragraphs.map(\.plainText).joined(separator: "\n") }

    /// Replaces the text in `range`, which lies within one paragraph, with
    /// `replacement` in the formatting of the text's first character.
    mutating func replace(_ range: NSRange, with replacement: String) {
        var offset = 0
        for index in paragraphs.indices {
            let length = paragraphs[index].editingLength
            defer { offset += length + 1 }
            guard range.location >= offset, range.location + range.length <= offset + length else { continue }
            let start = range.location - offset
            paragraphs[index].split(at: start)
            paragraphs[index].split(at: start + range.length)
            var position = 0
            var kept: [TextRun] = []
            var inserted = false
            for run in paragraphs[index].runs {
                let runLength = run.editingLength
                defer { position += runLength }
                guard position >= start, position + runLength <= start + range.length, runLength > 0 else {
                    kept.append(run)
                    continue
                }
                if !inserted {
                    var replaced = run
                    replaced.kind = .text
                    replaced.text = replacement
                    replaced.fieldID = nil
                    if !replacement.isEmpty { kept.append(replaced) }
                    inserted = true
                }
            }
            paragraphs[index].runs = kept
            return
        }
    }
}

extension Presentation {
    /// Every match, slide by slide: shapes in stacking order, then table
    /// cells, then the speaker notes.
    func matches(for query: FindQuery) -> [FindMatch] {
        var matches: [FindMatch] = []
        for slide in slides {
            func add(_ text: String, place: FindMatch.Place) {
                for range in query.ranges(in: text) {
                    let (excerpt, excerptRange) = Self.excerpt(of: text, around: range)
                    matches.append(FindMatch(slideID: slide.id, place: place, range: range, excerpt: excerpt, excerptRange: excerptRange))
                }
            }
            for shape in slide.shapes where shape.isEditable {
                if let text = shape.text { add(text.searchableText, place: .shape(shape.id)) }
                if case .table(let table) = shape.kind {
                    for (row, cells) in table.rows.enumerated() {
                        for (column, cell) in cells.cells.enumerated() where !cell.isMerged {
                            if let text = cell.text {
                                add(text.searchableText, place: .cell(shape.id, TableCellPosition(row: row, column: column)))
                            }
                        }
                    }
                }
            }
            add(slide.notes, place: .notes)
        }
        return matches
    }

    /// Replaces each of `matches` with `replacement`, as one change.
    mutating func replace(_ matches: [FindMatch], with replacement: String) {
        // From the end of each text backwards, so earlier offsets stay true.
        for match in matches.sorted(by: { $0.range.location > $1.range.location }) {
            guard let slideIndex = index(of: match.slideID) else { continue }
            switch match.place {
            case .notes:
                let notes = slides[slideIndex].notes as NSString
                guard match.range.location + match.range.length <= notes.length else { continue }
                slides[slideIndex].notes = notes.replacingCharacters(in: match.range, with: replacement)
                slides[slideIndex].areNotesModified = true
            case .shape(let id):
                guard slides[slideIndex].canEditShapes,
                      let shapeIndex = slides[slideIndex].shapes.firstIndex(where: { $0.id == id }) else { continue }
                slides[slideIndex].shapes[shapeIndex].text?.replace(match.range, with: replacement)
                slides[slideIndex].shapes[shapeIndex].edits.insert(.text)
                slides[slideIndex].isModified = true
            case .cell(let id, let position):
                guard slides[slideIndex].canEditShapes,
                      let shapeIndex = slides[slideIndex].shapes.firstIndex(where: { $0.id == id }),
                      case .table(var table) = slides[slideIndex].shapes[shapeIndex].kind,
                      table.cell(at: position) != nil else { continue }
                table.rows[position.row].cells[position.column].text?.replace(match.range, with: replacement)
                slides[slideIndex].shapes[shapeIndex].kind = .table(table)
                slides[slideIndex].shapes[shapeIndex].edits.insert(.table)
                slides[slideIndex].isModified = true
            }
        }
    }

    private static func excerpt(of text: String, around range: NSRange) -> (String, NSRange) {
        let string = text as NSString
        let start = max(range.location - 24, 0)
        let end = min(range.location + range.length + 40, string.length)
        var excerpt = string.substring(with: NSRange(location: start, length: end - start))
            .replacingOccurrences(of: "\n", with: " ")
        var offset = range.location - start
        if start > 0 {
            excerpt = "…" + excerpt
            offset += 1
        }
        if end < string.length { excerpt += "…" }
        return (excerpt, NSRange(location: offset, length: range.length))
    }
}
