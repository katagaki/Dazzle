import CoreGraphics
import CoreText
import Foundation

/// Draws slides with CoreGraphics, for every place a slide appears: the
/// editor, thumbnails, the slideshow, an external display, and exports.
struct SlideRenderer {
    struct Options: Sendable {
        /// Show "Tap to add title" in empty placeholders, as the editor does.
        var showsPlaceholderPrompts = false
        /// Leave this shape out, while it is being edited somewhere else.
        var hiddenShapeID: SlideShape.ID?

        static let presentation = Options()
        static let editing = Options(showsPlaceholderPrompts: true)
    }

    let presentation: Presentation
    let slide: Slide
    var options = Options.presentation

    private var style: SlideStyleContext { SlideStyleContext(presentation: presentation, slide: slide) }

    private var slideNumber: Int { (presentation.index(of: slide.id) ?? 0) + 1 }

    /// Draws the slide filling `size`, in a context whose y axis points down.
    func draw(in context: CGContext, size: CGSize) {
        let slideSize = presentation.slideSize.points
        guard slideSize.width > 0, slideSize.height > 0 else { return }
        let style = style
        context.saveGState()
        context.scaleBy(x: size.width / slideSize.width, y: size.height / slideSize.height)
        let bounds = CGRect(origin: .zero, size: slideSize)
        context.clip(to: bounds)

        let background = style.background(of: slide)
        context.setFillColor(RGBAColor.white.cgColor)
        context.fill(bounds)
        paint(background.fill, in: CGPath(rect: bounds, transform: nil), bounds: bounds,
              placeholderColor: background.placeholderColor, style: style, context: context)

        // Master and layout artwork sits under the slide's own shapes.
        // Their placeholders are only templates, so are not drawn.
        if slide.showsMasterShapes {
            if style.layout?.showsMasterShapes ?? true {
                for shape in style.master?.shapes ?? [] where shape.placeholder == nil {
                    draw(shape, sources: [], style: style, context: context)
                }
            }
            for shape in style.layout?.shapes ?? [] where shape.placeholder == nil {
                draw(shape, sources: [], style: style, context: context)
            }
        }
        for shape in slide.shapes where shape.id != options.hiddenShapeID {
            draw(shape, sources: style.sources(for: shape), style: style, context: context)
        }
        context.restoreGState()
    }

    // MARK: - Shapes

    private func draw(
        _ shape: SlideShape, sources: [SlideShape], style: SlideStyleContext, context: CGContext,
        groupFill: SlideStyleContext.ResolvedFill? = nil
    ) {
        let frame = shape.frame.points
        context.saveGState()
        defer { context.restoreGState() }
        if shape.rotation != 0 || shape.flipsHorizontally || shape.flipsVertically {
            context.translateBy(x: frame.midX, y: frame.midY)
            context.rotate(by: shape.rotation * .pi / 180)
            context.scaleBy(x: shape.flipsHorizontally ? -1 : 1, y: shape.flipsVertically ? -1 : 1)
            context.translateBy(x: -frame.midX, y: -frame.midY)
        }

        switch shape.kind {
        case .group(let group):
            let child = group.childFrame.points
            context.translateBy(x: frame.minX, y: frame.minY)
            context.scaleBy(
                x: child.width > 0 ? frame.width / child.width : 1,
                y: child.height > 0 ? frame.height / child.height : 1
            )
            context.translateBy(x: -child.minX, y: -child.minY)
            let fill = style.fill(for: shape, sources: [])
            for member in group.children {
                draw(member, sources: [], style: style, context: context, groupFill: fill ?? groupFill)
            }
        case .diagram(let shapes):
            for member in shapes {
                draw(member, sources: [], style: style, context: context)
            }
        case .picture(let picture):
            drawPicture(picture, shape: shape, frame: frame, style: style, context: context)
        case .table(let table):
            drawTable(table, shape: shape, frame: frame, style: style, context: context)
        case .chart:
            drawStandIn(String(localized: "Object.Chart"), frame: frame, context: context, isChart: true)
        case .unsupported(let label):
            if frame.width > 0, frame.height > 0 {
                drawStandIn(label, frame: frame, context: context, isChart: false)
            }
        case .shape, .connector:
            drawAutoShape(shape, sources: sources, frame: frame, style: style, context: context, groupFill: groupFill)
        }
    }

    private func outline(of shape: SlideShape, in frame: CGRect) -> (fill: CGPath, stroke: CGPath, isOpen: Bool) {
        switch shape.geometry {
        case .preset(let name, let adjustments):
            let path = PresetGeometry.path(name, adjustments: adjustments, in: frame)
            return (path, path, PresetGeometry.isOpen(name) || shape.kind == .connector)
        case .custom(let paths):
            let (fill, stroke) = PresetGeometry.path(paths, in: frame)
            return (fill, stroke, false)
        }
    }

    private func drawAutoShape(
        _ shape: SlideShape, sources: [SlideShape], frame: CGRect, style: SlideStyleContext, context: CGContext,
        groupFill: SlideStyleContext.ResolvedFill?
    ) {
        let (fillPath, strokePath, isOpen) = outline(of: shape, in: frame)
        if !isOpen, var fill = style.fill(for: shape, sources: sources) {
            if fill.fill == .group, let groupFill { fill = groupFill }
            paint(fill.fill, in: fillPath, bounds: frame, placeholderColor: fill.placeholderColor, style: style, context: context)
        }
        if let (line, placeholderColor) = style.line(for: shape, sources: sources) {
            stroke(strokePath, line: line, placeholderColor: placeholderColor, style: style, context: context)
        }

        let textFrame = shape.textFrame?.points ?? shape.geometry.presetName.map {
            PresetGeometry.textRect($0, adjustments: shape.geometry.adjustments, in: frame)
        } ?? frame
        let renderer = TextRenderer(style: style, slideNumber: slideNumber)
        if let text = shape.text, !text.isEmpty {
            renderer.draw(text, shape: shape, sources: sources, in: textFrame, context: context)
        } else if options.showsPlaceholderPrompts, let placeholder = shape.placeholder, !placeholder.isFurniture {
            drawPrompt(for: shape, placeholder: placeholder, sources: sources, frame: textFrame, renderer: renderer, context: context)
        }
    }

    /// An empty placeholder, in the editor: a dashed outline and a prompt.
    private func drawPrompt(
        for shape: SlideShape, placeholder: Placeholder, sources: [SlideShape], frame: CGRect,
        renderer: TextRenderer, context: CGContext
    ) {
        context.saveGState()
        context.setStrokeColor(RGBAColor(red: 0.55, green: 0.55, blue: 0.58, alpha: 0.8).cgColor)
        context.setLineWidth(1)
        context.setLineDash(phase: 0, lengths: [4, 3])
        context.stroke(frame)
        context.restoreGState()

        let prompt = switch placeholder.type {
        case "title", "ctrTitle": String(localized: "Placeholder.Title")
        case "subTitle": String(localized: "Placeholder.Subtitle")
        case "pic": String(localized: "Placeholder.Picture")
        default: String(localized: "Placeholder.Text")
        }
        var body = shape.text ?? TextBody(paragraphs: [])
        let paragraph = body.paragraphs.first ?? Paragraph(runs: [])
        var run = TextRun(text: prompt, properties: paragraph.endProperties ?? RunProperties())
        run.kind = .text
        body.paragraphs = [Paragraph(properties: paragraph.properties, runs: [run])]
        renderer.draw(
            body, shape: shape, sources: sources, in: frame, context: context,
            colorOverride: RGBAColor(red: 0.55, green: 0.55, blue: 0.58)
        )
    }

    // MARK: - Fills and lines

    private func paint(
        _ fill: Fill, in path: CGPath, bounds: CGRect, placeholderColor: RGBAColor?,
        style: SlideStyleContext, context: CGContext
    ) {
        switch fill {
        case .none, .group:
            return
        case .solid(let color):
            context.addPath(path)
            context.setFillColor(style.color(color, placeholder: placeholderColor).cgColor)
            context.fillPath(using: .evenOdd)
        case .gradient(let gradient):
            let colors = gradient.stops.map { style.color($0.color, placeholder: placeholderColor).cgColor } as CFArray
            let locations = gradient.stops.map { CGFloat($0.position) }
            guard let cgGradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: colors, locations: locations) else { return }
            context.saveGState()
            context.addPath(path)
            context.clip(using: .evenOdd)
            if gradient.isRadial {
                let radius = hypot(bounds.width, bounds.height) / 2
                context.drawRadialGradient(
                    cgGradient, startCenter: CGPoint(x: bounds.midX, y: bounds.midY), startRadius: 0,
                    endCenter: CGPoint(x: bounds.midX, y: bounds.midY), endRadius: radius,
                    options: [.drawsAfterEndLocation]
                )
            } else {
                let angle = gradient.angle * .pi / 180
                let half = (abs(cos(angle)) * bounds.width + abs(sin(angle)) * bounds.height) / 2
                let center = CGPoint(x: bounds.midX, y: bounds.midY)
                let delta = CGPoint(x: cos(angle) * half, y: sin(angle) * half)
                context.drawLinearGradient(
                    cgGradient, start: CGPoint(x: center.x - delta.x, y: center.y - delta.y),
                    end: CGPoint(x: center.x + delta.x, y: center.y + delta.y),
                    options: [.drawsBeforeStartLocation, .drawsAfterEndLocation]
                )
            }
            context.restoreGState()
        case .picture(let imagePath):
            guard let data = presentation.data(at: imagePath),
                  let image = ImageCache.shared.image(for: data, path: imagePath) else { return }
            context.saveGState()
            context.addPath(path)
            context.clip(using: .evenOdd)
            drawImage(image, in: bounds, context: context)
            context.restoreGState()
        }
    }

    private func stroke(
        _ path: CGPath, line: LineStyle, placeholderColor: RGBAColor?, style: SlideStyleContext, context: CGContext
    ) {
        guard case .solid(let color) = line.fill ?? .none else { return }
        let width = max(EMU.points(line.width ?? 9_525), 0.25)
        let resolved = style.color(color, placeholder: placeholderColor)
        context.saveGState()
        context.setStrokeColor(resolved.cgColor)
        context.setLineWidth(width)
        context.setLineJoin(.round)
        switch line.dash {
        case "dash", "lgDash", "sysDash": context.setLineDash(phase: 0, lengths: [width * 4, width * 3])
        case "dot", "sysDot": context.setLineDash(phase: 0, lengths: [width, width * 2])
        case "dashDot", "lgDashDot", "sysDashDot": context.setLineDash(phase: 0, lengths: [width * 4, width * 2, width, width * 2])
        default: break
        }
        context.addPath(path)
        context.strokePath()
        context.restoreGState()

        // Arrowheads, at either end of an open line.
        guard line.head != nil || line.tail != nil else { return }
        let points = endpoints(of: path)
        guard let points else { return }
        context.saveGState()
        context.setFillColor(resolved.cgColor)
        if line.tail != nil { arrowhead(at: points.end, from: points.beforeEnd, width: width, context: context) }
        if line.head != nil { arrowhead(at: points.start, from: points.afterStart, width: width, context: context) }
        context.restoreGState()
    }

    private func endpoints(of path: CGPath) -> (start: CGPoint, afterStart: CGPoint, beforeEnd: CGPoint, end: CGPoint)? {
        var points: [CGPoint] = []
        path.applyWithBlock { element in
            let element = element.pointee
            switch element.type {
            case .moveToPoint, .addLineToPoint: points.append(element.points[0])
            case .addQuadCurveToPoint: points += [element.points[0], element.points[1]]
            case .addCurveToPoint: points += [element.points[0], element.points[1], element.points[2]]
            default: break
            }
        }
        guard points.count >= 2 else { return nil }
        return (points[0], points[1], points[points.count - 2], points[points.count - 1])
    }

    private func arrowhead(at tip: CGPoint, from tail: CGPoint, width: CGFloat, context: CGContext) {
        let angle = atan2(tip.y - tail.y, tip.x - tail.x)
        let length = max(width * 4, 6)
        let spread: CGFloat = .pi / 7
        context.move(to: tip)
        context.addLine(to: CGPoint(x: tip.x - length * cos(angle - spread), y: tip.y - length * sin(angle - spread)))
        context.addLine(to: CGPoint(x: tip.x - length * cos(angle + spread), y: tip.y - length * sin(angle + spread)))
        context.closePath()
        context.fillPath()
    }

    // MARK: - Pictures

    private func drawPicture(
        _ picture: SlideShape.Picture, shape: SlideShape, frame: CGRect, style: SlideStyleContext, context: CGContext
    ) {
        guard let path = picture.imagePath, let data = presentation.data(at: path),
              var image = ImageCache.shared.image(for: data, path: path) else {
            drawStandIn(String(localized: "Object.Picture"), frame: frame, context: context, isChart: false)
            return
        }
        let width = CGFloat(image.width)
        let height = CGFloat(image.height)
        let crop = CGRect(
            x: width * max(picture.cropLeft, 0), y: height * max(picture.cropTop, 0),
            width: width * (1 - max(picture.cropLeft, 0) - max(picture.cropRight, 0)),
            height: height * (1 - max(picture.cropTop, 0) - max(picture.cropBottom, 0))
        ).integral
        if crop.width > 0, crop.height > 0, crop.size != CGSize(width: width, height: height),
           let cropped = image.cropping(to: crop) {
            image = cropped
        }
        let (outlinePath, _, _) = outline(of: shape, in: frame)
        context.saveGState()
        context.addPath(outlinePath)
        context.clip()
        drawImage(image, in: frame, context: context)
        context.restoreGState()
        if let (line, placeholderColor) = style.line(for: shape, sources: []) {
            stroke(outlinePath, line: line, placeholderColor: placeholderColor, style: style, context: context)
        }
    }

    /// CoreGraphics draws images bottom-up; the slide is drawn top-down.
    private func drawImage(_ image: CGImage, in rect: CGRect, context: CGContext) {
        context.saveGState()
        context.translateBy(x: 0, y: rect.minY + rect.maxY)
        context.scaleBy(x: 1, y: -1)
        context.interpolationQuality = .high
        context.draw(image, in: rect)
        context.restoreGState()
    }

    // MARK: - Tables

    private func drawTable(_ table: SlideTable, shape: SlideShape, frame: CGRect, style: SlideStyleContext, context: CGContext) {
        let widths = table.columnWidths.map { CGFloat(EMU.points($0)) }
        var columnStarts: [CGFloat] = [frame.minX]
        for width in widths { columnStarts.append((columnStarts.last ?? frame.minX) + width) }
        var rowStarts: [CGFloat] = [frame.minY]
        for row in table.rows { rowStarts.append((rowStarts.last ?? frame.minY) + CGFloat(EMU.points(row.height))) }

        let renderer = TextRenderer(style: style, slideNumber: slideNumber)
        let accent = style.color(.scheme("accent1"))
        for (rowIndex, row) in table.rows.enumerated() {
            for (columnIndex, cell) in row.cells.enumerated() where !cell.isMerged && columnIndex < widths.count {
                let lastColumn = min(columnIndex + cell.columnSpan, widths.count)
                let lastRow = min(rowIndex + cell.rowSpan, table.rows.count)
                let rect = CGRect(
                    x: columnStarts[columnIndex], y: rowStarts[rowIndex],
                    width: columnStarts[lastColumn] - columnStarts[columnIndex],
                    height: rowStarts[lastRow] - rowStarts[rowIndex]
                )
                // Without the table style itself, draw PowerPoint's default
                // look: an accent header, then banded tints of it.
                let isHeader = table.hasHeaderRow && rowIndex == 0
                let fallback: RGBAColor = isHeader ? accent
                    : (table.hasBandedRows && (rowIndex - (table.hasHeaderRow ? 1 : 0)).isMultiple(of: 2)
                        ? accent.applying(.init(name: "tint", value: 40_000))
                        : accent.applying(.init(name: "tint", value: 20_000)))
                if let fill = cell.fill {
                    paint(fill, in: CGPath(rect: rect, transform: nil), bounds: rect, placeholderColor: nil, style: style, context: context)
                } else {
                    context.setFillColor(fallback.cgColor)
                    context.fill(rect)
                }
                context.setStrokeColor(RGBAColor.white.cgColor)
                context.setLineWidth(1)
                context.stroke(rect)

                guard var body = cell.text, !body.isEmpty else { continue }
                if body.properties.anchor == nil { body.properties.anchor = cell.anchor }
                if isHeader, cell.fill == nil {
                    body.updateRuns { run in
                        if run.isBold == nil { run.isBold = true }
                        if run.color == nil { run.color = .scheme("lt1") }
                    }
                }
                var cellShape = SlideShape(shapeID: 0, name: "", kind: .shape, frame: EMURect(points: rect))
                cellShape.text = body
                renderer.draw(body, shape: cellShape, sources: [], in: rect, context: context)
            }
        }
    }

    // MARK: - Stand-ins

    /// What is drawn in place of something Dazzle keeps but cannot show.
    private func drawStandIn(_ label: String, frame: CGRect, context: CGContext, isChart: Bool) {
        context.saveGState()
        let path = CGPath(roundedRect: frame, cornerWidth: 8, cornerHeight: 8, transform: nil)
        context.addPath(path)
        context.setFillColor(RGBAColor(red: 0.5, green: 0.5, blue: 0.55, alpha: 0.12).cgColor)
        context.fillPath()
        context.addPath(path)
        context.setStrokeColor(RGBAColor(red: 0.5, green: 0.5, blue: 0.55, alpha: 0.4).cgColor)
        context.setLineWidth(1)
        context.strokePath()

        let glyph = min(frame.width, frame.height) * 0.28
        if isChart, glyph > 8 {
            // Three bars, the universal sign for "a chart was here".
            let barWidth = glyph / 4
            let base = CGPoint(x: frame.midX - glyph / 2, y: frame.midY + glyph / 2)
            context.setFillColor(RGBAColor(red: 0.5, green: 0.5, blue: 0.55, alpha: 0.55).cgColor)
            for (index, height) in [0.5, 1.0, 0.75].enumerated() {
                context.fill(CGRect(
                    x: base.x + CGFloat(index) * barWidth * 1.5, y: base.y - glyph * height,
                    width: barWidth, height: glyph * height
                ))
            }
        }
        context.restoreGState()

        let fontSize = max(min(frame.height * 0.08, 18), 7)
        let font = FontResolver.shared.font(family: nil, size: fontSize, bold: false, italic: false)
        let string = NSAttributedString(string: label, attributes: [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): RGBAColor(red: 0.4, green: 0.4, blue: 0.45).cgColor,
        ])
        let line = CTLineCreateWithAttributedString(string)
        let bounds = CTLineGetBoundsWithOptions(line, [])
        let y = isChart && glyph > 8 ? frame.midY + glyph / 2 + fontSize * 1.4 : frame.midY + fontSize / 3
        context.saveGState()
        context.textMatrix = CGAffineTransform(scaleX: 1, y: -1)
        context.textPosition = CGPoint(x: frame.midX - bounds.width / 2, y: y)
        CTLineDraw(line, context)
        context.restoreGState()
    }
}
