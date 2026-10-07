import Foundation

/// Changing a presentation's slide size, as PowerPoint's Slide Size does.
///
/// Everything on the slides, the layouts and the masters is scaled by the
/// same amount both ways, so nothing is stretched, and centred on the new
/// slide. Fitting scales by the smaller of the two changes, so everything
/// stays in view; maximising by the larger, so the slide stays full.
/// Text is scaled with it.
enum SlideSizeConverter {
    enum Scaling: Sendable {
        case ensureFit
        case maximize
    }

    /// Sizes PowerPoint offers by name.
    enum Preset: String, CaseIterable, Identifiable, Sendable {
        case widescreen
        case standard
        case widescreen16x10
        case a4

        var id: Self { self }

        var size: EMUSize {
            switch self {
            case .widescreen: .widescreen
            case .standard: EMUSize(width: 9_144_000, height: 6_858_000)
            case .widescreen16x10: EMUSize(width: 10_972_800, height: 6_858_000)
            case .a4: EMUSize(width: 9_906_000, height: 6_858_000)
            }
        }

        /// `p:sldSz`'s `type`.
        var typeName: String {
            switch self {
            case .widescreen: "custom"
            case .standard: "screen4x3"
            case .widescreen16x10: "screen16x10"
            case .a4: "A4"
            }
        }

        static func matching(_ size: EMUSize) -> Preset? {
            allCases.first { $0.size == size }
        }
    }

    static func convert(_ presentation: Presentation, to preset: Preset, scaling: Scaling) throws -> Presentation {
        let old = presentation.slideSize
        let new = preset.size
        let factorX = Double(new.width) / Double(max(old.width, 1))
        let factorY = Double(new.height) / Double(max(old.height, 1))
        let factor = scaling == .ensureFit ? min(factorX, factorY) : max(factorX, factorY)
        let shift = (
            x: (Double(new.width) - Double(old.width) * factor) / 2,
            y: (Double(new.height) - Double(old.height) * factor) / 2
        )

        var parts = try ZipArchive.entries(in: PPTXWriter.data(from: presentation))
        let mainPart = presentation.package.mainPart
        for (path, data) in parts where isScaledPart(path) {
            guard let root = try? XMLLite.parse(data) else { continue }
            if let tree = root.firstChild(named: "cSld")?.firstChild(named: "spTree") {
                for shape in tree.children { place(shape, factor: factor, shift: shift) }
            }
            scaleText(in: root, by: factor)
            guard let xml = XMLLite.serialize(root) else { throw PresentationWriteError.unwritablePart(path) }
            parts[path] = Data((PackagePath.declaration + xml).utf8)
        }

        guard let data = parts[mainPart], let root = try? XMLLite.parse(data) else {
            throw PresentationWriteError.unwritablePart(mainPart)
        }
        if let size = root.firstChild(named: "sldSz") {
            size.setAttribute("cx", String(new.width))
            size.setAttribute("cy", String(new.height))
            size.setAttribute("type", preset.typeName)
        }
        if let defaults = root.firstChild(named: "defaultTextStyle") { scaleText(in: defaults, by: factor) }
        guard let xml = XMLLite.serialize(root) else { throw PresentationWriteError.unwritablePart(mainPart) }
        parts[mainPart] = Data((PackagePath.declaration + xml).utf8)
        return try PPTXReader.presentation(fromParts: parts)
    }

    private static func isScaledPart(_ path: String) -> Bool {
        guard path.hasSuffix(".xml"), !path.contains("/_rels/") else { return false }
        return path.hasPrefix("ppt/slides/") || path.hasPrefix("ppt/slideLayouts/") || path.hasPrefix("ppt/slideMasters/")
    }

    /// Moves and sizes one shape in slide space. A group's members are in
    /// the group's own space, so follow it without being touched.
    private static func place(_ shape: XMLElement, factor: Double, shift: (x: Double, y: Double)) {
        if shape.name == "AlternateContent" {
            for branch in shape.children {
                for child in branch.children { place(child, factor: factor, shift: shift) }
            }
            return
        }
        let transform = shape.firstChild(named: "spPr")?.firstChild(named: "xfrm")
            ?? shape.firstChild(named: "grpSpPr")?.firstChild(named: "xfrm")
            ?? shape.firstChild(named: "xfrm")
        if let transform {
            func scale(_ element: XMLElement?, _ key: String, offset: Double) {
                guard let element, let value = element.attribute(key).flatMap(Double.init) else { return }
                element.setAttribute(key, String(Int((value * factor + offset).rounded())))
            }
            let position = transform.firstChild(named: "off")
            scale(position, "x", offset: shift.x)
            scale(position, "y", offset: shift.y)
            let extent = transform.firstChild(named: "ext")
            scale(extent, "cx", offset: 0)
            scale(extent, "cy", offset: 0)
        }
        // A table's grid has sizes of its own.
        if let table = shape.firstChild(named: "graphic")?.firstChild(named: "graphicData")?.firstChild(named: "tbl") {
            for column in table.firstChild(named: "tblGrid")?.children(named: "gridCol") ?? [] {
                if let width = column.attribute("w").flatMap(Double.init) {
                    column.setAttribute("w", String(Int((width * factor).rounded())))
                }
            }
            for row in table.children(named: "tr") {
                if let height = row.attribute("h").flatMap(Double.init) {
                    row.setAttribute("h", String(Int((height * factor).rounded())))
                }
            }
        }
    }

    /// Scales every stated text size, and spacing given in points.
    private static func scaleText(in element: XMLElement, by factor: Double) {
        if ["rPr", "defRPr", "endParaRPr"].contains(element.name), let size = element.attribute("sz").flatMap(Double.init) {
            element.setAttribute("sz", String(min(max(Int((size * factor).rounded()), 100), 400_000)))
        }
        if element.name == "spcPts", let points = element.attribute("val").flatMap(Double.init) {
            element.setAttribute("val", String(Int((points * factor).rounded())))
        }
        for child in element.children { scaleText(in: child, by: factor) }
    }
}
