import CoreGraphics
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
