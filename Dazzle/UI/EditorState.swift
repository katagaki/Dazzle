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
    var selectedShapeID: SlideShape.ID?
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

    func selectedShape(in presentation: Presentation) -> SlideShape? {
        guard let selectedShapeID else { return nil }
        return selectedSlide(in: presentation)?.shapes.first { $0.id == selectedShapeID }
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
        if selectedShapeID != nil, selectedShape(in: presentation) == nil {
            selectedShapeID = nil
            if presentedPanel == .text { presentedPanel = nil }
        }
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
        let original = presentation.slides[index]
        var copy = Slide(layoutPath: original.layoutPath, relationships: original.relationships, shapes: original.shapes)
        copy.sourcePart = original.sourcePart
        copy.background = original.background
        copy.isHidden = original.isHidden
        copy.showsMasterShapes = original.showsMasterShapes
        copy.canEditShapes = original.canEditShapes
        copy.isBackgroundModified = original.isBackgroundModified
        copy.hasRemovedShapes = original.hasRemovedShapes
        // Notes and comments belong to one slide; the copy gets its own notes.
        copy.relationships.removeAll {
            $0.type == OOXML.RelationshipType.notesSlide || $0.type == OOXML.RelationshipType.comments
                || $0.type.hasSuffix("/comments")
        }
        copy.notes = original.notes
        copy.areNotesModified = !original.notes.isEmpty
        copy.isModified = original.isModified
        copy.shapes = copy.shapes.map(SlideShape.init(copying:))
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
        presentedPanel = .text
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
        guard let id = selectedShapeID else { return }
        updateSlide(in: &presentation) { slide in
            slide.shapes.removeAll { $0.id == id }
            slide.hasRemovedShapes = true
        }
        selectedShapeID = nil
        if presentedPanel == .text { presentedPanel = nil }
    }

    func duplicateSelectedShape(in presentation: inout Presentation) {
        guard var shape = selectedShape(in: presentation), shape.isEditable,
              let slide = selectedSlide(in: presentation) else { return }
        shape = SlideShape(copying: shape)
        shape.shapeID = slide.nextShapeID
        // Offset a little, so the copy is visibly a copy.
        shape.frame.x += 182_880
        shape.frame.y += 182_880
        shape.hasOwnFrame = true
        shape.edits.formUnion([.transform, .identity])
        insert(shape, in: &presentation)
    }

    enum Arrangement {
        case front
        case forward
        case backward
        case back
    }

    func arrangeSelectedShape(_ arrangement: Arrangement, in presentation: inout Presentation) {
        guard let id = selectedShapeID else { return }
        updateSlide(in: &presentation) { slide in
            guard let index = slide.shapes.firstIndex(where: { $0.id == id }) else { return }
            let shape = slide.shapes.remove(at: index)
            let destination = switch arrangement {
            case .front: slide.shapes.count
            case .forward: min(index + 1, slide.shapes.count)
            case .backward: max(index - 1, 0)
            case .back: 0
            }
            slide.shapes.insert(shape, at: destination)
        }
    }

    /// Moves and resizes the selected shape. `frame` is in points.
    func setFrame(_ frame: CGRect, of id: SlideShape.ID, in presentation: inout Presentation) {
        updateShape(id, edits: [.transform], in: &presentation) { shape in
            shape.frame = EMURect(points: frame)
            shape.hasOwnFrame = true
        }
    }

    /// Moves, resizes and turns a shape at once. `rotation` is in degrees clockwise.
    func setTransform(frame: CGRect, rotation: Double, of id: SlideShape.ID, in presentation: inout Presentation) {
        updateShape(id, edits: [.transform], in: &presentation) { shape in
            shape.frame = EMURect(points: frame)
            shape.hasOwnFrame = true
            shape.rotation = SlideShape.normalized(rotation)
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

    /// The selected shape's text properties as they will be drawn: its
    /// first run's, with everything it inherits folded in.
    func effectiveRunProperties(in presentation: Presentation) -> RunProperties {
        guard let slide = selectedSlide(in: presentation), let shape = selectedShape(in: presentation) else {
            return RunProperties()
        }
        let style = SlideStyleContext(presentation: presentation, slide: slide)
        let paragraph = shape.text?.paragraphs.first
        let base = (paragraph?.properties ?? ParagraphProperties())
            .merged(over: style.paragraphBase(for: shape, sources: style.sources(for: shape), level: paragraph?.properties.level ?? 0))
        let run = paragraph?.runs.first?.properties ?? paragraph?.endProperties ?? RunProperties()
        return run.merged(over: base.defaultRun)
    }

    func effectiveAlignment(in presentation: Presentation) -> ParagraphAlignment {
        guard let slide = selectedSlide(in: presentation), let shape = selectedShape(in: presentation) else { return .left }
        let style = SlideStyleContext(presentation: presentation, slide: slide)
        let paragraph = shape.text?.paragraphs.first
        return paragraph?.properties.alignment
            ?? style.paragraphBase(for: shape, sources: style.sources(for: shape), level: 0).alignment ?? .left
    }

    func updateRuns(in presentation: inout Presentation, _ change: (inout RunProperties) -> Void) {
        updateShape(selectedShapeID, edits: [.text], in: &presentation) { shape in
            if shape.text == nil { shape.text = TextBody(paragraphs: [Paragraph(runs: [])]) }
            shape.text?.updateRuns(change)
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

    /// Steps the text size, in points, keeping relative sizes within the shape.
    func stepFontSize(by points: Int, in presentation: inout Presentation) {
        let current = effectiveRunProperties(in: presentation).size ?? 1_800
        let target = min(max(current + points * 100, 600), 40_000)
        updateRuns(in: &presentation) { $0.size = target }
    }

    func setAlignment(_ alignment: ParagraphAlignment, in presentation: inout Presentation) {
        updateShape(selectedShapeID, edits: [.text], in: &presentation) { shape in
            if shape.text == nil { shape.text = TextBody(paragraphs: [Paragraph(runs: [])]) }
            shape.text?.updateParagraphs { $0.alignment = alignment }
        }
    }

    func setTextColor(_ color: DrawingColor, in presentation: inout Presentation) {
        updateRuns(in: &presentation) { $0.color = color }
    }

    // MARK: - Fill and outline

    func setFill(_ fill: Fill, in presentation: inout Presentation) {
        updateShape(selectedShapeID, edits: [.fill], in: &presentation) { $0.fill = fill }
    }

    func setLine(_ change: (inout LineStyle) -> Void, in presentation: inout Presentation) {
        updateShape(selectedShapeID, edits: [.line], in: &presentation) { shape in
            var line = shape.line ?? LineStyle()
            change(&line)
            shape.line = line
        }
    }
}

extension SlideShape {
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
        copy.isLocked = shape.isLocked
        copy.source = shape.source
        copy.edits = shape.edits
        return copy
    }
}
