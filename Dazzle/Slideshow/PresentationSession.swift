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
        isPresenting = true
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
        publish()
    }

    // MARK: - Moving

    func next() {
        guard isPresenting else { return }
        if isBlanked {
            isBlanked = false
        } else if position < order.count - 1 {
            position += 1
        } else {
            // Moving on from the last slide ends the show, as in Keynote.
            return end()
        }
        publish()
    }

    func previous() {
        guard isPresenting, position > 0 else { return }
        isBlanked = false
        position -= 1
        publish()
    }

    func go(toPosition index: Int) {
        guard isPresenting, order.indices.contains(index) else { return }
        position = index
        isBlanked = false
        publish()
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
