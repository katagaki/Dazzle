import Foundation

/// Writes a shape back as XML.
///
/// A shape read from a file and left alone is written exactly as read. One
/// Dazzle changed has only the changed parts rewritten in its original XML —
/// its frame, fill, line or text — so whatever else it carried survives.
/// One Dazzle made starts from a skeleton and is filled in the same way.
struct ShapeWriter {
    /// The slide's part, which relationship targets are relative to.
    let partPath: String
    /// Namespace bindings in scope where the shape goes.
    let namespaces: [String: String]
    /// The slide's relationships, which a new picture adds to.
    var relationships: [Relationship]

    mutating func xml(for shape: SlideShape) -> String? {
        if shape.edits.isEmpty, let source = shape.source { return source }
        guard let element = element(for: shape) else { return shape.source }
        let edits: Set<SlideShape.Edit> = shape.source == nil
            ? [.transform, .fill, .line, .text, .table, .picture, .altText, .effects] : shape.edits
        if edits.contains(.transform), shape.hasOwnFrame || shape.source != nil {
            writeTransform(of: shape, into: element)
        }
        if edits.contains(.fill), let fill = shape.fill {
            writeFill(fill, into: element)
        }
        if edits.contains(.line), let line = shape.line {
            writeLine(line, into: element)
        }
        if edits.contains(.text), let text = shape.text {
            writeText(text, into: element)
        }
        if edits.contains(.table), case .table(let table) = shape.kind {
            writeTable(table, into: element)
        }
        if edits.contains(.effects), shape.source != nil || shape.shadow != nil {
            writeShadow(shape.shadow, into: element)
        }
        if edits.contains(.picture), case .picture(let picture) = shape.kind {
            writePicture(picture, into: element)
        }
        if edits.contains(.altText) {
            let common = element.children.first { $0.name.hasPrefix("nv") }?.firstChild(named: "cNvPr")
            common?.setAttribute("descr", shape.altText?.nilIfEmpty)
        }
        if edits.contains(.identity), shape.source != nil {
            writeIdentity(of: shape, into: element)
        }
        if edits.contains(.placeholder), shape.placeholder == nil {
            let details = element.children.first { $0.name.hasPrefix("nv") }?.firstChild(named: "nvPr")
            if let mark = details?.firstChild(named: "ph") { details?.removeChild(mark) }
        }
        return XMLLite.serialize(element, inheritedNamespaces: namespaces)
    }

    var fragmentNamespaces: [String: String] {
        OOXML.namespaces.merging(namespaces.filter { !$0.key.isEmpty }) { _, inScope in inScope }
    }

    private func fragment(_ xml: String) -> XMLElement? {
        XMLLite.fragment(xml, namespaces: fragmentNamespaces)
    }

    // MARK: - Skeletons

    private mutating func element(for shape: SlideShape) -> XMLElement? {
        if let source = shape.source { return fragment(source) }
        return fragment(skeleton(for: shape))
    }

    private mutating func skeleton(for shape: SlideShape) -> String {
        let name = XMLLite.escape(shape.name)
        let identity = "<p:cNvPr id=\"\(shape.shapeID)\" name=\"\(name)\"/>"
        switch shape.kind {
        case .group(let group):
            // Members are written in full inside the group, each as it would be on the slide.
            let members = group.children.compactMap { xml(for: $0) }.joined()
            return """
                <p:grpSp><p:nvGrpSpPr>\(identity)<p:cNvGrpSpPr/><p:nvPr/></p:nvGrpSpPr><p:grpSpPr><a:xfrm>\
                <a:off x="0" y="0"/><a:ext cx="0" cy="0"/><a:chOff x="0" y="0"/><a:chExt cx="0" cy="0"/></a:xfrm>\
                </p:grpSpPr>\(members)</p:grpSp>
                """
        case .table:
            return """
                <p:graphicFrame><p:nvGraphicFramePr>\(identity)<p:cNvGraphicFramePr><a:graphicFrameLocks noGrp="1"/>\
                </p:cNvGraphicFramePr><p:nvPr/></p:nvGraphicFramePr><p:xfrm><a:off x="0" y="0"/><a:ext cx="0" cy="0"/>\
                </p:xfrm><a:graphic><a:graphicData uri="http://schemas.openxmlformats.org/drawingml/2006/table"><a:tbl>\
                <a:tblPr/><a:tblGrid/></a:tbl></a:graphicData></a:graphic></p:graphicFrame>
                """
        case .picture(let picture):
            let reference = relationshipID(forImage: picture.imagePath ?? "")
            return """
                <p:pic><p:nvPicPr>\(identity)<p:cNvPicPr><a:picLocks noChangeAspect="1"/></p:cNvPicPr><p:nvPr/>\
                </p:nvPicPr><p:blipFill><a:blip r:embed="\(reference)"/><a:stretch><a:fillRect/></a:stretch>\
                </p:blipFill><p:spPr><a:prstGeom prst="rect"><a:avLst/></a:prstGeom></p:spPr></p:pic>
                """
        default:
            if let placeholder = shape.placeholder {
                let type = placeholder.type.map { " type=\"\($0)\"" } ?? ""
                let index = placeholder.index.map { " idx=\"\($0)\"" } ?? ""
                return """
                    <p:sp><p:nvSpPr>\(identity)<p:cNvSpPr><a:spLocks noGrp="1"/></p:cNvSpPr><p:nvPr><p:ph\(type)\(index)/>\
                    </p:nvPr></p:nvSpPr><p:spPr/><p:txBody><a:bodyPr/><a:lstStyle/><a:p><a:endParaRPr lang="en-US"/>\
                    </a:p></p:txBody></p:sp>
                    """
            }
            let geometry = shape.geometry.presetName ?? "rect"
            if shape.isTextBox {
                return """
                    <p:sp><p:nvSpPr>\(identity)<p:cNvSpPr txBox="1"/><p:nvPr/></p:nvSpPr><p:spPr>\
                    <a:prstGeom prst="rect"><a:avLst/></a:prstGeom><a:noFill/></p:spPr><p:txBody>\
                    <a:bodyPr wrap="square" rtlCol="0"><a:spAutoFit/></a:bodyPr><a:lstStyle/>\
                    <a:p><a:endParaRPr lang="en-US"/></a:p></p:txBody></p:sp>
                    """
            }
            // PowerPoint's own style for a new shape: accent fill, darker
            // outline, light text.
            return """
                <p:sp><p:nvSpPr>\(identity)<p:cNvSpPr/><p:nvPr/></p:nvSpPr><p:spPr>\
                <a:prstGeom prst="\(geometry)"><a:avLst/></a:prstGeom></p:spPr><p:style>\
                <a:lnRef idx="2"><a:schemeClr val="accent1"><a:shade val="15000"/></a:schemeClr></a:lnRef>\
                <a:fillRef idx="1"><a:schemeClr val="accent1"/></a:fillRef>\
                <a:effectRef idx="0"><a:schemeClr val="accent1"/></a:effectRef>\
                <a:fontRef idx="minor"><a:schemeClr val="lt1"/></a:fontRef></p:style>\
                <p:txBody><a:bodyPr rtlCol="0" anchor="ctr"/><a:lstStyle/><a:p><a:pPr algn="ctr"/>\
                <a:endParaRPr lang="en-US"/></a:p></p:txBody></p:sp>
                """
        }
    }

    /// The id of the slide's relationship to an image, adding one if needed.
    private mutating func relationshipID(forImage path: String) -> String {
        if let existing = relationships.first(where: {
            $0.type == OOXML.RelationshipType.image && !$0.isExternal
                && PackagePath.resolve($0.target, from: partPath) == path
        }) {
            return existing.id
        }
        let id = Relationship.unusedID(in: relationships)
        relationships.append(Relationship(
            id: id, type: OOXML.RelationshipType.image, target: PackagePath.relativeTarget(to: path, from: partPath)
        ))
        return id
    }

    // MARK: - Patching

    /// The element holding a shape's visual properties.
    private func properties(of element: XMLElement) -> XMLElement? {
        element.firstChild(named: "spPr") ?? element.firstChild(named: "grpSpPr")
    }

    private func writeTransform(of shape: SlideShape, into element: XMLElement) {
        let transform: XMLElement
        if element.name == "graphicFrame" {
            if let existing = element.firstChild(named: "xfrm") {
                transform = existing
            } else {
                guard let created = fragment("<p:xfrm/>") else { return }
                element.insertChild(created, at: 1)
                transform = created
            }
        } else {
            guard let properties = properties(of: element) else { return }
            if let existing = properties.firstChild(named: "xfrm") {
                transform = existing
            } else {
                guard let created = fragment("<a:xfrm/>") else { return }
                properties.insertChild(created, at: 0)
                transform = created
            }
        }
        let rotation = Int((shape.rotation * 60_000).rounded())
        transform.setAttribute("rot", rotation == 0 ? nil : String(rotation))
        transform.setAttribute("flipH", shape.flipsHorizontally ? "1" : nil)
        transform.setAttribute("flipV", shape.flipsVertically ? "1" : nil)

        let offset = transform.firstChild(named: "off") ?? fragment("<a:off/>")
        let extent = transform.firstChild(named: "ext") ?? fragment("<a:ext/>")
        guard let offset, let extent else { return }
        offset.setAttribute("x", String(shape.frame.x))
        offset.setAttribute("y", String(shape.frame.y))
        extent.setAttribute("cx", String(max(shape.frame.width, 0)))
        extent.setAttribute("cy", String(max(shape.frame.height, 0)))
        if offset.parent == nil { transform.insertChild(offset, at: 0) }
        if extent.parent == nil { transform.insertChild(extent, at: 1) }
        // A group Dazzle made maps its members' space onto its frame one to one.
        if shape.source == nil, case .group(let group) = shape.kind {
            transform.firstChild(named: "chOff")?.setAttribute("x", String(group.childFrame.x))
            transform.firstChild(named: "chOff")?.setAttribute("y", String(group.childFrame.y))
            transform.firstChild(named: "chExt")?.setAttribute("cx", String(max(group.childFrame.width, 0)))
            transform.firstChild(named: "chExt")?.setAttribute("cy", String(max(group.childFrame.height, 0)))
        }
    }

    /// Gives a copied shape, and everything inside it, ids of its own.
    private func writeIdentity(of shape: SlideShape, into element: XMLElement) {
        var next = shape.shapeID
        func renumber(_ element: XMLElement) {
            if element.name == "cNvPr" {
                element.setAttribute("id", String(next))
                // Children of a copied group are numbered well clear of the slide's own.
                next = next == shape.shapeID ? shape.shapeID * 1_000 + 1 : next + 1
            }
            element.children.forEach(renumber)
        }
        renumber(element)
    }

    /// A fill as DrawingML, a picture fill naming its image by a
    /// relationship of the slide's, added if the slide has none to it.
    mutating func fillXML(_ fill: Fill) -> String {
        switch fill {
        case .picture(let path, let effects), .tiledPicture(let path, let effects):
            let reference = relationshipID(forImage: path)
            let alpha = effects.opacity < 1 ? "<a:alphaModFix amt=\"\(Int((effects.opacity * 100_000).rounded()))\"/>" : ""
            let grey = effects.isGreyscale ? "<a:grayscl/>" : ""
            let layout = if case .tiledPicture = fill {
                "<a:tile tx=\"0\" ty=\"0\" sx=\"100000\" sy=\"100000\" flip=\"none\" algn=\"tl\"/>"
            } else {
                "<a:stretch><a:fillRect/></a:stretch>"
            }
            return "<a:blipFill dpi=\"0\" rotWithShape=\"1\"><a:blip r:embed=\"\(reference)\">\(alpha)\(grey)</a:blip>"
                + "<a:srcRect/>\(layout)</a:blipFill>"
        default:
            return fill.xml
        }
    }

    private mutating func writeFill(_ fill: Fill, into element: XMLElement) {
        guard let properties = properties(of: element), let new = fragment(fillXML(fill)) else { return }
        for child in properties.children where Fill.elementNames.contains(child.name) {
            properties.removeChild(child)
        }
        let after = properties.children.lastIndex { ["xfrm", "prstGeom", "custGeom"].contains($0.name) }
        properties.insertChild(new, at: (after ?? -1) + 1)
    }

    /// Replaces the shape's effects with its shadow, or with none at all,
    /// which outranks any its style would give it.
    private func writeShadow(_ shadow: Shadow?, into element: XMLElement) {
        guard let properties = properties(of: element) else { return }
        for child in properties.children where ["effectLst", "effectDag"].contains(child.name) { properties.removeChild(child) }
        guard let effects = fragment("<a:effectLst>\(shadow?.xml ?? "")</a:effectLst>") else { return }
        let before = properties.children.firstIndex { ["scene3d", "sp3d", "extLst"].contains($0.name) }
        properties.insertChild(effects, at: before ?? properties.children.count)
    }

    /// Writes the outline's fill, width, dash and arrowheads over what the
    /// file had, keeping its caps, joins and anything else.
    private func writeLine(_ line: LineStyle, into element: XMLElement) {
        guard let properties = properties(of: element) else { return }
        let outline: XMLElement
        if let existing = properties.firstChild(named: "ln") {
            outline = existing
        } else {
            guard let created = fragment("<a:ln/>") else { return }
            let after = properties.children.lastIndex {
                ["xfrm", "prstGeom", "custGeom"].contains($0.name) || Fill.elementNames.contains($0.name)
            }
            properties.insertChild(created, at: (after ?? -1) + 1)
            outline = created
        }
        if let width = line.width { outline.setAttribute("w", String(width)) }
        func place(_ xml: String?, replacing names: Set<String>) {
            for child in outline.children where names.contains(child.name) { outline.removeChild(child) }
            guard let xml, let new = fragment(xml) else { return }
            let before = outline.children.firstIndex { Self.lineChildOrder(of: $0.name) > Self.lineChildOrder(of: new.name) }
            outline.insertChild(new, at: before ?? outline.children.count)
        }
        if let fill = line.fill { place(fill.xml, replacing: Fill.elementNames) }
        if let dash = line.dash { place("<a:prstDash val=\"\(XMLLite.escape(dash))\"/>", replacing: ["prstDash", "custDash"]) }
        place(line.head.map { "<a:headEnd type=\"\(XMLLite.escape($0))\"/>" }, replacing: ["headEnd"])
        place(line.tail.map { "<a:tailEnd type=\"\(XMLLite.escape($0))\"/>" }, replacing: ["tailEnd"])
    }

    /// Where a child of `a:ln` goes among its siblings.
    private static func lineChildOrder(of name: String) -> Int {
        switch name {
        case "noFill", "solidFill", "gradFill", "pattFill": 0
        case "prstDash", "custDash": 1
        case "round", "bevel", "miter": 2
        case "headEnd": 3
        case "tailEnd": 4
        default: 5
        }
    }

    private func writeText(_ text: TextBody, into element: XMLElement) {
        let body: XMLElement
        if let existing = element.firstChild(named: "txBody") {
            body = existing
        } else {
            guard let created = fragment("<p:txBody><a:bodyPr/><a:lstStyle/></p:txBody>") else { return }
            let before = element.children.firstIndex { $0.name == "extLst" } ?? element.children.count
            element.insertChild(created, at: before)
            body = created
        }
        for paragraph in body.children(named: "p") {
            body.removeChild(paragraph)
        }
        let paragraphs = text.paragraphs.isEmpty ? [Paragraph(runs: [])] : text.paragraphs
        for paragraph in paragraphs {
            if let element = fragment(paragraphXML(paragraph)) {
                body.insertChild(element, at: body.children.count)
            }
        }
    }

    // MARK: - Pictures

    /// Points the picture at its image, and cuts it as its crop says.
    private mutating func writePicture(_ picture: SlideShape.Picture, into element: XMLElement) {
        guard let fill = element.firstChild(named: "blipFill") else { return }
        if let path = picture.imagePath, let blip = fill.firstChild(named: "blip") {
            blip.setAttribute("embed", relationshipID(forImage: path))
        }
        fill.firstChild(named: "srcRect").map(fill.removeChild)
        let edges = [("l", picture.cropLeft), ("t", picture.cropTop), ("r", picture.cropRight), ("b", picture.cropBottom)]
            .filter { $0.1 != 0 }
            .map { " \($0.0)=\"\(Int(($0.1 * 100_000).rounded()))\"" }
        guard !edges.isEmpty, let crop = fragment("<a:srcRect\(edges.joined())/>") else { return }
        let after = fill.children.firstIndex { $0.name == "blip" }
        fill.insertChild(crop, at: (after ?? -1) + 1)
    }

    // MARK: - Tables

    /// Writes the table's grid, rows and cells from the model, each cell
    /// starting from the XML it was read with.
    private func writeTable(_ table: SlideTable, into element: XMLElement) {
        guard let data = element.firstChild(named: "graphic")?.firstChild(named: "graphicData"),
              let grid = data.firstChild(named: "tbl") else { return }
        let properties = table.sourceProperties.flatMap(fragment) ?? grid.firstChild(named: "tblPr") ?? fragment("<a:tblPr/>")
        guard let properties else { return }
        properties.setAttribute("firstRow", table.hasHeaderRow ? "1" : nil)
        properties.setAttribute("bandRow", table.hasBandedRows ? "1" : nil)
        if let styleID = table.styleID, properties.firstChild(named: "tableStyleId") == nil,
           let style = fragment("<a:tableStyleId>\(XMLLite.escape(styleID))</a:tableStyleId>") {
            properties.insertChild(style, at: properties.children.count)
        }
        let extensions = grid.firstChild(named: "extLst")
        for child in grid.children { grid.removeChild(child) }
        grid.insertChild(properties, at: 0)
        let columns = table.columnWidths.map { "<a:gridCol w=\"\($0)\"/>" }.joined()
        if let gridColumns = fragment("<a:tblGrid>\(columns)</a:tblGrid>") {
            grid.insertChild(gridColumns, at: grid.children.count)
        }
        for row in table.rows {
            guard let rowElement = fragment("<a:tr h=\"\(row.height)\"/>") else { continue }
            for cell in row.cells {
                if let cellElement = cellElement(cell) { rowElement.insertChild(cellElement, at: rowElement.children.count) }
            }
            grid.insertChild(rowElement, at: grid.children.count)
        }
        if let extensions { grid.insertChild(extensions, at: grid.children.count) }
    }

    private func cellElement(_ cell: SlideTable.Cell) -> XMLElement? {
        guard let element = fragment("<a:tc/>") else { return nil }
        element.setAttribute("gridSpan", cell.columnSpan > 1 ? String(cell.columnSpan) : nil)
        element.setAttribute("rowSpan", cell.rowSpan > 1 ? String(cell.rowSpan) : nil)
        element.setAttribute("hMerge", cell.isHorizontalMerge ? "1" : nil)
        element.setAttribute("vMerge", cell.isVerticalMerge ? "1" : nil)

        let body = cell.sourceBody.flatMap(fragment) ?? fragment("<a:txBody><a:bodyPr/><a:lstStyle/></a:txBody>")
        if let body {
            for paragraph in body.children(named: "p") { body.removeChild(paragraph) }
            let paragraphs = cell.text?.paragraphs.nilIfEmpty ?? [Paragraph(runs: [])]
            for paragraph in paragraphs {
                if let paragraphElement = fragment(paragraphXML(paragraph)) {
                    body.insertChild(paragraphElement, at: body.children.count)
                }
            }
            element.insertChild(body, at: element.children.count)
        }

        let properties = cell.sourceProperties.flatMap(fragment) ?? fragment("<a:tcPr/>")
        if let properties {
            func margin(_ key: String, _ value: Int?) {
                if let value { properties.setAttribute(key, String(value)) }
            }
            margin("marL", cell.marginLeft)
            margin("marR", cell.marginRight)
            margin("marT", cell.marginTop)
            margin("marB", cell.marginBottom)
            if let anchor = cell.anchor { properties.setAttribute("anchor", anchor.rawValue) }
            // A picture fill is left as the file had it; others are written as they now are.
            switch cell.fill {
            case .picture?, .tiledPicture?:
                break
            default:
                for child in properties.children where Fill.elementNames.contains(child.name) { properties.removeChild(child) }
                if let fill = cell.fill, let fillElement = fragment(fill.xml) {
                    let before = properties.children.firstIndex { ["headers", "extLst"].contains($0.name) }
                    properties.insertChild(fillElement, at: before ?? properties.children.count)
                }
            }
            element.insertChild(properties, at: element.children.count)
        }
        return element
    }

    // MARK: - Paragraphs

    func paragraphXML(_ paragraph: Paragraph) -> String {
        var xml = "<a:p>"
        if let properties = paragraphPropertiesXML(paragraph) { xml += properties }
        for run in paragraph.runs {
            let properties = runPropertiesXML(run.properties, source: run.sourceProperties, name: "rPr")
            switch run.kind {
            case .lineBreak:
                xml += "<a:br>\(properties)</a:br>"
            case .field(let type):
                let id = run.fieldID ?? "{\(UUID().uuidString)}"
                xml += "<a:fld id=\"\(XMLLite.escape(id))\" type=\"\(XMLLite.escape(type))\">\(properties)"
                    + "<a:t>\(XMLLite.escape(run.text))</a:t></a:fld>"
            case .text:
                let lines = run.text.components(separatedBy: "\u{2028}")
                for (index, line) in lines.enumerated() {
                    if index > 0 { xml += "<a:br>\(properties)</a:br>" }
                    if !line.isEmpty { xml += "<a:r>\(properties)<a:t>\(XMLLite.escape(line))</a:t></a:r>" }
                }
            }
        }
        let end = paragraph.endProperties ?? paragraph.runs.last?.properties ?? RunProperties()
        xml += runPropertiesXML(end, source: paragraph.sourceEndProperties, name: "endParaRPr")
        return xml + "</a:p>"
    }

    private func paragraphPropertiesXML(_ paragraph: Paragraph) -> String? {
        let element = paragraph.sourceProperties.flatMap(fragment) ?? fragment("<a:pPr/>")
        guard let element else { return nil }
        let properties = paragraph.properties
        if let alignment = properties.alignment {
            element.setAttribute("algn", alignment.rawValue)
        }
        if let level = properties.level {
            element.setAttribute("lvl", level == 0 ? nil : String(level))
        }
        if let margin = properties.marginLeft { element.setAttribute("marL", String(margin)) }
        if let indent = properties.indent { element.setAttribute("indent", String(indent)) }

        // Children, each in its place in the schema's order.
        func place(_ xml: String, replacing names: Set<String>) {
            for child in element.children where names.contains(child.name) { element.removeChild(child) }
            guard let new = fragment(xml) else { return }
            let before = element.children.firstIndex { Self.paragraphChildOrder(of: $0.name) > Self.paragraphChildOrder(of: new.name) }
            element.insertChild(new, at: before ?? element.children.count)
        }
        func spacing(_ value: Spacing) -> String {
            switch value {
            case .percent(let percent): "<a:spcPct val=\"\(Int((percent * 100_000).rounded()))\"/>"
            case .points(let points): "<a:spcPts val=\"\(Int((points * 100).rounded()))\"/>"
            }
        }
        if let line = properties.lineSpacing { place("<a:lnSpc>\(spacing(line))</a:lnSpc>", replacing: ["lnSpc"]) }
        if let before = properties.spaceBefore { place("<a:spcBef>\(spacing(before))</a:spcBef>", replacing: ["spcBef"]) }
        if let after = properties.spaceAfter { place("<a:spcAft>\(spacing(after))</a:spcAft>", replacing: ["spcAft"]) }
        if let font = properties.bulletFont {
            place("<a:buFont typeface=\"\(XMLLite.escape(font))\"/>", replacing: ["buFont", "buFontTx"])
        }
        let bullets: Set<String> = ["buNone", "buAutoNum", "buChar", "buBlip"]
        switch properties.bullet {
        case .none?: place("<a:buNone/>", replacing: bullets)
        case .character(let character)?: place("<a:buChar char=\"\(XMLLite.escape(character))\"/>", replacing: bullets)
        case .autoNumber(let scheme, let start)?:
            let startAt = start == 1 ? "" : " startAt=\"\(start)\""
            place("<a:buAutoNum type=\"\(XMLLite.escape(scheme))\"\(startAt)/>", replacing: bullets)
        case nil: break
        }
        guard !element.attributes.isEmpty || !element.children.isEmpty else { return nil }
        return XMLLite.serialize(element, inheritedNamespaces: fragmentNamespaces)
    }

    /// Where a child of `a:pPr` goes among its siblings.
    private static func paragraphChildOrder(of name: String) -> Int {
        switch name {
        case "lnSpc": 0
        case "spcBef": 1
        case "spcAft": 2
        case "buClrTx", "buClr": 3
        case "buSzTx", "buSzPct", "buSzPts": 4
        case "buFontTx", "buFont": 5
        case "buNone", "buAutoNum", "buChar", "buBlip": 6
        case "tabLst": 7
        case "defRPr": 8
        default: 9
        }
    }

    /// Run properties as the file had them, with what Dazzle models laid over.
    func runPropertiesXML(_ properties: RunProperties, source: String?, name: String) -> String {
        var element = source.flatMap(fragment) ?? fragment("<a:\(name) lang=\"en-US\" dirty=\"0\"/>")
        if let existing = element, existing.name != name, let renamed = fragment("<a:\(name)/>") {
            // `endParaRPr` lending its properties to a run, or the other way round.
            for (key, value) in existing.attributes { renamed.setAttribute(key, value) }
            for child in existing.children { renamed.insertChild(child, at: renamed.children.count) }
            element = renamed
        }
        guard let element else { return "" }
        if let size = properties.size { element.setAttribute("sz", String(size)) }
        if let bold = properties.isBold { element.setAttribute("b", bold ? "1" : "0") }
        if let italic = properties.isItalic { element.setAttribute("i", italic ? "1" : "0") }
        if let underline = properties.isUnderlined { element.setAttribute("u", underline ? "sng" : "none") }
        if let strike = properties.isStruckThrough { element.setAttribute("strike", strike ? "sngStrike" : "noStrike") }
        if let baseline = properties.baseline { element.setAttribute("baseline", baseline == 0 ? nil : String(baseline)) }
        if let color = properties.color, let fill = fragment("<a:solidFill>\(color.xml)</a:solidFill>") {
            for child in element.children where Fill.elementNames.contains(child.name) {
                element.removeChild(child)
            }
            let after = element.children.firstIndex { $0.name == "ln" }
            element.insertChild(fill, at: after.map { $0 + 1 } ?? 0)
        }
        if let font = properties.latinFont, let latin = fragment("<a:latin typeface=\"\(XMLLite.escape(font))\"/>") {
            if let existing = element.firstChild(named: "latin") {
                element.replaceChild(existing, with: latin)
            } else {
                // Typefaces come after fills and underlines, before links.
                let before = element.children.firstIndex {
                    ["ea", "cs", "sym", "hlinkClick", "hlinkMouseOver", "rtl", "extLst"].contains($0.name)
                }
                element.insertChild(latin, at: before ?? element.children.count)
            }
        }
        return XMLLite.serialize(element, inheritedNamespaces: fragmentNamespaces) ?? ""
    }
}
