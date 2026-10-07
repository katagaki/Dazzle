import CoreGraphics
import CoreText
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Renders slides to PDF and to pictures.
enum SlideExporter {
    enum ImageFormat: String, CaseIterable, Identifiable, Sendable {
        case png
        case jpeg

        var id: Self { self }
        var fileExtension: String { rawValue == "jpeg" ? "jpg" : rawValue }
        var contentType: UTType { self == .png ? .png : .jpeg }
    }

    /// One slide as a picture `width` pixels wide.
    static func image(
        of slide: Slide, in presentation: Presentation, width: Int, format: ImageFormat, quality: Double = 0.9
    ) -> Data? {
        guard let image = cgImage(of: slide, in: presentation, width: width, opaque: true) else { return nil }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            data, format.contentType.identifier as CFString, 1, nil
        ) else { return nil }
        let properties: [CFString: Any] = format == .jpeg ? [kCGImageDestinationLossyCompressionQuality: quality] : [:]
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
    }

    /// Some of a slide's shapes alone, on transparency, cropped to them: what
    /// is put on the pasteboard for other apps when shapes are copied.
    static func png(of shapes: [SlideShape], on slide: Slide, in presentation: Presentation, scale: CGFloat = 2) -> Data? {
        let bounds = shapes.map(\.boundingBox).reduce(CGRect.null) { $0.union($1) }
            .intersection(CGRect(origin: .zero, size: presentation.slideSize.points))
        guard !bounds.isNull, bounds.width >= 1, bounds.height >= 1 else { return nil }
        var alone = slide
        alone.shapes = shapes
        var options = SlideRenderer.Options.presentation
        options.drawsBackground = false
        let width = Int((presentation.slideSize.points.width * scale).rounded())
        guard let image = cgImage(of: alone, in: presentation, width: width, opaque: false, options: options),
              let cropped = image.cropping(to: CGRect(
                x: bounds.minX * scale, y: bounds.minY * scale, width: bounds.width * scale, height: bounds.height * scale
              ).integral) else { return nil }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else {
            return nil
        }
        CGImageDestinationAddImage(destination, cropped, nil)
        return CGImageDestinationFinalize(destination) ? data as Data : nil
    }

    static func cgImage(
        of slide: Slide, in presentation: Presentation, width: Int, opaque: Bool = true,
        options: SlideRenderer.Options = .presentation
    ) -> CGImage? {
        let aspect = presentation.slideSize.aspectRatio
        let height = max(Int((Double(width) / aspect).rounded()), 1)
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                bitmapInfo: opaque ? CGImageAlphaInfo.noneSkipLast.rawValue : CGImageAlphaInfo.premultipliedLast.rawValue
              ) else { return nil }
        // Bitmap contexts count y upwards; slides are drawn downwards.
        context.translateBy(x: 0, y: CGFloat(height))
        context.scaleBy(x: 1, y: -1)
        SlideRenderer(presentation: presentation, slide: slide, options: options)
            .draw(in: context, size: CGSize(width: width, height: height))
        return context.makeImage()
    }

    /// How slides are laid out on paper.
    enum PageLayout: Hashable, Sendable {
        /// A page each, at the slide's own size.
        case slides
        /// A page each: the slide above, its speaker notes below.
        case notes
        /// Several slides to a page, for the audience to take away.
        case handouts(perPage: Int)

        static let handoutCounts = [1, 2, 3, 4, 6, 9]
    }

    /// Paper for notes and handouts: A4 where the metric system is used, Letter elsewhere.
    static var paperSize: CGSize {
        Locale.current.measurementSystem == .us ? CGSize(width: 612, height: 792) : CGSize(width: 595, height: 842)
    }

    static func pdf(of slides: [Slide], in presentation: Presentation, title: String, layout: PageLayout) -> Data {
        switch layout {
        case .slides: pdf(of: slides, in: presentation, title: title)
        case .notes: notesPDF(of: slides, in: presentation, title: title)
        case .handouts(let count): handoutPDF(of: slides, in: presentation, title: title, perPage: count)
        }
    }

    /// Draws pages of paper size, each by `draw`, which is given the
    /// context, in a y-down space, and the page's number.
    private static func paperPDF(title: String, pages: Int, draw: (CGContext, Int) -> Void) -> Data {
        let data = NSMutableData()
        var mediaBox = CGRect(origin: .zero, size: paperSize)
        let info: [CFString: Any] = [kCGPDFContextTitle: title, kCGPDFContextCreator: "Dazzle"]
        guard let consumer = CGDataConsumer(data: data),
              let context = CGContext(consumer: consumer, mediaBox: &mediaBox, info as CFDictionary) else { return Data() }
        for page in 0..<pages {
            context.beginPDFPage(nil)
            context.saveGState()
            context.setFillColor(RGBAColor.white.cgColor)
            context.fill(mediaBox)
            context.translateBy(x: 0, y: mediaBox.height)
            context.scaleBy(x: 1, y: -1)
            draw(context, page)
            drawText(String(page + 1), in: CGRect(x: 0, y: mediaBox.height - 30, width: mediaBox.width, height: 14),
                     size: 9, alignment: .center, color: RGBAColor(red: 0.45, green: 0.45, blue: 0.45), context: context)
            context.restoreGState()
            context.endPDFPage()
        }
        context.closePDF()
        return data as Data
    }

    /// A slide drawn into `rect` with a hairline round it.
    private static func drawSlide(_ slide: Slide, in presentation: Presentation, rect: CGRect, context: CGContext) {
        context.saveGState()
        context.translateBy(x: rect.minX, y: rect.minY)
        SlideRenderer(presentation: presentation, slide: slide).draw(in: context, size: rect.size)
        context.restoreGState()
        context.setStrokeColor(RGBAColor(red: 0.6, green: 0.6, blue: 0.6).cgColor)
        context.setLineWidth(0.5)
        context.stroke(rect)
    }

    /// The largest slide-shaped rectangle that fits in `box`, centred.
    private static func fitted(_ presentation: Presentation, in box: CGRect) -> CGRect {
        let aspect = presentation.slideSize.aspectRatio
        var size = CGSize(width: box.width, height: box.width / aspect)
        if size.height > box.height { size = CGSize(width: box.height * aspect, height: box.height) }
        return CGRect(x: box.midX - size.width / 2, y: box.midY - size.height / 2, width: size.width, height: size.height)
    }

    private static func notesPDF(of slides: [Slide], in presentation: Presentation, title: String) -> Data {
        paperPDF(title: title, pages: slides.count) { context, page in
            let paper = paperSize
            let margin: CGFloat = 54
            let slideBox = CGRect(x: margin, y: margin, width: paper.width - margin * 2, height: paper.height * 0.42)
            let slideRect = fitted(presentation, in: slideBox)
            drawSlide(slides[page], in: presentation, rect: slideRect, context: context)
            let notesRect = CGRect(
                x: margin, y: slideRect.maxY + 28, width: paper.width - margin * 2, height: paper.height - slideRect.maxY - 28 - margin
            )
            drawParagraphs(slides[page].notes, in: notesRect, size: 12, context: context)
        }
    }

    private static func handoutPDF(of slides: [Slide], in presentation: Presentation, title: String, perPage: Int) -> Data {
        let count = max(perPage, 1)
        let pages = Int((Double(slides.count) / Double(count)).rounded(.up))
        // Columns and rows for each count; three to a page leave room to write beside them.
        let grid: (columns: Int, rows: Int) = switch count {
        case 1: (1, 1)
        case 2: (1, 2)
        case 3: (1, 3)
        case 4: (2, 2)
        case 6: (2, 3)
        default: (3, 3)
        }
        return paperPDF(title: title, pages: max(pages, 1)) { context, page in
            let paper = paperSize
            let margin: CGFloat = 40
            let area = CGRect(x: margin, y: margin, width: paper.width - margin * 2, height: paper.height - margin * 2 - 24)
            let slideArea = count == 3 ? CGRect(x: area.minX, y: area.minY, width: area.width * 0.5, height: area.height) : area
            let cell = CGSize(width: slideArea.width / CGFloat(grid.columns), height: slideArea.height / CGFloat(grid.rows))
            for position in 0..<count {
                let index = page * count + position
                guard slides.indices.contains(index) else { break }
                let column = position % grid.columns
                let row = position / grid.columns
                let box = CGRect(
                    x: slideArea.minX + CGFloat(column) * cell.width, y: slideArea.minY + CGFloat(row) * cell.height,
                    width: cell.width, height: cell.height
                ).insetBy(dx: 10, dy: 10)
                let rect = fitted(presentation, in: box)
                drawSlide(slides[index], in: presentation, rect: rect, context: context)
                if count == 3 {
                    // Lines to write notes on, beside the slide.
                    context.setStrokeColor(RGBAColor(red: 0.75, green: 0.75, blue: 0.75).cgColor)
                    context.setLineWidth(0.5)
                    var y = rect.minY + 18
                    while y < rect.maxY {
                        context.move(to: CGPoint(x: area.midX + 16, y: y))
                        context.addLine(to: CGPoint(x: area.maxX, y: y))
                        y += 18
                    }
                    context.strokePath()
                }
            }
        }
    }

    // MARK: - Text on paper

    private static func attributes(size: CGFloat, color: RGBAColor) -> [NSAttributedString.Key: Any] {
        [
            NSAttributedString.Key(kCTFontAttributeName as String): FontResolver.shared.font(family: nil, size: size, bold: false, italic: false),
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): color.cgColor,
        ]
    }

    private static func drawText(
        _ text: String, in rect: CGRect, size: CGFloat, alignment: CTTextAlignment, color: RGBAColor, context: CGContext
    ) {
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attributes(size: size, color: color)))
        let width = CTLineGetBoundsWithOptions(line, []).width
        let x = alignment == .center ? rect.midX - width / 2 : rect.minX
        context.saveGState()
        context.textMatrix = CGAffineTransform(scaleX: 1, y: -1)
        context.textPosition = CGPoint(x: x, y: rect.maxY - 3)
        CTLineDraw(line, context)
        context.restoreGState()
    }

    /// Wrapped text from the top of `rect` down, cut off at its bottom.
    private static func drawParagraphs(_ text: String, in rect: CGRect, size: CGFloat, context: CGContext) {
        guard !text.isEmpty, rect.height > 0 else { return }
        let string = NSAttributedString(string: text, attributes: attributes(size: size, color: .black))
        let framesetter = CTFramesetterCreateWithAttributedString(string)
        let frame = CTFramesetterCreateFrame(
            framesetter, CFRange(location: 0, length: 0), CGPath(rect: CGRect(origin: .zero, size: rect.size), transform: nil), nil
        )
        context.saveGState()
        context.translateBy(x: rect.minX, y: rect.maxY)
        context.scaleBy(x: 1, y: -1)
        context.textMatrix = .identity
        CTFrameDraw(frame, context)
        context.restoreGState()
    }

    /// The slides as a PDF, a page each, at the slide's own size.
    static func pdf(of slides: [Slide], in presentation: Presentation, title: String) -> Data {
        let data = NSMutableData()
        var mediaBox = CGRect(origin: .zero, size: presentation.slideSize.points)
        let info: [CFString: Any] = [kCGPDFContextTitle: title, kCGPDFContextCreator: "Dazzle"]
        guard let consumer = CGDataConsumer(data: data),
              let context = CGContext(consumer: consumer, mediaBox: &mediaBox, info as CFDictionary) else { return Data() }
        for slide in slides {
            context.beginPDFPage(nil)
            context.translateBy(x: 0, y: mediaBox.height)
            context.scaleBy(x: 1, y: -1)
            SlideRenderer(presentation: presentation, slide: slide).draw(in: context, size: mediaBox.size)
            context.endPDFPage()
        }
        context.closePDF()
        return data as Data
    }
}
