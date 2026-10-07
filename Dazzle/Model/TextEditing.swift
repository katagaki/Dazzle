import Foundation

/// Formatting part of a shape's text rather than all of it.
///
/// Positions count UTF-16 code units through the text as it is edited:
/// each paragraph's runs in turn, with one more between paragraphs for the
/// line that separates them.
extension TextBody {
    /// The length of the text as edited, paragraph separators included.
    var editingLength: Int {
        paragraphs.map(\.editingLength).reduce(0, +) + max(paragraphs.count - 1, 0)
    }

    /// Where each paragraph starts.
    private var paragraphStarts: [Int] {
        var starts: [Int] = []
        var offset = 0
        for paragraph in paragraphs {
            starts.append(offset)
            offset += paragraph.editingLength + 1
        }
        return starts
    }

    /// The paragraphs `range` touches. An empty range touches the paragraph
    /// the caret is in.
    func paragraphIndices(in range: NSRange) -> [Int] {
        let starts = paragraphStarts
        return paragraphs.indices.filter { index in
            let start = starts[index]
            let end = start + paragraphs[index].editingLength
            if range.length == 0 { return range.location >= start && range.location <= end }
            return range.location <= end && range.location + range.length > start
        }
    }

    mutating func updateParagraphs(in range: NSRange, _ change: (inout ParagraphProperties) -> Void) {
        for index in paragraphIndices(in: range) {
            change(&paragraphs[index].properties)
        }
    }

    /// Applies a change to the runs inside `range`, splitting the runs it
    /// cuts through so that nothing outside it changes. Paragraphs wholly
    /// inside it have their end-of-paragraph properties changed too, so
    /// text typed at their end matches.
    mutating func updateRuns(in range: NSRange, _ change: (inout RunProperties) -> Void) {
        guard range.length > 0 else { return }
        let end = range.location + range.length
        let starts = paragraphStarts
        for index in paragraphs.indices {
            let start = starts[index]
            let length = paragraphs[index].editingLength
            guard range.location <= start + length, end > start else { continue }
            paragraphs[index].split(at: range.location - start)
            paragraphs[index].split(at: end - start)
            var offset = start
            for run in paragraphs[index].runs.indices {
                let runLength = paragraphs[index].runs[run].editingLength
                if offset >= range.location, offset + runLength <= end, runLength > 0 {
                    change(&paragraphs[index].runs[run].properties)
                }
                offset += runLength
            }
            if range.location <= start, end >= start + length {
                var properties = paragraphs[index].endProperties ?? paragraphs[index].runs.last?.properties ?? RunProperties()
                change(&properties)
                paragraphs[index].endProperties = properties
            }
        }
    }

    /// The properties of the text at `offset`: the run the character before
    /// it belongs to, or at a paragraph's start, the first run after it.
    func runProperties(at offset: Int) -> RunProperties? {
        let starts = paragraphStarts
        guard let index = paragraphs.indices.last(where: { starts[$0] <= offset }) else { return nil }
        let paragraph = paragraphs[index]
        var position = starts[index]
        for run in paragraph.runs {
            let next = position + run.editingLength
            if offset > position, offset <= next { return run.properties }
            if offset == position, run.editingLength > 0 { return run.properties }
            position = next
        }
        return paragraph.endProperties ?? paragraph.runs.last?.properties
    }
}

extension Paragraph {
    var editingLength: Int { runs.map(\.editingLength).reduce(0, +) }

    /// Splits the run that `offset` falls inside, so a run boundary lies
    /// there. Fields are kept whole.
    mutating func split(at offset: Int) {
        guard offset > 0 else { return }
        var position = 0
        for index in runs.indices {
            let length = runs[index].editingLength
            if offset > position, offset < position + length, runs[index].kind == .text {
                let text = runs[index].text as NSString
                let cut = offset - position
                var head = runs[index]
                head.text = text.substring(to: cut)
                var tail = runs[index]
                tail.text = text.substring(from: cut)
                runs.replaceSubrange(index...index, with: [head, tail])
                return
            }
            position += length
            if position >= offset { return }
        }
    }
}

extension TextRun {
    var editingLength: Int { (text as NSString).length }
}
