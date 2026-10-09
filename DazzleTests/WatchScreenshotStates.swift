import Foundation
import Testing
@testable import Dazzle

/// Writes the remote states the Apple Watch App Store screenshots show.
///
/// The watch only fills in once an iPhone tells it what is on screen, so
/// `Assets/App Store/capture.sh` renders the slides here, from the sample deck
/// at `SCREENSHOT_DECK`, and hands each state to the watch app at launch.
/// Without `SCREENSHOT_WATCH_DIR` the test stays out of an ordinary run.
@Suite("Watch screenshot states")
struct WatchScreenshotStates {
    private struct Shot {
        let name: String
        /// Counted from 1.
        let slide: Int
    }

    private static let shots = [
        Shot(name: "01-remote", slide: 2),
        Shot(name: "02-chart", slide: 3),
    ]

    private static let environment = ProcessInfo.processInfo.environment

    @Test(.enabled(if: !(environment["SCREENSHOT_WATCH_DIR"] ?? "").isEmpty))
    func states() throws {
        let directory = URL(fileURLWithPath: try #require(Self.environment["SCREENSHOT_WATCH_DIR"]))
        let deck = URL(fileURLWithPath: try #require(Self.environment["SCREENSHOT_DECK"]))
        let presentation = try PPTXReader.presentation(from: Data(contentsOf: deck))
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        for shot in Self.shots {
            let slide = presentation.slides[shot.slide - 1]
            var state = RemoteState()
            state.isPresenting = true
            state.canStart = true
            state.title = deck.deletingPathExtension().lastPathComponent
            state.slideNumber = shot.slide
            state.slideCount = presentation.slides.count
            state.notes = String(slide.notes.prefix(280))
            // Twice what the iPhone sends, so the slide stays sharp on the store.
            state.thumbnail = SlideExporter.image(of: slide, in: presentation, width: 624, format: .jpeg)
            // The watch counts from launch; capture.sh sets when the talk began.
            let data = try PropertyListSerialization.data(fromPropertyList: state.context, format: .binary, options: 0)
            try data.write(to: directory.appendingPathComponent("\(shot.name).plist"))
        }
    }
}
