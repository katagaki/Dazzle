import SwiftUI

/// The bottom-sheet panels the editor can raise.
enum EditorPanel: String, Identifiable, Hashable {
    case text
    case format
    case notes
    case export

    var id: String { rawValue }

    var title: String {
        switch self {
        case .text: String(localized: "Panel.Text.Title")
        case .format: String(localized: "Panel.Format.Title")
        case .notes: String(localized: "Panel.Notes.Title")
        case .export: String(localized: "Panel.Export.Title")
        }
    }
}

/// Everything about the editing session that isn't part of the document
/// itself, and every change the editor makes to the document.
@MainActor
@Observable
final class EditorState {
    var selectedSlideID: Slide.ID?
    /// The shapes selected on the current slide, in the order they were
    /// picked. The last is the one panels act on when only one can be.
    var selectedShapeIDs: [SlideShape.ID] = []
    /// Taps add shapes to the selection, or take them out, instead of
    /// replacing it.
    var isSelectingMultiple = false
    /// The shape being typed into over the slide, if any.
    var editingTextShapeID: SlideShape.ID?
    /// What is selected in the text being typed, as UTF-16 offsets.
    var textSelection: NSRange?
    /// The cell picked in the selected table.
    var selectedCell: TableCellPosition?
    /// Whether the picked cell's text is being typed into.
    var isEditingCell = false
    /// The picture whose crop is being adjusted.
    var croppingShapeID: SlideShape.ID?
    var presentedPanel: EditorPanel?
    /// Freehand drawing over the slide, which becomes a picture when done.
    var isDrawing = false
    var errorMessage: String?
    var isShowingUnsupportedFeatureNotice = false
    /// What the export panel opens on.
    var exportFormat: ExportOptions.Format = .pdf

    // MARK: - Selection

    func selectedIndex(in presentation: Presentation) -> Int {
        presentation.index(of: selectedSlideID) ?? 0
    }

    func selectedSlide(in presentation: Presentation) -> Slide? {
        guard !presentation.slides.isEmpty else { return nil }
        return presentation.slides[min(selectedIndex(in: presentation), presentation.slides.count - 1)]
    }

    /// The one selected shape, or the last picked of several.
    var selectedShapeID: SlideShape.ID? {
        get { selectedShapeIDs.last }
        set {
            if newValue != selectedShapeIDs.last {
                selectedCell = nil
                isEditingCell = false
                croppingShapeID = nil
            }
            selectedShapeIDs = newValue.map { [$0] } ?? []
            if newValue == nil { isSelectingMultiple = false }
            if newValue != editingTextShapeID { endEditingText() }
        }
    }

    var hasMultipleSelection: Bool { selectedShapeIDs.count > 1 }

    func isSelected(_ id: SlideShape.ID) -> Bool { selectedShapeIDs.contains(id) }

    func selectedShape(in presentation: Presentation) -> SlideShape? {
        guard let selectedShapeID else { return nil }
        return selectedSlide(in: presentation)?.shapes.first { $0.id == selectedShapeID }
    }

    /// Every selected shape, in the slide's stacking order.
    func selectedShapes(in presentation: Presentation) -> [SlideShape] {
        selectedSlide(in: presentation)?.shapes.filter { selectedShapeIDs.contains($0.id) } ?? []
    }

    /// Adds a shape to the selection, or takes it out if it is already in.
    func toggleSelection(_ id: SlideShape.ID) {
        endEditingText()
        if let index = selectedShapeIDs.firstIndex(of: id) {
            selectedShapeIDs.remove(at: index)
        } else {
            selectedShapeIDs.append(id)
        }
        if presentedPanel == .text, hasMultipleSelection { presentedPanel = nil }
    }

    func selectAllShapes(in presentation: Presentation) {
        selectedShapeIDs = selectedSlide(in: presentation)?.shapes.map(\.id) ?? []
        isSelectingMultiple = selectedShapeIDs.count > 1
        if presentedPanel == .text { presentedPanel = nil }
    }

    func selectSlide(_ id: Slide.ID?) {
        guard id != selectedSlideID else { return }
        selectedSlideID = id
        selectedShapeID = nil
        if presentedPanel == .text { presentedPanel = nil }
    }

    /// Keeps the selection pointing at something that exists, after an
    /// undo or a slide's removal.
    func reconcile(with presentation: Presentation) {
        if presentation.index(of: selectedSlideID) == nil {
            selectedSlideID = presentation.slides.first?.id
        }
        if !selectedShapeIDs.isEmpty {
            let existing = Set(selectedSlide(in: presentation)?.shapes.map(\.id) ?? [])
            let kept = selectedShapeIDs.filter(existing.contains)
            if kept != selectedShapeIDs { selectedShapeIDs = kept }
            if kept.isEmpty {
                isSelectingMultiple = false
                if presentedPanel == .text { presentedPanel = nil }
            }
        }
        if let editingTextShapeID, !selectedShapeIDs.contains(editingTextShapeID) { endEditingText() }
    }

    // MARK: - Slides

    func addSlide(using layout: SlideLayout, in presentation: inout Presentation) {
        var slide = Slide(layoutPath: layout.path)
        slide.relationships = [Relationship(
            id: "rId1", type: OOXML.RelationshipType.slideLayout,
            target: "../slideLayouts/" + (layout.path as NSString).lastPathComponent
        )]
        // A new slide starts with the layout's placeholders, empty.
        var nextID = 2
        for template in layout.shapes {
            guard let placeholder = template.placeholder, !placeholder.isFurniture else { continue }
            var shape = SlideShape(shapeID: nextID, name: template.name, kind: .shape, frame: template.frame, hasOwnFrame: false)
            shape.placeholder = placeholder
            shape.text = TextBody(paragraphs: [Paragraph(runs: [])])
            slide.shapes.append(shape)
            nextID += 1
        }
        slide.isModified = true
        let index = min(selectedIndex(in: presentation) + 1, presentation.slides.count)
        presentation.slides.insert(slide, at: index)
        presentation.isStructureModified = true
        selectSlide(slide.id)
    }

    func duplicateSlide(_ id: Slide.ID, in presentation: inout Presentation) {
        guard let index = presentation.index(of: id) else { return }
        let copy = Self.duplicate(of: presentation.slides[index])
        presentation.slides.insert(copy, at: index + 1)
        presentation.isStructureModified = true
        selectSlide(copy.id)
    }

    func deleteSlide(_ id: Slide.ID, in presentation: inout Presentation) {
        // A presentation always keeps at least one slide.
        guard presentation.slides.count > 1, let index = presentation.index(of: id) else { return }
        presentation.slides.remove(at: index)
        presentation.isStructureModified = true
        if selectedSlideID == id {
            selectSlide(presentation.slides[min(index, presentation.slides.count - 1)].id)
        }
    }

    func moveSlide(_ id: Slide.ID, to destination: Int, in presentation: inout Presentation) {
        guard let index = presentation.index(of: id) else { return }
        let target = min(max(destination, 0), presentation.slides.count - 1)
        guard target != index else { return }
        let slide = presentation.slides.remove(at: index)
        presentation.slides.insert(slide, at: target)
        presentation.isStructureModified = true
    }

    func toggleHidden(_ id: Slide.ID, in presentation: inout Presentation) {
        guard let index = presentation.index(of: id) else { return }
        presentation.slides[index].isHidden.toggle()
        presentation.slides[index].isModified = true
    }

    func setNotes(_ notes: String, in presentation: inout Presentation) {
        let index = selectedIndex(in: presentation)
        guard presentation.slides.indices.contains(index), presentation.slides[index].notes != notes else { return }
        presentation.slides[index].notes = notes
        presentation.slides[index].areNotesModified = true
    }

    func setBackground(_ fill: Fill?, in presentation: inout Presentation) {
        let index = selectedIndex(in: presentation)
        guard presentation.slides.indices.contains(index) else { return }
        presentation.slides[index].background = fill.map(Background.fill)
        presentation.slides[index].isBackgroundModified = true
        presentation.slides[index].isModified = true
    }

    // MARK: - Shapes

    /// Changes the selected slide's shapes, marking the slide for rewriting.
    private func updateSlide(in presentation: inout Presentation, _ change: (inout Slide) -> Void) {
        let index = selectedIndex(in: presentation)
        guard presentation.slides.indices.contains(index), presentation.slides[index].canEditShapes else { return }
        change(&presentation.slides[index])
        presentation.slides[index].isModified = true
    }

    /// Changes one shape, noting which parts of it were changed.
    func updateShape(
        _ id: SlideShape.ID?, edits: Set<SlideShape.Edit>, in presentation: inout Presentation,
        _ change: (inout SlideShape) -> Void
    ) {
        guard let id else { return }
        updateSlide(in: &presentation) { slide in
            guard let index = slide.shapes.firstIndex(where: { $0.id == id }), slide.shapes[index].isEditable else { return }
            change(&slide.shapes[index])
            slide.shapes[index].edits.formUnion(edits)
        }
    }

    private func insert(_ shape: SlideShape, in presentation: inout Presentation) {
        updateSlide(in: &presentation) { $0.shapes.append(shape) }
        selectedShapeID = shape.id
    }

    /// A rectangle of `size` points in the middle of the slide.
    private func centered(_ size: CGSize, in presentation: Presentation) -> EMURect {
        let slide = presentation.slideSize.points
        return EMURect(points: CGRect(
            x: (slide.width - size.width) / 2, y: (slide.height - size.height) / 2,
            width: size.width, height: size.height
        ))
    }

    func insertTextBox(in presentation: inout Presentation) {
        guard let slide = selectedSlide(in: presentation) else { return }
        let width = presentation.slideSize.points.width * 0.4
        var shape = SlideShape(
            shapeID: slide.nextShapeID, name: "TextBox \(slide.nextShapeID - 1)", kind: .shape,
            frame: centered(CGSize(width: width, height: 40), in: presentation)
        )
        shape.isTextBox = true
        shape.fill = Fill.none
        shape.text = TextBody(
            properties: { var body = BodyProperties(); body.wraps = true; body.autofit = .shape; return body }(),
            paragraphs: [Paragraph(runs: [])]
        )
        insert(shape, in: &presentation)
        beginEditingText(shape.id)
    }

    func insertShape(_ preset: String, in presentation: inout Presentation) {
        guard let slide = selectedSlide(in: presentation) else { return }
        let side = presentation.slideSize.points.height * 0.3
        let isLine = preset == "line"
        var shape = SlideShape(
            shapeID: slide.nextShapeID, name: "\(isLine ? "Straight Connector" : "Shape") \(slide.nextShapeID - 1)",
            kind: .shape,
            frame: centered(CGSize(width: isLine ? side * 1.5 : side, height: isLine ? 0 : side), in: presentation)
        )
        shape.geometry = .preset(preset, adjustments: [:])
        shape.style = StyleReferences(element: XMLLite.fragment(
            "<p:style><a:lnRef idx=\"2\"><a:schemeClr val=\"accent1\"><a:shade val=\"15000\"/></a:schemeClr></a:lnRef>"
                + "<a:fillRef idx=\"1\"><a:schemeClr val=\"accent1\"/></a:fillRef>"
                + "<a:fontRef idx=\"minor\"><a:schemeClr val=\"lt1\"/></a:fontRef></p:style>",
            namespaces: OOXML.namespaces
        ))
        if isLine {
            shape.line = LineStyle(fill: .solid(.scheme("accent1")), width: 28_575)
        } else {
            var paragraph = Paragraph(runs: [])
            paragraph.properties.alignment = .center
            var body = BodyProperties()
            body.anchor = .center
            shape.text = TextBody(properties: body, paragraphs: [paragraph])
        }
        insert(shape, in: &presentation)
    }

    /// Adds a picture to the package and the slide. Without a frame it is
    /// fitted into the middle of the slide.
    func insertPicture(_ media: PreparedMedia, frame: CGRect? = nil, name: String? = nil, in presentation: inout Presentation) {
        guard let slide = selectedSlide(in: presentation) else { return }
        let taken = Set(presentation.package.parts.keys).union(presentation.addedParts.keys)
        let path = PackagePath.unused(prefix: "ppt/media/image", suffix: "." + media.fileExtension, taken: taken)
        presentation.addedParts[path] = media.data

        let rect: EMURect
        if let frame {
            rect = EMURect(points: frame)
        } else {
            let bounds = presentation.slideSize.points
            let scale = min(bounds.width * 0.6 / media.size.width, bounds.height * 0.6 / media.size.height, 1)
            rect = centered(CGSize(width: media.size.width * scale, height: media.size.height * scale), in: presentation)
        }
        let shape = SlideShape(
            shapeID: slide.nextShapeID, name: name ?? "Picture \(slide.nextShapeID - 1)",
            kind: .picture(SlideShape.Picture(imagePath: path)), frame: rect
        )
        insert(shape, in: &presentation)
    }

    func deleteSelectedShape(in presentation: inout Presentation) {
        let ids = Set(selectedShapeIDs)
        guard !ids.isEmpty else { return }
        updateSlide(in: &presentation) { slide in
            slide.shapes.removeAll { ids.contains($0.id) }
            slide.hasRemovedShapes = true
        }
        selectedShapeID = nil
        if presentedPanel == .text { presentedPanel = nil }
    }

    func duplicateSelectedShape(in presentation: inout Presentation) {
        let originals = selectedShapes(in: presentation).filter(\.isEditable)
        guard !originals.isEmpty, var nextID = selectedSlide(in: presentation)?.nextShapeID else { return }
        var copies: [SlideShape] = []
        for original in originals {
            var shape = SlideShape(copying: original)
            shape.shapeID = nextID
            nextID += 1
            // Offset a little, so the copy is visibly a copy.
            shape.frame.x += 182_880
            shape.frame.y += 182_880
            shape.hasOwnFrame = true
            shape.edits.formUnion([.transform, .identity])
            copies.append(shape)
        }
        updateSlide(in: &presentation) { $0.shapes.append(contentsOf: copies) }
        selectedShapeIDs = copies.map(\.id)
    }

    enum Arrangement {
        case front
        case forward
        case backward
        case back
    }

    /// Restacks the selection, keeping the selected shapes in the order
    /// they were among themselves.
    func arrangeSelectedShape(_ arrangement: Arrangement, in presentation: inout Presentation) {
        let ids = Set(selectedShapeIDs)
        guard !ids.isEmpty else { return }
        updateSlide(in: &presentation) { slide in
            switch arrangement {
            case .front, .back:
                let moving = slide.shapes.filter { ids.contains($0.id) }
                slide.shapes.removeAll { ids.contains($0.id) }
                slide.shapes.insert(contentsOf: moving, at: arrangement == .front ? slide.shapes.count : 0)
            case .forward:
                // From the top down, so a shape never jumps one just moved.
                for index in slide.shapes.indices.reversed().dropFirst()
                where ids.contains(slide.shapes[index].id) && !ids.contains(slide.shapes[index + 1].id) {
                    slide.shapes.swapAt(index, index + 1)
                }
            case .backward:
                for index in slide.shapes.indices.dropFirst()
                where ids.contains(slide.shapes[index].id) && !ids.contains(slide.shapes[index - 1].id) {
                    slide.shapes.swapAt(index, index - 1)
                }
            }
        }
    }

    enum Alignment: CaseIterable {
        case left
        case center
        case right
        case top
        case middle
        case bottom
    }

    /// Lines the selected shapes up with one another, or a lone shape with
    /// the slide.
    func alignSelectedShapes(_ alignment: Alignment, in presentation: inout Presentation) {
        let shapes = selectedShapes(in: presentation).filter(\.isEditable)
        guard !shapes.isEmpty else { return }
        let bounds = shapes.count == 1
            ? CGRect(origin: .zero, size: presentation.slideSize.points)
            : shapes.map(\.frame.points).reduce(CGRect.null) { $0.union($1) }
        var frames: [SlideShape.ID: CGRect] = [:]
        for shape in shapes {
            var frame = shape.frame.points
            switch alignment {
            case .left: frame.origin.x = bounds.minX
            case .center: frame.origin.x = bounds.midX - frame.width / 2
            case .right: frame.origin.x = bounds.maxX - frame.width
            case .top: frame.origin.y = bounds.minY
            case .middle: frame.origin.y = bounds.midY - frame.height / 2
            case .bottom: frame.origin.y = bounds.maxY - frame.height
            }
            frames[shape.id] = frame
        }
        setFrames(frames, in: &presentation)
    }

    /// Spaces three or more shapes evenly between the outermost two.
    func distributeSelectedShapes(horizontally: Bool, in presentation: inout Presentation) {
        let shapes = selectedShapes(in: presentation).filter(\.isEditable)
            .sorted { horizontally ? $0.frame.x < $1.frame.x : $0.frame.y < $1.frame.y }
        guard shapes.count > 2, let first = shapes.first?.frame.points, let last = shapes.last?.frame.points else { return }
        let total = shapes.map { horizontally ? $0.frame.points.width : $0.frame.points.height }.reduce(0, +)
        let span = horizontally ? last.maxX - first.minX : last.maxY - first.minY
        let gap = (span - total) / CGFloat(shapes.count - 1)
        var position = horizontally ? first.minX : first.minY
        var frames: [SlideShape.ID: CGRect] = [:]
        for shape in shapes {
            var frame = shape.frame.points
            if horizontally { frame.origin.x = position } else { frame.origin.y = position }
            position += (horizontally ? frame.width : frame.height) + gap
            frames[shape.id] = frame
        }
        setFrames(frames, in: &presentation)
    }

    // MARK: - Pictures

    /// Cuts the picture to `frame`, a part of the whole image the crop
    /// fractions describe. `frame` is in points.
    func setCrop(
        frame: CGRect, left: Double, top: Double, right: Double, bottom: Double, of id: SlideShape.ID,
        in presentation: inout Presentation
    ) {
        updateShape(id, edits: [.picture, .transform], in: &presentation) { shape in
            guard case .picture(var picture) = shape.kind else { return }
            picture.cropLeft = left
            picture.cropTop = top
            picture.cropRight = right
            picture.cropBottom = bottom
            shape.kind = .picture(picture)
            shape.frame = EMURect(points: frame)
            shape.hasOwnFrame = true
        }
    }

    /// Shows the whole image again, at the size the visible part was shown.
    func resetCrop(in presentation: inout Presentation) {
        guard let shape = selectedShape(in: presentation), case .picture(let picture) = shape.kind else { return }
        let image = SlideShape.Picture.imageRect(frame: shape.frame.points, picture: picture)
        setCrop(frame: image, left: 0, top: 0, right: 0, bottom: 0, of: shape.id, in: &presentation)
    }

    /// Puts another image in the selected picture: as wide as the old one,
    /// centred where it was, as tall as the new image's proportions make it.
    func replacePicture(with media: PreparedMedia, in presentation: inout Presentation) {
        guard let shape = selectedShape(in: presentation), case .picture = shape.kind else { return }
        let path = PackagePath.unused(prefix: "ppt/media/image", suffix: "." + media.fileExtension, taken: presentation.partNames)
        presentation.addedParts[path] = media.data
        croppingShapeID = nil
        updateShape(shape.id, edits: [.picture, .transform], in: &presentation) { shape in
            let old = shape.frame.points
            let height = media.size.width > 0 ? old.width * media.size.height / media.size.width : old.height
            shape.frame = EMURect(points: CGRect(x: old.minX, y: old.midY - height / 2, width: old.width, height: height))
            shape.hasOwnFrame = true
            shape.kind = .picture(SlideShape.Picture(imagePath: path))
        }
    }

    func setAltText(_ text: String, in presentation: inout Presentation) {
        updateShape(selectedShapeID, edits: [.altText], in: &presentation) { shape in
            shape.altText = text.nilIfEmpty
        }
    }

    // MARK: - Tables

    /// Adds a table of empty cells in the middle of the slide.
    func insertTable(rows: Int, columns: Int, in presentation: inout Presentation) {
        guard let slide = selectedSlide(in: presentation) else { return }
        let bounds = presentation.slideSize.points
        let size = CGSize(width: bounds.width * 0.7, height: min(CGFloat(rows) * 37, bounds.height * 0.7))
        let frame = centered(size, in: presentation)
        let table = SlideTable.empty(rows: rows, columns: columns, width: frame.width, height: frame.height)
        let shape = SlideShape(shapeID: slide.nextShapeID, name: "Table \(slide.nextShapeID - 1)", kind: .table(table), frame: frame)
        insert(shape, in: &presentation)
        selectedCell = TableCellPosition(row: 0, column: 0)
    }

    func selectedTable(in presentation: Presentation) -> SlideTable? {
        guard let shape = selectedShape(in: presentation), case .table(let table) = shape.kind else { return nil }
        return table
    }

    /// Picks a cell of the selected table, optionally to type into.
    func selectCell(_ position: TableCellPosition?, editing: Bool = false) {
        selectedCell = position
        isEditingCell = editing && position != nil
        if isEditingCell {
            editingTextShapeID = nil
            textSelection = nil
        }
    }

    enum TableChange {
        case rowAbove
        case rowBelow
        case columnLeft
        case columnRight
        case deleteRow
        case deleteColumn
    }

    func changeTable(_ change: TableChange, in presentation: inout Presentation) {
        let position = selectedCell ?? TableCellPosition(row: 0, column: 0)
        var next = position
        updateTable(in: &presentation, resizes: true) { table in
            switch change {
            case .rowAbove:
                table.insertRow(at: position.row, copying: position.row)
                next.row += 1
            case .rowBelow:
                table.insertRow(at: position.row + 1, copying: position.row)
            case .columnLeft:
                table.insertColumn(at: position.column, copying: position.column)
                next.column += 1
            case .columnRight:
                table.insertColumn(at: position.column + 1, copying: position.column)
            case .deleteRow:
                table.deleteRow(at: position.row)
                next.row = min(position.row, table.rows.count - 1)
            case .deleteColumn:
                table.deleteColumn(at: position.column)
                next.column = min(position.column, table.columnCount - 1)
            }
        }
        selectCell(next)
    }

    func setTableHeaderRow(_ isOn: Bool, in presentation: inout Presentation) {
        updateTable(in: &presentation) { $0.hasHeaderRow = isOn }
    }

    func setTableBandedRows(_ isOn: Bool, in presentation: inout Presentation) {
        updateTable(in: &presentation) { $0.hasBandedRows = isOn }
    }

    func setCellText(_ body: TextBody, in presentation: inout Presentation) {
        guard let position = selectedCell else { return }
        updateTable(in: &presentation) { table in
            guard table.cell(at: position) != nil, table.rows[position.row].cells[position.column].text != body else { return }
            table.rows[position.row].cells[position.column].text = body
        }
    }

    func setCellFill(_ fill: Fill?, in presentation: inout Presentation) {
        guard let position = selectedCell else { return }
        updateTable(in: &presentation) { table in
            guard table.cell(at: position) != nil else { return }
            table.rows[position.row].cells[position.column].fill = fill
        }
    }

    /// Changes the selected table. After rows or columns come and go, its
    /// frame is made to fit them.
    private func updateTable(in presentation: inout Presentation, resizes: Bool = false, _ change: (inout SlideTable) -> Void) {
        updateShape(selectedShapeID, edits: resizes ? [.table, .transform] : [.table], in: &presentation) { shape in
            guard case .table(var table) = shape.kind else { return }
            change(&table)
            shape.kind = .table(table)
            if resizes {
                let size = table.gridSize
                shape.frame.width = size.width
                shape.frame.height = size.height
                shape.hasOwnFrame = true
            }
        }
    }

    // MARK: - Groups

    var canGroupSelection: Bool { selectedShapeIDs.count > 1 }

    /// Gathers the selected shapes into a group, which takes the place of the
    /// topmost of them.
    func groupSelectedShapes(in presentation: inout Presentation) {
        let members = selectedShapes(in: presentation).filter { $0.isEditable && $0.placeholder == nil }
        guard members.count > 1, let slide = selectedSlide(in: presentation) else { return }
        let bounds = members.map(\.boundingBox).reduce(CGRect.null) { $0.union($1) }
        let frame = EMURect(points: bounds)
        let id = slide.nextShapeID
        let group = SlideShape(
            shapeID: id, name: "Group \(id - 1)",
            kind: .group(SlideShape.ShapeGroup(childFrame: frame, children: members)), frame: frame
        )
        let ids = Set(members.map(\.id))
        updateSlide(in: &presentation) { slide in
            guard let top = slide.shapes.lastIndex(where: { ids.contains($0.id) }) else { return }
            let position = top - slide.shapes[..<top].filter { ids.contains($0.id) }.count
            slide.shapes.removeAll { ids.contains($0.id) }
            slide.shapes.insert(group, at: position)
        }
        selectedShapeIDs = [group.id]
        isSelectingMultiple = false
    }

    /// Breaks the selected group up into its members, placed on the slide
    /// where the group showed them.
    func ungroupSelectedShape(in presentation: inout Presentation) {
        guard let group = selectedShape(in: presentation), group.isEditable,
              case .group(let contents) = group.kind else { return }
        let members = contents.children.map { SlideShape.ungrouped($0, from: group, childFrame: contents.childFrame) }
        updateSlide(in: &presentation) { slide in
            guard let index = slide.shapes.firstIndex(where: { $0.id == group.id }) else { return }
            slide.shapes.replaceSubrange(index...index, with: members)
            // Animations on the group pointed at a shape that is gone.
            slide.hasRemovedShapes = true
        }
        selectedShapeIDs = members.map(\.id)
        isSelectingMultiple = members.count > 1
    }

    /// Moves several shapes at once, as one change. Frames are in points.
    func setFrames(_ frames: [SlideShape.ID: CGRect], in presentation: inout Presentation) {
        updateSlide(in: &presentation) { slide in
            for index in slide.shapes.indices {
                guard let frame = frames[slide.shapes[index].id], slide.shapes[index].isEditable else { continue }
                let rect = EMURect(points: frame)
                guard rect != slide.shapes[index].frame else { continue }
                slide.shapes[index].frame = rect
                slide.shapes[index].hasOwnFrame = true
                slide.shapes[index].edits.insert(.transform)
                slide.shapes[index].fitTableToFrame()
            }
        }
    }

    /// Moves and resizes the selected shape. `frame` is in points.
    func setFrame(_ frame: CGRect, of id: SlideShape.ID, in presentation: inout Presentation) {
        updateShape(id, edits: [.transform], in: &presentation) { shape in
            shape.frame = EMURect(points: frame)
            shape.hasOwnFrame = true
            shape.fitTableToFrame()
        }
    }

    /// Moves, resizes and turns a shape at once. `rotation` is in degrees clockwise.
    func setTransform(frame: CGRect, rotation: Double, of id: SlideShape.ID, in presentation: inout Presentation) {
        updateShape(id, edits: [.transform], in: &presentation) { shape in
            shape.frame = EMURect(points: frame)
            shape.hasOwnFrame = true
            shape.rotation = SlideShape.normalized(rotation)
            shape.fitTableToFrame()
        }
    }

    /// Turns the selected shape a quarter turn either way.
    func rotateSelectedShape(clockwise: Bool, in presentation: inout Presentation) {
        updateShape(selectedShapeID, edits: [.transform], in: &presentation) { shape in
            guard shape.canRotate else { return }
            shape.rotation = SlideShape.normalized(shape.rotation + (clockwise ? 90 : -90))
            shape.hasOwnFrame = true
        }
    }

    func flipSelectedShape(horizontally: Bool, in presentation: inout Presentation) {
        updateShape(selectedShapeID, edits: [.transform], in: &presentation) { shape in
            guard shape.canRotate else { return }
            if horizontally { shape.flipsHorizontally.toggle() } else { shape.flipsVertically.toggle() }
            shape.hasOwnFrame = true
        }
    }

    // MARK: - Text

    func setText(_ text: String, in presentation: inout Presentation) {
        updateShape(selectedShapeID, edits: [.text], in: &presentation) { shape in
            var body = shape.text ?? TextBody(paragraphs: [])
            guard body.plainText != text else { return }
            body.setPlainText(text)
            shape.text = body
        }
    }

    /// Starts typing into a shape, over the slide.
    func beginEditingText(_ id: SlideShape.ID) {
        selectedShapeID = id
        editingTextShapeID = id
        textSelection = nil
    }

    func endEditingText() {
        editingTextShapeID = nil
        textSelection = nil
        isEditingCell = false
    }

    /// The part of the text being edited that formatting applies to: the
    /// selection while typing, or `nil` for all of it.
    var activeTextRange: NSRange? {
        if isEditingCell { return textSelection }
        guard let editingTextShapeID, editingTextShapeID == selectedShapeID else { return nil }
        return textSelection
    }

    /// The text formatting applies to: the cell being typed into, or the
    /// selected shape's.
    private func formattedText(in presentation: Presentation) -> TextBody? {
        if isEditingCell, let position = selectedCell {
            return selectedTable(in: presentation)?.cell(at: position)?.text
        }
        return selectedShape(in: presentation)?.text
    }

    /// Changes the text formatting applies to.
    private func updateFormattedText(in presentation: inout Presentation, _ change: (inout TextBody) -> Void) {
        if isEditingCell, let position = selectedCell {
            updateTable(in: &presentation) { table in
                guard table.cell(at: position) != nil else { return }
                var body = table.rows[position.row].cells[position.column].text ?? TextBody(paragraphs: [Paragraph(runs: [])])
                change(&body)
                table.rows[position.row].cells[position.column].text = body
            }
            return
        }
        updateShape(selectedShapeID, edits: [.text], in: &presentation) { shape in
            var body = shape.text ?? TextBody(paragraphs: [Paragraph(runs: [])])
            change(&body)
            shape.text = body
        }
    }

    /// Replaces the text being typed into. A shape that grows to fit its
    /// text grows, or shrinks, with it.
    func setTextBody(_ body: TextBody, in presentation: inout Presentation) {
        guard let slide = selectedSlide(in: presentation), let current = selectedShape(in: presentation),
              current.text != body else { return }
        var height: Double?
        if case .shape = body.properties.autofit, current.rotation == 0 {
            let style = SlideStyleContext(presentation: presentation, slide: slide)
            var measured = current
            measured.text = body
            let width = measured.frame.points.width
            height = TextRenderer(style: style, slideNumber: 1).height(of: body, shape: measured, width: width)
        }
        updateShape(current.id, edits: height == nil ? [.text] : [.text, .transform], in: &presentation) { shape in
            shape.text = body
            if let height, abs(height - shape.frame.points.height) > 0.5 {
                shape.frame.height = EMU.from(points: height)
                shape.hasOwnFrame = true
            }
        }
    }

    /// The text properties as they will be drawn where formatting applies:
    /// at the selection's start while typing, or the first run's otherwise,
    /// with everything inherited folded in.
    func effectiveRunProperties(in presentation: Presentation) -> RunProperties {
        guard let slide = selectedSlide(in: presentation), let shape = selectedShape(in: presentation) else {
            return RunProperties()
        }
        let style = SlideStyleContext(presentation: presentation, slide: slide)
        let body = formattedText(in: presentation) ?? TextBody(paragraphs: [])
        let range = activeTextRange
        let paragraphIndex = range.flatMap { body.paragraphIndices(in: $0).first } ?? 0
        let paragraph = body.paragraphs.indices.contains(paragraphIndex) ? body.paragraphs[paragraphIndex] : nil
        let base = (paragraph?.properties ?? ParagraphProperties())
            .merged(over: style.paragraphBase(for: shape, sources: style.sources(for: shape), level: paragraph?.properties.level ?? 0))
        let run = range.flatMap { body.runProperties(at: $0.location + ($0.length > 0 ? 1 : 0)) }
            ?? paragraph?.runs.first?.properties ?? paragraph?.endProperties ?? RunProperties()
        return run.merged(over: base.defaultRun)
    }

    /// The paragraph properties in force where formatting applies.
    func effectiveParagraphProperties(in presentation: Presentation) -> ParagraphProperties {
        guard let slide = selectedSlide(in: presentation), let shape = selectedShape(in: presentation) else {
            return ParagraphProperties()
        }
        let style = SlideStyleContext(presentation: presentation, slide: slide)
        let body = formattedText(in: presentation) ?? TextBody(paragraphs: [])
        let index = activeTextRange.flatMap { body.paragraphIndices(in: $0).first } ?? 0
        let paragraph = body.paragraphs.indices.contains(index) ? body.paragraphs[index].properties : ParagraphProperties()
        return paragraph.merged(over: style.paragraphBase(for: shape, sources: style.sources(for: shape), level: paragraph.level ?? 0))
    }

    func effectiveAlignment(in presentation: Presentation) -> ParagraphAlignment {
        effectiveParagraphProperties(in: presentation).alignment ?? .left
    }

    func updateRuns(in presentation: inout Presentation, _ change: (inout RunProperties) -> Void) {
        let range = activeTextRange
        updateFormattedText(in: &presentation) { body in
            if let range, range.length > 0 {
                body.updateRuns(in: range, change)
            } else {
                body.updateRuns(change)
            }
        }
    }

    func updateParagraphs(in presentation: inout Presentation, _ change: (inout ParagraphProperties) -> Void) {
        let range = activeTextRange
        updateFormattedText(in: &presentation) { body in
            if let range {
                body.updateParagraphs(in: range, change)
            } else {
                body.updateParagraphs(change)
            }
        }
    }

    func toggleBold(in presentation: inout Presentation) {
        let isOn = effectiveRunProperties(in: presentation).isBold ?? false
        updateRuns(in: &presentation) { $0.isBold = !isOn }
    }

    func toggleItalic(in presentation: inout Presentation) {
        let isOn = effectiveRunProperties(in: presentation).isItalic ?? false
        updateRuns(in: &presentation) { $0.isItalic = !isOn }
    }

    func toggleUnderline(in presentation: inout Presentation) {
        let isOn = effectiveRunProperties(in: presentation).isUnderlined ?? false
        updateRuns(in: &presentation) { $0.isUnderlined = !isOn }
    }

    func toggleStrikethrough(in presentation: inout Presentation) {
        let isOn = effectiveRunProperties(in: presentation).isStruckThrough ?? false
        updateRuns(in: &presentation) { $0.isStruckThrough = !isOn }
    }

    /// Raises or lowers the text off the line: 30% up for superscript,
    /// 25% down for subscript, as PowerPoint does; again to undo.
    func toggleBaseline(superscript: Bool, in presentation: inout Presentation) {
        let current = effectiveRunProperties(in: presentation).baseline ?? 0
        let target = superscript ? 30_000 : -25_000
        updateRuns(in: &presentation) { $0.baseline = (current > 0) == superscript && current != 0 ? 0 : target }
    }

    /// Steps the text size, in points, keeping relative sizes within the shape.
    func stepFontSize(by points: Int, in presentation: inout Presentation) {
        let current = effectiveRunProperties(in: presentation).size ?? 1_800
        let target = min(max(current + points * 100, 600), 40_000)
        updateRuns(in: &presentation) { $0.size = target }
    }

    /// A typeface by name, or a theme font such as `+mn-lt`.
    func setFontFamily(_ family: String, in presentation: inout Presentation) {
        updateRuns(in: &presentation) { $0.latinFont = family }
    }

    func setAlignment(_ alignment: ParagraphAlignment, in presentation: inout Presentation) {
        updateParagraphs(in: &presentation) { $0.alignment = alignment }
    }

    func setTextColor(_ color: DrawingColor, in presentation: inout Presentation) {
        updateRuns(in: &presentation) { $0.color = color }
    }

    enum ListStyleChoice: Hashable {
        case none
        case bullets
        case numbers
    }

    func listStyle(in presentation: Presentation) -> ListStyleChoice {
        switch effectiveParagraphProperties(in: presentation).bullet {
        case .character?: .bullets
        case .autoNumber?: .numbers
        default: .none
        }
    }

    /// Makes the paragraphs a bulleted or numbered list, or plain. Text
    /// with no hanging indent of its own gets PowerPoint's, so the text
    /// lines up past the bullet.
    func setListStyle(_ choice: ListStyleChoice, in presentation: inout Presentation) {
        let effective = effectiveParagraphProperties(in: presentation)
        let needsIndent = (effective.marginLeft ?? 0) == 0
        updateParagraphs(in: &presentation) { paragraph in
            let level = paragraph.level ?? 0
            switch choice {
            case .none:
                paragraph.bullet = Bullet.none
                if paragraph.indent.map({ $0 < 0 }) == true {
                    paragraph.indent = 0
                    paragraph.marginLeft = level * 457_200
                }
            case .bullets, .numbers:
                if choice == .bullets {
                    paragraph.bullet = .character("•")
                    paragraph.bulletFont = "Arial"
                } else {
                    paragraph.bullet = .autoNumber(scheme: "arabicPeriod", startAt: 1)
                }
                if needsIndent {
                    let hang = choice == .bullets ? 285_750 : 342_900
                    paragraph.marginLeft = level * 457_200 + hang
                    paragraph.indent = -hang
                }
            }
        }
    }

    /// Moves the paragraphs a level in or out, as Tab and Shift-Tab do in a list.
    func changeIndent(by step: Int, in presentation: inout Presentation) {
        updateParagraphs(in: &presentation) { paragraph in
            let level = min(max((paragraph.level ?? 0) + step, 0), 8)
            guard level != paragraph.level ?? 0 else { return }
            paragraph.level = level
            if let margin = paragraph.marginLeft {
                paragraph.marginLeft = max(margin + step * 457_200, 0)
            }
        }
    }

    /// Line spacing as a multiple of single spacing.
    func setLineSpacing(_ multiple: Double, in presentation: inout Presentation) {
        updateParagraphs(in: &presentation) { $0.lineSpacing = .percent(multiple) }
    }

    // MARK: - Fill and outline

    func setFill(_ fill: Fill, in presentation: inout Presentation) {
        updateSelectedShapes(edits: [.fill], in: &presentation) { shape in
            guard case .shape = shape.kind else { return }
            shape.fill = fill
        }
    }

    /// Fills the selected shapes with a picture, added to the package.
    func setFillPicture(_ media: PreparedMedia, tiled: Bool, in presentation: inout Presentation) {
        let path = addMedia(media, to: &presentation)
        setFill(tiled ? .tiledPicture(path: path) : .picture(path: path), in: &presentation)
    }

    func setBackgroundPicture(_ media: PreparedMedia, tiled: Bool, in presentation: inout Presentation) {
        let path = addMedia(media, to: &presentation)
        setBackground(tiled ? .tiledPicture(path: path) : .picture(path: path), in: &presentation)
    }

    private func addMedia(_ media: PreparedMedia, to presentation: inout Presentation) -> String {
        let path = PackagePath.unused(prefix: "ppt/media/image", suffix: "." + media.fileExtension, taken: presentation.partNames)
        presentation.addedParts[path] = media.data
        return path
    }

    func setLine(_ change: (inout LineStyle) -> Void, in presentation: inout Presentation) {
        updateSelectedShapes(edits: [.line], in: &presentation) { shape in
            switch shape.kind {
            case .shape, .connector, .picture: break
            default: return
            }
            var line = shape.line ?? LineStyle()
            change(&line)
            shape.line = line
        }
    }

    /// Changes every selected shape that can be changed, as one change.
    func updateSelectedShapes(
        edits: Set<SlideShape.Edit>, in presentation: inout Presentation, _ change: (inout SlideShape) -> Void
    ) {
        let ids = Set(selectedShapeIDs)
        guard !ids.isEmpty else { return }
        updateSlide(in: &presentation) { slide in
            for index in slide.shapes.indices where ids.contains(slide.shapes[index].id) && slide.shapes[index].isEditable {
                let before = slide.shapes[index]
                change(&slide.shapes[index])
                if slide.shapes[index] != before { slide.shapes[index].edits.formUnion(edits) }
            }
        }
    }
}

extension SlideShape {
    /// A table's columns and rows stretched to its frame, after a resize.
    mutating func fitTableToFrame() {
        guard case .table(var table) = kind else { return }
        let size = table.gridSize
        guard size.width != frame.width || size.height != frame.height else { return }
        table.scale(toWidth: frame.width, height: frame.height)
        kind = .table(table)
        edits.insert(.table)
    }

    /// The slide-space box a turned shape covers, in points.
    var boundingBox: CGRect {
        let frame = self.frame.points
        guard rotation.truncatingRemainder(dividingBy: 180) != 0 else { return frame }
        let radians = rotation * .pi / 180
        let width = abs(frame.width * cos(radians)) + abs(frame.height * sin(radians))
        let height = abs(frame.width * sin(radians)) + abs(frame.height * cos(radians))
        return CGRect(x: frame.midX - width / 2, y: frame.midY - height / 2, width: width, height: height)
    }

    /// A group member as it stands on the slide once out of `group`: moved
    /// from the group's member space into slide space, and turned and
    /// flipped as the group turned and flipped it.
    static func ungrouped(_ member: SlideShape, from group: SlideShape, childFrame: EMURect) -> SlideShape {
        var shape = SlideRenderer.placed(member, from: childFrame, into: group.frame)
        let groupFrame = group.frame.points
        let center = CGPoint(x: groupFrame.midX, y: groupFrame.midY)
        var frame = shape.frame.points
        var middle = CGPoint(x: frame.midX, y: frame.midY)
        if group.flipsHorizontally {
            middle.x = 2 * center.x - middle.x
            shape.flipsHorizontally.toggle()
            shape.rotation = -shape.rotation
        }
        if group.flipsVertically {
            middle.y = 2 * center.y - middle.y
            shape.flipsVertically.toggle()
            shape.rotation = -shape.rotation
        }
        if group.rotation != 0 {
            let radians = group.rotation * .pi / 180
            let dx = middle.x - center.x
            let dy = middle.y - center.y
            middle = CGPoint(x: center.x + dx * cos(radians) - dy * sin(radians), y: center.y + dx * sin(radians) + dy * cos(radians))
        }
        frame.origin = CGPoint(x: middle.x - frame.width / 2, y: middle.y - frame.height / 2)
        shape.frame = EMURect(points: frame)
        shape.rotation = normalized(shape.rotation + group.rotation)
        shape.hasOwnFrame = true
        shape.edits.insert(.transform)
        return shape
    }

    /// A copy with an identity of its own, everywhere down its children.
    init(copying shape: SlideShape) {
        self = SlideShape.copy(of: shape)
    }

    private static func copy(of shape: SlideShape) -> SlideShape {
        var copy = SlideShape(id: UUID(), shapeID: shape.shapeID, name: shape.name, kind: shape.kind, frame: shape.frame)
        copy.hasOwnFrame = shape.hasOwnFrame
        copy.rotation = shape.rotation
        copy.flipsHorizontally = shape.flipsHorizontally
        copy.flipsVertically = shape.flipsVertically
        copy.placeholder = shape.placeholder
        copy.geometry = shape.geometry
        copy.fill = shape.fill
        copy.line = shape.line
        copy.style = shape.style
        copy.text = shape.text
        copy.textFrame = shape.textFrame
        copy.isTextBox = shape.isTextBox
        copy.altText = shape.altText
        copy.isLocked = shape.isLocked
        copy.source = shape.source
        copy.edits = shape.edits
        return copy
    }
}
