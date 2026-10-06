import CoreGraphics
import Foundation

/// Everything a slide inherits — its layout, master and theme — with the
/// lookups that turn a shape's unsaid properties into ones to draw with.
struct SlideStyleContext: Sendable {
    let resources: DeckResources
    let layout: SlideLayout?
    let master: SlideMaster?
    let colorMap: [String: String]

    init(presentation: Presentation, slide: Slide) {
        resources = presentation.resources
        layout = presentation.layout(for: slide)
        master = presentation.resources.master(for: layout)
        var map = master?.colorMap ?? SlideMaster.defaultColorMap
        for (key, value) in layout?.colorMapOverride ?? [:] { map[key] = value }
        colorMap = map
    }

    var theme: Theme { master?.theme ?? .office }

    // MARK: - Colour

    /// Resolves a colour through the colour map and theme. `placeholder`
    /// is what `phClr` stands for, when a style reference supplies one.
    func color(_ color: DrawingColor, placeholder: RGBAColor? = nil) -> RGBAColor {
        var resolved: RGBAColor
        switch color.base {
        case .rgb(let value):
            resolved = RGBAColor(hex: value)
        case .system(let name, let last):
            resolved = RGBAColor(hex: last ?? (name == "window" ? 0xFFFFFF : 0x000000))
        case .scheme(let name):
            if name == "phClr" {
                resolved = placeholder ?? .black
            } else {
                let slot = colorMap[name] ?? name
                resolved = RGBAColor(hex: theme.colors[slot] ?? theme.colors[name] ?? 0)
            }
        }
        for transform in color.transforms {
            resolved = resolved.applying(transform)
        }
        return resolved
    }

    // MARK: - Inheritance

    /// The layout and master placeholders a slide's placeholder inherits from.
    func sources(for shape: SlideShape) -> [SlideShape] {
        guard let placeholder = shape.placeholder else { return [] }
        return [
            layout?.shapes.inheritedPlaceholder(for: placeholder),
            master?.shapes.masterPlaceholder(for: placeholder),
        ].compactMap(\.self)
    }

    /// A fill with what `phClr` means for it.
    struct ResolvedFill {
        var fill: Fill
        var placeholderColor: RGBAColor?
    }

    func fill(for shape: SlideShape, sources: [SlideShape]) -> ResolvedFill? {
        if let fill = shape.fill { return ResolvedFill(fill: fill) }
        for source in sources {
            if let fill = source.fill { return ResolvedFill(fill: fill) }
        }
        for candidate in [shape] + sources {
            guard let reference = candidate.style?.fill, reference.index > 0 else { continue }
            let list = reference.index >= 1000 ? theme.backgroundFillStyles : theme.fillStyles
            let index = reference.index >= 1000 ? reference.index - 1001 : reference.index - 1
            let fill = list.indices.contains(index) ? list[index] : .solid(.scheme("phClr"))
            return ResolvedFill(fill: fill, placeholderColor: reference.color.map { color($0) })
        }
        return nil
    }

    func line(for shape: SlideShape, sources: [SlideShape]) -> (line: LineStyle, placeholderColor: RGBAColor?)? {
        var line = shape.line
        for source in sources {
            if let inherited = source.line { line = line?.merged(over: inherited) ?? inherited }
        }
        for candidate in [shape] + sources {
            guard let reference = candidate.style?.line, reference.index > 0 else { continue }
            let themed = theme.lineStyles.indices.contains(reference.index - 1)
                ? theme.lineStyles[reference.index - 1]
                : LineStyle(fill: .solid(.scheme("phClr")), width: 12_700)
            return ((line ?? LineStyle()).merged(over: themed), reference.color.map { color($0) })
        }
        return line.map { ($0, nil) }
    }

    func background(of slide: Slide) -> ResolvedFill {
        let background = slide.background ?? layout?.background ?? master?.background
        switch background {
        case .fill(let fill):
            return ResolvedFill(fill: fill)
        case .reference(let index, let reference):
            let list = index >= 1000 ? theme.backgroundFillStyles : theme.fillStyles
            let position = index >= 1000 ? index - 1001 : index - 1
            let fill = list.indices.contains(position) ? list[position] : .solid(.scheme("phClr"))
            return ResolvedFill(fill: fill, placeholderColor: reference.map { color($0) })
        case nil:
            return ResolvedFill(fill: .solid(.scheme("bg1")))
        }
    }

    // MARK: - Text

    func bodyProperties(for shape: SlideShape, sources: [SlideShape]) -> BodyProperties {
        var properties = shape.text?.properties ?? BodyProperties()
        for source in sources {
            if let inherited = source.text?.properties { properties = properties.merged(over: inherited) }
        }
        return properties
    }

    /// Paragraph properties at an outline level, with everything above the
    /// paragraph itself folded in.
    func paragraphBase(for shape: SlideShape, sources: [SlideShape], level: Int) -> ParagraphProperties {
        var properties = shape.text?.listStyle.level(level) ?? ParagraphProperties()
        for source in sources {
            if let inherited = source.text?.listStyle.level(level) { properties = properties.merged(over: inherited) }
        }
        if let fontColor = shape.style?.fontColor ?? sources.lazy.compactMap(\.style?.fontColor).first {
            var layer = ParagraphProperties()
            layer.defaultRun.color = fontColor
            properties = properties.merged(over: layer)
        }
        if let placeholder = shape.placeholder, let master {
            properties = properties.merged(over: master.textStyle(placeholder.textStyleCategory).level(level))
        }
        return properties.merged(over: resources.defaultTextStyle.level(level))
    }

    /// A theme font reference such as `+mj-lt`, made a typeface name.
    func typeface(_ name: String?, eastAsian: Bool = false) -> String? {
        guard let name else { return nil }
        switch name {
        case "+mj-lt": return theme.majorFont
        case "+mn-lt": return theme.minorFont
        case "+mj-ea": return theme.majorEastAsianFont ?? theme.majorFont
        case "+mn-ea": return theme.minorEastAsianFont ?? theme.minorFont
        default: return name.hasPrefix("+") ? theme.minorFont : name
        }
    }
}
