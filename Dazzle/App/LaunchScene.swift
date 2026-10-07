import SwiftUI

/// The top of the document browser: a quiet backdrop with a wall of slides
/// floating faintly behind the button.
struct DazzleLaunchScene: Scene {
    var body: some Scene {
        // No title: the app's name above the button read as part of it.
        DocumentGroupLaunchScene("") {
            NewDocumentButton("Launch.NewPresentation")
        } background: {
            LaunchPalette.background
                .ignoresSafeArea()
        } backgroundAccessoryView: { geometry in
            LaunchSlideWall(frame: geometry.frame, titleFrame: geometry.titleViewFrame)
        }
    }
}

/// A quiet backdrop for the browser, so the colour comes from the slides.
private enum LaunchPalette {
    static let background = adaptive(light: (1.00, 0.965, 0.94), dark: (0.11, 0.085, 0.075))
    /// The app icon's orange, lifted a little in dark mode to hold its own.
    static let ink = adaptive(light: (0.94, 0.40, 0.19), dark: (1.00, 0.52, 0.30))
    static let card = adaptive(light: (1.00, 1.00, 1.00), dark: (0.19, 0.145, 0.125))

    private static func adaptive(light: (CGFloat, CGFloat, CGFloat), dark: (CGFloat, CGFloat, CGFloat)) -> Color {
        Color(UIColor { traits in
            let (red, green, blue) = traits.userInterfaceStyle == .dark ? dark : light
            return UIColor(red: red, green: green, blue: blue, alpha: 1)
        })
    }
}

/// Slides laid like brickwork behind the button, every other row lined up
/// with its edges, fading out towards the browser. Held back so the button
/// stays easy to read. The slides come in once, all together, each row from
/// the other side to the one above, and then hold still.
private struct LaunchSlideWall: View {
    var frame: CGRect
    var titleFrame: CGRect

    @Environment(\.horizontalSizeClass) private var sizeClass
    /// Whether the slides have come in. Slides laid out after that, as when
    /// the device turns, are simply there.
    @State private var isRevealed = false

    /// How far in from its frame the system sets the title and button.
    private static let contentInset: CGFloat = 20
    /// Ordered so that slides of a kind fall well apart on the wall.
    private static let layouts: [LaunchSlideCard.Layout] = [
        .picture, .title, .chart, .quote, .columns, .donut, .bullets,
        .table, .lineChart, .section, .timeline, .gallery, .statistic,
    ]
    /// Six colours against thirteen layouts, so no two neighbours match in both.
    private static let colors: [Color] = [LaunchPalette.ink, .pink, .teal, .indigo, .purple, .green]

    private struct Slot: Identifiable {
        var id: Int
        var row: Int
        var column: Int
        var center: CGPoint
        /// How far down the wall the slide sits, from 0 at the top to 1 at the browser.
        var depth: Double
    }

    var body: some View {
        let scale: CGFloat = sizeClass == .regular ? 1.35 : 1
        let gap = 14 * scale
        let content = titleFrame.insetBy(dx: Self.contentInset, dy: 0)
        // As many columns as come closest to the size wanted, widened or
        // narrowed a little so they fill the title's width exactly.
        let columns = max(1, Int(((content.width + gap) / (120 * scale + gap)).rounded()))
        let width = (content.width - CGFloat(columns - 1) * gap) / CGFloat(columns)
        let slots = slots(content: content, columns: columns, slideWidth: width, gap: gap, scale: scale)
        ZStack {
            ForEach(slots) { slot in
                LaunchSlideCard(
                    // Stepped by row as well as column, so neither a row nor a
                    // column repeats however many columns there are.
                    layout: Self.layouts[(slot.column + 5 * slot.row) % Self.layouts.count],
                    color: Self.colors[(slot.column + 3 * slot.row) % Self.colors.count],
                    width: width
                )
                .opacity(1 - 0.7 * slot.depth)
                .modifier(entrance(for: slot))
                .position(slot.center)
            }
        }
        // Flattened first, so overlapping shadows fade as one.
        .compositingGroup()
        .opacity(0.45)
        // The system lays the wall out more than once while the browser loads
        // and fades it in after, so the slides wait until it can be seen.
        .background(LaunchVisibilityWatcher { isRevealed = true })
    }

    /// Even rows ease in a little way from the leading edge and odd rows from
    /// the trailing one, all at the same time.
    private func entrance(for slot: Slot) -> LaunchEntrance {
        LaunchEntrance(isShown: isRevealed, distance: (slot.row.isMultiple(of: 2) ? -1 : 1) * 40)
    }

    private func slots(content: CGRect, columns: Int, slideWidth: CGFloat, gap: CGFloat, scale: CGFloat) -> [Slot] {
        // SwiftUI sizes the view once before the title has a frame; there is
        // nothing to line up with until it does.
        guard !content.isNull, content.width > 0, slideWidth > 0 else { return [] }
        let size = CGSize(width: slideWidth, height: slideWidth * 9 / 16)
        let pitch = CGSize(width: size.width + gap, height: size.height + gap)
        // Carry on past the title's edges to the screen's, where there is room
        // for at least half a slide.
        let overhang = Int(((content.minX - frame.minX - gap) / size.width + 0.5).rounded(.down))
        let top = frame.minY + 10 * scale
        // The title's frame runs down into the browser, which covers anything lower.
        let bottom = titleFrame.maxY
        let rows = max(0, Int(((bottom - top) / pitch.height).rounded(.up)))

        let extra = max(0, overhang) + 1

        var slots: [Slot] = []
        for row in 0..<rows {
            let y = top + size.height / 2 + CGFloat(row) * pitch.height
            // Like brickwork: every other row sits half a slide over.
            let shift: CGFloat = row.isMultiple(of: 2) ? 0 : -0.5
            for column in -extra..<(columns + extra) {
                let x = content.minX + size.width / 2 + (CGFloat(column) + shift) * pitch.width
                guard x + size.width / 2 > frame.minX, x - size.width / 2 < frame.maxX else { continue }
                slots.append(Slot(
                    id: slots.count, row: row, column: column + extra,
                    center: CGPoint(x: x, y: y), depth: Double(row) / Double(max(1, rows - 1))
                ))
            }
        }
        return slots
    }
}

/// Eases a slide in from the side by the given distance as it fades in, once
/// it is to be shown. Only fades when Reduce Motion is on.
private struct LaunchEntrance: ViewModifier {
    var isShown: Bool
    var distance: CGFloat

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content
            .opacity(isShown ? 1 : 0)
            .offset(x: isShown || reduceMotion ? 0 : distance)
            .animation(.easeOut(duration: 1.2), value: isShown)
    }
}

/// Calls back once, the first time the view it sits behind is fully on
/// screen: in a window, with nothing above it hidden or faded.
private struct LaunchVisibilityWatcher: UIViewRepresentable {
    var onVisible: () -> Void

    func makeUIView(context: Context) -> WatcherView {
        let view = WatcherView()
        view.onVisible = onVisible
        return view
    }

    func updateUIView(_ uiView: WatcherView, context: Context) {
        uiView.onVisible = onVisible
    }

    final class WatcherView: UIView {
        var onVisible: (() -> Void)?
        private var displayLink: CADisplayLink?

        override func didMoveToWindow() {
            super.didMoveToWindow()
            displayLink?.invalidate()
            displayLink = nil
            guard window != nil, onVisible != nil else { return }
            // Checked every frame, since the system fades the wall in by
            // animating a view above it rather than telling it anything.
            let link = CADisplayLink(target: self, selector: #selector(check))
            link.add(to: .main, forMode: .common)
            displayLink = link
        }

        @objc private func check() {
            var view: UIView? = self
            while let current = view {
                let opacity = current.layer.presentation()?.opacity ?? current.layer.opacity
                if current.isHidden || opacity < 0.99 { return }
                view = current.superview
            }
            displayLink?.invalidate()
            displayLink = nil
            let onVisible = onVisible
            self.onVisible = nil
            onVisible?()
        }
    }
}

/// One slide on the wall, hinting at what a deck holds.
private struct LaunchSlideCard: View {
    enum Layout {
        case title, columns, chart, picture, bullets
        case quote, donut, table, timeline, gallery, lineChart, statistic, section
    }

    var layout: Layout
    /// The colour of what is on the slide.
    var color: Color
    var width: CGFloat

    var body: some View {
        let unit = width / 100
        content(unit: unit)
            .padding(12 * unit)
            // Sized outright rather than by aspect ratio, which gives way when
            // the accessory offers less height, so the slide stays a true 16:9.
            .frame(width: width, height: width * 9 / 16, alignment: .leading)
            .background(LaunchPalette.card, in: .rect(cornerRadius: 4 * unit, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 4 * unit, style: .continuous)
                    .strokeBorder(.primary.opacity(0.1), lineWidth: 1)
            }
            .shadow(color: color.opacity(0.15), radius: 6, y: 3)
            .accessibilityHidden(true)
    }

    @ViewBuilder
    private func content(unit: CGFloat) -> some View {
        switch layout {
        case .title:
            VStack(alignment: .leading, spacing: 6 * unit) {
                bar(width: 64 * unit, height: 9 * unit, opacity: 0.95)
                bar(width: 40 * unit, height: 6 * unit, opacity: 0.6)
            }
        case .columns:
            VStack(alignment: .leading, spacing: 6 * unit) {
                bar(width: 48 * unit, height: 7 * unit, opacity: 0.95)
                HStack(spacing: 6 * unit) {
                    bar(width: nil, height: nil, opacity: 0.7)
                    bar(width: nil, height: nil, opacity: 0.45)
                }
            }
        case .chart:
            HStack(alignment: .bottom, spacing: 7 * unit) {
                ForEach([0.45, 0.75, 0.6, 1.0], id: \.self) { fraction in
                    bar(width: nil, height: 32 * unit * fraction, opacity: 0.6 + 0.35 * fraction)
                }
            }
            .frame(maxHeight: .infinity, alignment: .bottom)
        case .picture:
            HStack(spacing: 8 * unit) {
                Circle()
                    .fill(color.opacity(0.95))
                    .frame(width: 24 * unit)
                VStack(alignment: .leading, spacing: 5 * unit) {
                    bar(width: 36 * unit, height: 7 * unit, opacity: 0.9)
                    bar(width: 24 * unit, height: 5 * unit, opacity: 0.55)
                }
            }
        case .bullets:
            VStack(alignment: .leading, spacing: 5 * unit) {
                ForEach([56, 44, 50] as [CGFloat], id: \.self) { length in
                    HStack(spacing: 4 * unit) {
                        Circle()
                            .fill(color.opacity(0.95))
                            .frame(width: 5 * unit)
                        bar(width: length * unit, height: 5 * unit, opacity: 0.7)
                    }
                }
            }
        case .quote:
            HStack(alignment: .top, spacing: 4 * unit) {
                Text(verbatim: "\u{201C}")
                    .font(.system(size: 30 * unit, weight: .black, design: .serif))
                    .foregroundStyle(color.opacity(0.95))
                    .frame(height: 20 * unit, alignment: .top)
                VStack(alignment: .leading, spacing: 4 * unit) {
                    bar(width: 52 * unit, height: 5 * unit, opacity: 0.8)
                    bar(width: 44 * unit, height: 5 * unit, opacity: 0.8)
                    bar(width: 22 * unit, height: 4 * unit, opacity: 0.45)
                        .padding(.top, 2 * unit)
                }
                .padding(.top, 4 * unit)
            }
        case .donut:
            HStack(spacing: 9 * unit) {
                ZStack {
                    Circle()
                        .stroke(color.opacity(0.25), lineWidth: 7 * unit)
                    Circle()
                        .trim(from: 0, to: 0.64)
                        .stroke(color.opacity(0.95), style: StrokeStyle(lineWidth: 7 * unit, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                }
                .frame(width: 26 * unit, height: 26 * unit)
                VStack(alignment: .leading, spacing: 5 * unit) {
                    ForEach([0.95, 0.6, 0.3], id: \.self) { opacity in
                        HStack(spacing: 3 * unit) {
                            bar(width: 5 * unit, height: 5 * unit, opacity: opacity)
                            bar(width: 26 * unit, height: 4 * unit, opacity: 0.45)
                        }
                    }
                }
            }
        case .table:
            VStack(spacing: 4 * unit) {
                ForEach(0..<4) { row in
                    HStack(spacing: 4 * unit) {
                        ForEach(0..<3) { _ in
                            bar(width: nil, height: 5 * unit, opacity: row == 0 ? 0.9 : 0.3)
                        }
                    }
                }
            }
        case .timeline:
            VStack(alignment: .leading, spacing: 7 * unit) {
                bar(width: 40 * unit, height: 6 * unit, opacity: 0.9)
                ZStack {
                    bar(width: nil, height: 2 * unit, opacity: 0.35)
                    HStack {
                        ForEach(0..<4) { index in
                            if index > 0 { Spacer(minLength: 0) }
                            Circle()
                                .fill(color.opacity(0.95))
                                .frame(width: 7 * unit, height: 7 * unit)
                        }
                    }
                }
                HStack {
                    ForEach(0..<4) { index in
                        if index > 0 { Spacer(minLength: 0) }
                        bar(width: 10 * unit, height: 3 * unit, opacity: 0.45)
                    }
                }
            }
        case .gallery:
            VStack(alignment: .leading, spacing: 5 * unit) {
                bar(width: 36 * unit, height: 6 * unit, opacity: 0.9)
                HStack(spacing: 4 * unit) {
                    ForEach([0.8, 0.5, 0.3], id: \.self) { opacity in
                        bar(width: nil, height: nil, opacity: opacity)
                    }
                }
            }
        case .lineChart:
            VStack(alignment: .leading, spacing: 4 * unit) {
                bar(width: 32 * unit, height: 5 * unit, opacity: 0.9)
                ZStack {
                    LaunchLineChart(closed: true)
                        .fill(color.opacity(0.18))
                    LaunchLineChart(closed: false)
                        .stroke(color.opacity(0.95), style: StrokeStyle(lineWidth: 2.5 * unit, lineCap: .round, lineJoin: .round))
                }
            }
        case .statistic:
            VStack(alignment: .leading, spacing: 3 * unit) {
                Text(verbatim: "87%")
                    .font(.system(size: 20 * unit, weight: .heavy, design: .rounded))
                    .foregroundStyle(color.opacity(0.95))
                bar(width: 46 * unit, height: 4 * unit, opacity: 0.45)
            }
        case .section:
            HStack(spacing: 8 * unit) {
                bar(width: 5 * unit, height: nil, opacity: 0.95)
                VStack(alignment: .leading, spacing: 5 * unit) {
                    bar(width: 14 * unit, height: 4 * unit, opacity: 0.5)
                    bar(width: 48 * unit, height: 8 * unit, opacity: 0.95)
                }
            }
        }
    }

    private func bar(width: CGFloat?, height: CGFloat?, opacity: Double) -> some View {
        RoundedRectangle(cornerRadius: 3, style: .continuous)
            .fill(color.opacity(opacity))
            .frame(width: width, height: height)
            .frame(maxHeight: height == nil ? .infinity : nil)
    }
}

/// A rising line across its frame, open for the stroke or closed down to
/// the baseline for the shading beneath it.
private struct LaunchLineChart: Shape {
    var closed: Bool

    private static let points: [CGPoint] = [
        CGPoint(x: 0, y: 0.75), CGPoint(x: 0.2, y: 0.5), CGPoint(x: 0.4, y: 0.6),
        CGPoint(x: 0.6, y: 0.3), CGPoint(x: 0.8, y: 0.38), CGPoint(x: 1, y: 0.08),
    ]

    func path(in rect: CGRect) -> Path {
        Path { path in
            path.addLines(Self.points.map { CGPoint(x: rect.minX + $0.x * rect.width, y: rect.minY + $0.y * rect.height) })
            if closed {
                path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
                path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
                path.closeSubpath()
            }
        }
    }
}

