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
        let edits: Set<SlideShape.Edit> = shape.source == nil ? [.transform, .fill, .line, .text] : shape.edits
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
        if edits.contains(.identity), shape.source != nil {
            writeIdentity(of: shape, into: element)
        }
        return XMLLite.serialize(element, inheritedNamespaces: namespaces)
    }

    private var fragmentNamespaces: [String: String] {
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

    private func writeFill(_ fill: Fill, into element: XMLElement) {
        guard let properties = properties(of: element), let new = fragment(fill.xml) else { return }
        for child in properties.children where Fill.elementNames.contains(child.name) {
            properties.removeChild(child)
        }
        let after = properties.children.lastIndex { ["xfrm", "prstGeom", "custGeom"].contains($0.name) }
        properties.insertChild(new, at: (after ?? -1) + 1)
    }

    private func writeLine(_ line: LineStyle, into element: XMLElement) {
        guard let properties = properties(of: element) else { return }
        let existing = properties.firstChild(named: "ln")
        let fillXML = line.fill?.xml ?? ""
        let width = line.width.map { " w=\"\($0)\"" } ?? ""
        guard let new = fragment("<a:ln\(width)>\(fillXML)</a:ln>") else { return }
        if let existing {
            // Keep the dash, joins and arrowheads the file gave it.
            for child in existing.children where !Fill.elementNames.contains(child.name) {
                new.insertChild(child, at: new.children.count)
            }
            for (key, value) in existing.attributes where key != "w" {
                new.setAttribute(key, value)
            }
            properties.replaceChild(existing, with: new)
        } else {
            let after = properties.children.lastIndex {
                ["xfrm", "prstGeom", "custGeom"].contains($0.name) || Fill.elementNames.contains($0.name)
            }
            properties.insertChild(new, at: (after ?? -1) + 1)
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
        if let alignment = paragraph.properties.alignment {
            element.setAttribute("algn", alignment.rawValue)
        }
        if let level = paragraph.properties.level {
            element.setAttribute("lvl", level == 0 ? nil : String(level))
        }
        guard !element.attributes.isEmpty || !element.children.isEmpty else { return nil }
        return XMLLite.serialize(element, inheritedNamespaces: fragmentNamespaces)
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
        if let color = properties.color, let fill = fragment("<a:solidFill>\(color.xml)</a:solidFill>") {
            for child in element.children where Fill.elementNames.contains(child.name) {
                element.removeChild(child)
            }
            let after = element.children.firstIndex { $0.name == "ln" }
            element.insertChild(fill, at: after.map { $0 + 1 } ?? 0)
        }
        return XMLLite.serialize(element, inheritedNamespaces: fragmentNamespaces) ?? ""
    }
}
