import CoreGraphics
import Foundation
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
