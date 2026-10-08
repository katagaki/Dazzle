import SwiftUI

/// The slide's animations in the order a slideshow plays them, and what
/// adds more to the selected shapes.
struct AnimationPanel: View {
    @Binding var presentation: Presentation
    @Bindable var state: EditorState

    private var slide: Slide? { state.selectedSlide(in: presentation) }
    private var canEdit: Bool { slide?.canEditShapes ?? false }
    private var hasSelection: Bool { state.selectedShapes(in: presentation).contains(where: \.isEditable) }

    var body: some View {
        List {
            Section {
                addMenu
                    .disabled(!hasSelection || !canEdit)
                PreviewButton(presentation: presentation, state: state)
            } footer: {
                if !hasSelection, canEdit { Text("Animation.SelectHint") }
            }

            if let slide, !slide.animations.isEmpty {
                let timeline = slide.animationTimeline
                Section {
                    ForEach(slide.animations) { animation in
                        NavigationLink(value: animation.id) {
                            AnimationRow(animation: animation, shape: shape(animation.shapeID), tapNumber: timeline.tapNumber(of: animation.id))
                        }
                        .listRowBackground(isSelected(animation) ? Color.accentColor.opacity(0.12) : nil)
                        .contextMenu { rowMenu(for: animation, in: slide) }
                    }
                    .onMove { state.moveAnimations(from: $0, to: $1, in: &presentation) }
                    .onDelete { offsets in
                        state.deleteAnimations(Set(offsets.map { slide.animations[$0].id }), in: &presentation)
                    }
                    .moveDisabled(!canEdit)
                    .deleteDisabled(!canEdit)
                } header: {
                    Text("Animation.Section.Order")
                } footer: {
                    Text("Animation.Footer")
                }
            }
        }
        .navigationDestination(for: ShapeAnimation.ID.self) { id in
            AnimationDetail(presentation: $presentation, state: state, id: id)
        }
        .onDisappear { state.stopPreviewingAnimations() }
        .accessibilityIdentifier("animationsPanel")
    }

    private var addMenu: some View {
        Menu {
            ForEach([ShapeAnimation.Category.entrance, .emphasis, .exit], id: \.self) { category in
                Section(category.label) {
                    ForEach(ShapeAnimation.Effect.choices(for: category), id: \.self) { effect in
                        Button(effect.label(in: category), systemImage: effect.symbol) {
                            state.addAnimation(effect, category: category, in: &presentation)
                        }
                    }
                }
            }
        } label: {
            Label("Animation.Add", systemImage: "plus")
        }
        .accessibilityIdentifier("addAnimation")
    }

    @ViewBuilder
    private func rowMenu(for animation: ShapeAnimation, in slide: Slide) -> some View {
        if canEdit, let index = slide.animations.firstIndex(where: { $0.id == animation.id }) {
            Button("Animation.MoveEarlier", systemImage: "arrow.up") {
                state.moveAnimations(from: [index], to: index - 1, in: &presentation)
            }
            .disabled(index == 0)
            Button("Animation.MoveLater", systemImage: "arrow.down") {
                state.moveAnimations(from: [index], to: index + 2, in: &presentation)
            }
            .disabled(index == slide.animations.count - 1)
            Button("Animation.Delete", systemImage: "trash", role: .destructive) {
                state.deleteAnimations([animation.id], in: &presentation)
            }
        }
    }

    private func shape(_ shapeID: Int) -> SlideShape? {
        slide?.shapes.first { $0.shapeID == shapeID }
    }

    private func isSelected(_ animation: ShapeAnimation) -> Bool {
        shape(animation.shapeID).map { state.isSelected($0.id) } ?? false
    }
}

/// One animation in the list: when it starts, what it does, and to what.
private struct AnimationRow: View {
    var animation: ShapeAnimation
    var shape: SlideShape?
    var tapNumber: Int?

    var body: some View {
        HStack(spacing: 12) {
            Group {
                if animation.trigger == .onClick, let tapNumber {
                    Text(String(tapNumber))
                        .font(.caption.weight(.bold).monospacedDigit())
                } else {
                    Image(systemName: animation.trigger == .afterPrevious ? "clock" : "link")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
            }
            .frame(width: 22)
            Image(systemName: animation.category.symbol)
                .foregroundStyle(animation.category.tint)
            VStack(alignment: .leading, spacing: 2) {
                Text(animation.effect.label(in: animation.category))
                Text(animation.targetLabel(shape: shape))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

/// One animation's effect and timing.
private struct AnimationDetail: View {
    @Binding var presentation: Presentation
    @Bindable var state: EditorState
    var id: ShapeAnimation.ID
    @Environment(\.dismiss) private var dismiss

    private var slide: Slide? { state.selectedSlide(in: presentation) }
    private var animation: ShapeAnimation? { slide?.animations.first { $0.id == id } }

    var body: some View {
        if let animation {
            form(for: animation)
                .navigationTitle(animation.effect.label(in: animation.category))
                .onAppear {
                    // The shape it animates is picked out on the slide.
                    if let shape = slide?.shapes.first(where: { $0.shapeID == animation.shapeID }) {
                        state.selectedShapeID = shape.id
                    }
                }
        } else {
            ContentUnavailableView("Animation.Gone", systemImage: "sparkles")
        }
    }

    private func form(for animation: ShapeAnimation) -> some View {
        let choices = ShapeAnimation.Effect.choices(for: animation.category)
        let isChoosable = animation.effect.isMadeByDazzle && choices.contains { $0.isKind(of: animation.effect) }
        return Form {
            Section {
                if isChoosable {
                    Picker("Animation.Effect", selection: Binding(
                        get: { choices.first { $0.isKind(of: animation.effect) } ?? animation.effect },
                        set: { state.setEffect($0.with(animation.effect.direction ?? .bottom), of: id, in: &presentation) }
                    )) {
                        ForEach(choices, id: \.self) { effect in
                            Label(effect.label(in: animation.category), systemImage: effect.symbol).tag(effect)
                        }
                    }
                    .accessibilityIdentifier("animationEffect")
                } else {
                    LabeledContent("Animation.Effect", value: animation.effect.label(in: animation.category))
                }
                if let direction = animation.effect.direction, isChoosable {
                    Picker("Animation.Direction", selection: Binding(
                        get: { direction },
                        set: { state.setEffect(animation.effect.with($0), of: id, in: &presentation) }
                    )) {
                        ForEach(ShapeAnimation.Direction.allCases, id: \.self) { direction in
                            Text(direction.label).tag(direction)
                        }
                    }
                }
            } footer: {
                if !animation.effect.isMadeByDazzle { Text("Animation.Custom.Footer") }
            }

            Section {
                Picker("Animation.Start", selection: Binding(
                    get: { animation.trigger },
                    set: { trigger in state.updateAnimation(id, in: &presentation) { $0.trigger = trigger } }
                )) {
                    ForEach(ShapeAnimation.Trigger.allCases, id: \.self) { trigger in
                        Text(trigger.label).tag(trigger)
                    }
                }
                .accessibilityIdentifier("animationStart")
                if animation.effect != .appear {
                    LabeledContent("Animation.Duration") {
                        secondsStepper(animation.duration, range: 0.1...60) { seconds in
                            state.updateAnimation(id, in: &presentation) { $0.duration = seconds }
                        }
                    }
                    .disabled(!animation.effect.isMadeByDazzle)
                }
                LabeledContent("Animation.Delay") {
                    secondsStepper(animation.delay, range: 0...60) { seconds in
                        state.updateAnimation(id, in: &presentation) { $0.delay = seconds }
                    }
                }
            }

            Section {
                PreviewButton(presentation: presentation, state: state)
                Button("Animation.Delete", systemImage: "trash", role: .destructive) {
                    state.deleteAnimations([id], in: &presentation)
                    dismiss()
                }
            }
        }
        .disabled(!(slide?.canEditShapes ?? false))
    }

    private func secondsStepper(_ value: Double, range: ClosedRange<Double>, set: @escaping (Double) -> Void) -> some View {
        Stepper(
            value: Binding(get: { value }, set: { set(min(max(($0 * 100).rounded() / 100, range.lowerBound), range.upperBound)) }),
            in: range, step: value < 2 ? 0.25 : 0.5
        ) {
            Text(value.formatted(.number.precision(.fractionLength(0...2))) + " " + String(localized: "Advance.Seconds"))
                .monospacedDigit()
        }
        .fixedSize()
    }
}

/// Plays the slide's animations through on the canvas, or stops them.
private struct PreviewButton: View {
    var presentation: Presentation
    @Bindable var state: EditorState

    var body: some View {
        let isPlaying = state.animationPreviewStartedAt != nil
        Button(isPlaying ? "Animation.Stop" : "Animation.Preview", systemImage: isPlaying ? "stop.fill" : "play.fill") {
            if isPlaying {
                state.stopPreviewingAnimations()
            } else {
                state.previewAnimations(in: presentation)
            }
        }
        .disabled(state.selectedSlide(in: presentation)?.animations.isEmpty ?? true)
        .accessibilityIdentifier("previewAnimations")
    }
}

// MARK: - Labels

extension ShapeAnimation.Category {
    var label: String {
        switch self {
        case .entrance: String(localized: "Animation.Category.Entrance")
        case .emphasis: String(localized: "Animation.Category.Emphasis")
        case .exit: String(localized: "Animation.Category.Exit")
        case .motionPath: String(localized: "Animation.Category.MotionPath")
        case .other: String(localized: "Animation.Category.Other")
        }
    }

    /// PowerPoint's stars: green coming in, yellow for attention, red going out.
    var symbol: String {
        switch self {
        case .entrance, .emphasis, .exit: "star.fill"
        case .motionPath: "point.topleft.down.to.point.bottomright.curvepath"
        case .other: "play.circle"
        }
    }

    var tint: Color {
        switch self {
        case .entrance: .green
        case .emphasis: .yellow
        case .exit: .red
        case .motionPath: .blue
        case .other: .secondary
        }
    }
}

extension ShapeAnimation.Effect {
    func label(in category: ShapeAnimation.Category) -> String {
        let exits = category == .exit
        return switch self {
        case .appear: exits ? String(localized: "Animation.Effect.Disappear") : String(localized: "Animation.Effect.Appear")
        case .fade: String(localized: "Animation.Effect.Fade")
        case .fly: exits ? String(localized: "Animation.Effect.FlyOut") : String(localized: "Animation.Effect.FlyIn")
        case .wipe: String(localized: "Animation.Effect.Wipe")
        case .zoom: String(localized: "Animation.Effect.Zoom")
        case .float: exits ? String(localized: "Animation.Effect.FloatOut") : String(localized: "Animation.Effect.FloatIn")
        case .pulse: String(localized: "Animation.Effect.Pulse")
        case .spin: String(localized: "Animation.Effect.Spin")
        case .growShrink: String(localized: "Animation.Effect.GrowShrink")
        case .teeter: String(localized: "Animation.Effect.Teeter")
        case .path: String(localized: "Animation.Effect.Path")
        case .preset:
            category == .other("mediacall") ? String(localized: "Animation.Effect.Media") : String(localized: "Animation.Effect.Custom")
        }
    }

    var symbol: String {
        switch self {
        case .appear: "eye"
        case .fade: "circle.lefthalf.filled"
        case .fly: "arrow.up.forward"
        case .wipe: "rectangle.righthalf.inset.filled"
        case .zoom: "plus.magnifyingglass"
        case .float: "arrow.up.and.down"
        case .pulse: "dot.radiowaves.left.and.right"
        case .spin: "arrow.clockwise"
        case .growShrink: "arrow.up.left.and.arrow.down.right"
        case .teeter: "metronome"
        case .path: "point.topleft.down.to.point.bottomright.curvepath"
        case .preset: "sparkles"
        }
    }
}

extension ShapeAnimation.Direction {
    var label: String {
        switch self {
        case .top: String(localized: "Animation.Direction.Top")
        case .right: String(localized: "Animation.Direction.Right")
        case .bottom: String(localized: "Animation.Direction.Bottom")
        case .left: String(localized: "Animation.Direction.Left")
        }
    }
}

extension ShapeAnimation.Trigger {
    var label: String {
        switch self {
        case .onClick: String(localized: "Animation.Trigger.OnTap")
        case .withPrevious: String(localized: "Animation.Trigger.WithPrevious")
        case .afterPrevious: String(localized: "Animation.Trigger.AfterPrevious")
        }
    }
}

extension ShapeAnimation {
    /// The shape it animates, and for text built a paragraph at a time, which.
    func targetLabel(shape: SlideShape?) -> String {
        let name = shape?.name.nilIfEmpty ?? String(localized: "Animation.UnnamedShape")
        guard let paragraphs else { return name }
        let which = paragraphs.count == 1
            ? String(format: String(localized: "Animation.Paragraph"), paragraphs.lowerBound + 1)
            : String(format: String(localized: "Animation.Paragraphs"), paragraphs.lowerBound + 1, paragraphs.upperBound + 1)
        return name + " · " + which
    }
}
