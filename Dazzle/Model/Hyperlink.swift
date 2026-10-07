import Foundation

/// Where clicking a shape or a run of text goes, during a slideshow.
enum Hyperlink: Equatable, Hashable, Sendable {
    /// A web page or other address, outside the presentation.
    case url(String)
    /// Another slide of the presentation.
    case slide(Slide.ID)
    /// A slide by its part, before slides have ids; only while reading.
    case slidePart(String)
    case nextSlide
    case previousSlide
    case firstSlide
    case lastSlide
    case endShow
    /// A link Dazzle does not follow, such as one that runs a macro. It is
    /// kept in the file as it was.
    case other

    static let jumpAction = "ppaction://hlinksldjump"
    static let showJumpAction = "ppaction://hlinkshowjump?jump="

    /// Reads an `a:hlinkClick`. `target` resolves its relationship id.
    init?(element: XMLElement?, target: (String) -> Relationship?) {
        guard let element else { return nil }
        let action = element.attribute("action") ?? ""
        let relationship = element.relationshipID.flatMap { $0.isEmpty ? nil : target($0) }
        if action.hasPrefix(Self.showJumpAction) {
            switch action.dropFirst(Self.showJumpAction.count) {
            case "nextslide": self = .nextSlide
            case "previousslide": self = .previousSlide
            case "firstslide": self = .firstSlide
            case "lastslide": self = .lastSlide
            case "endshow": self = .endShow
            default: self = .other
            }
        } else if action == Self.jumpAction, let relationship {
            self = .slidePart(relationship.target)
        } else if action.isEmpty, let relationship, relationship.isExternal {
            self = .url(relationship.target)
        } else {
            self = .other
        }
    }

    /// The `a:hlinkClick` for this link, given the id of the relationship
    /// it needs, if it needs one.
    func xml(relationshipID: String?) -> String? {
        switch self {
        case .url:
            return relationshipID.map { "<a:hlinkClick r:id=\"\($0)\"/>" }
        case .slide:
            return relationshipID.map { "<a:hlinkClick r:id=\"\($0)\" action=\"\(Self.jumpAction)\"/>" }
        case .nextSlide: return "<a:hlinkClick r:id=\"\" action=\"\(Self.showJumpAction)nextslide\"/>"
        case .previousSlide: return "<a:hlinkClick r:id=\"\" action=\"\(Self.showJumpAction)previousslide\"/>"
        case .firstSlide: return "<a:hlinkClick r:id=\"\" action=\"\(Self.showJumpAction)firstslide\"/>"
        case .lastSlide: return "<a:hlinkClick r:id=\"\" action=\"\(Self.showJumpAction)lastslide\"/>"
        case .endShow: return "<a:hlinkClick r:id=\"\" action=\"\(Self.showJumpAction)endshow\"/>"
        case .slidePart, .other: return nil
        }
    }
}

extension Presentation {
    /// Turns links to slide parts, as read, into links to the slides.
    mutating func resolveSlideLinks() {
        let ids = Dictionary(slides.compactMap { slide in slide.partName.map { ($0, slide.id) } }) { first, _ in first }
        func resolve(_ link: Hyperlink?) -> Hyperlink? {
            guard case .slidePart(let path)? = link else { return link }
            return ids[path].map(Hyperlink.slide) ?? .other
        }
        func resolve(_ shape: inout SlideShape) {
            shape.link = resolve(shape.link)
            if var body = shape.text {
                for paragraph in body.paragraphs.indices {
                    for run in body.paragraphs[paragraph].runs.indices {
                        body.paragraphs[paragraph].runs[run].properties.link = resolve(body.paragraphs[paragraph].runs[run].properties.link)
                    }
                }
                shape.text = body
            }
            if case .group(var group) = shape.kind {
                for index in group.children.indices { resolve(&group.children[index]) }
                shape.kind = .group(group)
            }
        }
        for slide in slides.indices {
            for shape in slides[slide].shapes.indices { resolve(&slides[slide].shapes[shape]) }
        }
    }
}

