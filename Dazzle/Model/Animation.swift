import CoreGraphics
import Foundation

/// One effect in a slide's animation sequence, as PowerPoint's animation
/// pane lists them: a shape, or some of its paragraphs, coming in, drawing
/// attention, going out, or moving along a path.
struct ShapeAnimation: Identifiable, Equatable, Hashable, Sendable {
    enum Category: Equatable, Hashable, Sendable {
        case entrance
        case emphasis
        case exit
        case motionPath
        /// Anything else the sequence runs, such as playing a video, by its
        /// `presetClass`.
        case other(String)

        init(presetClass: String?) {
            self = switch presetClass {
            case "entr": .entrance
            case "emph": .emphasis
            case "exit": .exit
            case "path": .motionPath
            default: .other(presetClass ?? "")
            }
        }

        var presetClass: String {
            switch self {
            case .entrance: "entr"
            case .emphasis: "emph"
            case .exit: "exit"
            case .motionPath: "path"
            case .other(let name): name
            }
        }
    }

    /// The edge an effect comes in from or goes out to, as `presetSubtype`
    /// numbers them.
    enum Direction: Int, CaseIterable, Hashable, Sendable {
        case top = 1
        case right = 2
        case bottom = 4
        case left = 8

        var opposite: Direction {
            switch self {
            case .top: .bottom
            case .right: .left
            case .bottom: .top
            case .left: .right
            }
        }
    }

    enum Effect: Equatable, Hashable, Sendable {
        case appear
        case fade
        case fly(Direction)
        case wipe(Direction)
        case zoom
        case float
        case pulse
        case spin
        case growShrink
        case teeter
        case path(MotionPath)
        /// An effect Dazzle does not make itself: played as near as it can,
        /// and written back as read.
        case preset(id: Int, subtype: Int)

        /// What each kind of animation offers to add.
        static func choices(for category: Category) -> [Effect] {
            switch category {
            case .entrance, .exit: [.appear, .fade, .fly(.bottom), .wipe(.bottom), .zoom, .float]
            case .emphasis: [.pulse, .spin, .growShrink, .teeter]
            case .motionPath, .other: []
            }
        }

        /// `presetID`, which tells PowerPoint which effect it is.
        var presetID: Int {
            switch self {
            case .appear: 1
            case .fly: 2
            case .growShrink: 6
            case .spin: 8
            case .fade: 10
            case .wipe: 22
            case .pulse: 26
            case .teeter: 32
            case .float: 42
            case .zoom: 53
            case .path: 0
            case .preset(let id, _): id
            }
        }

        var presetSubtype: Int {
            switch self {
            case .fly(let direction), .wipe(let direction): direction.rawValue
            case .zoom: 16
            case .preset(_, let subtype): subtype
            default: 0
            }
        }

        var direction: Direction? {
            switch self {
            case .fly(let direction), .wipe(let direction): direction
            default: nil
            }
        }

        /// The same effect from another edge.
        func with(_ direction: Direction) -> Effect {
            switch self {
            case .fly: .fly(direction)
            case .wipe: .wipe(direction)
            default: self
            }
        }

        /// Whether it is the same effect, whichever edge it uses.
        func isKind(of other: Effect) -> Bool {
            switch (self, other) {
            case (.fly, .fly), (.wipe, .wipe): true
            default: self == other
            }
        }

        /// How long it runs unless changed, in seconds.
        var defaultDuration: Double {
            switch self {
            case .appear: 0
            case .fade, .fly, .wipe, .zoom, .pulse: 0.5
            case .float, .teeter: 1
            case .spin, .growShrink, .path: 2
            case .preset: 0.5
            }
        }

        /// Whether Dazzle writes the effect itself, so can change its timing.
        var isMadeByDazzle: Bool {
            if case .preset = self { return false }
            return true
        }
    }

    enum Trigger: Hashable, Sendable, CaseIterable {
        case onClick
        case withPrevious
        case afterPrevious
    }

    let id: UUID
    /// The `cNvPr id` of the shape it animates.
    var shapeID: Int
    /// For text built a paragraph at a time, which paragraphs, from zero.
    var paragraphs: ClosedRange<Int>?
    var category: Category
    var effect: Effect
    var trigger: Trigger
    /// Seconds, from when it starts to when it settles.
    var duration: Double
    /// Seconds after its trigger before it starts.
    var delay: Double = 0
    /// The effect's `p:par` as read. Kept while only when it starts changes,
    /// so whatever Dazzle does not model about it survives; dropped once the
    /// effect itself is changed and has to be written anew.
    var source: String?

    init(
        id: UUID = UUID(), shapeID: Int, paragraphs: ClosedRange<Int>? = nil, category: Category, effect: Effect,
        trigger: Trigger = .onClick, duration: Double? = nil, delay: Double = 0, source: String? = nil
    ) {
        self.id = id
        self.shapeID = shapeID
        self.paragraphs = paragraphs
        self.category = category
        self.effect = effect
        self.trigger = trigger
        self.duration = duration ?? effect.defaultDuration
        self.delay = delay
        self.source = source
    }

    /// The same effect, as a new entry, for a copy of its slide.
    init(copying animation: ShapeAnimation) {
        self.init(
            shapeID: animation.shapeID, paragraphs: animation.paragraphs, category: animation.category,
            effect: animation.effect, trigger: animation.trigger, duration: animation.duration,
            delay: animation.delay, source: animation.source
        )
    }

    /// Whether it starts a video or sound the slide holds.
    var playsMedia: Bool {
        category == .other("mediacall") && source?.contains("playFrom") == true
    }
}

/// A motion path, as `p:animMotion` writes it: moves and lines and curves
/// in fractions of the slide, from where the shape sits.
struct MotionPath: Equatable, Hashable, Sendable {
    /// The path as written, such as `M 0 0 L 0.25 0.1 E`.
    var path: String

    /// The path flattened into points, in fractions of the slide.
    var points: [CGPoint] {
        var tokens = path.replacingOccurrences(of: ",", with: " ")
            .split(whereSeparator: \.isWhitespace).map(String.init)[...]
        var result: [CGPoint] = []
        var current = CGPoint.zero
        var start = CGPoint.zero
        var command = "M"
        func number() -> CGFloat? {
            guard let token = tokens.first, let value = Double(token) else { return nil }
            tokens.removeFirst()
            return CGFloat(value)
        }
        func point(relative: Bool) -> CGPoint? {
            guard let x = number(), let y = number() else { return nil }
            return relative ? CGPoint(x: current.x + x, y: current.y + y) : CGPoint(x: x, y: y)
        }
        while let token = tokens.first {
            if let letter = token.first, letter.isLetter {
                command = token
                tokens.removeFirst()
            }
            let relative = command.first?.isLowercase ?? false
            switch command.uppercased() {
            case "M":
                guard let next = point(relative: relative) else { return result }
                current = next
                start = next
                result.append(next)
                command = relative ? "l" : "L"
            case "L":
                guard let next = point(relative: relative) else { return result }
                current = next
                result.append(next)
            case "C":
                let from = current
                guard let first = point(relative: relative), let second = point(relative: relative),
                      let end = point(relative: relative) else { return result }
                for step in 1...16 {
                    let t = CGFloat(step) / 16
                    let u = 1 - t
                    result.append(CGPoint(
                        x: u * u * u * from.x + 3 * u * u * t * first.x + 3 * u * t * t * second.x + t * t * t * end.x,
                        y: u * u * u * from.y + 3 * u * u * t * first.y + 3 * u * t * t * second.y + t * t * t * end.y
                    ))
                }
                current = end
            case "Z":
                current = start
                result.append(start)
            case "E":
                return result
            default:
                tokens.removeFirst()
            }
        }
        return result
    }

    /// Where along the path the shape is, `progress` of the way, in
    /// fractions of the slide. The path is followed at an even pace.
    func offset(at progress: Double) -> CGPoint {
        let points = points
        guard let first = points.first, points.count > 1 else { return points.first ?? .zero }
        var lengths: [CGFloat] = [0]
        for index in 1..<points.count {
            lengths.append(lengths[index - 1] + hypot(points[index].x - points[index - 1].x, points[index].y - points[index - 1].y))
        }
        guard let total = lengths.last, total > 0 else { return first }
        let target = total * CGFloat(min(max(progress, 0), 1))
        let index = lengths.firstIndex { $0 >= target } ?? lengths.count - 1
        guard index > 0 else { return first }
        let span = lengths[index] - lengths[index - 1]
        let t = span > 0 ? (target - lengths[index - 1]) / span : 1
        return CGPoint(
            x: points[index - 1].x + (points[index].x - points[index - 1].x) * t,
            y: points[index - 1].y + (points[index].y - points[index - 1].y) * t
        )
    }
}

/// How an animation leaves a shape at one moment, for drawing.
struct AnimatedAppearance: Equatable, Hashable, Sendable {
    /// The part of a shape a wipe has revealed: a fraction of it, from one edge.
    struct Reveal: Equatable, Hashable, Sendable {
        var edge: ShapeAnimation.Direction
        var fraction: Double
    }

    var opacity = 1.0
    /// Points the shape has moved.
    var offset = CGSize.zero
    var scale = 1.0
    /// Degrees clockwise, on top of the shape's own.
    var rotation = 0.0
    var reveal: Reveal?

    static let hidden = AnimatedAppearance(opacity: 0)

    var isIdentity: Bool { self == AnimatedAppearance() }
}

/// Every animated shape's look at one moment of a slideshow.
struct AnimationFrame: Equatable, Hashable, Sendable {
    /// By `cNvPr id`.
    var shapes: [Int: AnimatedAppearance] = [:]
    /// How visible each built paragraph is, by `cNvPr id` then paragraph.
    var paragraphs: [Int: [Int: Double]] = [:]
}

/// When a slide's animations run: grouped into steps a tap starts, each
/// effect placed in seconds from the start of its step.
struct AnimationTimeline: Sendable {
    struct Entry: Sendable {
        var animation: ShapeAnimation
        var start: Double
        var end: Double { start + animation.duration }
    }

    private(set) var steps: [[Entry]] = []
    /// Whether the first step runs as the slide appears, rather than on a tap.
    private(set) var startsAutomatically = false
    private let animations: [ShapeAnimation]

    init(animations: [ShapeAnimation]) {
        self.animations = animations
        var subgroupStart = 0.0
        for animation in animations {
            if steps.isEmpty || animation.trigger == .onClick {
                if steps.isEmpty { startsAutomatically = animation.trigger != .onClick }
                steps.append([])
                subgroupStart = 0
            }
            if animation.trigger == .afterPrevious, let last = steps.indices.last {
                subgroupStart = steps[last].map(\.end).max() ?? 0
            }
            steps[steps.count - 1].append(Entry(animation: animation, start: subgroupStart + animation.delay))
        }
    }

    /// Taps the slide's animations wait for.
    var tapCount: Int { steps.count - (startsAutomatically ? 1 : 0) }

    /// Steps that have begun as the slide appears.
    var initiallyBegun: Int { startsAutomatically ? 1 : 0 }

    func duration(ofStep index: Int) -> Double {
        guard steps.indices.contains(index) else { return 0 }
        return steps[index].map(\.end).max() ?? 0
    }

    /// The step a tap starts on each animation, from one, or `nil` for those
    /// that start with the slide.
    func tapNumber(of id: ShapeAnimation.ID) -> Int? {
        guard let step = steps.firstIndex(where: { $0.contains { $0.animation.id == id } }) else { return nil }
        return startsAutomatically ? (step == 0 ? nil : step) : step + 1
    }

    /// The look of every animated shape once `begun` steps have started, the
    /// last of them `elapsed` seconds ago. `shapes` places fly-ins off the slide.
    func frame(begun: Int, elapsed: Double, shapes: [SlideShape], slideSize: CGSize) -> AnimationFrame {
        var progress: [ShapeAnimation.ID: Double] = [:]
        for (index, step) in steps.enumerated() where index < begun {
            for entry in step {
                if index < begun - 1 {
                    progress[entry.animation.id] = 1
                } else if elapsed >= entry.start {
                    progress[entry.animation.id] = entry.animation.duration > 0
                        ? min((elapsed - entry.start) / entry.animation.duration, 1) : 1
                }
            }
        }

        var frame = AnimationFrame()
        let frames = Dictionary(shapes.map { ($0.shapeID, $0.frame.points) }) { first, _ in first }
        for shapeID in Set(animations.map(\.shapeID)) {
            guard let shapeFrame = frames[shapeID] else { continue }
            let whole = animations.filter { $0.shapeID == shapeID && $0.paragraphs == nil }
            var appearance = whole.first?.category == .entrance ? AnimatedAppearance.hidden : AnimatedAppearance()
            for animation in whole {
                guard let value = progress[animation.id] else { continue }
                Self.apply(animation, at: value, to: &appearance, frame: shapeFrame, slideSize: slideSize)
            }
            if !appearance.isIdentity { frame.shapes[shapeID] = appearance }

            let built = animations.filter { $0.shapeID == shapeID && $0.paragraphs != nil }
            for paragraph in Set(built.flatMap { Array($0.paragraphs!) }) {
                let covering = built.filter { $0.paragraphs!.contains(paragraph) }
                var opacity = covering.first?.category == .entrance ? 0.0 : 1
                for animation in covering {
                    guard let value = progress[animation.id] else { continue }
                    switch animation.category {
                    case .entrance: opacity = animation.effect == .appear ? 1 : value
                    case .exit: opacity = value >= 1 ? 0 : (animation.effect == .appear ? 1 : 1 - value)
                    default: break
                    }
                }
                if opacity < 1 { frame.paragraphs[shapeID, default: [:]][paragraph] = opacity }
            }
        }
        return frame
    }

    /// The look of every animated shape `elapsed` seconds into playing the
    /// whole slide through, each step starting as the last settles, as the
    /// editor previews it.
    func playingThrough(at elapsed: Double, shapes: [SlideShape], slideSize: CGSize) -> AnimationFrame {
        var remaining = elapsed
        for index in steps.indices {
            let length = duration(ofStep: index) + Self.pauseBetweenSteps
            if remaining < length || index == steps.count - 1 {
                return frame(begun: index + 1, elapsed: remaining, shapes: shapes, slideSize: slideSize)
            }
            remaining -= length
        }
        return frame(begun: 0, elapsed: 0, shapes: shapes, slideSize: slideSize)
    }

    /// How long playing the slide through takes.
    var playingThroughDuration: Double {
        steps.indices.map { duration(ofStep: $0) }.reduce(0, +) + Double(max(steps.count - 1, 0)) * Self.pauseBetweenSteps
    }

    static let pauseBetweenSteps = 0.4

    // MARK: - Effects

    private static func apply(
        _ animation: ShapeAnimation, at progress: Double, to appearance: inout AnimatedAppearance,
        frame: CGRect, slideSize: CGSize
    ) {
        let eased = 1 - pow(1 - progress, 3)
        switch animation.category {
        case .entrance:
            appearance.opacity = 1
            appearance.reveal = nil
            switch animation.effect {
            case .appear: break
            case .fly(let direction):
                let start = offscreen(direction, frame: frame, slideSize: slideSize)
                appearance.offset.width += start.width * (1 - eased)
                appearance.offset.height += start.height * (1 - eased)
            case .wipe(let direction):
                if progress < 1 { appearance.reveal = .init(edge: direction, fraction: progress) }
            case .zoom:
                appearance.scale *= eased
                appearance.opacity = progress
            case .float:
                appearance.offset.height += slideSize.height * 0.1 * (1 - eased)
                appearance.opacity = progress
            default:
                appearance.opacity = progress
            }
        case .exit:
            if progress >= 1 {
                appearance = .hidden
                return
            }
            switch animation.effect {
            case .appear: break
            case .fly(let direction):
                let end = offscreen(direction, frame: frame, slideSize: slideSize)
                let accelerated = pow(progress, 3)
                appearance.offset.width += end.width * accelerated
                appearance.offset.height += end.height * accelerated
            case .wipe(let direction):
                appearance.reveal = .init(edge: direction.opposite, fraction: 1 - progress)
            case .zoom:
                appearance.scale *= 1 - pow(progress, 3)
                appearance.opacity *= 1 - progress
            case .float:
                appearance.offset.height -= slideSize.height * 0.1 * pow(progress, 3)
                appearance.opacity *= 1 - progress
            default:
                appearance.opacity *= 1 - progress
            }
        case .emphasis:
            switch animation.effect {
            case .pulse: appearance.scale *= 1 + 0.05 * sin(.pi * progress)
            case .spin: appearance.rotation += 360 * eased
            case .growShrink: appearance.scale *= 1 + 0.5 * eased
            case .teeter: appearance.rotation += Teeter.angle(at: progress)
            default: break
            }
        case .motionPath:
            guard case .path(let path) = animation.effect else { return }
            let point = path.offset(at: progress)
            appearance.offset.width += point.x * slideSize.width
            appearance.offset.height += point.y * slideSize.height
        case .other:
            break
        }
    }

    /// How far a shape moves to sit just off the slide past `edge`.
    private static func offscreen(_ edge: ShapeAnimation.Direction, frame: CGRect, slideSize: CGSize) -> CGSize {
        switch edge {
        case .top: CGSize(width: 0, height: -frame.maxY)
        case .bottom: CGSize(width: 0, height: slideSize.height - frame.minY)
        case .left: CGSize(width: -frame.maxX, height: 0)
        case .right: CGSize(width: slideSize.width - frame.minX, height: 0)
        }
    }
}

/// The rocking a teeter makes: turns, in degrees, each over a share of the
/// effect's time, ending where it began.
enum Teeter {
    static let swings: [(share: Double, degrees: Double)] = [
        (0.1, 4), (0.2, -8), (0.2, 8), (0.2, -8), (0.2, 8), (0.1, -4),
    ]

    static func angle(at progress: Double) -> Double {
        var angle = 0.0
        var start = 0.0
        for swing in swings {
            let local = (progress - start) / swing.share
            if local <= 0 { break }
            angle += swing.degrees * min(local, 1)
            start += swing.share
        }
        return angle
    }
}
