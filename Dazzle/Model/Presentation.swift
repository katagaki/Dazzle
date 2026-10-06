import Foundation

/// A whole presentation: its slides, and the package they came from.
///
/// Dazzle models what it draws and edits. Everything else — animations,
/// charts, embedded objects, custom XML, macros — stays in `package` exactly
/// as it was read and is written back untouched.
struct Presentation: Equatable, Sendable {
    var slideSize: EMUSize
    var slides: [Slide]
    /// Theme, masters and layouts: read once, never edited.
    let resources: DeckResources
    /// Every part of the file as it was read.
    let package: Package
    /// Parts Dazzle has added since, such as pictures.
    var addedParts: [String: Data] = [:]
    /// Whether slides were added, removed or reordered, which means the
    /// slide list itself has to be written again.
    var isStructureModified = false

    var unsupportedFeatures: UnsupportedFeatureReport { package.unsupportedFeatures }

    /// The bytes of a part, whether read or added.
    func data(at path: String) -> Data? {
        addedParts[path] ?? package.parts[path]
    }

    func index(of slideID: Slide.ID?) -> Int? {
        slides.firstIndex { $0.id == slideID }
    }

    func layout(for slide: Slide) -> SlideLayout? {
        resources.layouts[slide.layoutPath]
    }

    /// The slides a slideshow steps through: all but the hidden ones.
    var visibleSlideIndices: [Int] {
        let visible = slides.indices.filter { !slides[$0].isHidden }
        // A deck whose every slide is hidden still has something to show.
        return visible.isEmpty ? Array(slides.indices) : visible
    }
}

/// The package as read, shared between every copy of a presentation.
final class Package: Equatable, Sendable {
    let parts: [String: Data]
    /// Where the presentation part lives, normally `ppt/presentation.xml`.
    let mainPart: String
    let unsupportedFeatures: UnsupportedFeatureReport

    init(parts: [String: Data], mainPart: String, unsupportedFeatures: UnsupportedFeatureReport) {
        self.parts = parts
        self.mainPart = mainPart
        self.unsupportedFeatures = unsupportedFeatures
    }

    static func == (lhs: Package, rhs: Package) -> Bool { lhs === rhs }
}

/// One slide.
struct Slide: Identifiable, Equatable, Sendable {
    let id: UUID
    /// The part it is saved as; `nil` for a slide not yet saved.
    var partName: String?
    /// The part whose XML supplies everything Dazzle does not model: the
    /// slide itself, or for a duplicate, the slide it was copied from.
    var sourcePart: String?
    var layoutPath: String
    var relationships: [Relationship]
    var shapes: [SlideShape]
    var background: Background?
    var isHidden = false
    var showsMasterShapes = true
    /// The speaker notes, as plain text.
    var notes = ""
    var notesPart: String?
    /// Whether the slide's own XML must be written again.
    var isModified = false
    var isBackgroundModified = false
    var areNotesModified = false
    /// Whether every shape could be read faithfully enough to write back
    /// individually. When not, the slide is kept exactly as it was.
    var canEditShapes = true
    /// Whether a shape was removed, which leaves animations pointing at
    /// nothing. Those are dropped on save.
    var hasRemovedShapes = false

    init(id: UUID = UUID(), layoutPath: String, relationships: [Relationship] = [], shapes: [SlideShape] = []) {
        self.id = id
        self.layoutPath = layoutPath
        self.relationships = relationships
        self.shapes = shapes
    }

    /// The text of the slide's title placeholder, if it has one.
    var title: String? {
        shapes.first { $0.placeholder?.isTitle == true }?.text?.plainText
            .replacingOccurrences(of: "\n", with: " ").trimmed.nilIfEmpty
    }

    /// The first `cNvPr id` no shape on the slide uses.
    var nextShapeID: Int {
        (shapes.flatMap(\.flattened).map(\.shapeID).max() ?? 1) + 1
    }
}

extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}

/// The parts of a file Dazzle shows but cannot edit, or keeps but cannot use.
struct UnsupportedFeatureReport: Equatable, Sendable {
    enum Feature: String, CaseIterable, Sendable {
        case macros
        case charts
        case media
        case embeddedObjects
        case animations

        var message: String {
            switch self {
            case .macros: String(localized: "Notice.Feature.Macros")
            case .charts: String(localized: "Notice.Feature.Charts")
            case .media: String(localized: "Notice.Feature.Media")
            case .embeddedObjects: String(localized: "Notice.Feature.EmbeddedObjects")
            case .animations: String(localized: "Notice.Feature.Animations")
            }
        }
    }

    var features: Set<Feature> = []

    var isEmpty: Bool { features.isEmpty }

    var noticeMessage: String {
        Feature.allCases.filter(features.contains).map { "• " + $0.message }.joined(separator: "\n")
    }
}
