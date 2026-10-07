import Foundation

/// Reads the shapes of one part — a slide, layout, master or SmartArt
/// drawing — into `SlideShape`s.
final class ShapeParser {
    let partPath: String
    let relationships: [Relationship]
    /// Namespace bindings in scope at the shape tree, so a shape's captured
    /// XML need not repeat them.
    let namespaces: [String: String]
    /// Where placeholders without a frame of their own find one: the
    /// layout's shapes, then the master's.
    let inheritedShapes: [[SlideShape]]
    let parts: [String: Data]
    /// Whether to keep each top-level shape's XML for writing back. Only a
    /// slide's shapes are ever written.
    let capturesSource: Bool

    private(set) var features: Set<UnsupportedFeatureReport.Feature> = []
    /// Set when a shape's XML could not be captured, which means the part
    /// has to be written back exactly as it was read.
    private(set) var hasUncapturableShape = false

    init(
        partPath: String, relationships: [Relationship], namespaces: [String: String],
        inheritedShapes: [[SlideShape]] = [], parts: [String: Data], capturesSource: Bool = false
    ) {
        self.partPath = partPath
        self.relationships = relationships
        self.namespaces = namespaces
        self.inheritedShapes = inheritedShapes
        self.parts = parts
        self.capturesSource = capturesSource
    }

    /// The package path a relationship id points to, unless it points outside the package.
    func target(of relationshipID: String) -> String? {
        guard let relationship = relationships.first(where: { $0.id == relationshipID }),
              !relationship.isExternal else { return nil }
        return PackagePath.resolve(relationship.target, from: partPath)
    }

    // MARK: - Shape trees

    func shapes(in tree: XMLElement?) -> [SlideShape] {
        guard let tree else { return [] }
        return tree.children.compactMap { element in
            guard var shape = shape(from: element) else { return nil }
            shape.altText = Self.description(of: element)
            if capturesSource {
                if let source = XMLLite.serialize(element, inheritedNamespaces: namespaces) {
                    shape.source = source
                } else {
                    hasUncapturableShape = true
                }
            }
            return shape
        }
    }

    private func shape(from element: XMLElement) -> SlideShape? {
        switch element.name {
        case "sp": return autoShape(element, connector: false)
        case "cxnSp": return autoShape(element, connector: true)
        case "pic": return picture(element)
        case "grpSp": return group(element)
        case "graphicFrame": return graphicFrame(element)
        case "AlternateContent":
            // Two renditions of one thing for different readers. The fallback
            // is the one every reader understands; it is drawn, and the whole
            // is kept as it was.
            let fallback = element.firstChild(named: "Fallback")?.children.first
                ?? element.firstChild(named: "Choice")?.children.first
            guard let fallback, var shape = shape(from: fallback) else { return nil }
            shape.isLocked = true
            return shape
        case "contentPart":
            features.insert(.embeddedObjects)
            return SlideShape(
                shapeID: 0, name: "Ink", kind: .unsupported(String(localized: "Object.Ink")), frame: .zero
            )
        default:
            return nil
        }
    }

    // MARK: - Shapes

    /// A shape's `descr`, looking inside an alternative's rendition if need be.
    private static func description(of element: XMLElement) -> String? {
        let shape = element.name == "AlternateContent"
            ? (element.firstChild(named: "Fallback") ?? element.firstChild(named: "Choice"))?.children.first
            : element
        return shape?.children.first { $0.name.hasPrefix("nv") }?.firstChild(named: "cNvPr")?.attribute("descr")?.nilIfEmpty
    }

    private func nonVisualProperties(_ element: XMLElement) -> (id: Int, name: String, nv: XMLElement?) {
        let nonVisual = element.children.first { $0.name.hasPrefix("nv") }
        let common = nonVisual?.firstChild(named: "cNvPr")
        return (common?.attribute("id").flatMap(Int.init) ?? 0, common?.attribute("name") ?? "", nonVisual)
    }

    private func autoShape(_ element: XMLElement, connector: Bool) -> SlideShape {
        let (id, name, nonVisual) = nonVisualProperties(element)
        let placeholder = Placeholder(element: nonVisual?.firstChild(named: "nvPr")?.firstChild(named: "ph"))
        let properties = element.firstChild(named: "spPr")
        var shape = SlideShape(shapeID: id, name: name, kind: connector ? .connector : .shape, frame: .zero)
        shape.placeholder = placeholder
        shape.isTextBox = nonVisual?.firstChild(named: "cNvSpPr")?.attribute("txBox") == "1"
        applyTransform(properties?.firstChild(named: "xfrm"), to: &shape)
        shape.geometry = geometry(in: properties)
        shape.fill = Fill.parse(in: properties, image: target(of:))
        shape.line = properties?.firstChild(named: "ln").map(LineStyle.init(element:))
        shape.shadow = Shadow(element: properties?.firstChild(named: "effectLst")?.firstChild(named: "outerShdw"))
        shape.style = StyleReferences(element: element.firstChild(named: "style"))
        shape.text = element.firstChild(named: "txBody").map(textBody)
        if let textTransform = element.firstChild(named: "txXfrm") {
            var holder = SlideShape(shapeID: 0, name: "", kind: .shape, frame: .zero)
            applyTransform(textTransform, to: &holder)
            shape.textFrame = holder.frame
        }
        inheritFrame(&shape)
        return shape
    }

    private func picture(_ element: XMLElement) -> SlideShape {
        let (id, name, nonVisual) = nonVisualProperties(element)
        let blipFill = element.firstChild(named: "blipFill")
        var picture = SlideShape.Picture()
        if let reference = blipFill?.firstChild(named: "blip")?.attribute("embed") {
            picture.imagePath = target(of: reference)
        }
        picture.effects = BlipEffects(blip: blipFill?.firstChild(named: "blip"))
        if let crop = blipFill?.firstChild(named: "srcRect") {
            func fraction(_ key: String) -> Double { Double(crop.attribute(key).flatMap(Int.init) ?? 0) / 100_000 }
            picture.cropLeft = fraction("l")
            picture.cropTop = fraction("t")
            picture.cropRight = fraction("r")
            picture.cropBottom = fraction("b")
        }
        let details = nonVisual?.firstChild(named: "nvPr")
        if let details, details.firstChild(named: "videoFile") != nil || details.firstChild(named: "audioFile") != nil
            || details.firstChild(named: "extLst")?.children.contains(where: { $0.firstChild(named: "media") != nil }) == true {
            features.insert(.media)
        }
        let properties = element.firstChild(named: "spPr")
        var shape = SlideShape(shapeID: id, name: name, kind: .picture(picture), frame: .zero)
        shape.placeholder = Placeholder(element: details?.firstChild(named: "ph"))
        applyTransform(properties?.firstChild(named: "xfrm"), to: &shape)
        shape.geometry = geometry(in: properties)
        shape.line = properties?.firstChild(named: "ln").map(LineStyle.init(element:))
        shape.shadow = Shadow(element: properties?.firstChild(named: "effectLst")?.firstChild(named: "outerShdw"))
        inheritFrame(&shape)
        return shape
    }

    private func group(_ element: XMLElement) -> SlideShape {
        let (id, name, _) = nonVisualProperties(element)
        let transform = element.firstChild(named: "grpSpPr")?.firstChild(named: "xfrm")
        // Members keep their own XML too, so that ungrouping can write
        // each back on its own.
        let children = ShapeParser(
            partPath: partPath, relationships: relationships, namespaces: namespaces,
            inheritedShapes: inheritedShapes, parts: parts, capturesSource: capturesSource
        )
        let shapes = children.shapes(in: element)
        features.formUnion(children.features)
        if children.hasUncapturableShape { hasUncapturableShape = true }
        var childFrame = EMURect.zero
        if let offset = transform?.firstChild(named: "chOff"), let extent = transform?.firstChild(named: "chExt") {
            childFrame = EMURect(
                x: offset.attribute("x").flatMap(Int.init) ?? 0, y: offset.attribute("y").flatMap(Int.init) ?? 0,
                width: extent.attribute("cx").flatMap(Int.init) ?? 0, height: extent.attribute("cy").flatMap(Int.init) ?? 0
            )
        }
        var shape = SlideShape(
            shapeID: id, name: name, kind: .group(SlideShape.ShapeGroup(childFrame: childFrame, children: shapes)),
            frame: .zero
        )
        applyTransform(transform, to: &shape)
        if childFrame == .zero, case .group(var group) = shape.kind {
            group.childFrame = shape.frame
            shape.kind = .group(group)
        }
        return shape
    }

    private func graphicFrame(_ element: XMLElement) -> SlideShape {
        let (id, name, nonVisual) = nonVisualProperties(element)
        let data = element.firstChild(named: "graphic")?.firstChild(named: "graphicData")
        let uri = data?.attribute("uri") ?? ""
        var shape = SlideShape(
            shapeID: id, name: name, kind: .unsupported(String(localized: "Object.Embedded")), frame: .zero
        )
        shape.placeholder = Placeholder(element: nonVisual?.firstChild(named: "nvPr")?.firstChild(named: "ph"))
        applyTransform(element.firstChild(named: "xfrm"), to: &shape)
        inheritFrame(&shape)

        if let table = data?.firstChild(named: "tbl") {
            shape.kind = .table(self.table(table))
        } else if uri.hasSuffix("/chart") || uri.contains("chartex") {
            let path = data?.children.first { $0.name == "chart" }?.relationshipID.flatMap(target(of:))
            let chart = path.flatMap { Chart(path: $0, data: parts[$0]) }
            // Charts Dazzle cannot read, such as Office 2016's newer kinds, are kept and shown as a stand-in.
            if chart == nil { features.insert(.charts) }
            shape.kind = .chart(chart)
        } else if uri.hasSuffix("/diagram") {
            shape.kind = diagram(data, frame: shape.frame) ?? .unsupported(String(localized: "Object.SmartArt"))
        } else if uri.hasSuffix("/ole") {
            features.insert(.embeddedObjects)
            // An embedded object usually carries a picture of itself.
            let object = data?.firstChild(named: "oleObj")
                ?? data?.firstChild(named: "AlternateContent")?.firstChild(named: "Fallback")?.firstChild(named: "oleObj")
            if let preview = object?.firstChild(named: "pic"), case .picture(let picture) = self.picture(preview).kind {
                shape.kind = .picture(picture)
            }
        } else {
            features.insert(.embeddedObjects)
        }
        return shape
    }

    /// SmartArt keeps a drawing of itself in a part of its own, reached
    /// through the data part's extension.
    private func diagram(_ data: XMLElement?, frame: EMURect) -> SlideShape.Kind? {
        guard let dataReference = data?.firstChild(named: "relIds")?.attribute("dm"),
              let dataPath = target(of: dataReference),
              let dataPart = parts[dataPath], let model = try? XMLLite.parse(dataPart) else { return nil }
        func findDrawingReference(_ element: XMLElement) -> String? {
            if element.name == "dataModelExt", let id = element.attribute("relId") { return id }
            for child in element.children {
                if let found = findDrawingReference(child) { return found }
            }
            return nil
        }
        let drawingPath = findDrawingReference(model).flatMap(target(of:))
            ?? relationships.first { $0.type == OOXML.RelationshipType.diagramDrawing }
                .map { PackagePath.resolve($0.target, from: partPath) }
        guard let drawingPath, let drawingPart = parts[drawingPath],
              let drawing = try? XMLLite.parse(drawingPart) else { return nil }
        let drawingParser = ShapeParser(
            partPath: drawingPath, relationships: Relationship.parse(parts[PackagePath.relationships(of: drawingPath)]),
            namespaces: [:], parts: parts
        )
        // The drawing's coordinates start at the frame's corner.
        let shapes = drawingParser.shapes(in: drawing.firstChild(named: "spTree")).map { shape in
            var moved = shape
            moved.frame.x += frame.x
            moved.frame.y += frame.y
            if var text = moved.textFrame {
                text.x += frame.x
                text.y += frame.y
                moved.textFrame = text
            }
            return moved
        }
        // A drawing with nothing in it is a diagram only its layout engine
        // could draw; leave it to the stand-in, which at least says so.
        return shapes.isEmpty ? nil : .diagram(shapes)
    }

    private func table(_ element: XMLElement) -> SlideTable {
        let properties = element.firstChild(named: "tblPr")
        let widths = element.firstChild(named: "tblGrid")?.children(named: "gridCol")
            .map { $0.attribute("w").flatMap(Int.init) ?? 0 } ?? []
        let rows = element.children(named: "tr").map { row in
            SlideTable.Row(
                height: row.attribute("h").flatMap(Int.init) ?? 0,
                cells: row.children(named: "tc").map { cell in
                    let cellProperties = cell.firstChild(named: "tcPr")
                    func margin(_ key: String) -> Int? { cellProperties?.attribute(key).flatMap(Int.init) }
                    func border(_ name: String) -> LineStyle? {
                        cellProperties?.firstChild(named: name).map(LineStyle.init(element:))
                    }
                    return SlideTable.Cell(
                        text: cell.firstChild(named: "txBody").map(textBody),
                        fill: Fill.parse(in: cellProperties, image: target(of:)),
                        columnSpan: cell.attribute("gridSpan").flatMap(Int.init) ?? 1,
                        rowSpan: cell.attribute("rowSpan").flatMap(Int.init) ?? 1,
                        isHorizontalMerge: cell.attribute("hMerge") == "1",
                        isVerticalMerge: cell.attribute("vMerge") == "1",
                        anchor: cellProperties?.attribute("anchor").flatMap(BodyProperties.Anchor.init(rawValue:)),
                        marginLeft: margin("marL"), marginRight: margin("marR"),
                        marginTop: margin("marT"), marginBottom: margin("marB"),
                        borderLeft: border("lnL"), borderRight: border("lnR"),
                        borderTop: border("lnT"), borderBottom: border("lnB"),
                        sourceProperties: cellProperties.flatMap(capture),
                        sourceBody: cell.firstChild(named: "txBody").flatMap(capture)
                    )
                }
            )
        }
        return SlideTable(
            columnWidths: widths, rows: rows,
            hasHeaderRow: properties?.attribute("firstRow") == "1",
            hasBandedRows: properties?.attribute("bandRow") == "1",
            styleID: properties?.firstChild(named: "tableStyleId")?.text.trimmed.nilIfEmpty,
            sourceProperties: properties.flatMap(capture)
        )
    }

    // MARK: - Transforms and geometry

    private func applyTransform(_ transform: XMLElement?, to shape: inout SlideShape) {
        guard let transform else {
            shape.hasOwnFrame = false
            return
        }
        let offset = transform.firstChild(named: "off")
        let extent = transform.firstChild(named: "ext")
        shape.frame = EMURect(
            x: offset?.attribute("x").flatMap(Int.init) ?? 0, y: offset?.attribute("y").flatMap(Int.init) ?? 0,
            width: extent?.attribute("cx").flatMap(Int.init) ?? 0, height: extent?.attribute("cy").flatMap(Int.init) ?? 0
        )
        shape.hasOwnFrame = offset != nil || extent != nil
        shape.rotation = Double(transform.attribute("rot").flatMap(Int.init) ?? 0) / 60_000
        shape.flipsHorizontally = transform.attribute("flipH") == "1"
        shape.flipsVertically = transform.attribute("flipV") == "1"
    }

    /// A placeholder that does not say where it goes goes where its layout's does.
    private func inheritFrame(_ shape: inout SlideShape) {
        guard !shape.hasOwnFrame, let placeholder = shape.placeholder else { return }
        for (level, shapes) in inheritedShapes.enumerated() {
            let source = level == 0 && inheritedShapes.count > 1
                ? shapes.inheritedPlaceholder(for: placeholder)
                : shapes.masterPlaceholder(for: placeholder)
            if let source {
                shape.frame = source.frame
                return
            }
        }
    }

    private func geometry(in properties: XMLElement?) -> ShapeGeometry {
        if let preset = properties?.firstChild(named: "prstGeom") {
            var adjustments: [String: Int] = [:]
            for guide in preset.firstChild(named: "avLst")?.children(named: "gd") ?? [] {
                if let name = guide.attribute("name"), let formula = guide.attribute("fmla"), formula.hasPrefix("val ") {
                    adjustments[name] = Int(String(formula.dropFirst(4)).trimmed)
                }
            }
            return .preset(preset.attribute("prst") ?? "rect", adjustments: adjustments)
        }
        if let custom = properties?.firstChild(named: "custGeom") {
            let paths = custom.firstChild(named: "pathLst")?.children(named: "path").map(customPath) ?? []
            return .custom(paths)
        }
        return .preset("rect", adjustments: [:])
    }

    private func customPath(_ path: XMLElement) -> ShapeGeometry.CustomPath {
        func value(_ element: XMLElement?, _ key: String) -> Double {
            Double(element?.attribute(key) ?? "") ?? 0
        }
        func point(_ element: XMLElement, _ index: Int) -> (Double, Double) {
            let points = element.children(named: "pt")
            guard points.indices.contains(index) else { return (0, 0) }
            return (value(points[index], "x"), value(points[index], "y"))
        }
        let commands: [ShapeGeometry.CustomPath.Command] = path.children.compactMap { command in
            switch command.name {
            case "moveTo":
                let (x, y) = point(command, 0)
                return .move(x, y)
            case "lnTo":
                let (x, y) = point(command, 0)
                return .line(x, y)
            case "cubicBezTo":
                let (x1, y1) = point(command, 0)
                let (x2, y2) = point(command, 1)
                let (x3, y3) = point(command, 2)
                return .cubic(x1, y1, x2, y2, x3, y3)
            case "quadBezTo":
                let (x1, y1) = point(command, 0)
                let (x2, y2) = point(command, 1)
                return .quadratic(x1, y1, x2, y2)
            case "arcTo":
                return .arc(
                    widthRadius: value(command, "wR"), heightRadius: value(command, "hR"),
                    start: value(command, "stAng") / 60_000, sweep: value(command, "swAng") / 60_000
                )
            case "close":
                return .close
            default:
                return nil
            }
        }
        return ShapeGeometry.CustomPath(
            width: value(path, "w"), height: value(path, "h"),
            isFilled: path.attribute("fill") != "none", isStroked: path.attribute("stroke") != "0",
            commands: commands
        )
    }

    // MARK: - Text

    func textBody(_ element: XMLElement) -> TextBody {
        TextBody(
            properties: BodyProperties(element: element.firstChild(named: "bodyPr")),
            listStyle: ListStyle(element: element.firstChild(named: "lstStyle")),
            paragraphs: element.children(named: "p").map(paragraph)
        )
    }

    private func paragraph(_ element: XMLElement) -> Paragraph {
        var paragraph = Paragraph(runs: [])
        for child in element.children {
            switch child.name {
            case "pPr":
                paragraph.properties = ParagraphProperties(element: child)
                paragraph.sourceProperties = capture(child)
            case "r", "fld", "br":
                let properties = child.firstChild(named: "rPr")
                var run = TextRun(
                    text: child.name == "br" ? "\u{2028}" : child.firstChild(named: "t")?.text ?? "",
                    properties: RunProperties(element: properties)
                )
                if child.name == "br" { run.kind = .lineBreak }
                if child.name == "fld" {
                    run.kind = .field(type: child.attribute("type") ?? "")
                    run.fieldID = child.attribute("id")
                }
                run.sourceProperties = properties.flatMap(capture)
                paragraph.runs.append(run)
            case "endParaRPr":
                paragraph.endProperties = RunProperties(element: child)
                paragraph.sourceEndProperties = capture(child)
            default:
                break
            }
        }
        return paragraph
    }

    private func capture(_ element: XMLElement) -> String? {
        capturesSource ? XMLLite.serialize(element, inheritedNamespaces: namespaces) : nil
    }
}
