import CoreGraphics

/// Where a shape being moved or resized settles: onto the slide's edges and
/// centre lines, and onto the edges and centres of the other shapes, when
/// it comes within a few points of one. The lines it settled on are shown
/// as guides while the finger is down.
struct Snapping {
    /// A line a shape settled on: vertical at `position` for an x guide,
    /// horizontal for a y guide, in slide points.
    struct Guide: Equatable, Hashable {
        enum Axis: Hashable {
            case vertical
            case horizontal
        }

        var axis: Axis
        var position: CGFloat
    }

    /// Which of a rectangle's lines along one axis may move: its leading
    /// edge, its centre, its trailing edge.
    struct Lines: OptionSet {
        let rawValue: Int
        static let minimum = Lines(rawValue: 1)
        static let middle = Lines(rawValue: 2)
        static let maximum = Lines(rawValue: 4)
        static let all: Lines = [.minimum, .middle, .maximum]
    }

    /// The slide, in points.
    var slide: CGSize
    /// The frames of the shapes not being moved.
    var others: [CGRect]
    /// How close counts as close enough, in slide points.
    var threshold: CGFloat

    private var verticalTargets: [CGFloat] {
        [0, slide.width / 2, slide.width] + others.flatMap { [$0.minX, $0.midX, $0.maxX] }
    }

    private var horizontalTargets: [CGFloat] {
        [0, slide.height / 2, slide.height] + others.flatMap { [$0.minY, $0.midY, $0.maxY] }
    }

    /// How far to nudge `rect` so the nearest of its `lines` lands on a
    /// target, and the guides it then lies on.
    func adjustment(for rect: CGRect, x lines: Lines = .all, y yLines: Lines = .all) -> (offset: CGSize, guides: [Guide]) {
        let x = nearest(Self.values(of: lines, min: rect.minX, mid: rect.midX, max: rect.maxX), among: verticalTargets)
        let y = nearest(Self.values(of: yLines, min: rect.minY, mid: rect.midY, max: rect.maxY), among: horizontalTargets)
        let offset = CGSize(width: x?.delta ?? 0, height: y?.delta ?? 0)
        let moved = rect.offsetBy(dx: offset.width, dy: offset.height)
        // Every line the settled rectangle now lies on, not only the one
        // that pulled it there.
        var guides: [Guide] = []
        if x != nil {
            let own = Self.values(of: .all, min: moved.minX, mid: moved.midX, max: moved.maxX)
            for target in Set(verticalTargets) where own.contains(where: { abs($0 - target) < 0.01 }) {
                guides.append(Guide(axis: .vertical, position: target))
            }
        }
        if y != nil {
            let own = Self.values(of: .all, min: moved.minY, mid: moved.midY, max: moved.maxY)
            for target in Set(horizontalTargets) where own.contains(where: { abs($0 - target) < 0.01 }) {
                guides.append(Guide(axis: .horizontal, position: target))
            }
        }
        return (offset, guides)
    }

    private func nearest(_ values: [CGFloat], among targets: [CGFloat]) -> (delta: CGFloat, target: CGFloat)? {
        var best: (delta: CGFloat, target: CGFloat)?
        for value in values {
            for target in targets {
                let delta = target - value
                guard abs(delta) <= threshold, abs(delta) < abs(best?.delta ?? .infinity) else { continue }
                best = (delta, target)
            }
        }
        return best
    }

    private static func values(of lines: Lines, min: CGFloat, mid: CGFloat, max: CGFloat) -> [CGFloat] {
        var result: [CGFloat] = []
        if lines.contains(.minimum) { result.append(min) }
        if lines.contains(.middle) { result.append(mid) }
        if lines.contains(.maximum) { result.append(max) }
        return result
    }
}
