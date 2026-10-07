import SwiftUI

/// The slides in order: a sidebar of thumbnails where there is room, a
/// strip along the bottom where there is not. Tap to go to a slide, drag
/// to reorder, press and hold for what else can be done to it.
struct SlideNavigator: View {
    @Binding var presentation: Presentation
    @Bindable var state: EditorState
    var axis: Axis
    var play: (Int) -> Void

    @State private var dropTargetID: Slide.ID?

    /// How far in from the strip's ends thumbnails blur: no further than its
    /// buttons reach, so as many thumbnails as fit stay sharp.
    private static let edgeFade: CGFloat = 40
    private static let edgeBlurRadius: CGFloat = 8
    /// Where the first and last thumbnails rest: clear of the strip's buttons.
    private static let edgeInset: CGFloat = 60

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(axis == .vertical ? .vertical : .horizontal) {
                stack
                    .padding(axis == .vertical ? EdgeInsets(top: 4, leading: 12, bottom: 96, trailing: 12)
                             : EdgeInsets(top: 8, leading: Self.edgeInset, bottom: 8, trailing: Self.edgeInset))
                    .animation(.snappy(duration: 0.22), value: presentation.slides.map(\.id))
            }
            .scrollIndicators(.hidden)
            // Blurred thumbnails show through beneath the strip's buttons
            // rather than being cut off at its bounds.
            .scrollClipDisabled(axis == .horizontal)
            .onChange(of: state.selectedSlideID) { _, id in
                guard let id else { return }
                withAnimation(.snappy(duration: 0.25)) { proxy.scrollTo(id, anchor: .center) }
            }
        }
    }

    /// Blur that deepens point by point toward either end of the strip, so a
    /// thumbnail only softens where it has slid under a button.
    nonisolated private static func edgeBlur(for proxy: GeometryProxy) -> Shader {
        // The visible strip, in the thumbnail's own coordinates.
        let visible = proxy.bounds(of: .scrollView) ?? CGRect(origin: .zero, size: proxy.size)
        return ShaderLibrary.edgeBlur(
            .float(visible.minX), .float(visible.maxX), .float(edgeFade), .float(edgeBlurRadius)
        )
    }

    @ViewBuilder
    private var stack: some View {
        let items = ForEach(Array(presentation.slides.enumerated()), id: \.element.id) { index, slide in
            item(for: slide, at: index)
                .id(slide.id)
        }
        if axis == .vertical {
            LazyVStack(spacing: 14) { items }
        } else {
            LazyHStack(spacing: 8) { items }
        }
    }

    private func item(for slide: Slide, at index: Int) -> some View {
        let isSelected = slide.id == state.selectedSlideID
        let thumbnail = SlideThumbnail(presentation: presentation, slide: slide, number: index + 1, isSelected: isSelected)
        return Group {
            if axis == .vertical {
                HStack(alignment: .top, spacing: 6) {
                    Text(String(index + 1))
                        .font(.caption.monospacedDigit().weight(isSelected ? .semibold : .regular))
                        .foregroundStyle(isSelected ? Color.accentColor : .secondary)
                        .frame(width: 22, alignment: .trailing)
                    thumbnail
                }
            } else {
                thumbnail.frame(height: 52)
                    .visualEffect { content, proxy in
                        content.layerEffect(Self.edgeBlur(for: proxy), maxSampleOffset: CGSize(width: Self.edgeBlurRadius, height: Self.edgeBlurRadius))
                    }
            }
        }
        .overlay {
            // The slide a dragged slide will take the place of.
            if dropTargetID == slide.id {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 2, dash: [5, 3]))
                    .padding(-4)
            }
        }
        .contentShape(.rect)
        .onTapGesture { state.selectSlide(slide.id) }
        .contextMenu { menu(for: slide, at: index) }
        .draggable(slide.id.uuidString) {
            SlideThumbnail(presentation: presentation, slide: slide, number: index + 1, isSelected: true)
                .frame(width: 160)
        }
        .dropDestination(for: String.self) { items, _ in
            dropTargetID = nil
            guard let raw = items.first, let id = UUID(uuidString: raw), id != slide.id,
                  let target = presentation.index(of: slide.id) else { return false }
            withAnimation(.snappy(duration: 0.22)) {
                state.moveSlide(id, to: target, in: &presentation)
            }
            return true
        } isTargeted: { isTargeted in
            if isTargeted {
                dropTargetID = slide.id
            } else if dropTargetID == slide.id {
                dropTargetID = nil
            }
        }
        .accessibilityIdentifier("slideThumbnail.\(index + 1)")
    }

    @ViewBuilder
    private func menu(for slide: Slide, at index: Int) -> some View {
        Button("Slide.Menu.Play", systemImage: "play") { play(index) }
        Button("Slide.Menu.Duplicate", systemImage: "plus.square.on.square") {
            state.duplicateSlide(slide.id, in: &presentation)
        }
        Section {
            Button("Edit.Copy", systemImage: "doc.on.doc") {
                state.copySlides([slide.id], in: presentation)
            }
            Button("Edit.Cut", systemImage: "scissors") {
                state.cutSlide(slide.id, in: &presentation)
            }
            .disabled(presentation.slides.count < 2)
            Button("Edit.PasteAfter", systemImage: "doc.on.clipboard") {
                state.selectSlide(slide.id)
                state.paste(in: &presentation)
            }
        }
        Button(slide.isHidden ? "Slide.Menu.Show" : "Slide.Menu.Hide", systemImage: slide.isHidden ? "eye" : "eye.slash") {
            state.toggleHidden(slide.id, in: &presentation)
        }
        Section {
            Button("Slide.Menu.MoveUp", systemImage: axis == .vertical ? "arrow.up" : "arrow.left") {
                state.moveSlide(slide.id, to: index - 1, in: &presentation)
            }
            .disabled(index == 0)
            Button("Slide.Menu.MoveDown", systemImage: axis == .vertical ? "arrow.down" : "arrow.right") {
                state.moveSlide(slide.id, to: index + 1, in: &presentation)
            }
            .disabled(index == presentation.slides.count - 1)
        }
        Section {
            Button("Slide.Menu.Delete", systemImage: "trash", role: .destructive) {
                state.deleteSlide(slide.id, in: &presentation)
            }
            .disabled(presentation.slides.count < 2)
        }
    }
}

/// New Slide: picks one of the presentation's layouts.
struct NewSlideMenu<Label: View>: View {
    @Binding var presentation: Presentation
    @Bindable var state: EditorState
    @ViewBuilder var label: () -> Label

    var body: some View {
        Menu {
            ForEach(presentation.resources.orderedLayouts, id: \.path) { layout in
                Button(layout.name) { state.addSlide(using: layout, in: &presentation) }
            }
        } label: {
            label()
        }
        .accessibilityIdentifier("newSlide")
        .accessibilityLabel("Slide.New")
    }
}

/// The iPhone's strip of slides along the bottom, Tables' sheet tabs'
/// counterpart: the thumbnails, flowing beneath a glass add button at one
/// end and the trailing controls at the other.
struct SlideStrip<Trailing: View>: View {
    @Binding var presentation: Presentation
    @Bindable var state: EditorState
    var play: (Int) -> Void
    @ViewBuilder var trailing: () -> Trailing

    var body: some View {
        SlideNavigator(presentation: $presentation, state: state, axis: .horizontal, play: play)
            .overlay(alignment: .leading) {
                NewSlideMenu(presentation: $presentation, state: state) {
                    Image(systemName: "plus")
                        .font(.system(size: 15, weight: .semibold))
                        .frame(width: 40, height: 40)
                }
                .buttonStyle(.plain)
                .glassEffect(.regular.interactive(), in: .circle)
                .padding(.leading, 12)
            }
            .overlay(alignment: .trailing) {
                trailing()
                    .padding(.trailing, 12)
            }
            .frame(height: 68)
    }
}
