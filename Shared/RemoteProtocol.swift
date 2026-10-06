import Foundation

/// What the watch asks the iPhone to do.
enum RemoteCommand: String, Sendable {
    case next
    case previous
    /// Start presenting whichever presentation is open on the iPhone.
    case start
    case end
    /// Black the audience's screen out, or bring it back.
    case toggleBlank

    static let messageKey = "command"

    var message: [String: Any] { [Self.messageKey: rawValue] }

    init?(message: [String: Any]) {
        guard let value = message[Self.messageKey] as? String else { return nil }
        self.init(rawValue: value)
    }
}

/// The slideshow as the watch shows it, sent as the iPhone's application
/// context so the watch has the latest whenever it wakes.
struct RemoteState: Equatable, Sendable {
    var isPresenting = false
    /// Whether the iPhone has a presentation open that could be started.
    var canStart = false
    var title = ""
    /// One-based.
    var slideNumber = 0
    var slideCount = 0
    var startedAt: Date?
    var isBlanked = false
    /// A small JPEG of the slide on screen.
    var thumbnail: Data?
    /// The start of the speaker notes for the slide on screen.
    var notes = ""

    static let idle = RemoteState()

    private enum Key {
        static let isPresenting = "isPresenting"
        static let canStart = "canStart"
        static let title = "title"
        static let slideNumber = "slideNumber"
        static let slideCount = "slideCount"
        static let startedAt = "startedAt"
        static let isBlanked = "isBlanked"
        static let thumbnail = "thumbnail"
        static let notes = "notes"
    }

    init() {
        // Nothing open, nothing presenting.
    }

    init(context: [String: Any]) {
        isPresenting = context[Key.isPresenting] as? Bool ?? false
        canStart = context[Key.canStart] as? Bool ?? false
        title = context[Key.title] as? String ?? ""
        slideNumber = context[Key.slideNumber] as? Int ?? 0
        slideCount = context[Key.slideCount] as? Int ?? 0
        startedAt = (context[Key.startedAt] as? Double).map(Date.init(timeIntervalSince1970:))
        isBlanked = context[Key.isBlanked] as? Bool ?? false
        thumbnail = context[Key.thumbnail] as? Data
        notes = context[Key.notes] as? String ?? ""
    }

    /// Property-list types only, as WatchConnectivity requires.
    var context: [String: Any] {
        var context: [String: Any] = [
            Key.isPresenting: isPresenting,
            Key.canStart: canStart,
            Key.title: title,
            Key.slideNumber: slideNumber,
            Key.slideCount: slideCount,
            Key.isBlanked: isBlanked,
            Key.notes: notes,
        ]
        if let startedAt { context[Key.startedAt] = startedAt.timeIntervalSince1970 }
        if let thumbnail { context[Key.thumbnail] = thumbnail }
        return context
    }
}
