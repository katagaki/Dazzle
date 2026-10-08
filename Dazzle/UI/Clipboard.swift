import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// What Dazzle last copied, shared by every open presentation so shapes
/// and slides can be pasted from one into another.
///
/// The system pasteboard gets a picture and the text of what was copied,
/// for other apps. Its change count tells whether what is there is still
/// Dazzle's; once another app has copied something, that is what pastes.
@MainActor
final class DeckClipboard {
    static let shared = DeckClipboard()

    enum Content {
        case shapes([SlideShape], slide: Slide, presentation: Presentation)
        case slides([Slide], presentation: Presentation)
    }

    private var content: Content?
    private var changeCount = -1

    /// Dazzle's own content, if nothing has been copied since.
    var current: Content? {
        UIPasteboard.general.changeCount == changeCount ? content : nil
    }

    func copy(_ content: Content, image: Data?, text: String?) {
        var item: [String: Any] = [:]
        if let image { item[UTType.png.identifier] = image }
        if let text, !text.isEmpty { item[UTType.utf8PlainText.identifier] = text }
        UIPasteboard.general.setItems(item.isEmpty ? [] : [item])
        self.content = content
        changeCount = UIPasteboard.general.changeCount
    }
}

extension EditorState {
    // MARK: - Copying

    /// Copies the selected shapes, or with none selected, the slide.
    func copySelection(in presentation: Presentation) {
        guard let slide = selectedSlide(in: presentation) else { return }
        let shapes = selectedShapes(in: presentation)
        guard !shapes.isEmpty else { return copySlides([slide.id], in: presentation) }
        let text = shapes.compactMap { $0.text?.plainText.nilIfEmpty }.joined(separator: "\n")
        DeckClipboard.shared.copy(
            .shapes(shapes, slide: slide, presentation: presentation),
            image: SlideExporter.png(of: shapes, on: slide, in: presentation), text: text
        )
    }

    func cutSelection(in presentation: inout Presentation) {
        guard !selectedShapeIDs.isEmpty else {
            if let id = selectedSlide(in: presentation)?.id { cutSlide(id, in: &presentation) }
            return
        }
        copySelection(in: presentation)
        deleteSelectedShape(in: &presentation)
    }

    func copySlides(_ ids: [Slide.ID], in presentation: Presentation) {
        let slides = presentation.slides.filter { ids.contains($0.id) }
        guard let first = slides.first else { return }
        DeckClipboard.shared.copy(
            .slides(slides, presentation: presentation),
            image: SlideExporter.image(of: first, in: presentation, width: 1_280, format: .png),
            text: slides.compactMap(\.title).joined(separator: "\n")
        )
    }

    func cutSlide(_ id: Slide.ID, in presentation: inout Presentation) {
        guard presentation.slides.count > 1 else { return copySlides([id], in: presentation) }
        copySlides([id], in: presentation)
        deleteSlide(id, in: &presentation)
    }

    // MARK: - Pasting

    /// Pastes whatever is on the clipboard: Dazzle's shapes or slides, or
    /// another app's picture or text.
    func paste(in presentation: inout Presentation) {
        switch DeckClipboard.shared.current {
        case .shapes(let shapes, let slide, let source):
            pasteShapes(shapes, from: slide, of: source, into: &presentation)
        case .slides(let slides, let source):
            pasteSlides(slides, from: source, into: &presentation)
        case nil:
            pasteFromSystem(into: &presentation)
        }
    }

    private func pasteFromSystem(into presentation: inout Presentation) {
        let pasteboard = UIPasteboard.general
        if let data = pasteboard.data(forPasteboardType: UTType.png.identifier)
            ?? pasteboard.data(forPasteboardType: UTType.jpeg.identifier)
            ?? pasteboard.image?.pngData(),
           let media = PreparedMedia(data: data) {
            insertPicture(media, in: &presentation)
        } else if let text = pasteboard.string, !text.isEmpty {
            insertTextBox(in: &presentation)
            setText(text, in: &presentation)
            endEditingText()
        }
    }

    /// Puts copies of `shapes`, from `slide` in `source`, on the slide being edited.
    func pasteShapes(_ shapes: [SlideShape], from slide: Slide, of source: Presentation, into presentation: inout Presentation) {
        let index = selectedIndex(in: presentation)
        guard presentation.slides.indices.contains(index), presentation.slides[index].canEditShapes else { return }
        var target = presentation.slides[index]
        var importer = PartImporter(from: source, into: presentation)
        let isSameSlide = importer.sharesPackage && slide.id == target.id
        let sourceStyle = SlideStyleContext(presentation: source, slide: slide)
        var nextID = target.nextShapeID
        var pasted: [SlideShape] = []

        for original in shapes {
            var shape = isSameSlide ? original : importer.transplant(
                original, from: slide, into: &target.relationships,
                targetPart: target.partName ?? PartImporter.newSlidePart
            )
            shape = SlideShape(copying: shape)
            shape.shapeID = nextID
            nextID += 1
            // A placeholder stays one only where the slide has a place for it.
            if let placeholder = shape.placeholder {
                let layoutHasIt = presentation.layout(for: target)?.shapes.inheritedPlaceholder(for: placeholder) != nil
                let slideHasOne = (target.shapes + pasted).contains { $0.placeholder.map { placeholder.matches($0, byIndex: false) } ?? false }
                if !layoutHasIt || slideHasOne {
                    shape = Self.detached(shape, sources: sourceStyle.sources(for: original), style: sourceStyle)
                }
            }
            // Pasted where it came from, a copy steps aside so it shows.
            if (target.shapes + pasted).contains(where: { $0.frame == shape.frame }) {
                shape.frame.x += 182_880
                shape.frame.y += 182_880
            }
            shape.hasOwnFrame = true
            shape.edits.formUnion([.transform, .identity])
            pasted.append(shape)
        }

        target.shapes.append(contentsOf: pasted)
        target.isModified = true
        presentation.addedParts = importer.target.addedParts
        presentation.addedContentTypes = importer.target.addedContentTypes
        presentation.slides[index] = target
        selectedShapeIDs = pasted.map(\.id)
        isSelectingMultiple = pasted.count > 1
    }

    /// A placeholder made an ordinary shape, keeping the look it inherited.
    private static func detached(_ shape: SlideShape, sources: [SlideShape], style: SlideStyleContext) -> SlideShape {
        var shape = shape
        if var body = shape.text {
            for index in body.paragraphs.indices {
                let level = body.paragraphs[index].properties.level ?? 0
                let base = style.paragraphBase(for: shape, sources: sources, level: level)
                let effective = body.paragraphs[index].properties.merged(over: base)
                body.paragraphs[index].properties.alignment = effective.alignment
                func resolved(_ run: RunProperties) -> RunProperties {
                    var run = run.merged(over: effective.defaultRun)
                    run.latinFont = style.typeface(run.latinFont)
                    return run
                }
                for run in body.paragraphs[index].runs.indices {
                    body.paragraphs[index].runs[run].properties = resolved(body.paragraphs[index].runs[run].properties)
                }
                body.paragraphs[index].endProperties = resolved(body.paragraphs[index].endProperties ?? RunProperties())
            }
            shape.text = body
            shape.edits.insert(.text)
        }
        shape.placeholder = nil
        shape.edits.insert(.placeholder)
        return shape
    }

    /// Puts copies of `slides`, from `source`, after the slide being edited.
    func pasteSlides(_ slides: [Slide], from source: Presentation, into presentation: inout Presentation) {
        var importer = PartImporter(from: source, into: presentation)
        var position = min(selectedIndex(in: presentation) + 1, presentation.slides.count)
        var lastID: Slide.ID?
        for slide in slides {
            let copy = importer.sharesPackage
                ? Self.duplicate(of: slide)
                : Self.imported(slide, from: source, into: presentation, using: &importer)
            presentation.slides.insert(copy, at: position)
            position += 1
            lastID = copy.id
        }
        presentation.addedParts = importer.target.addedParts
        presentation.addedContentTypes = importer.target.addedContentTypes
        presentation.isStructureModified = true
        selectSlide(lastID)
    }

    /// A copy of a slide within its own presentation: the same XML, the
    /// same parts, its own notes.
    static func duplicate(of original: Slide) -> Slide {
        var copy = Slide(layoutPath: original.layoutPath, relationships: original.relationships, shapes: original.shapes)
        copy.sourcePart = original.sourcePart
        copy.background = original.background
        copy.isHidden = original.isHidden
        copy.showsMasterShapes = original.showsMasterShapes
        copy.canEditShapes = original.canEditShapes
        copy.isBackgroundModified = original.isBackgroundModified
        copy.hasRemovedShapes = original.hasRemovedShapes
        copy.autoAdvanceAfter = original.autoAdvanceAfter
        copy.advancesOnClick = original.advancesOnClick
        copy.isTransitionModified = original.isTransitionModified
        copy.animations = original.animations.map { ShapeAnimation(copying: $0) }
        copy.areAnimationsModified = original.areAnimationsModified
        // Notes and comments belong to one slide; the copy gets its own notes.
        copy.relationships.removeAll {
            $0.type == OOXML.RelationshipType.notesSlide || $0.type == OOXML.RelationshipType.comments
                || $0.type.hasSuffix("/comments")
        }
        copy.notes = original.notes
        copy.areNotesModified = !original.notes.isEmpty
        copy.isModified = original.isModified
        copy.shapes = copy.shapes.map(SlideShape.init(copying:))
        return copy
    }

    /// A slide from another presentation, rebuilt on this one's closest layout.
    private static func imported(
        _ slide: Slide, from source: Presentation, into presentation: Presentation, using importer: inout PartImporter
    ) -> Slide {
        let layout = matchingLayout(for: source.layout(for: slide), in: presentation)
        var copy = Slide(layoutPath: layout?.path ?? slide.layoutPath)
        if let layout {
            copy.relationships = [Relationship(
                id: "rId1", type: OOXML.RelationshipType.slideLayout,
                target: PackagePath.relativeTarget(to: layout.path, from: PartImporter.newSlidePart)
            )]
        }
        copy.shapes = slide.shapes.map { shape in
            importer.transplant(shape, from: slide, into: &copy.relationships, targetPart: PartImporter.newSlidePart)
        }
        if case .fill(let fill) = slide.background {
            copy.background = .fill(fill.remapped { importer.importPart($0) ?? $0 })
        } else {
            copy.background = slide.background
        }
        copy.isBackgroundModified = copy.background != nil
        copy.isHidden = slide.isHidden
        copy.showsMasterShapes = slide.showsMasterShapes
        copy.autoAdvanceAfter = slide.autoAdvanceAfter
        copy.advancesOnClick = slide.advancesOnClick
        copy.isTransitionModified = slide.autoAdvanceAfter != nil || !slide.advancesOnClick
        // Effects as read may name the other file's parts, such as a sound;
        // only those Dazzle can write anew come across.
        copy.animations = slide.animations.filter(\.effect.isMadeByDazzle).map { animation in
            var copied = ShapeAnimation(copying: animation)
            copied.source = nil
            return copied
        }
        copy.areAnimationsModified = !copy.animations.isEmpty
        copy.notes = slide.notes
        copy.areNotesModified = !slide.notes.isEmpty
        copy.isModified = true
        return copy
    }

    /// The layout in `presentation` most like `layout`: the same name, or
    /// the same placeholders, or failing those, the first.
    static func matchingLayout(for layout: SlideLayout?, in presentation: Presentation) -> SlideLayout? {
        let layouts = presentation.resources.orderedLayouts
        guard let layout else { return layouts.first }
        if let named = layouts.first(where: { $0.name == layout.name }) { return named }
        func kinds(_ layout: SlideLayout) -> Set<String> {
            Set(layout.shapes.compactMap { shape in
                shape.placeholder.flatMap { $0.isFurniture ? nil : ($0.type ?? "body") }
            })
        }
        let wanted = kinds(layout)
        return layouts.first { kinds($0) == wanted } ?? layouts.first
    }
}
