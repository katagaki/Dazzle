import AVFoundation
import CoreGraphics
import CoreTransferable
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// A picture made ready to put in a presentation.
///
/// PowerPoint reads PNG and JPEG everywhere, but not the HEIC photos an
/// iPhone takes, so anything else is re-encoded: PNG when it has
/// transparency to keep, JPEG when it is a photo.
struct PreparedMedia: Sendable {
    var data: Data
    var fileExtension: String
    /// In pixels, which is also the size it is placed at, in points.
    var size: CGSize

    init?(data: Data) {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let type = CGImageSourceGetType(source).flatMap({ UTType($0 as String) }),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] else { return nil }
        var width = properties[kCGImagePropertyPixelWidth] as? Double ?? 0
        var height = properties[kCGImagePropertyPixelHeight] as? Double ?? 0
        let orientation = properties[kCGImagePropertyOrientation] as? UInt32 ?? 1
        if orientation >= 5 { swap(&width, &height) }
        guard width > 0, height > 0 else { return nil }
        size = CGSize(width: width, height: height)

        // Already a format every reader takes, and upright: keep the bytes.
        if orientation == 1, type.conforms(to: .png) || type.conforms(to: .jpeg) {
            self.data = data
            fileExtension = type.conforms(to: .png) ? "png" : "jpeg"
            return
        }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: max(width, height),
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        let hasAlpha = ![.none, .noneSkipFirst, .noneSkipLast].contains(image.alphaInfo)
        let output = NSMutableData()
        let outputType: UTType = hasAlpha ? .png : .jpeg
        guard let destination = CGImageDestinationCreateWithData(output, outputType.identifier as CFString, 1, nil) else {
            return nil
        }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.85] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        self.data = output as Data
        fileExtension = hasAlpha ? "png" : "jpeg"
    }

    init(png: Data, size: CGSize) {
        data = png
        fileExtension = "png"
        self.size = size
    }

    static func png(of image: CGImage) -> Data? {
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, UTType.png.identifier as CFString, 1, nil) else {
            return nil
        }
        CGImageDestinationAddImage(destination, image, nil)
        return CGImageDestinationFinalize(destination) ? output as Data : nil
    }
}

/// A video made ready to put in a presentation: in H.264 MP4, which
/// PowerPoint plays everywhere, with a picture of its first frame to show
/// until it plays.
struct PreparedVideo: Sendable {
    var data: Data
    var poster: PreparedMedia
    /// At its natural size and orientation, in points.
    var size: CGSize

    static func prepare(from url: URL) async throws -> PreparedVideo {
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else {
            throw CocoaError(.fileReadCorruptFile)
        }
        let (natural, transform) = try await track.load(.naturalSize, .preferredTransform)
        let turned = natural.applying(transform)
        let size = CGSize(width: abs(turned.width), height: abs(turned.height))

        let output = FileManager.default.temporaryDirectory.appending(path: "\(UUID().uuidString).mp4")
        guard let session = AVAssetExportSession(asset: asset, presetName: AVAssetExportPreset1920x1080) else {
            throw CocoaError(.fileWriteUnknown)
        }
        try await session.export(to: output, as: .mp4)
        defer { try? FileManager.default.removeItem(at: output) }

        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        let (frame, _) = try await generator.image(at: .zero)
        guard let png = PreparedMedia.png(of: frame) else { throw CocoaError(.fileWriteUnknown) }
        return PreparedVideo(data: try Data(contentsOf: output), poster: PreparedMedia(png: png, size: size), size: size)
    }
}

/// A movie handed over by the photo picker, copied somewhere it can be read.
struct PickedMovie: Transferable {
    let url: URL

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(contentType: .movie) { movie in
            SentTransferredFile(movie.url)
        } importing: { received in
            let copy = FileManager.default.temporaryDirectory
                .appending(path: UUID().uuidString + "." + received.file.pathExtension)
            try FileManager.default.copyItem(at: received.file, to: copy)
            return PickedMovie(url: copy)
        }
    }
}

