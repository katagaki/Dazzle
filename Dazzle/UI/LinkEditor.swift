import SwiftUI

/// Choosing where a link goes: a web address, a slide, or a step through
/// the show.
struct LinkEditor: View {
    let link: Hyperlink?
    let presentation: Presentation
    let onChange: (Hyperlink?) -> Void

    private enum Kind: Hashable {
        case none
        case url
        case slide
        case next
        case previous
        case first
        case last
        case end
        case other
    }

    private var kind: Kind {
        switch link {
        case nil: .none
        case .url?: .url
        case .slide?, .slidePart?: .slide
        case .nextSlide?: .next
        case .previousSlide?: .previous
        case .firstSlide?: .first
        case .lastSlide?: .last
        case .endShow?: .end
        case .other?: .other
        }
    }

    var body: some View {
        Picker("Link.Kind", selection: Binding(get: { kind }, set: choose)) {
            Text("Link.None").tag(Kind.none)
            Text("Link.URL").tag(Kind.url)
            Text("Link.Slide").tag(Kind.slide)
            Text("Link.Next").tag(Kind.next)
            Text("Link.Previous").tag(Kind.previous)
            Text("Link.First").tag(Kind.first)
            Text("Link.Last").tag(Kind.last)
            Text("Link.End").tag(Kind.end)
            if kind == .other { Text("Link.Other").tag(Kind.other) }
        }
        .accessibilityIdentifier("linkKind")
        if case .url(let address)? = link {
            CommitTextField("Link.URL.Placeholder", text: address) { text in
                onChange(.url(Self.normalized(text)))
            }
            .keyboardType(.URL)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .accessibilityIdentifier("linkAddress")
        }
        if case .slide(let id)? = link {
            Picker("Link.Slide", selection: Binding(get: { id }, set: { onChange(.slide($0)) })) {
                ForEach(Array(presentation.slides.enumerated()), id: \.element.id) { index, slide in
                    Text(verbatim: "\(index + 1). \(slide.title ?? String(localized: "Slide.Untitled"))").tag(slide.id)
                }
            }
        }
    }

    private func choose(_ kind: Kind) {
        switch kind {
        case .none: onChange(nil)
        case .url: onChange(.url("https://"))
        case .slide: onChange(presentation.slides.first.map { .slide($0.id) })
        case .next: onChange(.nextSlide)
        case .previous: onChange(.previousSlide)
        case .first: onChange(.firstSlide)
        case .last: onChange(.lastSlide)
        case .end: onChange(.endShow)
        case .other: break
        }
    }

    /// An address typed without a scheme is taken to be on the web.
    static func normalized(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.contains("://"), !trimmed.hasPrefix("mailto:") else { return trimmed }
        return trimmed.contains("@") && !trimmed.contains("/") ? "mailto:" + trimmed : "https://" + trimmed
    }
}
