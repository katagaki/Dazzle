import AVFoundation
import SwiftUI
import UIKit

/// The videos and sounds on the slide being shown, and which are playing.
///
/// One player per media shape, shared by every view of the slide: the
/// device, an external display, the presenter's preview. Each shows the
/// same player, so a video plays in step everywhere and is heard once.
@MainActor
@Observable
final class MediaPlayback {
    private(set) var players: [SlideShape.ID: AVPlayer] = [:]
    private(set) var playing: Set<SlideShape.ID> = []
    /// Media that has played, whose picture now stays in place of its poster.
    private(set) var started: Set<SlideShape.ID> = []
    @ObservationIgnored private var slideID: Slide.ID?
    @ObservationIgnored private var observers: [NSObjectProtocol] = []

    /// The media on a slide: each media shape, and where it plays from.
    static func media(on slide: Slide) -> [(shape: SlideShape, media: SlideShape.Media)] {
        slide.shapes.compactMap { shape in
            guard case .picture(let picture) = shape.kind, let media = picture.media else { return nil }
            return (shape, media)
        }
    }

    /// Makes players for the slide now showing, leaving the last slide's
    /// behind, and starts those that start on their own.
    func show(_ slide: Slide?, in presentation: Presentation?) {
        guard slide?.id != slideID else { return }
        stopAll()
        slideID = slide?.id
        guard let slide, let presentation else { return }
        for (shape, media) in Self.media(on: slide) {
            guard let url = Self.url(for: media, in: presentation) else { continue }
            let player = AVPlayer(url: url)
            player.actionAtItemEnd = .pause
            players[shape.id] = player
            let id = shape.id
            observers.append(NotificationCenter.default.addObserver(
                forName: AVPlayerItem.didPlayToEndTimeNotification, object: player.currentItem, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.playing.remove(id)
                    self?.players[id]?.seek(to: .zero)
                }
            })
            if media.playsAutomatically { play(id) }
        }
    }

    func isPlaying(_ id: SlideShape.ID) -> Bool { playing.contains(id) }

    func toggle(_ id: SlideShape.ID) {
        if playing.contains(id) { pause(id) } else { play(id) }
    }

    func play(_ id: SlideShape.ID) {
        guard let player = players[id] else { return }
        try? AVAudioSession.sharedInstance().setCategory(.playback)
        player.play()
        playing.insert(id)
        started.insert(id)
    }

    func pause(_ id: SlideShape.ID) {
        players[id]?.pause()
        playing.remove(id)
    }

    func stopAll() {
        players.values.forEach { $0.pause() }
        players = [:]
        playing = []
        started = []
        observers.forEach(NotificationCenter.default.removeObserver)
        observers = []
        slideID = nil
    }

    // MARK: - Files

    /// Media in the package is played from a copy in the caches folder, as
    /// AVFoundation plays files rather than data.
    private static func url(for media: SlideShape.Media, in presentation: Presentation) -> URL? {
        if let path = media.path, let data = presentation.data(at: path) {
            let directory = FileManager.default.temporaryDirectory.appending(path: "Media", directoryHint: .isDirectory)
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            // Named for its contents, so the same media is written once.
            let name = "\(data.count)-\(ZipArchive.crc32(data)).\((path as NSString).pathExtension)"
            let url = directory.appending(path: name)
            if !FileManager.default.fileExists(atPath: url.path) { try? data.write(to: url) }
            return url
        }
        return media.url.flatMap(URL.init(string:))
    }
}

/// A player's picture, filling its frame as the shape's does.
struct PlayerLayerView: UIViewRepresentable {
    let player: AVPlayer

    func makeUIView(context: Context) -> PlayerView {
        let view = PlayerView()
        view.playerLayer.videoGravity = .resizeAspect
        view.isUserInteractionEnabled = false
        return view
    }

    func updateUIView(_ view: PlayerView, context: Context) {
        if view.playerLayer.player !== player { view.playerLayer.player = player }
    }

    final class PlayerView: UIView {
        override static var layerClass: AnyClass { AVPlayerLayer.self }
        var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer } // swiftlint:disable:this force_cast
    }
}

/// The current slide's videos, laid over the slide where their pictures are.
/// `showsControls` adds a play button over each paused one, for the screen
/// the presenter touches.
struct MediaOverlay: View {
    let slide: Slide
    let slideSize: CGSize
    let playback: MediaPlayback
    var showsControls = false

    var body: some View {
        GeometryReader { proxy in
            let scale = min(proxy.size.width / max(slideSize.width, 1), proxy.size.height / max(slideSize.height, 1))
            let origin = CGPoint(
                x: (proxy.size.width - slideSize.width * scale) / 2, y: (proxy.size.height - slideSize.height * scale) / 2
            )
            ForEach(MediaPlayback.media(on: slide), id: \.shape.id) { shape, media in
                let frame = shape.frame.points
                let rect = CGRect(
                    x: origin.x + frame.minX * scale, y: origin.y + frame.minY * scale,
                    width: frame.width * scale, height: frame.height * scale
                )
                ZStack {
                    if media.kind == .video, let player = playback.players[shape.id] {
                        PlayerLayerView(player: player)
                            .opacity(playback.started.contains(shape.id) ? 1 : 0)
                    }
                    if showsControls, !playback.isPlaying(shape.id) {
                        Image(systemName: media.kind == .video ? "play.circle.fill" : "speaker.wave.2.circle.fill")
                            .font(.system(size: min(max(min(rect.width, rect.height) * 0.3, 24), 64)))
                            .symbolRenderingMode(.palette)
                            .foregroundStyle(.white, .black.opacity(0.45))
                            .allowsHitTesting(false)
                    }
                }
                .frame(width: rect.width, height: rect.height)
                .position(x: rect.midX, y: rect.midY)
                .allowsHitTesting(false)
            }
        }
    }
}
