import Foundation

enum PresentationReadError: LocalizedError {
    case notAPresentation

    var errorDescription: String? {
        String(localized: "Error.NotAPresentation")
    }
}

/// Reads a `.pptx`, `.pptm` or `.ppsx` package.
enum PPTXReader {
    static func presentation(from data: Data) throws -> Presentation {
        try presentation(fromParts: ZipArchive.entries(in: data))
    }

    static func presentation(fromParts parts: [String: Data]) throws -> Presentation {
        let rootRelationships = Relationship.parse(parts["_rels/.rels"])
        let mainPart = rootRelationships.first { $0.type == OOXML.RelationshipType.officeDocument }
            .map { PackagePath.resolve($0.target, from: "") } ?? "ppt/presentation.xml"
        guard let mainData = parts[mainPart], let main = try? XMLLite.parse(mainData),
              main.name == "presentation" else {
            throw PresentationReadError.notAPresentation
        }
        let mainRelationships = Relationship.parse(parts[PackagePath.relationships(of: mainPart)])
        func target(_ id: String?) -> String? {
            guard let id, let relationship = mainRelationships.first(where: { $0.id == id }) else { return nil }
            return PackagePath.resolve(relationship.target, from: mainPart)
        }

        var features: Set<UnsupportedFeatureReport.Feature> = []
        if mainRelationships.contains(where: { $0.type == OOXML.RelationshipType.vbaProject })
            || parts.keys.contains(where: { $0.hasSuffix("vbaProject.bin") }) {
            features.insert(.macros)
        }

        // Masters, and the layouts each one offers.
        var masters: [String: SlideMaster] = [:]
        var layouts: [String: SlideLayout] = [:]
        var layoutOrder: [String] = []
        let masterPaths = main.firstChild(named: "sldMasterIdLst")?.children(named: "sldMasterId")
            .compactMap { target($0.relationshipID) } ?? []
        let masterTargets = masterPaths.isEmpty
            ? mainRelationships.filter { $0.type == OOXML.RelationshipType.slideMaster }
                .map { PackagePath.resolve($0.target, from: mainPart) }
            : masterPaths
        for masterPath in masterTargets {
            guard let master = readMaster(masterPath, parts: parts) else { continue }
            masters[masterPath] = master.master
            for layoutPath in master.layoutPaths {
                guard layouts[layoutPath] == nil,
                      let layout = readLayout(layoutPath, master: master.master, parts: parts) else { continue }
                layouts[layoutPath] = layout
                if masters.count == 1 { layoutOrder.append(layoutPath) }
            }
        }

        let resources = DeckResources(
            masters: masters, layouts: layouts, layoutOrder: layoutOrder,
            defaultTextStyle: ListStyle(element: main.firstChild(named: "defaultTextStyle")),
            notesMasterPath: target(main.firstChild(named: "notesMasterIdLst")?.firstChild(named: "notesMasterId")?.relationshipID)
        )

        // Slides, in the order the presentation lists them.
        var slides: [Slide] = []
        for entry in main.firstChild(named: "sldIdLst")?.children(named: "sldId") ?? [] {
            guard let path = target(entry.relationshipID), parts[path] != nil else { continue }
            guard var slide = readSlide(path, resources: resources, parts: parts, features: &features) else { continue }
            slide.partName = path
            slide.sourcePart = path
            slides.append(slide)
        }

        let size = main.firstChild(named: "sldSz")
        return Presentation(
            slideSize: EMUSize(
                width: size?.attribute("cx").flatMap(Int.init) ?? EMUSize.widescreen.width,
                height: size?.attribute("cy").flatMap(Int.init) ?? EMUSize.widescreen.height
            ),
            slides: slides,
            resources: resources,
            package: Package(
                parts: parts, mainPart: mainPart,
                unsupportedFeatures: UnsupportedFeatureReport(features: features)
            )
        )
    }

    // MARK: - Masters and layouts

    private static func readMaster(_ path: String, parts: [String: Data]) -> (master: SlideMaster, layoutPaths: [String])? {
        guard let data = parts[path], let root = try? XMLLite.parse(data) else { return nil }
        let relationships = Relationship.parse(parts[PackagePath.relationships(of: path)])
        let theme = relationships.first { $0.type == OOXML.RelationshipType.theme }
            .flatMap { parts[PackagePath.resolve($0.target, from: path)] }
            .flatMap { try? XMLLite.parse($0) }
            .map(readTheme) ?? .office
        let parser = ShapeParser(partPath: path, relationships: relationships, namespaces: [:], parts: parts)
        let common = root.firstChild(named: "cSld")
        let styles = root.firstChild(named: "txStyles")

        var colorMap = SlideMaster.defaultColorMap
        if let map = root.firstChild(named: "clrMap") {
            for key in colorMap.keys {
                if let value = map.attribute(key) { colorMap[key] = value }
            }
        }

        let layoutIDs = root.firstChild(named: "sldLayoutIdLst")?.children(named: "sldLayoutId")
            .compactMap(\.relationshipID) ?? []
        var layoutPaths = layoutIDs.compactMap { id in
            relationships.first { $0.id == id }.map { PackagePath.resolve($0.target, from: path) }
        }
        if layoutPaths.isEmpty {
            layoutPaths = relationships.filter { $0.type == OOXML.RelationshipType.slideLayout }
                .map { PackagePath.resolve($0.target, from: path) }
        }

        let master = SlideMaster(
            path: path, theme: theme, colorMap: colorMap,
            background: Background(element: common?.firstChild(named: "bg"), image: parser.target(of:)),
            shapes: parser.shapes(in: common?.firstChild(named: "spTree")),
            titleStyle: ListStyle(element: styles?.firstChild(named: "titleStyle")),
            bodyStyle: ListStyle(element: styles?.firstChild(named: "bodyStyle")),
            otherStyle: ListStyle(element: styles?.firstChild(named: "otherStyle"))
        )
        return (master, layoutPaths)
    }

    private static func readLayout(_ path: String, master: SlideMaster, parts: [String: Data]) -> SlideLayout? {
        guard let data = parts[path], let root = try? XMLLite.parse(data) else { return nil }
        let relationships = Relationship.parse(parts[PackagePath.relationships(of: path)])
        let parser = ShapeParser(
            partPath: path, relationships: relationships, namespaces: [:],
            inheritedShapes: [master.shapes], parts: parts
        )
        let common = root.firstChild(named: "cSld")
        var override: [String: String]?
        if let mapping = root.firstChild(named: "clrMapOvr")?.firstChild(named: "overrideClrMapping") {
            override = SlideMaster.defaultColorMap.keys.reduce(into: [:]) { map, key in
                map[key] = mapping.attribute(key)
            }
        }
        return SlideLayout(
            path: path,
            name: common?.attribute("name") ?? (path as NSString).lastPathComponent,
            masterPath: master.path,
            background: Background(element: common?.firstChild(named: "bg"), image: parser.target(of:)),
            shapes: parser.shapes(in: common?.firstChild(named: "spTree")),
            showsMasterShapes: root.attribute("showMasterSp") != "0",
            colorMapOverride: override
        )
    }

    private static func readTheme(_ root: XMLElement) -> Theme {
        let elements = root.firstChild(named: "themeElements")
        var colors = Theme.office.colors
        for slot in elements?.firstChild(named: "clrScheme")?.children ?? [] {
            if let rgb = slot.firstChild(named: "srgbClr")?.attribute("val").flatMap({ UInt32($0, radix: 16) }) {
                colors[slot.name] = rgb
            } else if let system = slot.firstChild(named: "sysClr") {
                colors[slot.name] = system.attribute("lastClr").flatMap { UInt32($0, radix: 16) }
                    ?? (system.attribute("val") == "window" ? 0xFFFFFF : 0x000000)
            }
        }
        let fonts = elements?.firstChild(named: "fontScheme")
        let format = elements?.firstChild(named: "fmtScheme")
        func fills(_ name: String) -> [Fill] {
            format?.firstChild(named: name)?.children.compactMap { Fill.parse(element: $0) { _ in nil } } ?? []
        }
        return Theme(
            colors: colors,
            majorFont: fonts?.firstChild(named: "majorFont")?.firstChild(named: "latin")?.attribute("typeface")
                ?? Theme.office.majorFont,
            minorFont: fonts?.firstChild(named: "minorFont")?.firstChild(named: "latin")?.attribute("typeface")
                ?? Theme.office.minorFont,
            majorEastAsianFont: fonts?.firstChild(named: "majorFont")?.firstChild(named: "ea")?.attribute("typeface")?.nilIfEmpty,
            minorEastAsianFont: fonts?.firstChild(named: "minorFont")?.firstChild(named: "ea")?.attribute("typeface")?.nilIfEmpty,
            fillStyles: fills("fillStyleLst"),
            backgroundFillStyles: fills("bgFillStyleLst"),
            lineStyles: format?.firstChild(named: "lnStyleLst")?.children(named: "ln").map(LineStyle.init(element:)) ?? []
        )
    }

    // MARK: - Slides

    private static func readSlide(
        _ path: String, resources: DeckResources, parts: [String: Data],
        features: inout Set<UnsupportedFeatureReport.Feature>
    ) -> Slide? {
        guard let data = parts[path], let root = try? XMLLite.parse(data) else { return nil }
        let relationships = Relationship.parse(parts[PackagePath.relationships(of: path)])
        let layoutPath = relationships.first { $0.type == OOXML.RelationshipType.slideLayout }
            .map { PackagePath.resolve($0.target, from: path) } ?? resources.layoutOrder.first ?? ""
        let layout = resources.layouts[layoutPath]
        let master = resources.master(for: layout)
        let tree = root.firstChild(named: "cSld")?.firstChild(named: "spTree")

        let parser = ShapeParser(
            partPath: path, relationships: relationships,
            namespaces: namespacesInScope(of: tree),
            inheritedShapes: [layout?.shapes ?? [], master?.shapes ?? []],
            parts: parts, capturesSource: true
        )
        var slide = Slide(layoutPath: layoutPath, relationships: relationships, shapes: parser.shapes(in: tree))
        slide.background = Background(element: root.firstChild(named: "cSld")?.firstChild(named: "bg"), image: parser.target(of:))
        slide.isHidden = root.attribute("show") == "0"
        slide.showsMasterShapes = root.attribute("showMasterSp") != "0"
        slide.canEditShapes = !parser.hasUncapturableShape
        features.formUnion(parser.features)
        if root.firstChild(named: "timing") != nil { features.insert(.animations) }

        if let notesPath = relationships.first(where: { $0.type == OOXML.RelationshipType.notesSlide })
            .map({ PackagePath.resolve($0.target, from: path) }) {
            slide.notesPart = notesPath
            slide.notes = notesText(parts[notesPath]) ?? ""
        }
        return slide
    }

    /// The speaker notes: the text of a notes page's body placeholder.
    static func notesText(_ data: Data?) -> String? {
        guard let data, let root = try? XMLLite.parse(data),
              let tree = root.firstChild(named: "cSld")?.firstChild(named: "spTree") else { return nil }
        let parser = ShapeParser(partPath: "", relationships: [], namespaces: [:], parts: [:])
        let body = parser.shapes(in: tree).first { $0.placeholder?.type == "body" }
        return body?.text?.plainText
    }

    /// Every namespace binding visible at `element`, from it up to the root.
    static func namespacesInScope(of element: XMLElement?) -> [String: String] {
        var result: [String: String] = [:]
        var current = element
        while let node = current {
            for (prefix, uri) in node.namespaceDeclarations where result[prefix] == nil {
                result[prefix] = uri
            }
            current = node.parent
        }
        return result
    }
}
