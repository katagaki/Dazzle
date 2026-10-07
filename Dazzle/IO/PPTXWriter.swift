import Foundation

enum PresentationWriteError: LocalizedError {
    case unwritablePart(String)

    var errorDescription: String? {
        switch self {
        case .unwritablePart(let part):
            String(format: String(localized: "Error.UnwritablePart"), part)
        }
    }
}

/// Writes a presentation back into its package.
///
/// Starts from every part as it was read and replaces only what changed:
/// edited slides, notes, the slide list, and the bookkeeping that ties
/// them together. Untouched slides are written back byte for byte.
enum PPTXWriter {
    static func data(from presentation: Presentation) throws -> Data {
        var package = PackageBuilder(presentation: presentation)
        try package.build()
        return try package.archive()
    }
}

private struct PackageBuilder {
    let presentation: Presentation
    var parts: [String: Data]
    var contentTypes: ContentTypes
    var mainRelationships: [Relationship]
    var slides: [Slide]
    /// Set when a notes master had to be made for new notes.
    var createdNotesMasterRelationship: String?

    init(presentation: Presentation) {
        self.presentation = presentation
        parts = presentation.package.parts.merging(presentation.addedParts) { _, added in added }
        contentTypes = ContentTypes(data: parts["[Content_Types].xml"])
        mainRelationships = Relationship.parse(parts[PackagePath.relationships(of: presentation.package.mainPart)])
        slides = presentation.slides
    }

    private var mainPart: String { presentation.package.mainPart }

    mutating func build() throws {
        for path in presentation.addedParts.keys {
            if let type = presentation.addedContentTypes[path] {
                contentTypes.setOverride(type, for: path)
            } else {
                contentTypes.ensureDefault(for: path)
            }
        }
        assignPartNames()
        removeDeletedSlides()
        for index in slides.indices {
            try writeSlide(at: index)
        }
        if presentation.isStructureModified || createdNotesMasterRelationship != nil {
            try writePresentationPart()
        }
        parts[PackagePath.relationships(of: mainPart)] = Relationship.xml(mainRelationships)
        parts["[Content_Types].xml"] = contentTypes.data
    }

    func archive() throws -> Data {
        // Content types first: some readers insist on it.
        let order = ["[Content_Types].xml", "_rels/.rels"]
        let rest = parts.keys.filter { !order.contains($0) }.sorted()
        return try ZipArchive.archive(entries: (order + rest).compactMap { path in
            parts[path].map { (path: path, data: $0) }
        })
    }

    // MARK: - Slide list

    private mutating func assignPartNames() {
        var taken = Set(parts.keys)
        for index in slides.indices where slides[index].partName == nil {
            let name = PackagePath.unused(prefix: "ppt/slides/slide", suffix: ".xml", taken: taken)
            taken.insert(name)
            slides[index].partName = name
        }
    }

    private var originalSlidePaths: [String] {
        mainRelationships.filter { $0.type == OOXML.RelationshipType.slide }
            .map { PackagePath.resolve($0.target, from: mainPart) }
    }

    private mutating func removeDeletedSlides() {
        let kept = Set(slides.compactMap(\.partName))
        for path in originalSlidePaths where !kept.contains(path) {
            let relationships = Relationship.parse(parts[PackagePath.relationships(of: path)])
            // A slide's notes belong to it alone and go with it.
            for notes in relationships where notes.type == OOXML.RelationshipType.notesSlide {
                removePart(PackagePath.resolve(notes.target, from: path))
            }
            removePart(path)
            let mainPart = mainPart
            mainRelationships.removeAll {
                $0.type == OOXML.RelationshipType.slide && PackagePath.resolve($0.target, from: mainPart) == path
            }
        }
    }

    private mutating func removePart(_ path: String) {
        parts[path] = nil
        parts[PackagePath.relationships(of: path)] = nil
        contentTypes.removeOverride(for: path)
    }

    // MARK: - Slides

    private mutating func writeSlide(at index: Int) throws {
        var slide = slides[index]
        guard let path = slide.partName else { return }
        let isNewPart = path != slide.sourcePart

        if !mainRelationships.contains(where: {
            $0.type == OOXML.RelationshipType.slide && PackagePath.resolve($0.target, from: mainPart) == path
        }) {
            mainRelationships.append(Relationship(
                id: Relationship.unusedID(in: mainRelationships), type: OOXML.RelationshipType.slide,
                target: PackagePath.relativeTarget(to: path, from: mainPart)
            ))
            contentTypes.setOverride(OOXML.ContentType.slide, for: path)
        }

        if slide.areNotesModified {
            try writeNotes(for: &slide, slidePath: path)
        }

        if slide.isModified || isNewPart {
            if slide.canEditShapes || slide.sourcePart == nil {
                parts[path] = try slideXML(for: &slide, path: path)
            } else if let source = slide.sourcePart {
                parts[path] = presentation.package.parts[source]
            }
        }

        let original = Relationship.parse(presentation.package.parts[PackagePath.relationships(of: path)])
        if isNewPart || slide.relationships != original {
            parts[PackagePath.relationships(of: path)] = Relationship.xml(slide.relationships)
        }
        slides[index] = slide
    }

    private func slideXML(for slide: inout Slide, path: String) throws -> Data {
        let base = slide.sourcePart.flatMap { presentation.package.parts[$0] } ?? Data(SlideSkeleton.slide.utf8)
        guard let root = try? XMLLite.parse(base),
              let common = root.firstChild(named: "cSld"),
              let tree = common.firstChild(named: "spTree") else {
            throw PresentationWriteError.unwritablePart(path)
        }
        let scope = PPTXReader.namespacesInScope(of: tree)
        var writer = ShapeWriter(partPath: path, namespaces: scope, relationships: slide.relationships)
        for child in tree.children where !["nvGrpSpPr", "grpSpPr"].contains(child.name) {
            tree.removeChild(child)
        }
        for shape in slide.shapes {
            guard let xml = writer.xml(for: shape),
                  let element = XMLLite.fragment(xml, namespaces: scope.filter { !$0.key.isEmpty }) else {
                throw PresentationWriteError.unwritablePart(path)
            }
            tree.insertChild(element, at: tree.children.count)
        }
        root.setAttribute("show", slide.isHidden ? "0" : nil)
        if slide.isBackgroundModified {
            if let existing = common.firstChild(named: "bg") { common.removeChild(existing) }
            if case .fill(let fill) = slide.background,
               let background = XMLLite.fragment(
                "<p:bg><p:bgPr>\(writer.fillXML(fill))<a:effectLst/></p:bgPr></p:bg>", namespaces: writer.fragmentNamespaces
               ) {
                common.insertChild(background, at: 0)
            }
        }
        slide.relationships = writer.relationships
        if slide.hasRemovedShapes, let timing = root.firstChild(named: "timing") {
            // Animations name shapes by id; with one gone they point at nothing.
            root.removeChild(timing)
        }
        guard let xml = XMLLite.serialize(root) else { throw PresentationWriteError.unwritablePart(path) }
        return Data((PackagePath.declaration + xml).utf8)
    }

    // MARK: - Notes

    private mutating func writeNotes(for slide: inout Slide, slidePath: String) throws {
        let paragraphs = slide.notes.components(separatedBy: "\n").map { line in
            Paragraph(runs: line.isEmpty ? [] : [TextRun(text: line)])
        }
        let writer = ShapeWriter(partPath: "", namespaces: [:], relationships: [])
        let paragraphXML = paragraphs.map(writer.paragraphXML).joined()

        if let notesPath = slide.notesPart, let data = parts[notesPath],
           let root = try? XMLLite.parse(data),
           let tree = root.firstChild(named: "cSld")?.firstChild(named: "spTree") {
            let body = tree.children(named: "sp").first {
                $0.firstChild(named: "nvSpPr")?.firstChild(named: "nvPr")?.firstChild(named: "ph")?.attribute("type") == "body"
            }
            if let body {
                let text = body.firstChild(named: "txBody")
                for paragraph in text?.children(named: "p") ?? [] { text?.removeChild(paragraph) }
                if let text, let wrapper = XMLLite.fragment("<a:txBody>\(paragraphXML)</a:txBody>", namespaces: OOXML.namespaces) {
                    for paragraph in wrapper.children { text.insertChild(paragraph, at: text.children.count) }
                }
            } else if let shape = XMLLite.fragment(SlideSkeleton.notesBody(paragraphXML, id: 99), namespaces: OOXML.namespaces) {
                tree.insertChild(shape, at: tree.children.count)
            }
            guard let xml = XMLLite.serialize(root) else { throw PresentationWriteError.unwritablePart(notesPath) }
            parts[notesPath] = Data((PackagePath.declaration + xml).utf8)
            return
        }

        guard !slide.notes.isEmpty else { return }
        let masterPath = notesMasterPath()
        let notesPath = PackagePath.unused(prefix: "ppt/notesSlides/notesSlide", suffix: ".xml", taken: Set(parts.keys))
        parts[notesPath] = Data((PackagePath.declaration + SlideSkeleton.notes(paragraphXML)).utf8)
        parts[PackagePath.relationships(of: notesPath)] = Relationship.xml([
            Relationship(id: "rId1", type: OOXML.RelationshipType.notesMaster,
                         target: PackagePath.relativeTarget(to: masterPath, from: notesPath)),
            Relationship(id: "rId2", type: OOXML.RelationshipType.slide,
                         target: PackagePath.relativeTarget(to: slidePath, from: notesPath)),
        ])
        contentTypes.setOverride(OOXML.ContentType.notesSlide, for: notesPath)
        slide.relationships.append(Relationship(
            id: Relationship.unusedID(in: slide.relationships), type: OOXML.RelationshipType.notesSlide,
            target: PackagePath.relativeTarget(to: notesPath, from: slidePath)
        ))
        slide.notesPart = notesPath
    }

    /// The presentation's notes master, made if it has none: notes pages
    /// cannot exist without one.
    private mutating func notesMasterPath() -> String {
        if let existing = presentation.resources.notesMasterPath ?? mainRelationships
            .first(where: { $0.type == OOXML.RelationshipType.notesMaster })
            .map({ PackagePath.resolve($0.target, from: mainPart) }) {
            return existing
        }
        let taken = Set(parts.keys)
        let masterPath = PackagePath.unused(prefix: "ppt/notesMasters/notesMaster", suffix: ".xml", taken: taken)
        let themePath = PackagePath.unused(prefix: "ppt/theme/theme", suffix: ".xml", taken: taken)
        // The notes master gets a theme of its own: a copy of the slides'.
        let slideTheme = presentation.resources.masters.values.first.flatMap { master in
            Relationship.parse(parts[PackagePath.relationships(of: master.path)])
                .first { $0.type == OOXML.RelationshipType.theme }
                .flatMap { parts[PackagePath.resolve($0.target, from: master.path)] }
        }
        parts[themePath] = slideTheme ?? Data(PresentationTemplate.parts()["ppt/theme/theme1.xml"] ?? Data())
        contentTypes.setOverride(OOXML.ContentType.theme, for: themePath)
        parts[masterPath] = Data((PackagePath.declaration + SlideSkeleton.notesMaster).utf8)
        parts[PackagePath.relationships(of: masterPath)] = Relationship.xml([
            Relationship(id: "rId1", type: OOXML.RelationshipType.theme,
                         target: PackagePath.relativeTarget(to: themePath, from: masterPath)),
        ])
        contentTypes.setOverride(OOXML.ContentType.notesMaster, for: masterPath)
        let id = Relationship.unusedID(in: mainRelationships)
        mainRelationships.append(Relationship(
            id: id, type: OOXML.RelationshipType.notesMaster,
            target: PackagePath.relativeTarget(to: masterPath, from: mainPart)
        ))
        createdNotesMasterRelationship = id
        return masterPath
    }

    // MARK: - Presentation part

    private mutating func writePresentationPart() throws {
        guard let data = parts[mainPart], let root = try? XMLLite.parse(data) else {
            throw PresentationWriteError.unwritablePart(mainPart)
        }
        let scope = PPTXReader.namespacesInScope(of: root)
        let namespaces = OOXML.namespaces.merging(scope.filter { !$0.key.isEmpty }) { _, inScope in inScope }
        func insert(_ xml: String, into parent: XMLElement, at index: Int) {
            if let element = XMLLite.fragment(xml, namespaces: namespaces) {
                parent.insertChild(element, at: index)
            }
        }

        if presentation.isStructureModified, let list = root.firstChild(named: "sldIdLst") ?? {
            let created = XMLLite.fragment("<p:sldIdLst/>", namespaces: namespaces)
            let after = root.children.lastIndex { ["sldMasterIdLst", "notesMasterIdLst", "handoutMasterIdLst"].contains($0.name) }
            if let created { root.insertChild(created, at: (after ?? 0) + 1) }
            return created
        }() {
            var listIDs: [String: Int] = [:]
            for entry in list.children(named: "sldId") {
                if let relationship = entry.relationshipID, let id = entry.attribute("id").flatMap(Int.init) {
                    listIDs[relationship] = id
                }
            }
            for entry in list.children { list.removeChild(entry) }
            var nextID = max(256, (listIDs.values.max() ?? 255) + 1)
            var keptIDs: Set<Int> = []
            for slide in slides {
                guard let path = slide.partName, let relationship = mainRelationships.first(where: {
                    $0.type == OOXML.RelationshipType.slide && PackagePath.resolve($0.target, from: mainPart) == path
                }) else { continue }
                let id = listIDs[relationship.id] ?? {
                    defer { nextID += 1 }
                    return nextID
                }()
                keptIDs.insert(id)
                insert("<p:sldId id=\"\(id)\" r:id=\"\(relationship.id)\"/>", into: list, at: list.children.count)
            }
            pruneSlideReferences(in: root, keeping: keptIDs)
        }

        if let notesMaster = createdNotesMasterRelationship, root.firstChild(named: "notesMasterIdLst") == nil {
            let after = root.children.firstIndex { $0.name == "sldMasterIdLst" } ?? -1
            insert(
                "<p:notesMasterIdLst><p:notesMasterId r:id=\"\(notesMaster)\"/></p:notesMasterIdLst>",
                into: root, at: after + 1
            )
        }

        guard let xml = XMLLite.serialize(root) else { throw PresentationWriteError.unwritablePart(mainPart) }
        parts[mainPart] = Data((PackagePath.declaration + xml).utf8)
    }

    /// Custom shows and sections list slides too. Entries for slides that
    /// are gone are dropped, and sections — which must cover every slide,
    /// and which Dazzle cannot place a new slide into — are dropped whole.
    private func pruneSlideReferences(in root: XMLElement, keeping keptIDs: Set<Int>) {
        let livingRelationships = Set(mainRelationships.map(\.id))
        for show in root.firstChild(named: "custShowLst")?.children(named: "custShow") ?? [] {
            guard let list = show.firstChild(named: "sldLst") else { continue }
            for entry in list.children where !livingRelationships.contains(entry.relationshipID ?? "") {
                list.removeChild(entry)
            }
        }
        if let extensions = root.firstChild(named: "extLst") {
            for item in extensions.children where item.firstChild(named: "sectionLst") != nil {
                extensions.removeChild(item)
            }
        }
    }
}

/// `[Content_Types].xml`.
private struct ContentTypes {
    var defaults: [(extension: String, type: String)] = []
    var overrides: [String: String] = [:]

    init(data: Data?) {
        guard let data, let root = try? XMLLite.parse(data) else { return }
        defaults = root.children(named: "Default").compactMap { element in
            guard let ext = element.attribute("Extension"), let type = element.attribute("ContentType") else { return nil }
            return (ext, type)
        }
        for element in root.children(named: "Override") {
            if let part = element.attribute("PartName"), let type = element.attribute("ContentType") {
                overrides[part] = type
            }
        }
    }

    mutating func setOverride(_ type: String, for path: String) {
        overrides["/" + path] = type
    }

    mutating func removeOverride(for path: String) {
        overrides["/" + path] = nil
    }

    mutating func ensureDefault(for path: String) {
        let ext = (path as NSString).pathExtension.lowercased()
        guard !ext.isEmpty, !defaults.contains(where: { $0.extension.lowercased() == ext }) else { return }
        let type = switch ext {
        case "png": "image/png"
        case "jpg", "jpeg": "image/jpeg"
        case "gif": "image/gif"
        case "xml": "application/xml"
        case "rels": "application/vnd.openxmlformats-package.relationships+xml"
        case "xlsx": "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet"
        case "mp4", "m4v": "video/mp4"
        case "mov": "video/quicktime"
        case "m4a": "audio/mp4"
        case "mp3": "audio/mpeg"
        case "wav": "audio/wav"
        default: "application/octet-stream"
        }
        defaults.append((ext, type))
    }

    var data: Data {
        let defaultEntries = defaults.map {
            "<Default Extension=\"\(XMLLite.escape($0.extension))\" ContentType=\"\(XMLLite.escape($0.type))\"/>"
        }
        let overrideEntries = overrides.sorted { $0.key < $1.key }.map {
            "<Override PartName=\"\(XMLLite.escape($0.key))\" ContentType=\"\(XMLLite.escape($0.value))\"/>"
        }
        return Data((PackagePath.declaration + "<Types xmlns=\"\(OOXML.contentTypesNS)\">"
            + defaultEntries.joined() + overrideEntries.joined() + "</Types>").utf8)
    }
}

/// XML for parts Dazzle makes from nothing.
enum SlideSkeleton {
    private static let namespaces = OOXML.namespaces.sorted { $0.key < $1.key }
        .map { "xmlns:\($0.key)=\"\($0.value)\"" }.joined(separator: " ")

    private static let groupProperties = """
        <p:nvGrpSpPr><p:cNvPr id="1" name=""/><p:cNvGrpSpPr/><p:nvPr/></p:nvGrpSpPr><p:grpSpPr><a:xfrm>\
        <a:off x="0" y="0"/><a:ext cx="0" cy="0"/><a:chOff x="0" y="0"/><a:chExt cx="0" cy="0"/></a:xfrm></p:grpSpPr>
        """

    static let slide = """
        <p:sld \(namespaces)><p:cSld><p:spTree>\(groupProperties)</p:spTree></p:cSld>\
        <p:clrMapOvr><a:masterClrMapping/></p:clrMapOvr></p:sld>
        """

    static func notesBody(_ paragraphs: String, id: Int) -> String {
        """
        <p:sp><p:nvSpPr><p:cNvPr id="\(id)" name="Notes Placeholder \(id - 1)"/><p:cNvSpPr><a:spLocks noGrp="1"/>\
        </p:cNvSpPr><p:nvPr><p:ph type="body" idx="1"/></p:nvPr></p:nvSpPr><p:spPr/><p:txBody><a:bodyPr/>\
        <a:lstStyle/>\(paragraphs)</p:txBody></p:sp>
        """
    }

    static func notes(_ paragraphs: String) -> String {
        """
        <p:notes \(namespaces)><p:cSld><p:spTree>\(groupProperties)\
        <p:sp><p:nvSpPr><p:cNvPr id="2" name="Slide Image Placeholder 1"/><p:cNvSpPr><a:spLocks noGrp="1" \
        noRot="1" noChangeAspect="1"/></p:cNvSpPr><p:nvPr><p:ph type="sldImg"/></p:nvPr></p:nvSpPr><p:spPr/></p:sp>\
        \(notesBody(paragraphs, id: 3))</p:spTree></p:cSld><p:clrMapOvr><a:masterClrMapping/></p:clrMapOvr></p:notes>
        """
    }

    static let notesMaster = """
        <p:notesMaster \(namespaces)><p:cSld><p:bg><p:bgRef idx="1001"><a:schemeClr val="bg1"/></p:bgRef></p:bg>\
        <p:spTree>\(groupProperties)\
        <p:sp><p:nvSpPr><p:cNvPr id="2" name="Slide Image Placeholder 1"/><p:cNvSpPr><a:spLocks noGrp="1" \
        noRot="1" noChangeAspect="1"/></p:cNvSpPr><p:nvPr><p:ph type="sldImg" idx="2"/></p:nvPr></p:nvSpPr>\
        <p:spPr><a:xfrm><a:off x="685800" y="1143000"/><a:ext cx="5486400" cy="3086100"/></a:xfrm>\
        <a:prstGeom prst="rect"><a:avLst/></a:prstGeom><a:noFill/><a:ln w="12700"><a:solidFill>\
        <a:prstClr val="black"/></a:solidFill></a:ln></p:spPr></p:sp>\
        <p:sp><p:nvSpPr><p:cNvPr id="3" name="Notes Placeholder 2"/><p:cNvSpPr><a:spLocks noGrp="1"/></p:cNvSpPr>\
        <p:nvPr><p:ph type="body" sz="quarter" idx="3"/></p:nvPr></p:nvSpPr><p:spPr><a:xfrm>\
        <a:off x="685800" y="4400550"/><a:ext cx="5486400" cy="3600450"/></a:xfrm><a:prstGeom prst="rect">\
        <a:avLst/></a:prstGeom></p:spPr><p:txBody><a:bodyPr vert="horz" lIns="91440" tIns="45720" rIns="91440" \
        bIns="45720" rtlCol="0"/><a:lstStyle/><a:p><a:endParaRPr lang="en-US"/></a:p></p:txBody></p:sp>\
        </p:spTree></p:cSld><p:clrMap bg1="lt1" tx1="dk1" bg2="lt2" tx2="dk2" accent1="accent1" \
        accent2="accent2" accent3="accent3" accent4="accent4" accent5="accent5" accent6="accent6" hlink="hlink" \
        folHlink="folHlink"/><p:notesStyle><a:lvl1pPr marL="0" algn="l" defTabSz="914400" rtl="0" eaLnBrk="1" \
        latinLnBrk="0" hangingPunct="1"><a:defRPr sz="1200" kern="1200"><a:solidFill><a:schemeClr val="tx1"/>\
        </a:solidFill><a:latin typeface="+mn-lt"/><a:ea typeface="+mn-ea"/><a:cs typeface="+mn-cs"/></a:defRPr>\
        </a:lvl1pPr></p:notesStyle></p:notesMaster>
        """
}
