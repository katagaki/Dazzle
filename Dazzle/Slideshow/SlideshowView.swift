import SwiftUI

/// The slideshow, full screen.
///
/// Alone, the device shows the audience the slides. With an external
/// display connected, the display shows the slides and the device becomes
/// the presenter's view: the slide now and next, the notes, and the time.
struct SlideshowView: View {
    var session: PresentationSession

    var body: some View {
        Group {
            if session.hasExternalDisplay {
                PresenterView(session: session)
            } else {
                AudienceControls(session: session)
            }
        }
        .focusable()
        .focusEffectDisabled()
        .onKeyPress(action: handleKey)
        .statusBarHidden()
        .preferredColorScheme(.dark)
    }

    /// Arrows, space and return step through, as presentation clickers send.
    private func handleKey(_ press: KeyPress) -> KeyPress.Result {
        switch press.key {
        case .rightArrow, .downArrow, .space, .return, .pageDown:
            session.next()
        case .leftArrow, .upArrow, .pageUp, .delete:
            session.previous()
        case .escape:
            session.end()
        case .home:
            session.go(toPosition: 0)
        case .end:
            session.go(toPosition: session.slideCount - 1)
        default:
            // "B" blacks the screen, as it does in PowerPoint and Keynote.
            guard press.characters.lowercased() == "b" || press.characters == "." else { return .ignored }
            session.toggleBlank()
        }
        return .handled
    }
}

/// The audience's view on the device itself, with touch controls: tap to
/// move on, tap the left edge or swipe to go back.
private struct AudienceControls: View {
    var session: PresentationSession
    @State private var showsControls = true
    @State private var hideTask: Task<Void, Never>?
    @State private var size = CGSize.zero
    @Environment(\.openURL) private var openURL

    var body: some View {
        AudienceView(session: session, showsMediaControls: true)
            .onGeometryChange(for: CGSize.self) { $0.size } action: { size = $0 }
            .contentShape(.rect)
            .gesture(
                DragGesture(minimumDistance: 30).onEnded { value in
                    guard abs(value.translation.width) > abs(value.translation.height) else { return }
                    if value.translation.width < 0 { session.next() } else { session.previous() }
                }
            )
            .simultaneousGesture(
                SpatialTapGesture().onEnded { value in
                    defer { revealControls() }
                    if let presentation = session.presentation,
                       let point = SlideGeometry.slidePoint(value.location, in: size, slideSize: presentation.slideSize.points) {
                        // A video or sound plays or pauses.
                        if let media = session.mediaShape(at: point) {
                            session.media.toggle(media)
                            return
                        }
                        // A link on the slide goes where it leads.
                        if let link = session.link(at: point) {
                            if let url = session.follow(link) { openURL(url) }
                            return
                        }
                    }
                    // The left fifth goes back; anywhere else goes on, unless the slide only moves on by itself.
                    if value.location.x < 120 {
                        session.previous()
                    } else if session.advancesOnTap {
                        session.next()
                    }
                }
            )
            .overlay(alignment: .top) {
                if showsControls { controls.transition(.opacity) }
            }
            .animation(.easeInOut(duration: 0.25), value: showsControls)
            .onAppear(perform: revealControls)
            .onDisappear { hideTask?.cancel() }
            .accessibilityIdentifier("slideshow")
    }

    private var controls: some View {
        HStack(spacing: 10) {
            Button("Slideshow.End", systemImage: "xmark") { session.end() }
                .labelStyle(.iconOnly)
                .frame(width: 44, height: 44)
                .glassEffect(.regular.interactive(), in: .circle)
                .accessibilityIdentifier("endSlideshow")
            Spacer()
            Text(String(format: String(localized: "Slideshow.Position"), session.position + 1, session.slideCount))
                .font(.subheadline.monospacedDigit().weight(.medium))
                .padding(.horizontal, 14)
                .frame(height: 44)
                .glassEffect(.regular, in: .capsule)
            Spacer()
            Button(
                session.isBlanked ? "Slideshow.Unblank" : "Slideshow.Blank",
                systemImage: session.isBlanked ? "eye" : "eye.slash"
            ) {
                session.toggleBlank()
            }
            .labelStyle(.iconOnly)
            .frame(width: 44, height: 44)
            .glassEffect(.regular.interactive(), in: .circle)
        }
        .buttonStyle(.plain)
        .foregroundStyle(.white)
        .padding(.horizontal, 16)
        .padding(.top, 8)
    }

    private func revealControls() {
        showsControls = true
        hideTask?.cancel()
        hideTask = Task {
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled else { return }
            showsControls = false
        }
    }
}

/// The presenter's view, while the audience watches an external display.
struct PresenterView: View {
    var session: PresentationSession
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.openURL) private var openURL
    @State private var currentSize = CGSize.zero

    var body: some View {
        VStack(spacing: 12) {
            header
            if horizontalSizeClass == .compact {
                VStack(spacing: 12) {
                    currentSlide
                    HStack(alignment: .top, spacing: 12) {
                        nextSlide.frame(maxWidth: 160)
                        notes
                    }
                }
            } else {
                HStack(alignment: .top, spacing: 16) {
                    currentSlide
                        .frame(maxWidth: .infinity)
                    VStack(alignment: .leading, spacing: 12) {
                        nextSlide
                        notes
                    }
                    .frame(width: 320)
                }
            }
            Spacer(minLength: 0)
            controls
        }
        .padding(16)
        .background(Color(white: 0.07).ignoresSafeArea())
        .foregroundStyle(.white)
        .accessibilityIdentifier("presenterView")
    }

    private var header: some View {
        HStack {
            Label("Presenter.Connected", systemImage: "display")
                .font(.footnote.weight(.medium))
                .foregroundStyle(.secondary)
            Spacer()
            if let startedAt = session.startedAt {
                Text(startedAt, style: .timer)
                    .font(.title3.monospacedDigit().weight(.semibold))
                    .accessibilityLabel("Presenter.Elapsed")
            }
            Spacer()
            Button("Slideshow.End", systemImage: "xmark") { session.end() }
                .buttonStyle(.plain)
                .padding(.horizontal, 14)
                .frame(height: 36)
                .glassEffect(.regular.interactive(), in: .capsule)
                .accessibilityIdentifier("endSlideshow")
        }
    }

    @ViewBuilder
    private var currentSlide: some View {
        if let presentation = session.presentation, let slide = session.currentSlide {
            ShowingSlideView(session: session, presentation: presentation, slide: slide)
                .aspectRatio(presentation.slideSize.aspectRatio, contentMode: .fit)
                // The presenter can follow the slide's links from here.
                .onGeometryChange(for: CGSize.self) { $0.size } action: { currentSize = $0 }
                .overlay {
                    MediaOverlay(slide: slide, slideSize: presentation.slideSize.points, playback: session.media, showsControls: true)
                }
                .onTapGesture { location in
                    guard let point = SlideGeometry.slidePoint(location, in: currentSize, slideSize: presentation.slideSize.points) else {
                        return
                    }
                    if let media = session.mediaShape(at: point) {
                        session.media.toggle(media)
                    } else if let link = session.link(at: point), let url = session.follow(link) {
                        openURL(url)
                    }
                }
                .clipShape(.rect(cornerRadius: 8))
                .overlay {
                    if session.isBlanked {
                        RoundedRectangle(cornerRadius: 8)
                            .fill(.black.opacity(0.7))
                            .overlay(Label("Presenter.Blanked", systemImage: "eye.slash").font(.headline))
                    }
                }
        }
    }

    @ViewBuilder
    private var nextSlide: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Presenter.Next")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            if let presentation = session.presentation, let slide = session.nextSlide {
                SlideView(presentation: presentation, slide: slide)
                    .aspectRatio(presentation.slideSize.aspectRatio, contentMode: .fit)
                    .clipShape(.rect(cornerRadius: 6))
                    .opacity(0.9)
            } else {
                RoundedRectangle(cornerRadius: 6)
                    .fill(.white.opacity(0.08))
                    .aspectRatio(session.presentation?.slideSize.aspectRatio ?? 16 / 9, contentMode: .fit)
                    .overlay(Text("Presenter.End").font(.caption).foregroundStyle(.secondary))
            }
        }
    }

    private var notes: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Presenter.Notes")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            ScrollView {
                Text(session.currentSlide?.notes.nilIfEmpty ?? String(localized: "Presenter.NoNotes"))
                    .font(.title3)
                    .foregroundStyle(session.currentSlide?.notes.isEmpty ?? true ? .secondary : .primary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            }
        }
        .frame(maxHeight: .infinity, alignment: .top)
    }

    private var controls: some View {
        GlassEffectContainer(spacing: 12) {
            HStack(spacing: 12) {
                Button("Slideshow.Previous", systemImage: "chevron.backward") { session.previous() }
                    .labelStyle(.iconOnly)
                    .font(.title2.weight(.semibold))
                    .frame(width: 72, height: 56)
                    .glassEffect(.regular.interactive(), in: .capsule)
                    .disabled(session.position == 0)
                Text(String(format: String(localized: "Slideshow.Position"), session.position + 1, session.slideCount))
                    .font(.headline.monospacedDigit())
                    .frame(minWidth: 90)
                Button(
                    session.isBlanked ? "Slideshow.Unblank" : "Slideshow.Blank",
                    systemImage: session.isBlanked ? "eye" : "eye.slash"
                ) {
                    session.toggleBlank()
                }
                .labelStyle(.iconOnly)
                .frame(width: 56, height: 56)
                .glassEffect(.regular.interactive(), in: .circle)
                Button("Slideshow.Next", systemImage: "chevron.forward") { session.next() }
                    .labelStyle(.iconOnly)
                    .font(.title2.weight(.semibold))
                    .frame(width: 120, height: 56)
                    .glassEffect(.regular.tint(Color.accentColor.opacity(0.5)).interactive(), in: .capsule)
                    .accessibilityIdentifier("nextSlide")
            }
            .buttonStyle(.plain)
        }
    }
}

/// The slide a slideshow is on, its animations playing as it is tapped through.
struct ShowingSlideView: View {
    var session: PresentationSession
    var presentation: Presentation
    var slide: Slide

    var body: some View {
        TimelineView(.animation(paused: !session.isAnimating)) { timeline in
            SlideView(presentation: presentation, slide: slide, options: options(at: timeline.date))
        }
    }

    private func options(at date: Date) -> SlideRenderer.Options {
        var options = SlideRenderer.Options.presentation
        options.animation = session.animationFrame(at: date)
        return options
    }
}

/// Turning a point in a view that shows a slide, fitted and centred, into
/// a point on the slide.
enum SlideGeometry {
    static func slidePoint(_ location: CGPoint, in size: CGSize, slideSize: CGSize) -> CGPoint? {
        guard size.width > 0, size.height > 0, slideSize.width > 0, slideSize.height > 0 else { return nil }
        let scale = min(size.width / slideSize.width, size.height / slideSize.height)
        let shown = CGSize(width: slideSize.width * scale, height: slideSize.height * scale)
        let origin = CGPoint(x: (size.width - shown.width) / 2, y: (size.height - shown.height) / 2)
        let point = CGPoint(x: (location.x - origin.x) / scale, y: (location.y - origin.y) / scale)
        guard point.x >= 0, point.y >= 0, point.x <= slideSize.width, point.y <= slideSize.height else { return nil }
        return point
    }
}

