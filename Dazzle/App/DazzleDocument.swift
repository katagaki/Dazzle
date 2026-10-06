import SwiftUI
import UniformTypeIdentifiers

extension UTType {
    /// The Office Open XML presentation, declared by the system.
    static let openXMLPresentation = UTType("org.openxmlformats.presentationml.presentation") ?? .data
    /// The `.pptm` presentation, which may carry macros. Dazzle opens and
    /// saves these, keeping the macros, but never runs them.
    static let macroEnabledPresentation = UTType("org.openxmlformats.presentationml.presentation.macroenabled") ?? .data
    /// The `.ppsx` slide show: a presentation that opens straight into playing.
    static let openXMLSlideShow = UTType("org.openxmlformats.presentationml.slideshow") ?? .data
}

/// The app's document: one presentation.
struct DazzleDocument: FileDocument {
    static let readableContentTypes: [UTType] = [.openXMLPresentation, .macroEnabledPresentation, .openXMLSlideShow]
    static let writableContentTypes: [UTType] = [.openXMLPresentation, .macroEnabledPresentation, .openXMLSlideShow]

    var presentation: Presentation

    init() {
        presentation = .blank
    }

    init(presentation: Presentation) {
        self.presentation = presentation
    }

    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents else {
            throw CocoaError(.fileReadCorruptFile)
        }
        presentation = try PPTXReader.presentation(from: data)
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: try PPTXWriter.data(from: presentation))
    }
}

extension Presentation {
    /// A new presentation: one title slide on the built-in template.
    static var blank: Presentation {
        do {
            return try PPTXReader.presentation(fromParts: PresentationTemplate.parts())
        } catch {
            preconditionFailure("The built-in template must always read: \(error)")
        }
    }
}
