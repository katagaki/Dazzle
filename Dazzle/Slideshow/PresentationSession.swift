import SwiftUI

/// The slideshow in progress, if any.
///
/// One for the whole app: the device showing the presenter's controls, an
/// external display showing the audience the slide, and the watch acting
/// as a remote all follow the same session.
@MainActor
@Observable
final class PresentationSession {
    static let shared = PresentationSession()

    private(set) var presentation: Presentation?
    private(set) var title = ""
    /// Indices into the presentation's slides, in showing order.
    private(set) var order: [Int] = []
    /// Where in `order` the slideshow is.
    private(set) var position = 0
    private(set) var isPresenting = false
    private(set) var startedAt: Date?
    /// The audience sees black, while the presenter keeps their place.
    private(set) var isBlanked = false
    /// The editor window the slideshow was started from.
    private(set) var ownerID: UUID?
    /// The slide on screen when the last slideshow ended, so the editor can
    /// pick up where the presenter left off.
    private(set) var lastShownSlideID: Slide.ID?
    /// External displays currently showing the audience view.
    private(set) var externalDisplayCount = 0
    /// The current slide's videos and sounds.
    let media = MediaPlayback()
    /// Whether the show starts over after its last slide.
    private(set) var loops = false
    /// How many of the current slide's animation steps have begun.
    private(set) var builds = 0
    /// When the latest of them began.
    private(set) var buildStartedAt = Date.distantPast
    /// Whether an animation is running, so views showing the slide redraw
    /// every frame only while there is something to see.
    private(set) var isAnimating = false
    @ObservationIgnored private var animatingTask: Task<Void, Never>?
    /// Moving on by itself, after the current slide's time.
    @ObservationIgnored private var advanceTask: Task<Void, Never>?
    /// What the running wait is for, so publishing again does not restart it.
    @ObservationIgnored private var advanceFor: (position: Int, builds: Int, blanked: Bool, presenting: Bool)?

    var hasExternalDisplay: Bool { externalDisplayCount > 0 }

    var currentSlide: Slide? { slide(atPosition: position) }
    var nextSlide: Slide? { slide(atPosition: position + 1) }
    var slideCount: Int { order.count }
    var isAtEnd: Bool { position >= order.count - 1 }

    func slide(atPosition index: Int) -> Slide? {
        guard let presentation, order.indices.contains(index) else { return nil }
        return presentation.slides[order[index]]
    }

    // MARK: - Starting and stopping

    func start(_ presentation: Presentation, title: String, fromSlide slideIndex: Int, owner: UUID) {
        self.presentation = presentation
        self.title = title
        order = presentation.visibleSlideIndices
        // Starting on a hidden slide starts on the next one that shows.
        position = order.firstIndex { $0 >= slideIndex } ?? 0
        isBlanked = false
        startedAt = Date()
        ownerID = owner
        loops = presentation.loopsSlideshow
        isPresenting = true
        beginSlide()
        publish()
    }

    func end() {
        guard isPresenting else { return }
        lastShownSlideID = currentSlide?.id
        isPresenting = false
        isBlanked = false
        startedAt = nil
        ownerID = nil
        presentation = nil
        order = []
        position = 0
        builds = 0
        isAnimating = false
        animatingTask?.cancel()
        publish()
    }

    // MARK: - Moving

    /// Plays the slide's next animation step, or with none left, moves on.
    func next() {
        guard isPresenting else { return }
        if isBlanked {
            isBlanked = false
        } else if hasStepsLeft {
            builds += 1
            buildStartedAt = Date()
            trackAnimation()
            playMedia(inStep: builds - 1)
        } else if position < order.count - 1 {
            position += 1
            beginSlide()
        } else if loops {
            position = 0
            beginSlide()
        } else {
            // Moving on from the last slide ends the show, as in Keynote.
            return end()
        }
        publish()
    }

    /// Whether a tap on the slide moves the show on: as the slide says, but
    /// always while animations wait for one.
    var advancesOnTap: Bool { hasStepsLeft || (currentSlide?.advancesOnClick ?? true) }

    /// Whether the current slide has animations still to play.
    var hasStepsLeft: Bool { builds < (currentSlide?.animationTimeline.steps.count ?? 0) }

    /// Waits out the current slide's time, if it has one, after its running
    /// animations settle, then moves on.
    private func scheduleAdvance() {
        let now = (position: position, builds: builds, blanked: isBlanked, presenting: isPresenting)
        if let advanceFor, advanceFor == now { return }
        advanceFor = now
        advanceTask?.cancel()
        advanceTask = nil
        guard isPresenting, !isBlanked, let seconds = currentSlide?.autoAdvanceAfter else { return }
        let shown = (position, builds)
        let wait = max(seconds, 0.1) + animationTimeLeft
        advanceTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(wait))
            guard !Task.isCancelled, let self, self.isPresenting, self.position == shown.0, self.builds == shown.1,
                  !self.isBlanked else { return }
            self.advanceFor = nil
            self.next()
        }
    }

    /// Takes back the last animation step, or with none played, goes back a slide.
    func previous() {
        guard isPresenting else { return }
        if builds > (currentSlide?.animationTimeline.initiallyBegun ?? 0) {
            // Back to how the slide looked before the step, without playing it backwards.
            builds -= 1
            buildStartedAt = .distantPast
            isBlanked = false
            trackAnimation()
            return publish()
        }
        guard position > 0 else { return }
        isBlanked = false
        position -= 1
        // Going back finds a slide as it was left: every animation played.
        beginSlide(fullyBuilt: true)
        publish()
    }

    func go(toPosition index: Int) {
        guard isPresenting, order.indices.contains(index) else { return }
        position = index
        isBlanked = false
        beginSlide()
        publish()
    }

    // MARK: - Animations

    /// The look of the current slide's animated shapes at `date`.
    func animationFrame(at date: Date) -> AnimationFrame? {
        guard let presentation, let slide = currentSlide, !slide.animations.isEmpty else { return nil }
        return slide.animationTimeline.frame(
            begun: builds, elapsed: date.timeIntervalSince(buildStartedAt), shapes: slide.shapes,
            slideSize: presentation.slideSize.points
        )
    }

    /// Starts the slide now showing: the animations that run as it appears
    /// begin, the rest wait for taps.
    private func beginSlide(fullyBuilt: Bool = false) {
        let timeline = currentSlide?.animationTimeline
        if fullyBuilt {
            builds = timeline?.steps.count ?? 0
            buildStartedAt = .distantPast
        } else {
            builds = timeline?.initiallyBegun ?? 0
            buildStartedAt = Date()
        }
        trackAnimation()
    }

    /// Seconds until the step playing now settles.
    private var animationTimeLeft: Double {
        guard builds > 0, let timeline = currentSlide?.animationTimeline else { return 0 }
        return max(timeline.duration(ofStep: builds - 1) - Date().timeIntervalSince(buildStartedAt), 0)
    }

    private func trackAnimation() {
        animatingTask?.cancel()
        let remaining = animationTimeLeft
        isAnimating = remaining > 0
        guard isAnimating else { return }
        animatingTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(remaining))
            guard !Task.isCancelled else { return }
            self?.isAnimating = false
        }
    }

    /// Starts the videos and sounds a step plays, as PowerPoint does on the click that reaches them.
    private func playMedia(inStep index: Int) {
        guard let slide = currentSlide else { return }
        let steps = slide.animationTimeline.steps
        guard steps.indices.contains(index) else { return }
        for entry in steps[index] where entry.animation.playsMedia {
            if let shape = slide.shapes.first(where: { $0.shapeID == entry.animation.shapeID }) { media.play(shape.id) }
        }
    }

    // MARK: - Media

    /// The video or sound at a point on the current slide, in slide points.
    func mediaShape(at point: CGPoint) -> SlideShape.ID? {
        guard let slide = currentSlide, !isBlanked else { return nil }
        return MediaPlayback.media(on: slide).reversed().first { $0.shape.frame.points.contains(point) }?.shape.id
    }

    // MARK: - Links

    /// The link at a point on the current slide, in slide points. A little
    /// slack round each makes them easier to hit with a finger.
    func link(at point: CGPoint) -> Hyperlink? {
        guard let presentation, let slide = currentSlide, !isBlanked else { return nil }
        return SlideRenderer(presentation: presentation, slide: slide).linkAreas()
            .first { $0.0.insetBy(dx: -6, dy: -6).contains(point) }?.1
    }

    /// Follows a link within the show. A web address is handed back for the
    /// caller to open.
    func follow(_ link: Hyperlink) -> URL? {
        guard isPresenting else { return nil }
        switch link {
        case .url(let address):
            return URL(string: address)
        case .slide(let id):
            guard let presentation, let index = presentation.index(of: id) else { return nil }
            if let target = order.firstIndex(of: index) {
                go(toPosition: target)
            } else {
                // A hidden slide shows when a link leads to it.
                order.insert(index, at: position + 1)
                go(toPosition: position + 1)
            }
        case .nextSlide: next()
        case .previousSlide: previous()
        case .firstSlide: go(toPosition: 0)
        case .lastSlide: go(toPosition: order.count - 1)
        case .endShow: end()
        case .slidePart, .other: break
        }
        return nil
    }

    func toggleBlank() {
        guard isPresenting else { return }
        isBlanked.toggle()
        publish()
    }

    func handle(_ command: RemoteCommand) {
        switch command {
        case .next: next()
        case .previous: previous()
        case .end: end()
        case .toggleBlank: toggleBlank()
        case .start:
            guard !isPresenting, let candidate = candidates.last else { return }
            candidate.start()
        }
    }

    // MARK: - External displays

    func externalDisplayConnected() {
        externalDisplayCount += 1
    }

    func externalDisplayDisconnected() {
        externalDisplayCount = max(externalDisplayCount - 1, 0)
    }

    // MARK: - Starting from the watch

    /// An open presentation the watch could start.
    struct Candidate {
        var id: UUID
        var title: String
        var start: @MainActor () -> Void
    }

    /// Open presentations, the most recently active last.
    private var candidates: [Candidate] = []

    func offer(_ candidate: Candidate) {
        candidates.removeAll { $0.id == candidate.id }
        candidates.append(candidate)
        publish()
    }

    func withdraw(_ id: UUID) {
        candidates.removeAll { $0.id == id }
        if ownerID == id { end() }
        publish()
    }

    // MARK: - Remote

    private func publish() {
        media.show(isPresenting ? currentSlide : nil, in: presentation)
        scheduleAdvance()
        var state = RemoteState()
        state.canStart = !candidates.isEmpty
        state.title = isPresenting ? title : candidates.last?.title ?? ""
        if isPresenting, let presentation, let slide = currentSlide {
            state.isPresenting = true
            state.slideNumber = position + 1
            state.slideCount = order.count
            state.startedAt = startedAt
            state.isBlanked = isBlanked
            state.notes = String(slide.notes.prefix(280))
            state.thumbnail = SlideExporter.image(of: slide, in: presentation, width: 312, format: .jpeg, quality: 0.6)
        }
        RemoteControlServer.shared.publish(state)
    }
}
