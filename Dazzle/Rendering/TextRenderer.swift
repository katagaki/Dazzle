import CoreGraphics
import CoreText
import Foundation

/// Lays out and draws a shape's text with CoreText.
struct TextRenderer {
    let style: SlideStyleContext
    let slideNumber: Int

    /// Draws `body` into `rect`, in a context whose y axis points down.
    /// `colorOverride` replaces every colour, for placeholder prompts.
    /// `hidesText` lays the text out but draws only its bullets.
    func draw(
        _ body: TextBody, shape: SlideShape, sources: [SlideShape], in rect: CGRect, context: CGContext,
        colorOverride: RGBAColor? = nil, hidesText: Bool = false
    ) {
        let properties = style.bodyProperties(for: shape, sources: sources)
            .merged(over: body.properties)
        var inner = CGRect(
            x: rect.minX + EMU.points(properties.leftInset ?? 91_440),
            y: rect.minY + EMU.points(properties.topInset ?? 45_720),
            width: rect.width - EMU.points((properties.leftInset ?? 91_440) + (properties.rightInset ?? 91_440)),
            height: rect.height - EMU.points((properties.topInset ?? 45_720) + (properties.bottomInset ?? 45_720))
        )
        guard inner.width > 0 || properties.wraps == false else { return }

        context.saveGState()
        defer { context.restoreGState() }
        // Vertical text is laid out across the shape's height, then turned.
        if let vertical = properties.vertical, ["vert", "eaVert", "vert270", "wordArtVert", "mongolianVert"].contains(vertical) {
            let angle: CGFloat = vertical == "vert270" ? -.pi / 2 : .pi / 2
            context.translateBy(x: inner.midX, y: inner.midY)
            context.rotate(by: angle)
            inner = CGRect(x: -inner.height / 2, y: -inner.width / 2, width: inner.height, height: inner.width)
        }

        var fontScale = 1.0
        var spacingReduction = 0.0
        if case .normal(let scale, let reduction) = properties.autofit {
            fontScale = scale
            spacingReduction = reduction
        }
        let wraps = properties.wraps ?? true
        let layoutWidth = wraps ? max(inner.width, 1) : 100_000

        var string = attributedString(
            body, shape: shape, sources: sources, scale: fontScale, spacingReduction: spacingReduction,
            colorOverride: colorOverride, hidesText: hidesText
        )
        var framesetter = CTFramesetterCreateWithAttributedString(string)
        var size = suggestedSize(framesetter, string: string, width: layoutWidth)

        // Shrink on overflow, as PowerPoint would have when it last saved.
        if case .normal = properties.autofit, fontScale == 1, size.height > inner.height + 1 {
            for scale in stride(from: 0.9, through: 0.3, by: -0.1) {
                string = attributedString(
                    body, shape: shape, sources: sources, scale: scale, spacingReduction: 0.1, colorOverride: colorOverride,
                    hidesText: hidesText
                )
                framesetter = CTFramesetterCreateWithAttributedString(string)
                size = suggestedSize(framesetter, string: string, width: layoutWidth)
                if size.height <= inner.height + 1 { break }
            }
        }

        var originX = inner.minX
        var frameWidth = layoutWidth
        if !wraps {
            frameWidth = max(ceil(size.width) + 1, inner.width)
            switch body.paragraphs.first?.properties.alignment ?? .left {
            case .center: originX = inner.midX - frameWidth / 2
            case .right: originX = inner.maxX - frameWidth
            default: break
            }
        }
        let frameHeight = ceil(size.height) + 1
        let offset: CGFloat = switch properties.anchor ?? .top {
        case .top: 0
        case .center: (inner.height - frameHeight) / 2
        case .bottom: inner.height - frameHeight
        }

        let path = CGPath(rect: CGRect(x: 0, y: 0, width: frameWidth, height: frameHeight), transform: nil)
        let frame = CTFramesetterCreateFrame(framesetter, CFRange(location: 0, length: 0), path, nil)
        context.translateBy(x: originX, y: inner.minY + offset + frameHeight)
        context.scaleBy(x: 1, y: -1)
        context.textMatrix = .identity
        CTFrameDraw(frame, context)
        drawStrikethroughs(in: frame, context: context)
    }

    /// Where a shape's text is laid out, in slide points: the shape's text
    /// rectangle with the insets taken off, and the body properties in force.
    func textArea(of shape: SlideShape, sources: [SlideShape]) -> (rect: CGRect, properties: BodyProperties) {
        let frame = shape.frame.points
        let textFrame = shape.textFrame?.points ?? shape.geometry.presetName.map {
            PresetGeometry.textRect($0, adjustments: shape.geometry.adjustments, in: frame)
        } ?? frame
        let properties = style.bodyProperties(for: shape, sources: sources)
        let rect = CGRect(
            x: textFrame.minX + EMU.points(properties.leftInset ?? 91_440),
            y: textFrame.minY + EMU.points(properties.topInset ?? 45_720),
            width: textFrame.width - EMU.points((properties.leftInset ?? 91_440) + (properties.rightInset ?? 91_440)),
            height: textFrame.height - EMU.points((properties.topInset ?? 45_720) + (properties.bottomInset ?? 45_720))
        )
        return (rect, properties)
    }

    /// How tall `body` lays out at `width`, insets included.
    func height(of body: TextBody, shape: SlideShape, width: CGFloat) -> CGFloat {
        let properties = style.bodyProperties(for: shape, sources: []).merged(over: body.properties)
        let horizontal = EMU.points((properties.leftInset ?? 91_440) + (properties.rightInset ?? 91_440))
        let vertical = EMU.points((properties.topInset ?? 45_720) + (properties.bottomInset ?? 45_720))
        let string = attributedString(body, shape: shape, sources: [], scale: 1, spacingReduction: 0, colorOverride: nil)
        let size = suggestedSize(CTFramesetterCreateWithAttributedString(string), string: string, width: max(width - horizontal, 1))
        return ceil(size.height) + vertical
    }

    private func suggestedSize(_ framesetter: CTFramesetter, string: NSAttributedString, width: CGFloat) -> CGSize {
        CTFramesetterSuggestFrameSizeWithConstraints(
            framesetter, CFRange(location: 0, length: string.length), nil,
            CGSize(width: width, height: .greatestFiniteMagnitude), nil
        )
    }

    // MARK: - Attributed string

    private static let fontKey = NSAttributedString.Key(kCTFontAttributeName as String)
    private static let colorKey = NSAttributedString.Key(kCTForegroundColorAttributeName as String)
    private static let paragraphKey = NSAttributedString.Key(kCTParagraphStyleAttributeName as String)
    private static let underlineKey = NSAttributedString.Key(kCTUnderlineStyleAttributeName as String)
    private static let superscriptKey = NSAttributedString.Key(kCTSuperscriptAttributeName as String)
    private static let strikeKey = NSAttributedString.Key("DazzleStrikethrough")

    func attributedString(
        _ body: TextBody, shape: SlideShape, sources: [SlideShape], scale: Double, spacingReduction: Double,
        colorOverride: RGBAColor?, hidesText: Bool = false
    ) -> NSAttributedString {
        let textColor = hidesText ? RGBAColor(red: 0, green: 0, blue: 0, alpha: 0) : colorOverride
        let result = NSMutableAttributedString()
        var counters: [Int: Int] = [:]

        for (index, paragraph) in body.paragraphs.enumerated() {
            let level = paragraph.properties.level ?? 0
            let properties = paragraph.properties.merged(over: style.paragraphBase(for: shape, sources: sources, level: level))
            let start = result.length
            // A paragraph break is as tall as the text before it; only an empty
            // paragraph, or one that says so, takes its end-of-paragraph size.
            let endRun = (paragraph.endProperties ?? paragraph.runs.last?.properties ?? RunProperties())
                .merged(over: properties.defaultRun)
            let firstRun = paragraph.runs.first.map { $0.properties.merged(over: properties.defaultRun) } ?? endRun
            let baseSize = CGFloat(firstRun.size ?? 1_800) / 100 * scale

            // Numbering continues through a level until something interrupts it.
            for deeper in counters.keys where deeper > level { counters[deeper] = nil }
            var bulletText: String?
            if !paragraph.plainText.isEmpty {
                switch properties.bullet {
                case .character(let character):
                    bulletText = character
                case .autoNumber(let scheme, let startAt):
                    let number = (counters[level] ?? (startAt - 1)) + 1
                    counters[level] = number
                    bulletText = Self.numberLabel(number, scheme: scheme)
                default:
                    counters[level] = nil
                }
            }
            if let bulletText {
                var bulletRun = firstRun
                bulletRun.isUnderlined = false
                if let font = properties.bulletFont, !font.hasPrefix("+"), !["Arial", "Wingdings", "Symbol"].contains(font) {
                    bulletRun.latinFont = font
                }
                if let color = properties.bulletColor { bulletRun.color = color }
                let bulletScale = scale * (properties.bulletSize ?? 1)
                result.append(NSAttributedString(
                    string: Self.displayable(bulletText) + "\t",
                    attributes: attributes(for: bulletRun, scale: bulletScale, colorOverride: colorOverride)
                ))
            }

            for run in paragraph.runs {
                let runProperties = run.properties.merged(over: properties.defaultRun)
                var text = run.text
                if case .field(let type) = run.kind, type == "slidenum" { text = String(slideNumber) }
                if runProperties.capitalization == "all" { text = text.uppercased() }
                text = Self.symbolsMapped(text)
                result.append(NSAttributedString(
                    string: text, attributes: attributes(for: runProperties, scale: scale, colorOverride: textColor)
                ))
            }

            // A paragraph break, or for the last paragraph a zero-width space
            // so an empty paragraph still occupies a line.
            let terminator = index < body.paragraphs.count - 1 ? "\n" : (paragraph.runs.isEmpty ? "\u{200B}" : "")
            if !terminator.isEmpty {
                result.append(NSAttributedString(
                    string: terminator, attributes: attributes(for: endRun, scale: scale, colorOverride: textColor)
                ))
            }

            let range = NSRange(location: start, length: result.length - start)
            if range.length > 0 {
                result.addAttribute(
                    Self.paragraphKey,
                    value: paragraphStyle(properties, fontSize: baseSize, hasBullet: bulletText != nil, spacingReduction: spacingReduction),
                    range: range
                )
            }
        }
        return result
    }

    private func attributes(for run: RunProperties, scale: Double, colorOverride: RGBAColor?) -> [NSAttributedString.Key: Any] {
        var size = CGFloat(run.size ?? 1_800) / 100 * scale
        if run.baseline.map({ $0 != 0 }) == true { size *= 2 / 3 }
        let family = style.typeface(run.latinFont) ?? style.theme.minorFont
        let font = FontResolver.shared.font(
            family: family, size: max(size, 1), bold: run.isBold ?? false, italic: run.isItalic ?? false
        )
        let color = colorOverride ?? run.color.map { style.color($0) } ?? style.color(.scheme("tx1"))
        var attributes: [NSAttributedString.Key: Any] = [
            Self.fontKey: font,
            Self.colorKey: color.cgColor,
        ]
        if run.isUnderlined == true {
            attributes[Self.underlineKey] = NSNumber(value: CTUnderlineStyle.single.rawValue)
        }
        if run.isStruckThrough == true {
            attributes[Self.strikeKey] = NSNumber(value: true)
        }
        if let baseline = run.baseline, baseline != 0 {
            attributes[Self.superscriptKey] = NSNumber(value: baseline > 0 ? 1 : -1)
        }
        return attributes
    }

    private func paragraphStyle(
        _ properties: ParagraphProperties, fontSize: CGFloat, hasBullet: Bool, spacingReduction: Double
    ) -> CTParagraphStyle {
        let marginLeft = CGFloat(EMU.points(properties.marginLeft ?? 0))
        let indent = CGFloat(EMU.points(properties.indent ?? 0))
        var alignment: CTTextAlignment = switch properties.alignment ?? .left {
        case .left: .left
        case .center: .center
        case .right: .right
        case .justified: .justified
        }
        // The first line starts at the indent, where a bullet hangs; the tab
        // after the bullet lands on the margin, where the rest of the lines start.
        var firstLine = max(marginLeft + indent, 0)
        var head = marginLeft
        let tabLocation = marginLeft > firstLine || !hasBullet ? marginLeft : firstLine + fontSize * 0.6
        var tabs = [CTTextTabCreate(.left, Double(tabLocation), nil)] as CFArray
        var defaultTab: CGFloat = 72

        var lineMultiple: CGFloat = 1
        var minimumLine: CGFloat = 0
        var maximumLine: CGFloat = 0
        switch properties.lineSpacing {
        case .percent(let value): lineMultiple = CGFloat(max(value - spacingReduction, 0.5))
        case .points(let value):
            minimumLine = CGFloat(value)
            maximumLine = CGFloat(value)
        case nil: lineMultiple = CGFloat(max(1 - spacingReduction, 0.5))
        }
        func spacing(_ value: Spacing?) -> CGFloat {
            switch value {
            case .points(let points): CGFloat(points)
            case .percent(let percent): CGFloat(percent) * fontSize * 1.2
            case nil: 0
            }
        }
        var before = spacing(properties.spaceBefore)
        var after = spacing(properties.spaceAfter)

        var cleanups: [() -> Void] = []
        defer { cleanups.forEach { $0() } }
        func setting<T>(_ specifier: CTParagraphStyleSpecifier, _ value: inout T) -> CTParagraphStyleSetting {
            let pointer = UnsafeMutablePointer<T>.allocate(capacity: 1)
            pointer.initialize(to: value)
            cleanups.append {
                pointer.deinitialize(count: 1)
                pointer.deallocate()
            }
            return CTParagraphStyleSetting(spec: specifier, valueSize: MemoryLayout<T>.size, value: pointer)
        }
        var settings = [
            setting(.alignment, &alignment),
            setting(.firstLineHeadIndent, &firstLine),
            setting(.headIndent, &head),
            setting(.tabStops, &tabs),
            setting(.defaultTabInterval, &defaultTab),
            setting(.paragraphSpacingBefore, &before),
            setting(.paragraphSpacing, &after),
        ]
        if minimumLine > 0 {
            settings.append(setting(.minimumLineHeight, &minimumLine))
            settings.append(setting(.maximumLineHeight, &maximumLine))
        } else {
            settings.append(setting(.lineHeightMultiple, &lineMultiple))
        }
        return CTParagraphStyleCreate(settings, settings.count)
    }

    /// Strikethrough is a TextKit attribute that CoreText does not draw.
    private func drawStrikethroughs(in frame: CTFrame, context: CGContext) {
        let lines = CTFrameGetLines(frame) as? [CTLine] ?? []
        guard !lines.isEmpty else { return }
        var origins = [CGPoint](repeating: .zero, count: lines.count)
        CTFrameGetLineOrigins(frame, CFRange(location: 0, length: 0), &origins)
        for (line, origin) in zip(lines, origins) {
            for run in CTLineGetGlyphRuns(line) as? [CTRun] ?? [] {
                let attributes = CTRunGetAttributes(run) as NSDictionary
                guard attributes[Self.strikeKey.rawValue] != nil else { continue }
                let font = attributes[kCTFontAttributeName as String].map { $0 as! CTFont } // swiftlint:disable:this force_cast
                let height = font.map { CTFontGetXHeight($0) / 2 } ?? 4
                let start = CTLineGetOffsetForStringIndex(line, CTRunGetStringRange(run).location, nil)
                let width = CTRunGetTypographicBounds(run, CFRange(location: 0, length: 0), nil, nil, nil)
                if let color = attributes[kCTForegroundColorAttributeName as String] {
                    context.setStrokeColor(color as! CGColor) // swiftlint:disable:this force_cast
                }
                context.setLineWidth(max((font.map { CTFontGetSize($0) } ?? 12) / 16, 0.5))
                context.move(to: CGPoint(x: origin.x + start, y: origin.y + height))
                context.addLine(to: CGPoint(x: origin.x + start + width, y: origin.y + height))
                context.strokePath()
            }
        }
    }

    // MARK: - Bullets

    /// Wingdings and Symbol bullets name private-use glyphs; draw the
    /// common ones as the characters they look like.
    private static func displayable(_ bullet: String) -> String {
        // Symbol fonts are often written in the private use area, U+F0xx,
        // standing for the font's own character xx.
        if let scalar = bullet.unicodeScalars.first, bullet.unicodeScalars.count == 1,
           (0xF000...0xF0FF).contains(scalar.value) {
            let symbol = String(UnicodeScalar(UInt8(scalar.value - 0xF000)))
            let mapped = displayable(symbol)
            return mapped == symbol ? "•" : mapped
        }
        return switch bullet {
        case "§": "■"
        case "Ø": "➢"
        case "ü": "✓"
        case "û": "✗"
        case "à": "→"
        case "è": "➔"
        case "q", "o": "◦"
        case "Ÿ", "·": "•"
        case "n": "■"
        case "l": "●"
        case "v": "❖"
        case "": "•"
        default: bullet
        }
    }

    /// Run text in a symbol font can carry the same private-use characters
    /// as bullets do; those are drawn as what they look like, the rest left be.
    static func symbolsMapped(_ text: String) -> String {
        guard text.unicodeScalars.contains(where: { (0xF000...0xF0FF).contains($0.value) }) else { return text }
        var result = ""
        for scalar in text.unicodeScalars {
            if (0xF000...0xF0FF).contains(scalar.value) {
                result += displayable(String(scalar))
            } else {
                result.unicodeScalars.append(scalar)
            }
        }
        return result
    }

    static func numberLabel(_ number: Int, scheme: String) -> String {
        let core: String
        if scheme.hasPrefix("alphaLc") {
            core = alphabetic(number, uppercase: false)
        } else if scheme.hasPrefix("alphaUc") {
            core = alphabetic(number, uppercase: true)
        } else if scheme.hasPrefix("romanLc") {
            core = roman(number).lowercased()
        } else if scheme.hasPrefix("romanUc") {
            core = roman(number)
        } else {
            core = String(number)
        }
        if scheme.hasSuffix("ParenBoth") { return "(\(core))" }
        if scheme.hasSuffix("ParenR") { return "\(core))" }
        if scheme.hasSuffix("Plain") { return core }
        return "\(core)."
    }

    private static func alphabetic(_ number: Int, uppercase: Bool) -> String {
        let letter = Character(UnicodeScalar(UInt8((number - 1) % 26) + (uppercase ? 65 : 97)))
        return String(repeating: letter, count: (number - 1) / 26 + 1)
    }

    private static func roman(_ number: Int) -> String {
        let table: [(Int, String)] = [
            (1000, "M"), (900, "CM"), (500, "D"), (400, "CD"), (100, "C"), (90, "XC"),
            (50, "L"), (40, "XL"), (10, "X"), (9, "IX"), (5, "V"), (4, "IV"), (1, "I"),
        ]
        var remaining = max(number, 1)
        var result = ""
        for (value, numeral) in table {
            while remaining >= value {
                result += numeral
                remaining -= value
            }
        }
        return result
    }
}
