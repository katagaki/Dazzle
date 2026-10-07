import AVFoundation
import CoreGraphics
import CoreVideo
import Foundation

/// Renders slides to an H.264 movie: each slide held for its time, with a
/// short dissolve into the next.
enum VideoExporter {
    enum ExportError: LocalizedError {
        case couldNotStart
        case failed(String)

        var errorDescription: String? {
            switch self {
            case .couldNotStart: String(localized: "Error.VideoExport")
            case .failed(let reason): String(localized: "Error.VideoExport") + "\n" + reason
            }
        }
    }

    static let framesPerSecond: Int32 = 30
    static let dissolve = 0.5

    /// Writes the movie to `url`, holding each slide for the matching
    /// number of seconds, and telling `progress` how far it has got, 0…1.
    static func export(
        _ slides: [Slide], of presentation: Presentation, width: Int, durations: [Double], to url: URL,
        progress: @Sendable (Double) -> Void
    ) async throws {
        // Video encoders want even dimensions.
        let width = width - width % 2
        var height = Int((Double(width) / presentation.slideSize.aspectRatio).rounded())
        height -= height % 2
        try? FileManager.default.removeItem(at: url)
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
        ])
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32ARGB,
            kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height,
        ])
        guard writer.canAdd(input) else { throw ExportError.couldNotStart }
        writer.add(input)
        guard writer.startWriting() else { throw ExportError.failed(writer.error?.localizedDescription ?? "") }
        writer.startSession(atSourceTime: .zero)

        let images = slides.compactMap { SlideExporter.cgImage(of: $0, in: presentation, width: width) }
        let holds = images.indices.map { index in
            max(Int((durations.indices.contains(index) ? durations[index] : 3) * Double(framesPerSecond)), 1)
        }
        let total = holds.reduce(0, +)
        var frame: Int64 = 0

        for (index, image) in images.enumerated() {
            let holdFrames = holds[index]
            let dissolveFrames = min(Int(dissolve * Double(framesPerSecond)), holdFrames / 2)
            for step in 0..<holdFrames {
                try Task.checkCancellation()
                // The last frames of a slide dissolve into the next one.
                let next = images.indices.contains(index + 1) ? images[index + 1] : nil
                let fade = step >= holdFrames - dissolveFrames && next != nil
                    ? Double(step - (holdFrames - dissolveFrames) + 1) / Double(dissolveFrames + 1) : 0
                while !input.isReadyForMoreMediaData { try await Task.sleep(for: .milliseconds(5)) }
                guard let buffer = pixelBuffer(from: adaptor, width: width, height: height, draw: { context in
                    let bounds = CGRect(x: 0, y: 0, width: width, height: height)
                    context.draw(image, in: bounds)
                    if fade > 0, let next {
                        context.setAlpha(fade)
                        context.draw(next, in: bounds)
                    }
                }) else { throw ExportError.couldNotStart }
                adaptor.append(buffer, withPresentationTime: CMTime(value: frame, timescale: framesPerSecond))
                frame += 1
                if frame % 15 == 0 { progress(Double(frame) / Double(max(total, 1))) }
            }
        }
        input.markAsFinished()
        await writer.finishWriting()
        if writer.status != .completed { throw ExportError.failed(writer.error?.localizedDescription ?? "") }
        progress(1)
    }

    private static func pixelBuffer(
        from adaptor: AVAssetWriterInputPixelBufferAdaptor, width: Int, height: Int, draw: (CGContext) -> Void
    ) -> CVPixelBuffer? {
        var buffer: CVPixelBuffer?
        if let pool = adaptor.pixelBufferPool {
            CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer)
        } else {
            CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_32ARGB, nil, &buffer)
        }
        guard let buffer else { return nil }
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let context = CGContext(
            data: CVPixelBufferGetBaseAddress(buffer), width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: CVPixelBufferGetBytesPerRow(buffer), space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue
        ) else { return nil }
        draw(context)
        return buffer
    }
}
