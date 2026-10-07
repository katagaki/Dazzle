import AVFoundation
import CoreGraphics
import Foundation
import SwiftUI
import Testing
@testable import Dazzle

@Suite("ZIP container")
struct ZipArchiveTests {
    @Test("Entries survive a write/read round trip")
    func roundTrip() throws {
        let small = Data("hello".utf8)
        let large = Data(String(repeating: "presentation ", count: 5_000).utf8)
        let archive = try ZipArchive.archive(entries: [("a.txt", small), ("nested/b.xml", large)])
        let entries = try ZipArchive.entries(in: archive)
        #expect(entries["a.txt"] == small)
        #expect(entries["nested/b.xml"] == large)
    }

    @Test("Non-archives are rejected rather than misread")
    func rejectsGarbage() {
        #expect(throws: (any Error).self) {
            _ = try PPTXReader.presentation(from: Data(repeating: 0x41, count: 512))
        }
    }
}

@Suite("Package paths")
struct PackagePathTests {
    @Test("Relationship targets resolve against their part")
    func resolve() {
        #expect(PackagePath.resolve("../slideLayouts/slideLayout2.xml", from: "ppt/slides/slide1.xml")
            == "ppt/slideLayouts/slideLayout2.xml")
        #expect(PackagePath.resolve("/ppt/media/image1.png", from: "ppt/slides/slide1.xml") == "ppt/media/image1.png")
        #expect(PackagePath.resolve("slides/slide3.xml", from: "ppt/presentation.xml") == "ppt/slides/slide3.xml")
    }

    @Test("Relative targets lead back to the path")
    func relative() {
        #expect(PackagePath.relativeTarget(to: "ppt/media/image1.png", from: "ppt/slides/slide1.xml") == "../media/image1.png")
        #expect(PackagePath.relativeTarget(to: "ppt/slides/slide2.xml", from: "ppt/presentation.xml") == "slides/slide2.xml")
    }

    @Test("Relationship parts sit beside their part")
    func relationships() {
        #expect(PackagePath.relationships(of: "ppt/slides/slide1.xml") == "ppt/slides/_rels/slide1.xml.rels")
        #expect(PackagePath.relationships(of: "ppt/presentation.xml") == "ppt/_rels/presentation.xml.rels")
    }
}

@Suite("New presentations")
struct TemplateTests {
    @Test("The template reads as a one-slide widescreen deck")
    func template() {
        let presentation = Presentation.blank
        #expect(presentation.slides.count == 1)
        #expect(presentation.slideSize == .widescreen)
        #expect(presentation.resources.orderedLayouts.map(\.name)
            == ["Title Slide", "Title and Content", "Section Header", "Title Only", "Blank"])
        let slide = presentation.slides[0]
        #expect(slide.shapes.count == 2)
        // Placeholders without a frame of their own take the layout's.
        #expect(slide.shapes[0].placeholder?.type == "ctrTitle")
        #expect(slide.shapes[0].frame == EMURect(x: 1_524_000, y: 1_122_363, width: 9_144_000, height: 2_387_600))
        #expect(!slide.shapes[0].hasOwnFrame)
    }

    @Test("Theme colours resolve through the colour map")
    func themeColors() {
        let presentation = Presentation.blank
        let style = SlideStyleContext(presentation: presentation, slide: presentation.slides[0])
        #expect(style.color(.scheme("tx1")).hexValue == 0x000000)
        #expect(style.color(.scheme("bg1")).hexValue == 0xFFFFFF)
        #expect(style.color(.scheme("accent1")).hexValue == 0x156082)
    }

    @Test("Title text inherits the master's title size")
    func inheritedSize() {
        let presentation = Presentation.blank
        let slide = presentation.slides[0]
        let style = SlideStyleContext(presentation: presentation, slide: slide)
        let title = slide.shapes[0]
        let base = style.paragraphBase(for: title, sources: style.sources(for: title), level: 0)
        // The layout says 60pt, over the master's 44pt.
        #expect(base.defaultRun.size == 6_000)
        #expect(base.alignment == .center)
    }
}

@Suite("Round trips")
struct RoundTripTests {
    private func reread(_ presentation: Presentation) throws -> Presentation {
        try PPTXReader.presentation(from: PPTXWriter.data(from: presentation))
    }

    @Test("An untouched deck reads back the same")
    func untouched() throws {
        let original = Presentation.blank
        let copy = try reread(original)
        #expect(copy.slides.count == original.slides.count)
        #expect(copy.slides[0].shapes.map(\.name) == original.slides[0].shapes.map(\.name))
    }

    @Test("Edited text is written and keeps its placeholder")
    func editedText() throws {
        var presentation = Presentation.blank
        presentation.slides[0].shapes[0].text?.setPlainText("Quarterly Review")
        presentation.slides[0].shapes[0].edits.insert(.text)
        presentation.slides[0].isModified = true
        let copy = try reread(presentation)
        let title = copy.slides[0].shapes[0]
        #expect(title.text?.plainText == "Quarterly Review")
        #expect(title.placeholder?.type == "ctrTitle")
        #expect(copy.slides[0].title == "Quarterly Review")
    }

    @Test("Moved shapes keep their new frame")
    func movedShape() throws {
        var presentation = Presentation.blank
        presentation.slides[0].shapes[1].frame = EMURect(x: 100, y: 200, width: 3_000_000, height: 1_000_000)
        presentation.slides[0].shapes[1].hasOwnFrame = true
        presentation.slides[0].shapes[1].edits.insert(.transform)
        presentation.slides[0].isModified = true
        let copy = try reread(presentation)
        #expect(copy.slides[0].shapes[1].frame == EMURect(x: 100, y: 200, width: 3_000_000, height: 1_000_000))
        #expect(copy.slides[0].shapes[1].hasOwnFrame)
    }

    @Test("Turned and flipped shapes keep their rotation and flips")
    func rotatedShape() throws {
        var presentation = Presentation.blank
        presentation.slides[0].shapes[1].rotation = 30
        presentation.slides[0].shapes[1].flipsHorizontally = true
        presentation.slides[0].shapes[1].hasOwnFrame = true
        presentation.slides[0].shapes[1].edits.insert(.transform)
        presentation.slides[0].isModified = true
        let copy = try reread(presentation)
        #expect(copy.slides[0].shapes[1].rotation == 30)
        #expect(copy.slides[0].shapes[1].flipsHorizontally)
        #expect(!copy.slides[0].shapes[1].flipsVertically)
        #expect(SlideShape.normalized(-90) == 270)
    }

    @Test("Added, duplicated and reordered slides survive saving")
    func structure() throws {
        var presentation = Presentation.blank
        let layout = try #require(presentation.resources.orderedLayouts.first { $0.name == "Title and Content" })
        var second = Slide(layoutPath: layout.path, relationships: [
            Relationship(id: "rId1", type: OOXML.RelationshipType.slideLayout,
                         target: "../slideLayouts/" + (layout.path as NSString).lastPathComponent),
        ])
        var title = SlideShape(shapeID: 2, name: "Title 1", kind: .shape, frame: .zero, hasOwnFrame: false)
        title.placeholder = Placeholder(type: "title", index: nil)
        title.text = TextBody(paragraphs: [Paragraph(runs: [TextRun(text: "Agenda")])])
        second.shapes = [title]
        second.isModified = true
        presentation.slides.insert(second, at: 0)
        presentation.isStructureModified = true

        let copy = try reread(presentation)
        #expect(copy.slides.count == 2)
        #expect(copy.slides[0].title == "Agenda")
        #expect(copy.slides[0].layoutPath == layout.path)

        var reordered = copy
        reordered.slides.swapAt(0, 1)
        reordered.slides.remove(at: 1)
        reordered.isStructureModified = true
        let final = try reread(reordered)
        #expect(final.slides.count == 1)
        #expect(final.slides[0].title == nil)
        #expect(final.package.parts.keys.filter { $0.hasPrefix("ppt/slides/slide") }.count == 1)
    }

    @Test("Speaker notes are created, read and rewritten")
    func notes() throws {
        var presentation = Presentation.blank
        presentation.slides[0].notes = "Welcome everyone.\nIntroduce the team."
        presentation.slides[0].areNotesModified = true
        let copy = try reread(presentation)
        #expect(copy.slides[0].notes == "Welcome everyone.\nIntroduce the team.")
        #expect(copy.resources.notesMasterPath != nil)

        var edited = copy
        edited.slides[0].notes = "Changed."
        edited.slides[0].areNotesModified = true
        let final = try reread(edited)
        #expect(final.slides[0].notes == "Changed.")
    }

    @Test("Pictures are added to the package with a relationship")
    func picture() throws {
        var presentation = Presentation.blank
        let png = try #require(SlideExporter.image(of: presentation.slides[0], in: presentation, width: 64, format: .png))
        presentation.addedParts["ppt/media/image1.png"] = png
        var shape = SlideShape(
            shapeID: 10, name: "Picture 1", kind: .picture(SlideShape.Picture(imagePath: "ppt/media/image1.png")),
            frame: EMURect(x: 0, y: 0, width: 914_400, height: 514_350)
        )
        shape.hasOwnFrame = true
        presentation.slides[0].shapes.append(shape)
        presentation.slides[0].isModified = true

        let copy = try reread(presentation)
        let picture = try #require(copy.slides[0].shapes.last)
        guard case .picture(let read) = picture.kind else {
            Issue.record("Expected a picture")
            return
        }
        #expect(read.imagePath == "ppt/media/image1.png")
        #expect(copy.data(at: "ppt/media/image1.png") == png)
    }

    @Test("Hidden slides stay hidden")
    func hidden() throws {
        var presentation = Presentation.blank
        presentation.slides[0].isHidden = true
        presentation.slides[0].isModified = true
        #expect(try reread(presentation).slides[0].isHidden)
    }

    @Test("Text edits keep the formatting of untouched paragraphs")
    func paragraphFormatting() {
        var body = TextBody(paragraphs: [
            Paragraph(runs: [TextRun(text: "One", properties: { var p = RunProperties(); p.isBold = true; return p }())]),
            Paragraph(runs: [TextRun(text: "Two")]),
        ])
        body.setPlainText("One\nTwo, edited\nThree")
        #expect(body.paragraphs.count == 3)
        #expect(body.paragraphs[0].runs[0].properties.isBold == true)
        #expect(body.paragraphs[1].plainText == "Two, edited")
        #expect(body.paragraphs[2].plainText == "Three")
    }
}

@Suite("Rendering")
struct RenderingTests {
    @Test("Slides render to pictures and PDF")
    func exports() throws {
        let presentation = Presentation.blank
        let png = try #require(SlideExporter.image(of: presentation.slides[0], in: presentation, width: 320, format: .png))
        #expect(png.starts(with: [0x89, 0x50, 0x4E, 0x47]))
        let jpeg = try #require(SlideExporter.image(of: presentation.slides[0], in: presentation, width: 320, format: .jpeg))
        #expect(jpeg.starts(with: [0xFF, 0xD8]))
        let pdf = SlideExporter.pdf(of: presentation.slides, in: presentation, title: "Test")
        #expect(pdf.starts(with: Array("%PDF".utf8)))
    }

    @Test("Numbered lists count in the scheme they ask for")
    func numbering() {
        #expect(TextRenderer.numberLabel(3, scheme: "arabicPeriod") == "3.")
        #expect(TextRenderer.numberLabel(2, scheme: "alphaLcParenR") == "b)")
        #expect(TextRenderer.numberLabel(4, scheme: "romanUcPeriod") == "IV.")
    }

    @Test("Colour transforms follow DrawingML")
    func colorTransforms() {
        let red = RGBAColor(hex: 0xFF0000)
        #expect(red.applying(.init(name: "alpha", value: 50_000)).alpha == 0.5)
        // Tint and shade mix in linear light, as Office does.
        #expect(RGBAColor.black.applying(.init(name: "tint", value: 75_000)).hexValue == 0x898989)
        #expect(red.applying(.init(name: "shade", value: 50_000)).hexValue == 0xBC0000)
        let lighter = red.applying(.init(name: "lumMod", value: 60_000)).applying(.init(name: "lumOff", value: 40_000))
        #expect(lighter.hsl.luminance > red.hsl.luminance)
    }
}

@Suite("Rendering fidelity")
struct RenderingFidelityTests {
    @Test("Group members are placed in slide space, not scaled")
    func groupPlacement() {
        let member = SlideShape(shapeID: 2, name: "", kind: .shape, frame: EMURect(x: 10, y: 20, width: 50, height: 25))
        let placed = SlideRenderer.placed(
            member, from: EMURect(x: 0, y: 0, width: 100, height: 100),
            into: EMURect(x: 1_000, y: 2_000, width: 1_000, height: 2_000)
        )
        #expect(placed.frame == EMURect(x: 1_100, y: 2_400, width: 500, height: 500))
    }

    @Test("Table styles read fills, text and borders, including theme references")
    func tableStyle() throws {
        let xml = """
            <a:tblStyle xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main" styleId="x"><a:wholeTbl>\
            <a:tcTxStyle><a:fontRef idx="minor"><a:prstClr val="black"/></a:fontRef><a:schemeClr val="tx1"/></a:tcTxStyle>\
            <a:tcStyle><a:tcBdr><a:left><a:lnRef idx="1"><a:schemeClr val="accent1"/></a:lnRef></a:left></a:tcBdr>\
            <a:fill><a:noFill/></a:fill></a:tcStyle></a:wholeTbl><a:firstRow><a:tcTxStyle b="on"><a:schemeClr val="bg1"/>\
            </a:tcTxStyle><a:tcStyle><a:fillRef idx="1"><a:schemeClr val="accent1"/></a:fillRef></a:tcStyle></a:firstRow></a:tblStyle>
            """
        let style = TableStyle(element: try XMLLite.parse(Data(xml.utf8)))
        #expect(style.whole.textColor == .scheme("tx1"))
        #expect(style.whole.fill == Fill.none)
        #expect(style.whole.borders["left"]?.fill == .solid(.scheme("accent1")))
        #expect(style.headerRow.fill == .solid(.scheme("accent1")))
        #expect(style.headerRow.isBold == true)
        #expect(style.headerRow.textColor == .scheme("bg1"))
    }

    @Test("Radial gradients start where fillToRect puts them, and tiled pictures say so")
    func fills() throws {
        let gradient = try XMLLite.parse(Data("""
            <gradFill><gsLst><gs pos="0"><srgbClr val="000000"/></gs><gs pos="100000"><srgbClr val="FFFFFF"/></gs></gsLst>\
            <path path="circle"><fillToRect l="100000" t="100000"/></path></gradFill>
            """.utf8))
        guard case .gradient(let parsed) = Fill.parse(element: gradient, image: { _ in nil }) else {
            Issue.record("Expected a gradient")
            return
        }
        #expect(parsed.focusX == 1 && parsed.focusY == 1)

        let tiled = try XMLLite.parse(Data("""
            <blipFill xmlns:r="r"><blip r:embed="rId1"><alphaModFix amt="50000"/></blip><tile/></blipFill>
            """.utf8))
        #expect(Fill.parse(element: tiled, image: { _ in "ppt/media/a.png" }) == .tiledPicture(path: "ppt/media/a.png", effects: { var e = BlipEffects(); e.opacity = 0.5; return e }()))
    }
}

@Suite("Picture effects and symbols")
struct PictureEffectTests {
    @Test("Blip effects read greyscale, duotone and transparency")
    func blipEffects() throws {
        let blip = try XMLLite.parse(Data("""
            <blip><grayscl/><alphaModFix amt="40000"/><duotone><srgbClr val="000000"/><schemeClr val="bg1"/></duotone></blip>
            """.utf8))
        let effects = BlipEffects(blip: blip)
        #expect(effects.isGreyscale)
        #expect(effects.opacity == 0.4)
        #expect(effects.duotone == [.rgb(0x000000), .scheme("bg1")])
        #expect(effects.altersColor)
        #expect(!BlipEffects().altersColor)
    }

    @Test("Recolouring maps luminance onto the duotone colours")
    func recolor() throws {
        let space = try #require(CGColorSpace(name: CGColorSpace.sRGB))
        let context = try #require(CGContext(
            data: nil, width: 2, height: 1, bitsPerComponent: 8, bytesPerRow: 8, space: space,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 2, height: 1))
        let white = try #require(context.makeImage())
        let red = RGBAColor(hex: 0xFF0000)
        let recolored = try #require(ImageCache.shared.recolored(
            white, key: "test-white", isGreyscale: false, duotone: [.black, red]
        ))
        let data = try #require(recolored.dataProvider?.data as Data?)
        // White is the light end of the duotone.
        #expect(Array(data.prefix(3)) == [255, 0, 0])
    }

    @Test("Symbol-font characters in text are drawn as what they look like")
    func symbols() {
        #expect(TextRenderer.symbolsMapped("\u{F0E0} next") == "→ next")
        #expect(TextRenderer.symbolsMapped("\u{F0FC}") == "✓")
        #expect(TextRenderer.symbolsMapped("plain") == "plain")
    }
}

@Suite("Editing")
@MainActor
struct EditingTests {
    /// A blank deck with three plain shapes added, selected in turn.
    private func deck(with frames: [CGRect]) -> (Presentation, EditorState) {
        var presentation = Presentation.blank
        let state = EditorState()
        state.selectSlide(presentation.slides[0].id)
        for frame in frames {
            state.insertShape("rect", in: &presentation)
            if let id = state.selectedShapeID { state.setFrame(frame, of: id, in: &presentation) }
        }
        state.selectedShapeIDs = presentation.slides[0].shapes.suffix(frames.count).map(\.id)
        return (presentation, state)
    }

    @Test("Aligning lines the selection up with its own edges")
    func align() {
        var (presentation, state) = deck(with: [
            CGRect(x: 10, y: 10, width: 50, height: 50), CGRect(x: 100, y: 40, width: 20, height: 20),
        ])
        state.alignSelectedShapes(.right, in: &presentation)
        let frames = state.selectedShapes(in: presentation).map(\.frame.points)
        #expect(frames.count == 2)
        #expect(frames.allSatisfy { abs($0.maxX - 120) < 0.01 })
    }

    @Test("Distributing spaces shapes evenly between the outermost two")
    func distribute() {
        var (presentation, state) = deck(with: [
            CGRect(x: 0, y: 0, width: 10, height: 10), CGRect(x: 15, y: 0, width: 10, height: 10),
            CGRect(x: 90, y: 0, width: 10, height: 10),
        ])
        state.distributeSelectedShapes(horizontally: true, in: &presentation)
        let xs = state.selectedShapes(in: presentation).map(\.frame.points.minX).sorted()
        #expect(abs(xs[1] - 45) < 0.01)
    }

    @Test("Bringing several shapes forward keeps their order among themselves")
    func arrangeForward() {
        var (presentation, state) = deck(with: [
            CGRect(x: 0, y: 0, width: 10, height: 10), CGRect(x: 0, y: 0, width: 10, height: 10),
            CGRect(x: 0, y: 0, width: 10, height: 10),
        ])
        let ids = presentation.slides[0].shapes.suffix(3).map(\.id)
        state.selectedShapeIDs = [ids[0], ids[1]]
        state.arrangeSelectedShape(.forward, in: &presentation)
        #expect(Array(presentation.slides[0].shapes.suffix(3).map(\.id)) == [ids[2], ids[0], ids[1]])
    }

    @Test("Grouping writes a group PowerPoint can read, and ungrouping puts the members back")
    func groupAndUngroup() throws {
        var (presentation, state) = deck(with: [
            CGRect(x: 10, y: 10, width: 50, height: 50), CGRect(x: 100, y: 40, width: 20, height: 20),
        ])
        state.groupSelectedShapes(in: &presentation)
        let group = try #require(state.selectedShape(in: presentation))
        #expect(group.frame.points.minX == 10 && group.frame.points.maxX == 120)

        var copy = try PPTXReader.presentation(from: PPTXWriter.data(from: presentation))
        guard case .group(let read) = try #require(copy.slides[0].shapes.last).kind else {
            Issue.record("Expected a group")
            return
        }
        #expect(read.children.count == 2)
        #expect(read.children.allSatisfy { $0.source != nil })

        let reread = EditorState()
        reread.selectSlide(copy.slides[0].id)
        reread.selectedShapeID = copy.slides[0].shapes.last?.id
        reread.ungroupSelectedShape(in: &copy)
        let final = try PPTXReader.presentation(from: PPTXWriter.data(from: copy))
        let frames = final.slides[0].shapes.suffix(2).map(\.frame.points)
        #expect(frames.map(\.minX) == [10, 100])
    }

    @Test("A member of a turned group comes out turned with it")
    func ungroupTurned() {
        var group = SlideShape(shapeID: 2, name: "", kind: .shape, frame: EMURect(points: CGRect(x: 0, y: 0, width: 100, height: 100)))
        group.rotation = 90
        let member = SlideShape(shapeID: 3, name: "", kind: .shape, frame: EMURect(points: CGRect(x: 0, y: 0, width: 50, height: 100)))
        let placed = SlideShape.ungrouped(member, from: group, childFrame: group.frame)
        #expect(placed.rotation == 90)
        // The left half, turned a quarter clockwise, is the top half.
        #expect(abs(placed.frame.points.midX - 50) < 0.01 && abs(placed.frame.points.midY - 25) < 0.01)
    }
}

@Suite("Snapping")
struct SnappingTests {
    @Test("A shape near the slide's centre line settles on it")
    func centre() {
        let snapping = Snapping(slide: CGSize(width: 960, height: 540), others: [], threshold: 5)
        let (offset, guides) = snapping.adjustment(for: CGRect(x: 428, y: 100, width: 100, height: 50))
        #expect(offset.width == 2)
        #expect(offset.height == 0)
        #expect(guides.contains(.init(axis: .vertical, position: 480)))
    }

    @Test("A shape lines up with a neighbour's edge, and only within reach")
    func neighbour() {
        let snapping = Snapping(slide: CGSize(width: 960, height: 540), others: [CGRect(x: 300, y: 300, width: 80, height: 80)], threshold: 5)
        #expect(snapping.adjustment(for: CGRect(x: 297, y: 100, width: 40, height: 40), y: []).offset.width == 3)
        #expect(snapping.adjustment(for: CGRect(x: 250, y: 100, width: 40, height: 40), y: []).offset.width == 0)
    }
}

@Suite("Copy and paste")
@MainActor
struct PasteTests {
    /// A saved and reopened deck with a picture on its one slide, so the
    /// picture's XML names its image by relationship id.
    private func deckWithPicture() throws -> Presentation {
        var presentation = Presentation.blank
        let png = try #require(SlideExporter.image(of: presentation.slides[0], in: presentation, width: 32, format: .png))
        presentation.addedParts["ppt/media/image1.png"] = png
        var shape = SlideShape(
            shapeID: 10, name: "Picture 1", kind: .picture(SlideShape.Picture(imagePath: "ppt/media/image1.png")),
            frame: EMURect(x: 0, y: 0, width: 914_400, height: 514_350)
        )
        shape.hasOwnFrame = true
        presentation.slides[0].shapes.append(shape)
        presentation.slides[0].isModified = true
        return try PPTXReader.presentation(from: PPTXWriter.data(from: presentation))
    }

    private func reread(_ presentation: Presentation) throws -> Presentation {
        try PPTXReader.presentation(from: PPTXWriter.data(from: presentation))
    }

    @Test("A picture pasted into another presentation brings its image along")
    func pictureAcrossDecks() throws {
        let source = try deckWithPicture()
        let picture = try #require(source.slides[0].shapes.last)
        var target = Presentation.blank
        let state = EditorState()
        state.selectSlide(target.slides[0].id)
        state.pasteShapes([picture], from: source.slides[0], of: source, into: &target)

        let saved = try reread(target)
        let pasted = try #require(saved.slides[0].shapes.last)
        guard case .picture(let read) = pasted.kind, let path = read.imagePath else {
            Issue.record("Expected a picture with an image")
            return
        }
        #expect(saved.data(at: path) == source.data(at: "ppt/media/image1.png"))
    }

    @Test("A picture pasted onto another slide of its own deck gets a relationship there")
    func pictureAcrossSlides() throws {
        var deck = try deckWithPicture()
        let state = EditorState()
        let layout = try #require(deck.resources.orderedLayouts.last)
        state.selectSlide(deck.slides[0].id)
        state.addSlide(using: layout, in: &deck)
        state.pasteShapes([try #require(deck.slides[0].shapes.last)], from: deck.slides[0], of: deck, into: &deck)

        let saved = try reread(deck)
        guard case .picture(let read) = try #require(saved.slides[1].shapes.last).kind else {
            Issue.record("Expected a picture")
            return
        }
        #expect(read.imagePath == "ppt/media/image1.png")
    }

    @Test("A slide pasted into another presentation lands on a layout of the same name")
    func slideAcrossDecks() throws {
        var source = Presentation.blank
        source.slides[0].shapes[0].text?.setPlainText("Imported")
        source.slides[0].shapes[0].edits.insert(.text)
        source.slides[0].isModified = true
        source = try reread(source)
        var target = Presentation.blank
        let state = EditorState()
        state.selectSlide(target.slides[0].id)
        state.pasteSlides([source.slides[0]], from: source, into: &target)

        let saved = try reread(target)
        #expect(saved.slides.count == 2)
        #expect(saved.slides[1].title == "Imported")
        #expect(saved.layout(for: saved.slides[1])?.name == "Title Slide")
    }

    @Test("Part names step past ones already taken")
    func unusedNames() {
        #expect(PartImporter.unusedName(like: "ppt/charts/chart3.xml", taken: ["ppt/charts/chart1.xml"]) == "ppt/charts/chart2.xml")
        #expect(PartImporter.unusedName(like: "ppt/embeddings/Sheet.xlsx", taken: []) == "ppt/embeddings/Sheet1.xlsx")
    }
}

@Suite("Rich text")
@MainActor
struct RichTextTests {
    private var body: TextBody {
        TextBody(paragraphs: [
            Paragraph(runs: [TextRun(text: "Hello world")]),
            Paragraph(runs: [TextRun(text: "Second")]),
        ])
    }

    @Test("Formatting a range splits runs and leaves the rest alone")
    func rangeFormatting() {
        var text = body
        text.updateRuns(in: NSRange(location: 6, length: 5)) { $0.isBold = true }
        #expect(text.paragraphs[0].runs.map(\.text) == ["Hello ", "world"])
        #expect(text.paragraphs[0].runs.map(\.properties.isBold) == [nil, true])
        #expect(text.paragraphs[1].runs[0].properties.isBold == nil)
        #expect(text.plainText == "Hello world\nSecond")
    }

    @Test("A range across paragraphs formats both, and finds both")
    func acrossParagraphs() {
        var text = body
        let range = NSRange(location: 8, length: 6)
        #expect(text.paragraphIndices(in: range) == [0, 1])
        #expect(text.paragraphIndices(in: NSRange(location: 13, length: 0)) == [1])
        text.updateRuns(in: range) { $0.isItalic = true }
        #expect(text.paragraphs[0].runs.map(\.text) == ["Hello wo", "rld"])
        #expect(text.paragraphs[1].runs.map(\.text) == ["Se", "cond"])
        #expect(text.runProperties(at: 13)?.isItalic == true)
        #expect(text.runProperties(at: 3)?.isItalic == nil)
    }

    @Test("Text round-trips through the editor, keeping each run's formatting")
    func editorRoundTrip() {
        var text = body
        text.updateRuns(in: NSRange(location: 0, length: 5)) { $0.isBold = true }
        let presentation = Presentation.blank
        let style = SlideStyleContext(presentation: presentation, slide: presentation.slides[0])
        let shape = SlideShape(shapeID: 2, name: "", kind: .shape, frame: .zero)
        let string = NSMutableAttributedString(attributedString: EditableText.attributedString(
            text, shape: shape, sources: [], style: style, scale: 1, fontScale: 1, slideNumber: 1
        ))
        #expect(EditableText.body(from: string, template: text) == text)

        // Typing at the end of the bold word continues it in bold.
        string.insert(NSAttributedString(string: "!", attributes: string.attributes(at: 4, effectiveRange: nil)), at: 5)
        let edited = EditableText.body(from: string, template: text)
        #expect(edited.paragraphs[0].runs.map(\.text) == ["Hello!", " world"])
        #expect(edited.paragraphs[0].runs[0].properties.isBold == true)
    }

    @Test("Lists, indents and spacing are written and read back")
    func paragraphWriting() throws {
        var presentation = Presentation.blank
        let state = EditorState()
        state.selectSlide(presentation.slides[0].id)
        state.insertTextBox(in: &presentation)
        state.setText("One\nTwo", in: &presentation)
        state.endEditingText()
        state.setListStyle(.numbers, in: &presentation)
        state.setLineSpacing(1.5, in: &presentation)
        state.changeIndent(by: 1, in: &presentation)
        let copy = try PPTXReader.presentation(from: PPTXWriter.data(from: presentation))
        let paragraph = try #require(copy.slides[0].shapes.last?.text?.paragraphs.first?.properties)
        #expect(paragraph.bullet == .autoNumber(scheme: "arabicPeriod", startAt: 1))
        #expect(paragraph.lineSpacing == .percent(1.5))
        #expect(paragraph.level == 1)
        #expect(paragraph.marginLeft == 342_900 + 457_200)
        #expect(paragraph.indent == -342_900)
    }
}

@Suite("Tables")
@MainActor
struct TableEditingTests {
    private func reread(_ presentation: Presentation) throws -> Presentation {
        try PPTXReader.presentation(from: PPTXWriter.data(from: presentation))
    }

    @Test("A new table is written, with its cell text, and grows a row")
    func newTable() throws {
        var presentation = Presentation.blank
        let state = EditorState()
        state.selectSlide(presentation.slides[0].id)
        state.insertTable(rows: 2, columns: 3, in: &presentation)
        state.selectCell(TableCellPosition(row: 1, column: 2), editing: true)
        state.setCellText(TextBody(paragraphs: [Paragraph(runs: [TextRun(text: "42")])]), in: &presentation)
        state.changeTable(.rowBelow, in: &presentation)

        let copy = try reread(presentation)
        guard case .table(let table) = try #require(copy.slides[0].shapes.last).kind else {
            Issue.record("Expected a table")
            return
        }
        #expect(table.rows.count == 3)
        #expect(table.columnCount == 3)
        #expect(table.rows[1].cells[2].text?.plainText == "42")
        #expect(table.rows[2].cells[2].text?.plainText == "")
        #expect(table.hasHeaderRow)
        #expect(table.styleID == "{5C22544A-7EE6-4342-B048-85BDC9FD1C3A}")
        #expect(copy.slides[0].shapes.last?.frame.height == table.gridSize.height)
    }

    @Test("Rows added inside a merge widen it; deleting its first row hands it on")
    func merges() {
        var table = SlideTable.empty(rows: 3, columns: 2, width: 200, height: 300)
        table.rows[0].cells[0].rowSpan = 2
        table.rows[1].cells[0].isVerticalMerge = true
        table.rows[0].cells[0].text = TextBody(paragraphs: [Paragraph(runs: [TextRun(text: "Merged")])])

        table.insertRow(at: 1, copying: 0)
        #expect(table.rows[0].cells[0].rowSpan == 3)
        #expect(table.rows[1].cells[0].isVerticalMerge)

        table.deleteRow(at: 0)
        #expect(table.rows[0].cells[0].rowSpan == 2)
        #expect(!table.rows[0].cells[0].isVerticalMerge)
        #expect(table.rows[0].cells[0].text?.plainText == "Merged")
        #expect(table.anchor(of: TableCellPosition(row: 1, column: 0)) == TableCellPosition(row: 0, column: 0))
    }

    @Test("An edited table read from a file keeps what Dazzle does not model")
    func preservesSource() throws {
        var presentation = Presentation.blank
        let state = EditorState()
        state.selectSlide(presentation.slides[0].id)
        state.insertTable(rows: 2, columns: 2, in: &presentation)
        var copy = try reread(presentation)
        let reopened = EditorState()
        reopened.selectSlide(copy.slides[0].id)
        reopened.selectedShapeID = copy.slides[0].shapes.last?.id
        reopened.selectCell(TableCellPosition(row: 0, column: 0))
        reopened.setCellFill(.solid(.rgb(0xFF0000)), in: &copy)
        reopened.changeTable(.columnRight, in: &copy)
        let final = try reread(copy)
        guard case .table(let table) = try #require(final.slides[0].shapes.last).kind else {
            Issue.record("Expected a table")
            return
        }
        #expect(table.columnCount == 3)
        #expect(table.rows[0].cells[0].fill == .solid(.rgb(0xFF0000)))
        #expect(table.rows[0].cells[1].fill == .solid(.rgb(0xFF0000)))
    }
}

@Suite("Pictures")
@MainActor
struct PictureEditingTests {
    @Test("Crops, replaced images and descriptions are written and read back")
    func cropReplaceDescribe() throws {
        var presentation = Presentation.blank
        let state = EditorState()
        state.selectSlide(presentation.slides[0].id)
        let png = try #require(SlideExporter.image(of: presentation.slides[0], in: presentation, width: 40, format: .png))
        state.insertPicture(PreparedMedia(png: png, size: CGSize(width: 40, height: 20)), in: &presentation)
        let id = try #require(state.selectedShapeID)
        state.setCrop(frame: CGRect(x: 10, y: 10, width: 20, height: 20), left: 0.25, top: 0, right: 0.25, bottom: 0, of: id, in: &presentation)
        state.setAltText("A chart of sales", in: &presentation)

        var copy = try PPTXReader.presentation(from: PPTXWriter.data(from: presentation))
        let shape = try #require(copy.slides[0].shapes.last)
        guard case .picture(let picture) = shape.kind else {
            Issue.record("Expected a picture")
            return
        }
        #expect(picture.cropLeft == 0.25 && picture.cropRight == 0.25)
        #expect(shape.altText == "A chart of sales")
        #expect(SlideShape.Picture.imageRect(frame: shape.frame.points, picture: picture).width == 40)

        let reopened = EditorState()
        reopened.selectSlide(copy.slides[0].id)
        reopened.selectedShapeID = shape.id
        reopened.replacePicture(with: PreparedMedia(png: png, size: CGSize(width: 10, height: 10)), in: &copy)
        let final = try PPTXReader.presentation(from: PPTXWriter.data(from: copy))
        guard case .picture(let replaced) = try #require(final.slides[0].shapes.last).kind else {
            Issue.record("Expected a picture")
            return
        }
        #expect(replaced.cropLeft == 0)
        #expect(replaced.imagePath != picture.imagePath)
        #expect(final.data(at: replaced.imagePath ?? "") == png)
    }
}

@Suite("Fills")
@MainActor
struct FillTests {
    @Test("Picture and gradient fills are written for shapes and backgrounds")
    func pictureAndGradient() throws {
        var presentation = Presentation.blank
        let state = EditorState()
        state.selectSlide(presentation.slides[0].id)
        let png = try #require(SlideExporter.image(of: presentation.slides[0], in: presentation, width: 16, format: .png))
        state.insertShape("rect", in: &presentation)
        state.setFillPicture(PreparedMedia(png: png, size: CGSize(width: 16, height: 9)), tiled: true, in: &presentation)
        let gradient = Fill.Gradient(
            stops: [.init(position: 0, color: .rgb(0xFF0000)), .init(position: 1, color: .rgb(0x0000FF))], angle: 45, isRadial: false
        )
        state.setBackground(.gradient(gradient), in: &presentation)

        let copy = try PPTXReader.presentation(from: PPTXWriter.data(from: presentation))
        guard case .tiledPicture(let path, _)? = copy.slides[0].shapes.last?.fill else {
            Issue.record("Expected a tiled picture fill")
            return
        }
        #expect(copy.data(at: path) == png)
        #expect(copy.slides[0].background == .fill(.gradient(gradient)))

        var withPicture = copy
        let reopened = EditorState()
        reopened.selectSlide(withPicture.slides[0].id)
        reopened.setBackgroundPicture(PreparedMedia(png: png, size: CGSize(width: 16, height: 9)), tiled: false, in: &withPicture)
        let final = try PPTXReader.presentation(from: PPTXWriter.data(from: withPicture))
        guard case .fill(.picture(let backgroundPath, _))? = final.slides[0].background else {
            Issue.record("Expected a picture background")
            return
        }
        #expect(final.data(at: backgroundPath) == png)
    }
}

@Suite("Outlines")
@MainActor
struct OutlineTests {
    @Test("Dashes and arrowheads are written where the schema wants them")
    func dashAndArrows() throws {
        var presentation = Presentation.blank
        let state = EditorState()
        state.selectSlide(presentation.slides[0].id)
        state.insertShape("line", in: &presentation)
        state.setLine({ $0.dash = "sysDot"; $0.tail = "triangle"; $0.head = "oval" }, in: &presentation)
        let copy = try PPTXReader.presentation(from: PPTXWriter.data(from: presentation))
        let line = try #require(copy.slides[0].shapes.last?.line)
        #expect(line.dash == "sysDot")
        #expect(line.head == "oval")
        #expect(line.tail == "triangle")
        let source = try #require(copy.slides[0].shapes.last?.source)
        let order = ["solidFill", "prstDash", "headEnd", "tailEnd"].compactMap { source.range(of: $0)?.lowerBound }
        #expect(order == order.sorted() && order.count == 4)
    }
}

@Suite("Shadows")
@MainActor
struct ShadowTests {
    @Test("Shadows are written, read back, and fall the way they point")
    func shadow() throws {
        var presentation = Presentation.blank
        let state = EditorState()
        state.selectSlide(presentation.slides[0].id)
        state.insertShape("rect", in: &presentation)
        let id = try #require(state.selectedShapeID)
        state.setFrame(CGRect(x: 400, y: 200, width: 100, height: 100), of: id, in: &presentation)
        state.setFill(.solid(.rgb(0xFFFFFF)), in: &presentation)
        state.setLine({ $0.fill = Fill.none }, in: &presentation)
        let shadow = Shadow(blur: 0, distance: 254_000, direction: 90, color: .rgb(0x000000))
        state.setShadow(shadow, in: &presentation)
        let copy = try PPTXReader.presentation(from: PPTXWriter.data(from: presentation))
        #expect(copy.slides[0].shapes.last?.shadow == shadow)

        // A 20pt shadow straight down: dark just below the shape, not above it.
        var slide = copy.slides[0]
        slide.shapes = [try #require(slide.shapes.last)]
        let image = try #require(SlideExporter.cgImage(of: slide, in: copy, width: 960))
        let data = try #require(image.dataProvider?.data as Data?)
        func brightness(x: Int, y: Int) -> Int {
            let offset = y * image.bytesPerRow + x * 4
            return Int(data[offset])
        }
        #expect(brightness(x: 450, y: 310) < 100)
        #expect(brightness(x: 450, y: 190) > 200)

        // Drawn by SwiftUI, as on screen, it falls the same way.
        let renderer = ImageRenderer(content: SlideView(presentation: copy, slide: slide).frame(width: 960, height: 540))
        renderer.scale = 1
        let screen = try #require(renderer.cgImage)
        let context = try #require(CGContext(
            data: nil, width: screen.width, height: screen.height, bitsPerComponent: 8, bytesPerRow: screen.width * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.draw(screen, in: CGRect(x: 0, y: 0, width: screen.width, height: screen.height))
        let pixels = try #require(context.data).assumingMemoryBound(to: UInt8.self)
        // Rows run from the top in the context's memory.
        func screenBrightness(x: Int, y: Int) -> Int { Int(pixels[(y * screen.width + x) * 4]) }
        #expect(screenBrightness(x: 450, y: 310) < 100)
        #expect(screenBrightness(x: 450, y: 190) > 200)
    }
}

@Suite("Find and replace")
struct FindReplaceTests {
    @Test("Matches respect case and whole words")
    func query() {
        #expect(FindQuery(text: "cat").ranges(in: "Cat concatenate cat").count == 3)
        #expect(FindQuery(text: "cat", matchesCase: true).ranges(in: "Cat concatenate cat").count == 2)
        #expect(FindQuery(text: "cat", matchesWholeWords: true).ranges(in: "Cat concatenate cat").count == 2)
    }

    @Test("Replacing keeps the formatting of the text replaced, everywhere it is")
    func replaceAll() throws {
        var presentation = Presentation.blank
        var bold = RunProperties()
        bold.isBold = true
        presentation.slides[0].shapes[0].text = TextBody(paragraphs: [
            Paragraph(runs: [TextRun(text: "Sales in "), TextRun(text: "2025", properties: bold), TextRun(text: " grew")]),
        ])
        presentation.slides[0].notes = "Mention 2025 targets."
        let matches = presentation.matches(for: FindQuery(text: "2025"))
        #expect(matches.count == 2)
        presentation.replace(matches, with: "2026")

        let copy = try PPTXReader.presentation(from: PPTXWriter.data(from: presentation))
        let runs = try #require(copy.slides[0].shapes[0].text?.paragraphs.first?.runs)
        #expect(runs.map(\.text) == ["Sales in ", "2026", " grew"])
        #expect(runs[1].properties.isBold == true)
        #expect(copy.slides[0].notes == "Mention 2026 targets.")
    }
}

@Suite("Slide size")
struct SlideSizeTests {
    @Test("Going to 4:3 scales layouts, slides and text to fit, centred")
    func toStandard() throws {
        var presentation = Presentation.blank
        presentation.slides[0].shapes[0].frame = EMURect(x: 0, y: 0, width: 12_192_000, height: 1_000_000)
        presentation.slides[0].shapes[0].hasOwnFrame = true
        presentation.slides[0].shapes[0].edits.insert(.transform)
        presentation.slides[0].isModified = true
        let converted = try SlideSizeConverter.convert(presentation, to: .standard, scaling: .ensureFit)
        #expect(converted.slideSize == SlideSizeConverter.Preset.standard.size)
        let factor = 9_144_000.0 / 12_192_000.0
        let title = converted.slides[0].shapes[0]
        #expect(title.frame.width == 9_144_000)
        #expect(title.frame.x == 0)
        #expect(abs(Double(title.frame.y) - (6_858_000 - 6_858_000 * factor) / 2) < 2)

        // The subtitle has no frame of its own; it follows its scaled layout.
        let layout = try #require(converted.layout(for: converted.slides[0]))
        let subtitle = converted.slides[0].shapes[1]
        #expect(subtitle.frame == layout.shapes.first { $0.placeholder?.type == "subTitle" }?.frame)

        let style = SlideStyleContext(presentation: converted, slide: converted.slides[0])
        let size = style.paragraphBase(for: title, sources: style.sources(for: title), level: 0).defaultRun.size
        #expect(size == Int((6_000 * factor).rounded()))
    }
}

@Suite("Charts")
@MainActor
struct ChartTests {
    private func reread(_ presentation: Presentation) throws -> Presentation {
        try PPTXReader.presentation(from: PPTXWriter.data(from: presentation))
    }

    @Test("A new chart is written with its data and a workbook, and reads back")
    func insert() throws {
        var presentation = Presentation.blank
        let state = EditorState()
        state.selectSlide(presentation.slides[0].id)
        state.insertChart(.column, in: &presentation)
        let copy = try reread(presentation)
        guard case .chart(let chart?) = try #require(copy.slides[0].shapes.last).kind else {
            Issue.record("Expected a chart")
            return
        }
        #expect(chart.kind == .column)
        #expect(chart.categories.count == 4)
        #expect(chart.allSeries.map { $0.values.first ?? nil } == [4.3, 2.4, 2])
        #expect(copy.unsupportedFeatures.isEmpty)
        let workbook = try #require(ChartWriter.workbookPath(of: chart, in: copy))
        let sheet = try ZipArchive.entries(in: try #require(copy.data(at: workbook)))["xl/worksheets/sheet1.xml"]
        #expect(String(decoding: try #require(sheet), as: UTF8.self).contains("<v>4.3</v>"))
    }

    @Test("Editing values, type, title and legend is written to the chart's part")
    func edit() throws {
        var presentation = Presentation.blank
        let state = EditorState()
        state.selectSlide(presentation.slides[0].id)
        state.insertChart(.column, in: &presentation)
        var copy = try reread(presentation)
        let reopened = EditorState()
        reopened.selectSlide(copy.slides[0].id)
        reopened.selectedShapeID = copy.slides[0].shapes.last?.id
        reopened.updateChart(in: &copy) { chart in
            chart.plots[0].series[1].values[2] = 9
            chart.categories.append("Extra")
            for index in chart.plots[0].series.indices { chart.plots[0].series[index].values.append(1) }
            chart.plots[0].grouping = .stacked
            chart.plots[0].kind = .bar
            chart.title = "Quarterly"
            chart.legendPosition = "r"
        }
        let final = try reread(copy)
        guard case .chart(let chart?) = try #require(final.slides[0].shapes.last).kind else {
            Issue.record("Expected a chart")
            return
        }
        #expect(chart.kind == .bar)
        #expect(chart.plots[0].grouping == .stacked)
        #expect(chart.categories.last == "Extra")
        #expect(chart.allSeries[1].values[2] == 9)
        #expect(chart.title == "Quarterly")
        #expect(chart.legendPosition == "r")

        reopened.selectedShapeID = final.slides[0].shapes.last?.id
        var pie = final
        reopened.selectSlide(pie.slides[0].id)
        reopened.selectedShapeID = pie.slides[0].shapes.last?.id
        reopened.updateChart(in: &pie) { $0.plots = [Chart.Plot(kind: .pie, series: [$0.allSeries[0]])] }
        guard case .chart(let pieChart?) = try #require(try reread(pie).slides[0].shapes.last).kind else {
            Issue.record("Expected a chart")
            return
        }
        #expect(pieChart.kind == .pie)
        #expect(pieChart.allSeries.count == 1)
    }

    @Test("Value axes round to steps of 1, 2 or 5")
    func scale() {
        let scale = ChartRenderer.Scale.nice(low: 0, high: 4.5)
        #expect(scale.minimum == 0 && scale.maximum == 5 && scale.step == 1)
        #expect(ChartWriter.columnLetter(28) == "AB")
    }

    @Test("Charts render", arguments: Chart.Kind.allCases)
    func render(kind: Chart.Kind) throws {
        var presentation = Presentation.blank
        let state = EditorState()
        state.selectSlide(presentation.slides[0].id)
        state.insertChart(kind, in: &presentation)
        let png = try #require(SlideExporter.image(of: presentation.slides[0], in: presentation, width: 960, format: .png))
        #expect(png.starts(with: [0x89, 0x50, 0x4E, 0x47]))
    }
}

@Suite("Comments")
@MainActor
struct CommentTests {
    private func reread(_ presentation: Presentation) throws -> Presentation {
        try PPTXReader.presentation(from: PPTXWriter.data(from: presentation))
    }

    @Test("New comments and their replies are written in the format every app reads")
    func legacy() throws {
        var presentation = Presentation.blank
        let state = EditorState()
        state.selectSlide(presentation.slides[0].id)
        state.addComment("Is this the final figure?", author: "Ada Lovelace", at: CGPoint(x: 100, y: 50), in: &presentation)
        let thread = try #require(presentation.slides[0].comments.first)
        state.reply(to: thread.id, with: "Yes, signed off.", author: "Charles Babbage", in: &presentation)

        let copy = try reread(presentation)
        let read = try #require(copy.slides[0].comments.first)
        #expect(copy.slides[0].comments.count == 1)
        #expect(read.text == "Is this the final figure?")
        #expect(read.author == "Ada Lovelace" && read.initials == "AL")
        #expect(read.position == CGPoint(x: 100, y: 50))
        #expect(read.replies.map(\.text) == ["Yes, signed off."])
        #expect(read.replies.first?.author == "Charles Babbage")
        #expect(copy.commentAuthors.count == 2)

        // Deleting the thread takes the part away.
        var edited = copy
        let reopened = EditorState()
        reopened.selectSlide(edited.slides[0].id)
        reopened.deleteComment(read.id, in: &edited)
        let final = try reread(edited)
        #expect(final.slides[0].comments.isEmpty)
        #expect(!final.package.parts.keys.contains { $0.hasPrefix("ppt/comments/") })
    }

    @Test("PowerPoint 365's threaded comments are read, replied to and resolved")
    func modern() throws {
        var parts = PresentationTemplate.parts()
        let author = "{11111111-2222-3333-4444-555555555555}"
        parts["ppt/authors.xml"] = Data("""
            <p188:authorLst xmlns:p188="\(CommentXML.modernNamespace)"><p188:author id="\(author)" name="Grace Hopper" \
            initials="GH" userId="grace" providerId="None"/></p188:authorLst>
            """.utf8)
        parts["ppt/comments/modernComment_1.xml"] = Data("""
            <p188:cmLst xmlns:a="\(OOXML.drawingML)" xmlns:p188="\(CommentXML.modernNamespace)"><p188:cm id="{A}" \
            authorId="\(author)" created="2025-01-02T03:04:05.000"><pc:sldMkLst \
            xmlns:pc="http://schemas.microsoft.com/office/powerpoint/2013/main/command"><pc:docMk/><pc:sldMk cId="1" sldId="256"/>\
            </pc:sldMkLst><p188:txBody><a:bodyPr/><a:lstStyle/><a:p><a:r><a:t>Tighten this</a:t></a:r></a:p></p188:txBody>\
            </p188:cm></p188:cmLst>
            """.utf8)
        let slideRels = "ppt/slides/_rels/slide1.xml.rels"
        var relationships = Relationship.parse(parts[slideRels])
        relationships.append(Relationship(id: "rId99", type: OOXML.RelationshipType.modernComments, target: "../comments/modernComment_1.xml"))
        parts[slideRels] = Relationship.xml(relationships)
        var main = Relationship.parse(parts["ppt/_rels/presentation.xml.rels"])
        main.append(Relationship(id: "rId99", type: OOXML.RelationshipType.authors, target: "authors.xml"))
        parts["ppt/_rels/presentation.xml.rels"] = Relationship.xml(main)

        var presentation = try PPTXReader.presentation(fromParts: parts)
        let thread = try #require(presentation.slides[0].comments.first)
        #expect(thread.format == .modern)
        #expect(thread.author == "Grace Hopper")
        #expect(thread.text == "Tighten this")

        let state = EditorState()
        state.selectSlide(presentation.slides[0].id)
        state.reply(to: thread.id, with: "Done.", author: "Ada Lovelace", in: &presentation)
        state.setCommentResolved(thread.id, true, in: &presentation)
        state.addComment("Another", author: "Ada Lovelace", in: &presentation)

        let copy = try reread(presentation)
        #expect(copy.slides[0].comments.count == 2)
        let read = try #require(copy.slides[0].comments.first)
        #expect(read.isResolved)
        #expect(read.replies.first?.text == "Done.")
        #expect(read.replies.first?.author == "Ada Lovelace")
        #expect(copy.slides[0].comments.allSatisfy { $0.format == .modern })
        // The new comment is anchored to the slide as the old one is.
        let written = String(decoding: try #require(copy.data(at: "ppt/comments/modernComment_1.xml")), as: UTF8.self)
        #expect(written.components(separatedBy: "sldMkLst").count - 1 == 4)
    }
}

@Suite("Header and footer")
@MainActor
struct HeaderFooterTests {
    @Test("Slide numbers, dates and footers go in the layout's placeholders, and come off again")
    func apply() throws {
        var presentation = Presentation.blank
        let state = EditorState()
        let layout = try #require(presentation.resources.orderedLayouts.first { $0.name == "Title and Content" })
        state.selectSlide(presentation.slides[0].id)
        state.addSlide(using: layout, in: &presentation)
        var settings = HeaderFooterSettings()
        settings.showsSlideNumber = true
        settings.showsFooter = true
        settings.footer = "Confidential"
        settings.showsDate = true
        settings.hidesOnTitleSlide = true
        state.applyHeaderFooter(settings, toAll: true, in: &presentation)

        let copy = try PPTXReader.presentation(from: PPTXWriter.data(from: presentation))
        #expect(!copy.slides[0].shapes.contains { $0.placeholder?.isFurniture == true })
        let reread = HeaderFooterSettings(slide: copy.slides[1])
        #expect(reread.showsSlideNumber && reread.showsFooter && reread.showsDate && reread.updatesDate)
        #expect(reread.footer == "Confidential")
        let number = try #require(copy.slides[1].shapes.first { $0.placeholder?.type == "sldNum" })
        let template = layout.shapes.first { $0.placeholder?.type == "sldNum" }
            ?? copy.resources.master(for: layout)?.shapes.first { $0.placeholder?.type == "sldNum" }
        #expect(number.frame == template?.frame)

        var off = copy
        let reopened = EditorState()
        reopened.selectSlide(off.slides[1].id)
        reopened.applyHeaderFooter(HeaderFooterSettings(), toAll: false, in: &off)
        #expect(!off.slides[1].shapes.contains { $0.placeholder?.isFurniture == true })
    }

    @Test("Date fields show today's date")
    func dateField() {
        let date = Date(timeIntervalSince1970: 1_767_225_600)
        #expect(DateField.datetime1.string(for: date, locale: Locale(identifier: "en_US")).contains("2026"))
    }
}

@Suite("Export")
struct ExportTests {
    @Test("Notes pages and handouts lay slides out on paper")
    func pageLayouts() throws {
        var presentation = Presentation.blank
        presentation.slides[0].notes = "Remember to thank the team."
        let slides = Array(repeating: presentation.slides[0], count: 7)
        for (layout, pages) in [(SlideExporter.PageLayout.notes, 7), (.handouts(perPage: 3), 3), (.handouts(perPage: 9), 1)] {
            let data = SlideExporter.pdf(of: slides, in: presentation, title: "Test", layout: layout)
            let document = try #require(CGPDFDocument(CGDataProvider(data: data as CFData)!))
            #expect(document.numberOfPages == pages)
            #expect(document.page(at: 1)?.getBoxRect(.mediaBox).size == SlideExporter.paperSize)
        }
    }

    @Test("Slides make a movie of the right length")
    func video() async throws {
        let presentation = Presentation.blank
        let url = FileManager.default.temporaryDirectory.appending(path: "dazzle-test.mp4")
        try await VideoExporter.export(
            presentation.slides + presentation.slides, of: presentation, width: 320, durations: [1, 2], to: url
        ) { _ in }
        let asset = AVURLAsset(url: url)
        let duration = try await asset.load(.duration).seconds
        #expect(abs(duration - 3) < 0.1)
    }
}

@Suite("Hyperlinks")
@MainActor
struct HyperlinkTests {
    @Test("Links on shapes and on text are written and read back, to the web and to slides")
    func roundTrip() throws {
        var presentation = Presentation.blank
        let state = EditorState()
        state.selectSlide(presentation.slides[0].id)
        let layout = try #require(presentation.resources.orderedLayouts.last)
        state.addSlide(using: layout, in: &presentation)
        let second = presentation.slides[1].id
        state.selectSlide(presentation.slides[0].id)
        state.insertShape("rect", in: &presentation)
        state.setShapeLink(.url("https://example.com"), in: &presentation)
        state.insertTextBox(in: &presentation)
        state.setText("Go to the end", in: &presentation)
        state.endEditingText()
        state.setTextLink(.slide(second), in: &presentation)

        let copy = try PPTXReader.presentation(from: PPTXWriter.data(from: presentation))
        let shapes = copy.slides[0].shapes
        #expect(shapes[shapes.count - 2].link == .url("https://example.com"))
        let run = try #require(shapes.last?.text?.paragraphs.first?.runs.first)
        #expect(run.properties.link == .slide(copy.slides[1].id))
    }

    @Test("Linked text can be found where it is drawn, and a session follows it")
    func follow() throws {
        var presentation = Presentation.blank
        let state = EditorState()
        state.selectSlide(presentation.slides[0].id)
        let layout = try #require(presentation.resources.orderedLayouts.last)
        state.addSlide(using: layout, in: &presentation)
        state.selectSlide(presentation.slides[0].id)
        state.insertTextBox(in: &presentation)
        state.setText("Next", in: &presentation)
        state.endEditingText()
        state.setTextLink(.nextSlide, in: &presentation)
        let box = try #require(presentation.slides[0].shapes.last)

        let areas = SlideRenderer(presentation: presentation, slide: presentation.slides[0]).linkAreas()
        let area = try #require(areas.first)
        #expect(area.1 == .nextSlide)
        #expect(box.frame.points.contains(CGPoint(x: area.0.midX, y: area.0.midY)))

        let session = PresentationSession()
        session.start(presentation, title: "Test", fromSlide: 0, owner: UUID())
        let link = try #require(session.link(at: CGPoint(x: area.0.midX, y: area.0.midY)))
        _ = session.follow(link)
        #expect(session.position == 1)
        session.end()
    }
}

@Suite("Media")
@MainActor
struct MediaTests {
    @Test("An inserted video is saved as PowerPoint embeds one, plays, and can start by itself")
    func video() async throws {
        let blank = Presentation.blank
        let source = FileManager.default.temporaryDirectory.appending(path: "dazzle-source.mp4")
        try await VideoExporter.export(blank.slides, of: blank, width: 320, durations: [1], to: source) { _ in }
        let video = try await PreparedVideo.prepare(from: source)

        var presentation = Presentation.blank
        let state = EditorState()
        state.selectSlide(presentation.slides[0].id)
        state.insertVideo(video, in: &presentation)
        let data = try PPTXWriter.data(from: presentation)
        let copy = try PPTXReader.presentation(from: data)
        let shape = try #require(copy.slides[0].shapes.last)
        guard case .picture(let picture) = shape.kind, let media = picture.media, let path = media.path else {
            Issue.record("Expected a video")
            return
        }
        #expect(media.kind == .video)
        #expect(copy.data(at: path) == video.data)
        #expect(copy.unsupportedFeatures.isEmpty)

        let playback = MediaPlayback()
        playback.show(copy.slides[0], in: copy)
        #expect(playback.players[shape.id] != nil)
        #expect(!playback.isPlaying(shape.id))
        playback.stopAll()

        // A play command that runs after the slide starts makes it start by itself.
        var parts = try ZipArchive.entries(in: data)
        let slidePath = try #require(copy.slides[0].partName)
        var xml = String(decoding: try #require(parts[slidePath]), as: UTF8.self)
        xml = xml.replacingOccurrences(of: "</p:sld>", with: """
            <p:timing><p:tnLst><p:par><p:cTn id="1" nodeType="tmRoot"><p:childTnLst><p:par><p:cTn id="2" \
            nodeType="afterEffect" presetClass="mediacall"><p:childTnLst><p:cmd type="call" cmd="playFrom(0.0)"><p:cBhvr>\
            <p:cTn id="3" dur="1"/><p:tgtEl><p:spTgt spid="\(shape.shapeID)"/></p:tgtEl></p:cBhvr></p:cmd></p:childTnLst>\
            </p:cTn></p:par></p:childTnLst></p:cTn></p:par></p:tnLst></p:timing></p:sld>
            """)
        parts[slidePath] = Data(xml.utf8)
        let timed = try PPTXReader.presentation(fromParts: parts)
        guard case .picture(let timedPicture) = try #require(timed.slides[0].shapes.last).kind else {
            Issue.record("Expected a picture")
            return
        }
        #expect(timedPicture.media?.playsAutomatically == true)
    }
}

@Suite("Advancing")
@MainActor
struct AdvanceTests {
    @Test("Slide timings and looping are written and read back")
    func roundTrip() throws {
        var presentation = Presentation.blank
        let state = EditorState()
        state.selectSlide(presentation.slides[0].id)
        state.setAutoAdvance(2.5, in: &presentation)
        state.setAdvancesOnClick(false, in: &presentation)
        state.setLoopsSlideshow(true, in: &presentation)
        let copy = try PPTXReader.presentation(from: PPTXWriter.data(from: presentation))
        #expect(copy.slides[0].autoAdvanceAfter == 2.5)
        #expect(!copy.slides[0].advancesOnClick)
        #expect(copy.loopsSlideshow)
    }

    @Test("A timed slide moves on by itself, and a looping show starts over")
    func advances() async throws {
        var presentation = Presentation.blank
        let state = EditorState()
        state.selectSlide(presentation.slides[0].id)
        let layout = try #require(presentation.resources.orderedLayouts.last)
        state.addSlide(using: layout, in: &presentation)
        state.setAutoAdvance(0.2, toAll: true, in: &presentation)
        state.setLoopsSlideshow(true, in: &presentation)
        let session = PresentationSession()
        session.start(presentation, title: "Test", fromSlide: 0, owner: UUID())
        try await Task.sleep(for: .milliseconds(350))
        #expect(session.position == 1)
        try await Task.sleep(for: .milliseconds(250))
        #expect(session.position == 0)
        #expect(session.isPresenting)
        session.end()
    }
}
