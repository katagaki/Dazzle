import CoreTransferable
import Foundation
import UniformTypeIdentifiers

/// What the export panel has been asked for.
struct ExportOptions: Equatable, Sendable {
    enum Format: String, CaseIterable, Identifiable, Sendable {
        case pdf
        case images
        case video

        var id: Self { self }
    }

    enum Scope: String, CaseIterable, Identifiable, Sendable {
        case current
        case all
        case chosen

        var id: Self { self }
    }

    /// Picture widths offered, in pixels.
    enum Resolution: Int, CaseIterable, Identifiable, Sendable {
        case standard = 1_280
        case high = 1_920
        case ultra = 3_840

        var id: Self { self }
    }

    var format: Format = .pdf
    var scope: Scope = .all
    var imageFormat: SlideExporter.ImageFormat = .png
    var resolution: Resolution = .high
    var includesHiddenSlides = false
    var chosenSlideIDs: Set<Slide.ID> = []
    var pageLayout: SlideExporter.PageLayout = .slides
    var secondsPerSlide = 5.0
}

/// Wraps the presentation so it can be handed to `ShareLink`, written only
/// when the user picks somewhere to send it.
struct PresentationShare: Transferable, Sendable {
    var presentation: Presentation
    var name: String

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(exportedContentType: .openXMLPresentation) { share in
            SentTransferredFile(try ExportFile.write(name: share.name, extension: "pptx") {
                try PPTXWriter.data(from: share.presentation)
            })
        }
        .suggestedFileName { $0.name + ".pptx" }
    }
}

/// Slides as one PDF.
struct PDFExport: Transferable, Sendable {
    var presentation: Presentation
    var slides: [Slide]
    var name: String
    var layout: SlideExporter.PageLayout = .slides

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(exportedContentType: .pdf) { export in
            SentTransferredFile(try ExportFile.write(name: export.name, extension: "pdf") {
                SlideExporter.pdf(of: export.slides, in: export.presentation, title: export.name, layout: export.layout)
            })
        }
        .suggestedFileName { $0.name + ".pdf" }
    }
}

/// One slide as a picture.
struct SlideImageExport: Transferable, Sendable {
    var presentation: Presentation
    var slide: Slide
    var name: String
    var format: SlideExporter.ImageFormat
    var width: Int

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(exportedContentType: .png) { export in
            SentTransferredFile(try export.write())
        }
        .exportingCondition { $0.format == .png }
        .suggestedFileName { $0.name + ".png" }

        FileRepresentation(exportedContentType: .jpeg) { export in
            SentTransferredFile(try export.write())
        }
        .exportingCondition { $0.format == .jpeg }
        .suggestedFileName { $0.name + ".jpg" }
    }

    private func write() throws -> URL {
        try ExportFile.write(name: name, extension: format.fileExtension) {
            guard let data = SlideExporter.image(of: slide, in: presentation, width: width, format: format) else {
                throw CocoaError(.fileWriteUnknown)
            }
            return data
        }
    }
}

enum ExportFile {
    static func write(name: String, extension pathExtension: String, encode: () throws -> Data) throws -> URL {
        // A per-export directory keeps concurrent shares from colliding on name.
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "Share-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appending(path: "\(sanitized(name)).\(pathExtension)")
        try encode().write(to: url, options: .atomic)
        return url
    }

    static func sanitized(_ name: String) -> String {
        let cleaned = name.components(separatedBy: CharacterSet(charactersIn: "/:\\?%*|\"<>"))
            .joined(separator: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? "Presentation" : cleaned
    }
}
