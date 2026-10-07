import SwiftUI
import UIKit

/// A shape's text as UIKit edits it, and back.
///
/// Each run's text carries the run it came from, and each paragraph's the
/// paragraph, so what is typed takes on the formatting of what it is typed
/// next to, and what is not touched comes back exactly as it was.
enum EditableText {
    static let runKey = NSAttributedString.Key("DazzleRun")
    static let paragraphKey = NSAttributedString.Key("DazzleParagraph")

    final class RunBox: NSObject {
        let run: TextRun
        init(_ run: TextRun) { self.run = run }
    }

    final class ParagraphBox: NSObject {
        /// The paragraph with its runs taken out.
        let paragraph: Paragraph
        init(_ paragraph: Paragraph) {
            var bare = paragraph
            bare.runs = []
            self.paragraph = bare
        }
    }

    // MARK: - To UIKit

    /// `body` drawn as the slide draws it, at `scale` view points per slide point.
    static func attributedString(
        _ body: TextBody, shape: SlideShape, sources: [SlideShape], style: SlideStyleContext, scale: CGFloat,
        fontScale: Double, slideNumber: Int
    ) -> NSAttributedString {
        let result = NSMutableAttributedString()
        let paragraphs = body.paragraphs.isEmpty ? [Paragraph(runs: [])] : body.paragraphs
        for (index, paragraph) in paragraphs.enumerated() {
            let level = paragraph.properties.level ?? 0
            let properties = paragraph.properties.merged(over: style.paragraphBase(for: shape, sources: sources, level: level))
            let start = result.length
            let endRun = (paragraph.endProperties ?? paragraph.runs.last?.properties ?? RunProperties())
                .merged(over: properties.defaultRun)
            for run in paragraph.runs {
                let text = run.text
                var attributes = Self.attributes(
                    for: run.properties.merged(over: properties.defaultRun), style: style, scale: scale * fontScale
                )
                attributes[runKey] = RunBox(run)
                result.append(NSAttributedString(string: text, attributes: attributes))
            }
            if index < paragraphs.count - 1 {
                var attributes = Self.attributes(for: endRun, style: style, scale: scale * fontScale)
                attributes[runKey] = RunBox(TextRun(text: "", properties: paragraph.endProperties ?? RunProperties()))
                result.append(NSAttributedString(string: "\n", attributes: attributes))
            }
            let range = NSRange(location: start, length: result.length - start)
            if range.length > 0 {
                let firstSize = CGFloat((paragraph.runs.first?.properties.merged(over: properties.defaultRun) ?? endRun).size ?? 1_800) / 100
                result.addAttributes([
                    .paragraphStyle: paragraphStyle(properties, fontSize: firstSize * scale * fontScale, scale: scale),
                    paragraphKey: ParagraphBox(paragraph),
                ], range: range)
            }
        }
        return result
    }

    /// What newly typed text looks like where nothing is there yet.
    static func typingAttributes(
        for body: TextBody, shape: SlideShape, sources: [SlideShape], style: SlideStyleContext, scale: CGFloat, fontScale: Double
    ) -> [NSAttributedString.Key: Any] {
        let paragraph = body.paragraphs.first ?? Paragraph(runs: [])
        let properties = paragraph.properties.merged(over: style.paragraphBase(for: shape, sources: sources, level: paragraph.properties.level ?? 0))
        let run = (paragraph.endProperties ?? RunProperties()).merged(over: properties.defaultRun)
        var attributes = Self.attributes(for: run, style: style, scale: scale * fontScale)
        attributes[.paragraphStyle] = paragraphStyle(properties, fontSize: CGFloat(run.size ?? 1_800) / 100 * scale * fontScale, scale: scale)
        attributes[paragraphKey] = ParagraphBox(paragraph)
        attributes[runKey] = RunBox(TextRun(text: "", properties: paragraph.endProperties ?? RunProperties()))
        return attributes
    }

    static func attributes(for run: RunProperties, style: SlideStyleContext, scale: CGFloat) -> [NSAttributedString.Key: Any] {
        var size = CGFloat(run.size ?? 1_800) / 100 * scale
        if run.baseline.map({ $0 != 0 }) == true { size *= 2 / 3 }
        let family = style.typeface(run.latinFont) ?? style.theme.minorFont
        let font = FontResolver.shared.font(family: family, size: max(size, 1), bold: run.isBold ?? false, italic: run.isItalic ?? false)
        let color = run.color.map { style.color($0) } ?? style.color(.scheme("tx1"))
        var attributes: [NSAttributedString.Key: Any] = [
            .font: font as UIFont,
            .foregroundColor: UIColor(cgColor: color.cgColor),
        ]
        if run.isUnderlined == true { attributes[.underlineStyle] = NSUnderlineStyle.single.rawValue }
        if run.isStruckThrough == true { attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
        if let baseline = run.baseline, baseline != 0 {
            attributes[.baselineOffset] = CGFloat(baseline) / 100_000 * size * 1.5
        }
        return attributes
    }

    static func paragraphStyle(_ properties: ParagraphProperties, fontSize: CGFloat, scale: CGFloat) -> NSParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.alignment = switch properties.alignment ?? .left {
        case .left: .left
        case .center: .center
        case .right: .right
        case .justified: .justified
        }
        // The slide draws the bullet behind the text; the text starts where
        // the slide's tab after the bullet puts it.
        let margin = CGFloat(EMU.points(properties.marginLeft ?? 0)) * scale
        let firstLine = max(margin + CGFloat(EMU.points(properties.indent ?? 0)) * scale, 0)
        let hasBullet = switch properties.bullet {
        case .character?, .autoNumber?: true
        default: false
        }
        style.headIndent = margin
        style.firstLineHeadIndent = !hasBullet ? firstLine : (margin > firstLine ? margin : firstLine + fontSize * 0.6)
        switch properties.lineSpacing {
        case .percent(let value): style.lineHeightMultiple = CGFloat(max(value, 0.5))
        case .points(let value):
            style.minimumLineHeight = CGFloat(value) * scale
            style.maximumLineHeight = CGFloat(value) * scale
        case nil: break
        }
        func spacing(_ value: Spacing?) -> CGFloat {
            switch value {
            case .points(let points): CGFloat(points) * scale
            case .percent(let percent): CGFloat(percent) * fontSize * 1.2
            case nil: 0
            }
        }
        style.paragraphSpacingBefore = spacing(properties.spaceBefore)
        style.paragraphSpacing = spacing(properties.spaceAfter)
        return style
    }

    // MARK: - From UIKit

    /// The text as edited, back as a text body with `template`'s body
    /// properties and list style.
    static func body(from string: NSAttributedString, template: TextBody) -> TextBody {
        var body = template
        body.paragraphs = []
        let text = string.string as NSString
        let fallbackParagraph = template.paragraphs.last ?? Paragraph(runs: [])
        var location = 0
        while true {
            let newline = text.range(of: "\n", options: [], range: NSRange(location: location, length: text.length - location))
            let end = newline.location == NSNotFound ? text.length : newline.location
            let range = NSRange(location: location, length: end - location)
            body.paragraphs.append(paragraph(in: string, range: range, fallback: fallbackParagraph))
            guard newline.location != NSNotFound else { break }
            location = end + 1
        }
        return body
    }

    private static func paragraph(in string: NSAttributedString, range: NSRange, fallback: Paragraph) -> Paragraph {
        // An empty paragraph's formatting rides on its line break, or failing
        // that, on what came before it.
        let probe = range.length > 0 ? range.location
            : (range.location < string.length ? range.location : max(range.location - 1, 0))
        let box = string.length > 0 ? string.attribute(paragraphKey, at: min(probe, string.length - 1), effectiveRange: nil) as? ParagraphBox : nil
        var paragraph = box?.paragraph ?? { var bare = fallback; bare.runs = []; return bare }()
        var previous: TextRun?
        string.enumerateAttribute(runKey, in: range) { value, runRange, _ in
            let text = (string.string as NSString).substring(with: runRange).replacingOccurrences(of: "\r", with: "")
            guard !text.isEmpty else { return }
            var run = (value as? RunBox)?.run ?? previous ?? TextRun(text: "", properties: paragraph.endProperties ?? RunProperties())
            if run.kind != .text, run.text != text {
                // A field or line break typed into is text now.
                run.kind = .text
                run.fieldID = nil
            }
            run.text = text
            paragraph.runs.append(run)
            previous = run
        }
        return paragraph
    }
}

/// Typing into a shape over the slide: a text view laid exactly where the
/// shape's text goes, drawn as the slide draws it, with a bar of
/// formatting buttons above the keyboard.
struct InPlaceTextEditor: UIViewRepresentable {
    var body: TextBody
    var shape: SlideShape
    var sources: [SlideShape]
    var style: SlideStyleContext
    var slideNumber: Int
    /// View points per slide point.
    var scale: CGFloat
    var fontScale: Double
    var anchor: BodyProperties.Anchor
    var selection: NSRange?
    var onChange: (TextBody) -> Void
    var onSelectionChange: (NSRange) -> Void
    var toolbar: Toolbar

    /// What the buttons above the keyboard do.
    struct Toolbar {
        var bold: () -> Void
        var italic: () -> Void
        var underline: () -> Void
        var bullets: () -> Void
        var numbers: () -> Void
        var outdent: () -> Void
        var indent: () -> Void
        var format: () -> Void
        var done: () -> Void
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> AnchoredTextView {
        let view = AnchoredTextView()
        view.backgroundColor = .clear
        view.isScrollEnabled = false
        view.clipsToBounds = false
        view.textContainerInset = .zero
        view.textContainer.lineFragmentPadding = 0
        view.delegate = context.coordinator
        view.anchor = anchor
        view.inputAccessoryView = context.coordinator.makeToolbar()
        context.coordinator.load(into: view)
        DispatchQueue.main.async { view.becomeFirstResponder() }
        return view
    }

    func updateUIView(_ view: AnchoredTextView, context: Context) {
        let coordinator = context.coordinator
        let needsReload = body != coordinator.lastBody || scale != coordinator.parent.scale
            || fontScale != coordinator.parent.fontScale
        coordinator.parent = self
        view.anchor = anchor
        if needsReload { coordinator.load(into: view) }
    }

    static func dismantleUIView(_ view: AnchoredTextView, coordinator: Coordinator) {
        view.resignFirstResponder()
    }

    @MainActor
    final class Coordinator: NSObject, UITextViewDelegate {
        var parent: InPlaceTextEditor
        var lastBody: TextBody?
        private var isLoading = false

        init(_ parent: InPlaceTextEditor) { self.parent = parent }

        func load(into view: UITextView) {
            isLoading = true
            defer { isLoading = false }
            let parent = parent
            view.attributedText = EditableText.attributedString(
                parent.body, shape: parent.shape, sources: parent.sources, style: parent.style, scale: parent.scale,
                fontScale: parent.fontScale, slideNumber: parent.slideNumber
            )
            if view.attributedText.length == 0 {
                view.typingAttributes = EditableText.typingAttributes(
                    for: parent.body, shape: parent.shape, sources: parent.sources, style: parent.style,
                    scale: parent.scale, fontScale: parent.fontScale
                )
            }
            if let selection = parent.selection {
                let length = view.attributedText.length
                let location = min(selection.location, length)
                view.selectedRange = NSRange(location: location, length: min(selection.length, length - location))
            } else {
                view.selectedRange = NSRange(location: view.attributedText.length, length: 0)
            }
            lastBody = parent.body
            view.setNeedsLayout()
        }

        func textViewDidChange(_ view: UITextView) {
            guard !isLoading else { return }
            let body = EditableText.body(from: view.attributedText, template: lastBody ?? parent.body)
            lastBody = body
            parent.onChange(body)
            view.setNeedsLayout()
        }

        func textViewDidChangeSelection(_ view: UITextView) {
            guard !isLoading else { return }
            parent.onSelectionChange(view.selectedRange)
        }

        func makeToolbar() -> UIToolbar {
            let toolbar = UIToolbar(frame: CGRect(x: 0, y: 0, width: 320, height: 44))
            func item(_ symbol: String, _ label: String.LocalizationValue, _ action: @escaping (InPlaceTextEditor.Toolbar) -> Void) -> UIBarButtonItem {
                let item = UIBarButtonItem(image: UIImage(systemName: symbol), primaryAction: UIAction { [weak self] _ in
                    guard let self else { return }
                    action(self.parent.toolbar)
                })
                item.accessibilityLabel = String(localized: label)
                return item
            }
            toolbar.items = [
                item("bold", "Format.Bold") { $0.bold() },
                item("italic", "Format.Italic") { $0.italic() },
                item("underline", "Format.Underline") { $0.underline() },
                .flexibleSpace(),
                item("list.bullet", "Format.List.Bullets") { $0.bullets() },
                item("list.number", "Format.List.Numbers") { $0.numbers() },
                item("decrease.indent", "Format.Outdent") { $0.outdent() },
                item("increase.indent", "Format.Indent") { $0.indent() },
                .flexibleSpace(),
                item("textformat", "Format.MoreText") { $0.format() },
                item("keyboard.chevron.compact.down", "Format.DoneEditing") { $0.done() },
            ]
            toolbar.sizeToFit()
            return toolbar
        }
    }
}

/// A text view that sits its text at the top, middle or bottom of its
/// frame, as a shape's anchor says.
final class AnchoredTextView: UITextView {
    var anchor: BodyProperties.Anchor = .top {
        didSet { if anchor != oldValue { setNeedsLayout() } }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let fitting = sizeThatFits(CGSize(width: bounds.width, height: .greatestFiniteMagnitude)).height
            - textContainerInset.top - textContainerInset.bottom
        let room = max(bounds.height - fitting, 0)
        let top: CGFloat = switch anchor {
        case .top: 0
        case .center: room / 2
        case .bottom: room
        }
        if abs(textContainerInset.top - top) > 0.5 {
            textContainerInset = UIEdgeInsets(top: top, left: 0, bottom: 0, right: 0)
        }
    }
}
