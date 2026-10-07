import Foundation

/// Moves shapes and slides from where they were to another slide, perhaps
/// in another presentation.
///
/// A shape's XML names what it uses — pictures, charts, links — by the ids
/// of its slide's relationships. Taken to another slide, those ids mean
/// nothing, or something else, so each is given a relationship of the new
/// slide's own. Taken to another presentation, the parts they lead to are
/// copied over too, along with everything those parts lead to in turn.
struct PartImporter {
    let source: Presentation
    private(set) var target: Presentation
    /// Source part paths already brought over, and where they went.
    private var imported: [String: String] = [:]
    private var taken: Set<String>
    /// Namespace bindings in scope on each source slide, by part.
    private var scopes: [String: [String: String]] = [:]

    /// Within one presentation, pictures and media are shared rather than
    /// copied; everything else still gets a copy, as PowerPoint gives each
    /// chart one slide to live on.
    var sharesPackage: Bool { source.package === target.package }

    /// Prefixes PowerPoint commonly declares only at a slide's root, so a
    /// shape captured without them can still be read on its own.
    static let commonNamespaces: [String: String] = OOXML.namespaces.merging([
        "mc": "http://schemas.openxmlformats.org/markup-compatibility/2006",
        "a14": "http://schemas.microsoft.com/office/drawing/2010/main",
        "a16": "http://schemas.microsoft.com/office/drawing/2014/main",
        "p14": "http://schemas.microsoft.com/office/powerpoint/2010/main",
        "p15": "http://schemas.microsoft.com/office/powerpoint/2012/main",
        "v": "urn:schemas-microsoft-com:vml",
        "o": "urn:schemas-microsoft-com:office:office",
    ]) { mine, _ in mine }

    /// Relationship types whose targets are shared within a presentation.
    private static let sharedTypes: Set<String> = [
        OOXML.RelationshipType.image, OOXML.RelationshipType.video, OOXML.RelationshipType.audio,
        OOXML.RelationshipType.media, OOXML.RelationshipType.hyperlink,
    ]

    /// Relationship types never followed: what a slide belongs to, rather
    /// than what it uses.
    private static let skippedTypes: Set<String> = [
        OOXML.RelationshipType.slideLayout, OOXML.RelationshipType.slideMaster, OOXML.RelationshipType.notesSlide,
        OOXML.RelationshipType.notesMaster, OOXML.RelationshipType.comments, OOXML.RelationshipType.modernComments,
    ]

    init(from source: Presentation, into target: Presentation) {
        self.source = source
        self.target = target
        taken = target.partNames
    }

    // MARK: - Parts

    /// Brings a part, and the parts it relies on, into the target, giving
    /// back where it went.
    mutating func importPart(_ path: String) -> String? {
        if let done = imported[path] { return done }
        guard let data = source.data(at: path) else { return nil }
        let name = Self.unusedName(like: path, taken: taken)
        taken.insert(name)
        imported[path] = name
        target.addedParts[name] = data
        if let type = source.contentType(of: path),
           source.addedContentTypes[path] != nil || source.package.contentTypes.isOverridden(path) {
            target.addedContentTypes[name] = type
        }
        // Its own relationships, followed in turn.
        let relationships = Relationship.parse(source.data(at: PackagePath.relationships(of: path)))
        if !relationships.isEmpty {
            let moved = relationships.compactMap { relationship -> Relationship? in
                guard !relationship.isExternal else { return relationship }
                guard !Self.skippedTypes.contains(relationship.type), relationship.type != OOXML.RelationshipType.slide,
                      let destination = importPart(PackagePath.resolve(relationship.target, from: path)) else { return nil }
                var copy = relationship
                copy.target = PackagePath.relativeTarget(to: destination, from: name)
                return copy
            }
            let rels = PackagePath.relationships(of: name)
            target.addedParts[rels] = Relationship.xml(moved)
            taken.insert(rels)
        }
        return name
    }

    /// `ppt/charts/chart3.xml` → the first free `ppt/charts/chartN.xml`.
    static func unusedName(like path: String, taken: Set<String>) -> String {
        let directory = (path as NSString).deletingLastPathComponent
        let file = (path as NSString).lastPathComponent
        let ext = (file as NSString).pathExtension
        var stem = (file as NSString).deletingPathExtension
        while let last = stem.last, last.isNumber { stem.removeLast() }
        return PackagePath.unused(
            prefix: (directory.isEmpty ? "" : directory + "/") + stem, suffix: ext.isEmpty ? "" : "." + ext, taken: taken
        )
    }

    // MARK: - Shapes

    /// `shape`, from `slide` in the source, readied for a slide whose part
    /// is `targetPart` and whose relationships are `relationships`, which
    /// gain whatever the shape needs.
    mutating func transplant(
        _ shape: SlideShape, from slide: Slide, into relationships: inout [Relationship], targetPart: String
    ) -> SlideShape {
        let sourcePart = slide.partName ?? slide.sourcePart ?? Self.newSlidePart
        let namespaces = scope(of: slide)
        var remap: [String: String?] = [:]
        func relationshipID(for id: String) -> String? {
            if let done = remap[id] { return done }
            guard let relationship = slide.relationships.first(where: { $0.id == id }) else {
                remap[id] = .some(nil)
                return nil
            }
            var moved = relationship
            if !relationship.isExternal {
                let path = PackagePath.resolve(relationship.target, from: sourcePart)
                let destination: String?
                if relationship.type == OOXML.RelationshipType.slide {
                    // A link to another slide only means something in its own presentation.
                    destination = sharesPackage ? path : nil
                } else if sharesPackage, Self.sharedTypes.contains(relationship.type) || !Self.isOwned(relationship.type) {
                    destination = path
                } else {
                    destination = importPart(path)
                }
                guard let destination else {
                    remap[id] = .some(nil)
                    return nil
                }
                moved.target = PackagePath.relativeTarget(to: destination, from: targetPart)
            }
            if let existing = relationships.first(where: {
                $0.type == moved.type && $0.target == moved.target && $0.isExternal == moved.isExternal
            }) {
                remap[id] = existing.id
                return existing.id
            }
            moved.id = Relationship.unusedID(in: relationships)
            relationships.append(moved)
            remap[id] = moved.id
            return moved.id
        }
        func rewrite(_ xml: String?) -> String? {
            guard let xml else { return nil }
            return Self.remappingRelationships(in: xml, namespaces: namespaces, using: relationshipID) ?? xml
        }
        var paths: [String: String] = [:]
        func path(_ old: String) -> String {
            if let done = paths[old] { return done }
            let new = sharesPackage ? old : (importPart(old) ?? old)
            paths[old] = new
            return new
        }
        return shape.remapped(xml: rewrite, path: path)
    }

    /// Where a slide not yet saved will go; every slide shares a folder, so
    /// targets relative to it are right for whichever name it gets.
    static let newSlidePart = "ppt/slides/slide.xml"

    /// Parts that belong to the slide that uses them, rather than being shared.
    private static func isOwned(_ type: String) -> Bool {
        type.hasSuffix("/chart") || type.hasSuffix("/diagramData") || type.hasSuffix("/diagramLayout")
            || type.hasSuffix("/diagramQuickStyle") || type.hasSuffix("/diagramColors")
            || type.hasSuffix("/diagramDrawing") || type.hasSuffix("/package") || type.hasSuffix("/oleObject")
            || type.hasSuffix("/chartUserShapes")
    }

    private mutating func scope(of slide: Slide) -> [String: String] {
        let part = slide.sourcePart ?? ""
        if let known = scopes[part] { return known }
        var namespaces = Self.commonNamespaces
        if let data = source.data(at: part), let root = try? XMLLite.parse(data),
           let tree = root.firstChild(named: "cSld")?.firstChild(named: "spTree") {
            namespaces.merge(PPTXReader.namespacesInScope(of: tree).filter { !$0.key.isEmpty }) { _, inScope in inScope }
        }
        scopes[part] = namespaces
        return namespaces
    }

    /// `xml`, made self-contained, with every attribute in the relationships
    /// namespace given the id `map` returns. A link whose target cannot come
    /// along is dropped whole.
    static func remappingRelationships(
        in xml: String, namespaces: [String: String], using map: (String) -> String?
    ) -> String? {
        guard let root = XMLLite.fragment(xml, namespaces: namespaces) else { return nil }
        func visit(_ element: XMLElement) {
            for child in element.children { visit(child) }
            for (key, value) in element.qualifiedAttributes where key.contains(":") && !key.hasPrefix("xmlns") {
                let prefix = String(key.prefix { $0 != ":" })
                guard element.sourceNamespaceBinding(forPrefix: prefix) == OOXML.relationshipsNS else { continue }
                let local = String(key.drop { $0 != ":" }.dropFirst())
                if let id = map(value) {
                    element.setAttribute(local, id)
                } else if ["hlinkClick", "hlinkHover"].contains(element.name), let parent = element.parent {
                    parent.removeChild(element)
                } else {
                    element.setAttribute(local, "")
                }
            }
        }
        visit(root)
        return XMLLite.serialize(root)
    }
}

extension SlideShape {
    /// This shape with every captured piece of XML passed through `xml`, and
    /// every package path through `path`, all the way down its members.
    func remapped(xml: (String?) -> String?, path: (String) -> String) -> SlideShape {
        var shape = self
        shape.source = xml(source)
        shape.text = text?.remapped(xml: xml)
        shape.fill = fill?.remapped(path: path)
        switch kind {
        case .picture(var picture):
            picture.imagePath = picture.imagePath.map(path)
            shape.kind = .picture(picture)
        case .group(var group):
            group.children = group.children.map { $0.remapped(xml: xml, path: path) }
            shape.kind = .group(group)
        case .diagram(let children):
            shape.kind = .diagram(children.map { $0.remapped(xml: xml, path: path) })
        case .table(var table):
            for row in table.rows.indices {
                for cell in table.rows[row].cells.indices {
                    table.rows[row].cells[cell].text = table.rows[row].cells[cell].text?.remapped(xml: xml)
                    table.rows[row].cells[cell].fill = table.rows[row].cells[cell].fill?.remapped(path: path)
                }
            }
            shape.kind = .table(table)
        default:
            break
        }
        return shape
    }
}

extension TextBody {
    func remapped(xml: (String?) -> String?) -> TextBody {
        var body = self
        for index in body.paragraphs.indices {
            body.paragraphs[index].sourceProperties = xml(body.paragraphs[index].sourceProperties)
            body.paragraphs[index].sourceEndProperties = xml(body.paragraphs[index].sourceEndProperties)
            for run in body.paragraphs[index].runs.indices {
                body.paragraphs[index].runs[run].sourceProperties = xml(body.paragraphs[index].runs[run].sourceProperties)
            }
        }
        return body
    }
}

extension Fill {
    func remapped(path: (String) -> String) -> Fill {
        switch self {
        case .picture(let old, let effects): .picture(path: path(old), effects: effects)
        case .tiledPicture(let old, let effects): .tiledPicture(path: path(old), effects: effects)
        default: self
        }
    }
}
