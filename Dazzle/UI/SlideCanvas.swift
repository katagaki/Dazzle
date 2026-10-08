import GameController
import SwiftUI

/// The slide being edited, fitted to the space it has, with the selected
/// shapes' frames, and a lone selected shape's handles, drawn over it.
///
/// Tap a shape to select it, drag it to move it, drag a handle to resize
/// it, drag the handle above it to turn it, and double-tap one with text to
/// edit the text. Shift-tap, or tap while selecting several, to add a shape
/// to the selection; dragging any of them moves them all. Moves, resizes and
/// turns are previewed live and written to the document once, when the
/// finger lifts, so each is a single undo step. Pinch to zoom the slide in;
/// zoomed in, drag across empty slide to pan, and double-tap it to zoom out.
struct SlideCanvas: View {
    @Binding var presentation: Presentation
    @Bindable var state: EditorState
    /// Swiping across empty slide moves to the neighbouring slide.
    var onSwipe: (_ forward: Bool) -> Void = { _ in /* No neighbouring slides to move to. */ }
    /// Lift the slide to the top, clear of a panel covering the lower half.
    var isRaised = false

    /// A move, resize or turn in progress, in slide points and degrees.
    @State private var interaction: Interaction?

    private struct Interaction: Equatable {
        struct Placement: Equatable {
            var frame: CGRect
            var rotation: Double
        }

        var originals: [SlideShape.ID: Placement]
        var current: [SlideShape.ID: Placement]

        init(shapes: [SlideShape]) {
            originals = Dictionary(uniqueKeysWithValues: shapes.map {
                ($0.id, Placement(frame: $0.frame.points, rotation: $0.rotation))
            })
            current = originals
        }

        var isChange: Bool { current != originals }
    }

    /// A crop being adjusted: the visible part's frame, in points, and the
    /// fractions of the whole image cut from each edge.
    @State private var cropDraft: CropDraft?

    private struct CropDraft: Equatable {
        var shapeID: SlideShape.ID
        var frame: CGRect
        var picture: SlideShape.Picture
    }

    /// The lines a moved or resized shape has settled on.
    @State private var guides: [Snapping.Guide] = []

    /// How near a line a shape has to come to settle on it, in view points.
    private static let snapDistance: CGFloat = 6

    /// How far above a shape its rotation handle sits, in view points.
    private static let rotationHandleDistance: CGFloat = 28

    /// How far the slide can be pinched in, over its fitted size.
    private static let maximumZoom: CGFloat = 4

    /// How far the slide is zoomed in, and how far it is moved from where
    /// it sits fitted, in view points.
    private struct Viewport: Equatable {
        var zoom: CGFloat = 1
        var pan: CGSize = .zero

        var isZoomed: Bool { zoom > 1 }
    }

    /// Where the slide sits fitted to the space the canvas has.
    private struct Fitting {
        var slideSize: CGSize
        var available: CGSize
        /// The scale at which the whole slide fits.
        var scale: CGFloat
        /// The slide's centre when it is not moved.
        var center: CGPoint

        /// `pan` held so that a slide zoomed past the space never leaves it
        /// partly empty, and one that fits stays put.
        func clamped(_ pan: CGSize, zoom: CGFloat) -> CGSize {
            let reachX = max((slideSize.width * scale * zoom - available.width) / 2, 0)
            let reachY = max((slideSize.height * scale * zoom - available.height) / 2, 0)
            return CGSize(width: min(max(pan.width, -reachX), reachX), height: min(max(pan.height, -reachY), reachY))
        }
    }

    @State private var viewport = Viewport()
    /// The viewport a pinch in progress would leave, shown by stretching
    /// the slide rather than redrawing it; taken up when the fingers lift.
    @State private var pinch: Viewport?
    /// Where the slide was moved to when a drag across it began panning.
    @State private var panOrigin: CGSize?

    var body: some View {
        GeometryReader { proxy in
            let slideSize = presentation.slideSize.points
            let available = CGSize(width: max(proxy.size.width - 32, 1), height: max(proxy.size.height - 32, 1))
            let fitScale = min(available.width / slideSize.width, available.height / slideSize.height)
            let fitting = Fitting(
                slideSize: slideSize, available: available, scale: fitScale,
                center: CGPoint(x: proxy.size.width / 2, y: isRaised ? 16 + slideSize.height * fitScale / 2 : proxy.size.height / 2)
            )
            let scale = fitScale * viewport.zoom
            let size = CGSize(width: slideSize.width * scale, height: slideSize.height * scale)
            let shown = pinch ?? viewport
            ZStack {
                Color.clear
                    .contentShape(.rect)
                if let slide = state.selectedSlide(in: presentation) {
                    canvas(for: slide, scale: scale, size: size, fitting: fitting)
                        .frame(width: size.width, height: size.height)
                        .scaleEffect(shown.zoom / viewport.zoom)
                        .position(x: fitting.center.x + shown.pan.width, y: fitting.center.y + shown.pan.height)
                        .animation(.snappy(duration: 0.3), value: isRaised)
                }
            }
            .coordinateSpace(.named(Self.viewportSpace))
            .simultaneousGesture(magnifyGesture(fitting: fitting), including: state.isDrawing ? .subviews : .all)
        }
        // Zoomed in, the slide stays within the canvas rather than running
        // under the sidebar; fitted, its handles may reach past the edges.
        .clipShape(Rectangle().inset(by: (pinch ?? viewport).isZoomed ? 0 : -1000))
        .onChange(of: state.selectedSlideID) { viewport = Viewport() }
    }

    // MARK: - Zooming

    /// Pinching zooms the slide in or out about the point between the
    /// fingers, no further out than fitted.
    private func magnifyGesture(fitting: Fitting) -> some Gesture {
        MagnifyGesture(minimumScaleDelta: 0.01)
            .onChanged { value in
                let zoom = min(max(viewport.zoom * value.magnification, 1), Self.maximumZoom)
                let ratio = zoom / viewport.zoom
                // The slide point under the fingers stays under them.
                let anchor = value.startLocation
                let center = CGPoint(x: fitting.center.x + viewport.pan.width, y: fitting.center.y + viewport.pan.height)
                let pan = CGSize(
                    width: anchor.x - (anchor.x - center.x) * ratio - fitting.center.x,
                    height: anchor.y - (anchor.y - center.y) * ratio - fitting.center.y
                )
                pinch = Viewport(zoom: zoom, pan: fitting.clamped(pan, zoom: zoom))
            }
            .onEnded { _ in
                if let pinch { viewport = pinch }
                pinch = nil
            }
    }

    // MARK: - Canvas

    private func canvas(for slide: Slide, scale: CGFloat, size: CGSize, fitting: Fitting) -> some View {
        let displayed = preview(of: slide)
        return ZStack(alignment: .topLeading) {
            TimelineView(.animation(paused: state.animationPreviewStartedAt == nil)) { timeline in
                SlideView(presentation: presentation, slide: displayed, options: renderOptions(for: displayed, at: timeline.date))
            }
                .frame(width: size.width, height: size.height)
                .clipShape(.rect(cornerRadius: 3))
                .shadow(color: .black.opacity(0.18), radius: 10, y: 3)
                .contentShape(.rect)
                .gesture(moveGesture(on: slide, scale: scale, size: size, fitting: fitting))
                .simultaneousGesture(tapGestures(on: slide, scale: scale))
                .accessibilityIdentifier("slideCanvas")

            guideLines(scale: scale, size: size)

            if !state.isDrawing {
                commentPins(on: slide, scale: scale)
            }

            if state.presentedPanel == .animations, state.animationPreviewStartedAt == nil {
                animationBadges(on: displayed, scale: scale)
            }

            if !state.isDrawing {
                let selected = displayed.shapes.filter { state.isSelected($0.id) }
                if selected.count == 1, let shape = selected.first, shape.id == state.croppingShapeID,
                   case .picture(let picture) = shape.kind {
                    cropOverlay(for: shape, picture: picture, scale: scale)
                } else if selected.count == 1, let shape = selected.first {
                    selection(for: shape, scale: scale)
                } else {
                    ForEach(selected) { shape in
                        outline(for: shape, scale: scale)
                    }
                }
            }

            if !state.isDrawing, let id = state.editingTextShapeID,
               let shape = displayed.shapes.first(where: { $0.id == id }), shape.canHoldText {
                textEditor(for: shape, on: displayed, scale: scale)
            }

            if !state.isDrawing, let shape = state.selectedShape(in: presentation), case .table(let table) = shape.kind,
               let position = state.selectedCell, table.cell(at: position) != nil, interaction == nil {
                cellOverlay(table: table, shape: shape, position: position, on: displayed, scale: scale)
            }

            if state.isDrawing {
                DrawingOverlay(scale: scale) { media, frame in
                    state.insertPicture(media, frame: frame, name: String(localized: "Drawing.ShapeName"), in: &presentation)
                    state.isDrawing = false
                } cancel: {
                    state.isDrawing = false
                }
                .frame(width: size.width, height: size.height)
            }
        }
        .coordinateSpace(.named(Self.coordinateSpace))
    }

    private func renderOptions(for slide: Slide, at date: Date) -> SlideRenderer.Options {
        var options = SlideRenderer.Options.editing
        options.bulletsOnlyShapeID = state.editingTextShapeID
        if state.isEditingCell, let id = state.selectedShapeID, let position = state.selectedCell {
            options.editingCell = TableEditingCell(shapeID: id, position: position)
        }
        if let started = state.animationPreviewStartedAt {
            options.animation = slide.animationTimeline.playingThrough(
                at: date.timeIntervalSince(started), shapes: slide.shapes, slideSize: presentation.slideSize.points
            )
        }
        return options
    }

    // MARK: - Animations

    /// While the animations panel is up, a tag by each animated shape with
    /// the taps that set off its effects, as PowerPoint numbers them.
    private func animationBadges(on slide: Slide, scale: CGFloat) -> some View {
        let timeline = slide.animationTimeline
        let animations = slide.playableAnimations
        let frames = Dictionary(slide.shapes.map { ($0.shapeID, $0.frame.points) }) { first, _ in first }
        let shapeIDs = animations.map(\.shapeID).reduce(into: [Int]()) { if !$0.contains($1) { $0.append($1) } }
        return ForEach(shapeIDs, id: \.self) { shapeID in
            let labels = animations.filter { $0.shapeID == shapeID }
                .map { timeline.tapNumber(of: $0.id).map(String.init) ?? "0" }
                .reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }
            let frame = frames[shapeID] ?? .zero
            Text(labels.joined(separator: ", "))
                .font(.system(size: 10, weight: .bold).monospacedDigit())
                .foregroundStyle(.white)
                .padding(.horizontal, 5)
                .padding(.vertical, 2)
                .background(Color.accentColor, in: .rect(cornerRadius: 4))
                .offset(x: frame.minX * scale - 4, y: frame.minY * scale - 8)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
    }

    // MARK: - Comments

    /// A pin for each comment thread where it was left on the slide, which
    /// opens the comments; dragged, it moves.
    private func commentPins(on slide: Slide, scale: CGFloat) -> some View {
        ForEach(slide.comments.filter { $0.position != nil && !$0.isResolved }) { thread in
            let point = thread.position ?? .zero
            CommentBadge(initials: thread.initials, name: thread.author)
                .overlay(alignment: .topTrailing) {
                    if !thread.replies.isEmpty {
                        Text(String(thread.replies.count + 1))
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(.white)
                            .padding(3)
                            .background(.black.opacity(0.7), in: .circle)
                            .offset(x: 6, y: -6)
                    }
                }
                .shadow(radius: 2)
                .offset(x: point.x * scale, y: point.y * scale)
                .onTapGesture { state.presentedPanel = .comments }
                .gesture(DragGesture(minimumDistance: 8).onEnded { value in
                    let moved = CGPoint(
                        x: min(max(point.x + value.translation.width / scale, 0), presentation.slideSize.points.width),
                        y: min(max(point.y + value.translation.height / scale, 0), presentation.slideSize.points.height)
                    )
                    state.moveComment(thread.id, to: moved, in: &presentation)
                })
                .accessibilityLabel(String(format: String(localized: "Comments.Pin"), thread.author, thread.text))
                .accessibilityAddTraits(.isButton)
        }
    }

    // MARK: - Cropping

    /// The whole image, faded, round the part the crop keeps, with handles
    /// on the kept part's edges to cut more or less of it away.
    private func cropOverlay(for shape: SlideShape, picture: SlideShape.Picture, scale: CGFloat) -> some View {
        let frame = shape.frame.points
        let image = SlideShape.Picture.imageRect(frame: frame, picture: picture)
        let rect = CGRect(x: frame.minX * scale, y: frame.minY * scale, width: frame.width * scale, height: frame.height * scale)
        return ZStack(alignment: .topLeading) {
            if let path = picture.imagePath, let data = presentation.data(at: path),
               let cgImage = ImageCache.shared.image(for: data, path: path) {
                Image(decorative: cgImage, scale: 1)
                    .resizable()
                    .opacity(0.35)
                    .frame(width: image.width * scale, height: image.height * scale)
                    .offset(x: image.minX * scale, y: image.minY * scale)
                    .allowsHitTesting(false)
            }
            Rectangle()
                .strokeBorder(Color.accentColor, lineWidth: 2)
                .frame(width: max(rect.width, 1), height: max(rect.height, 1))
                .offset(x: rect.minX, y: rect.minY)
                .allowsHitTesting(false)
            ForEach(Handle.allCases) { handle in
                let point = position(of: handle, in: rect)
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(Color.accentColor)
                    .frame(width: handle.unit.x == 0 ? 18 : 5, height: handle.unit.y == 0 ? 18 : 5)
                    .frame(width: 12, height: 12)
                    .padding(10)
                    .contentShape(.rect)
                    .offset(x: point.x - 16, y: point.y - 16)
                    .gesture(cropGesture(handle, shape: shape, picture: picture, scale: scale))
                    .accessibilityHidden(true)
            }
        }
    }

    /// Moves the kept part's edges, never past the edges of the image.
    private func cropGesture(_ handle: Handle, shape: SlideShape, picture: SlideShape.Picture, scale: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                let original = shape.frame.points
                let image = SlideShape.Picture.imageRect(frame: original, picture: picture)
                let dx = value.translation.width / scale
                let dy = value.translation.height / scale
                var minX = original.minX
                var maxX = original.maxX
                var minY = original.minY
                var maxY = original.maxY
                if handle.unit.x < 0 { minX = min(max(minX + dx, image.minX), maxX - 4) }
                if handle.unit.x > 0 { maxX = max(min(maxX + dx, image.maxX), minX + 4) }
                if handle.unit.y < 0 { minY = min(max(minY + dy, image.minY), maxY - 4) }
                if handle.unit.y > 0 { maxY = max(min(maxY + dy, image.maxY), minY + 4) }
                var cropped = picture
                cropped.cropLeft = (minX - image.minX) / image.width
                cropped.cropRight = (image.maxX - maxX) / image.width
                cropped.cropTop = (minY - image.minY) / image.height
                cropped.cropBottom = (image.maxY - maxY) / image.height
                cropDraft = CropDraft(
                    shapeID: shape.id, frame: CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY), picture: cropped
                )
            }
            .onEnded { _ in
                if let cropDraft, cropDraft.picture != picture {
                    let crop = cropDraft.picture
                    state.setCrop(
                        frame: cropDraft.frame, left: crop.cropLeft, top: crop.cropTop, right: crop.cropRight,
                        bottom: crop.cropBottom, of: shape.id, in: &presentation
                    )
                }
                cropDraft = nil
            }
    }

    // MARK: - Tables

    private func tableLayout(_ table: SlideTable, shape: SlideShape, on slide: Slide) -> TableLayout {
        TableLayout(
            table: table, frame: shape.frame.points, style: SlideStyleContext(presentation: presentation, slide: slide),
            presentation: presentation, slideNumber: (presentation.index(of: slide.id) ?? 0) + 1
        )
    }

    /// The picked cell, outlined; while it is being typed into, its text editor.
    @ViewBuilder
    private func cellOverlay(
        table: SlideTable, shape: SlideShape, position: TableCellPosition, on slide: Slide, scale: CGFloat
    ) -> some View {
        let layout = tableLayout(table, shape: shape, on: slide)
        let rect = layout.rect(of: position)
        Rectangle()
            .strokeBorder(Color.accentColor, lineWidth: 2.5)
            .frame(width: max(rect.width * scale, 1), height: max(rect.height * scale, 1))
            .offset(x: rect.minX * scale, y: rect.minY * scale)
            .allowsHitTesting(false)
        if state.isEditingCell, let cell = table.cell(at: position) {
            let body = cell.text ?? TextBody(paragraphs: [Paragraph(runs: [])])
            let area = CGRect(
                x: rect.minX + EMU.points(cell.marginLeft ?? 91_440), y: rect.minY + EMU.points(cell.marginTop ?? 45_720),
                width: rect.width - EMU.points((cell.marginLeft ?? 91_440) + (cell.marginRight ?? 91_440)),
                height: rect.height - EMU.points((cell.marginTop ?? 45_720) + (cell.marginBottom ?? 45_720))
            )
            InPlaceTextEditor(
                body: body, shape: TableLayout.cellShape(body, rect), sources: [layout.styleSource(forRow: position.row)],
                style: layout.style, slideNumber: (presentation.index(of: slide.id) ?? 0) + 1, scale: scale, fontScale: 1,
                anchor: cell.anchor ?? .top, selection: state.textSelection,
                onChange: { state.setCellText($0, in: &presentation) },
                onSelectionChange: { state.textSelection = $0 },
                toolbar: textToolbar
            )
            .frame(width: max(area.width * scale, 1), height: max(area.height * scale, 1))
            .offset(x: area.minX * scale, y: area.minY * scale)
            .id(position)
            .accessibilityIdentifier("cellTextEditor")
        }
    }

    /// The buttons above the keyboard, for a shape's text or a cell's.
    private var textToolbar: InPlaceTextEditor.Toolbar {
        InPlaceTextEditor.Toolbar(
            bold: { state.toggleBold(in: &presentation) },
            italic: { state.toggleItalic(in: &presentation) },
            underline: { state.toggleUnderline(in: &presentation) },
            bullets: {
                let current = state.listStyle(in: presentation)
                state.setListStyle(current == .bullets ? .none : .bullets, in: &presentation)
            },
            numbers: {
                let current = state.listStyle(in: presentation)
                state.setListStyle(current == .numbers ? .none : .numbers, in: &presentation)
            },
            outdent: { state.changeIndent(by: -1, in: &presentation) },
            indent: { state.changeIndent(by: 1, in: &presentation) },
            format: { state.presentedPanel = .text },
            done: { state.endEditingText() }
        )
    }

    // MARK: - Typing

    /// The text being typed, laid over the shape exactly where its text is drawn.
    private func textEditor(for shape: SlideShape, on slide: Slide, scale: CGFloat) -> some View {
        let style = SlideStyleContext(presentation: presentation, slide: slide)
        let sources = style.sources(for: shape)
        let slideNumber = (presentation.index(of: slide.id) ?? 0) + 1
        let (area, properties) = TextRenderer(style: style, slideNumber: slideNumber).textArea(of: shape, sources: sources)
        let frame = shape.frame.points
        var fontScale = 1.0
        if case .normal(let scale, _) = properties.autofit { fontScale = scale }
        return InPlaceTextEditor(
            body: shape.text ?? TextBody(paragraphs: [Paragraph(runs: [])]),
            shape: shape, sources: sources, style: style, slideNumber: slideNumber, scale: scale, fontScale: fontScale,
            anchor: properties.anchor ?? .top, selection: state.textSelection,
            onChange: { state.setTextBody($0, in: &presentation) },
            onSelectionChange: { state.textSelection = $0 },
            toolbar: textToolbar
        )
        .frame(width: max(area.width * scale, 1), height: max(area.height * scale, 1))
        .offset(x: (area.minX - frame.minX) * scale, y: (area.minY - frame.minY) * scale)
        .frame(width: max(frame.width * scale, 1), height: max(frame.height * scale, 1), alignment: .topLeading)
        .rotationEffect(.degrees(shape.rotation))
        .offset(x: frame.minX * scale, y: frame.minY * scale)
        .accessibilityIdentifier("inPlaceTextEditor")
    }

    /// The slide with the move, resize or turn in progress applied.
    private func preview(of slide: Slide) -> Slide {
        var slide = slide
        if let cropDraft, let index = slide.shapes.firstIndex(where: { $0.id == cropDraft.shapeID }) {
            slide.shapes[index].frame = EMURect(points: cropDraft.frame)
            slide.shapes[index].kind = .picture(cropDraft.picture)
        }
        guard let interaction else { return slide }
        for index in slide.shapes.indices {
            guard let placement = interaction.current[slide.shapes[index].id] else { continue }
            slide.shapes[index].frame = EMURect(points: placement.frame)
            slide.shapes[index].rotation = placement.rotation
        }
        return slide
    }

    // MARK: - Hit testing

    /// The topmost shape under a point, in slide points.
    private func shape(at point: CGPoint, on slide: Slide, scale: CGFloat) -> SlideShape? {
        // A line has no area; give it some, a fingertip's worth.
        let slop = 10 / scale
        return slide.shapes.reversed().first { shape in
            let frame = shape.frame.points
            // A turned shape is tested in its own unturned space.
            let local = Self.rotate(point, around: CGPoint(x: frame.midX, y: frame.midY), by: -shape.rotation)
            return frame.insetBy(dx: frame.width < slop ? -slop : 0, dy: frame.height < slop ? -slop : 0).contains(local)
        }
    }

    private func tapGestures(on slide: Slide, scale: CGFloat) -> some Gesture {
        let doubleTap = SpatialTapGesture(count: 2).onEnded { value in
            let point = CGPoint(x: value.location.x / scale, y: value.location.y / scale)
            guard let shape = shape(at: point, on: slide, scale: scale) else {
                // Double-tapping empty slide fits a zoomed slide back.
                if viewport.isZoomed {
                    withAnimation(.snappy(duration: 0.3)) { viewport = Viewport() }
                }
                return
            }
            if case .table(let table) = shape.kind, shape.isEditable, slide.canEditShapes {
                state.selectedShapeID = shape.id
                state.selectCell(tableLayout(table, shape: shape, on: slide).cell(at: point), editing: true)
            } else if shape.canHoldText, shape.isEditable, slide.canEditShapes {
                state.beginEditingText(shape.id)
            } else {
                state.selectedShapeID = shape.id
            }
        }
        let singleTap = SpatialTapGesture().onEnded { value in
            let point = CGPoint(x: value.location.x / scale, y: value.location.y / scale)
            let hit = shape(at: point, on: slide, scale: scale)
            // A tap in the shape being typed into belongs to the text.
            if let editing = state.editingTextShapeID, hit?.id == editing { return }
            // A tap in a selected table picks a cell.
            if let hit, hit.id == state.selectedShapeID, !state.isSelectingMultiple, case .table(let table) = hit.kind {
                let cell = tableLayout(table, shape: hit, on: slide).cell(at: point)
                if cell != state.selectedCell { state.selectCell(cell, editing: state.isEditingCell) }
                return
            }
            if state.isSelectingMultiple || Self.isShiftHeld {
                if let hit { state.toggleSelection(hit.id) }
            } else {
                state.selectedShapeID = hit?.id
            }
        }
        return doubleTap.exclusively(before: singleTap)
    }

    /// Whether a hardware keyboard's Shift key is down. SwiftUI's taps do
    /// not report modifiers on iOS.
    private static var isShiftHeld: Bool {
        guard let keyboard = GCKeyboard.coalesced?.keyboardInput else { return false }
        return keyboard.button(forKeyCode: .leftShift)?.isPressed == true
            || keyboard.button(forKeyCode: .rightShift)?.isPressed == true
    }

    /// Dragging a shape moves it. Across empty slide, a drag pans the slide
    /// when it is zoomed in, and otherwise swipes to the neighbouring slide.
    private func moveGesture(on slide: Slide, scale: CGFloat, size: CGSize, fitting: Fitting) -> some Gesture {
        // Measured where the slide sits, not on it, so it holds still under
        // the finger as the slide pans.
        DragGesture(minimumDistance: 6, coordinateSpace: .named(Self.viewportSpace))
            .onChanged { value in
                guard pinch == nil else { return }
                if interaction == nil, panOrigin == nil {
                    let origin = CGPoint(
                        x: fitting.center.x + viewport.pan.width - size.width / 2,
                        y: fitting.center.y + viewport.pan.height - size.height / 2
                    )
                    let start = CGPoint(
                        x: (value.startLocation.x - origin.x) / scale, y: (value.startLocation.y - origin.y) / scale
                    )
                    if let shape = shape(at: start, on: slide, scale: scale), shape.isEditable, slide.canEditShapes {
                        // Dragging one of the selection moves the whole selection.
                        if !state.isSelected(shape.id) {
                            if state.isSelectingMultiple {
                                state.toggleSelection(shape.id)
                            } else {
                                state.selectedShapeID = shape.id
                            }
                        }
                        interaction = Interaction(shapes: slide.shapes.filter { state.isSelected($0.id) && $0.isEditable })
                    } else if viewport.isZoomed {
                        panOrigin = viewport.pan
                    }
                }
                if let panOrigin {
                    let pan = CGSize(width: panOrigin.width + value.translation.width, height: panOrigin.height + value.translation.height)
                    viewport.pan = fitting.clamped(pan, zoom: viewport.zoom)
                    return
                }
                guard var current = interaction else { return }
                var translation = CGSize(width: value.translation.width / scale, height: value.translation.height / scale)
                // The selection as a whole settles onto nearby lines.
                let bounds = slide.shapes.filter { current.originals[$0.id] != nil }.map(\.boundingBox)
                    .reduce(CGRect.null) { $0.union($1) }
                if !bounds.isNull {
                    let snapping = snapping(on: slide, excluding: Set(current.originals.keys), scale: scale)
                    let (offset, settled) = snapping.adjustment(for: bounds.offsetBy(dx: translation.width, dy: translation.height))
                    translation.width += offset.width
                    translation.height += offset.height
                    if settled != guides { guides = settled }
                }
                for (id, original) in current.originals {
                    current.current[id]?.frame = original.frame.offsetBy(dx: translation.width, dy: translation.height)
                }
                interaction = current
            }
            .onEnded { value in
                guides = []
                if panOrigin != nil {
                    panOrigin = nil
                } else if let interaction {
                    commit(interaction)
                    self.interaction = nil
                } else if !viewport.isZoomed, pinch == nil, abs(value.translation.width) > 60, abs(value.translation.width) > abs(value.translation.height) * 1.5 {
                    onSwipe(value.translation.width < 0)
                }
            }
    }

    // MARK: - Selection

    private enum Handle: CaseIterable, Identifiable {
        case topLeft, top, topRight, right, bottomRight, bottom, bottomLeft, left

        var id: Self { self }

        /// Which edges the handle moves: -1 the leading or top, 1 the trailing or bottom.
        var unit: (x: CGFloat, y: CGFloat) {
            switch self {
            case .topLeft: (-1, -1)
            case .top: (0, -1)
            case .topRight: (1, -1)
            case .right: (1, 0)
            case .bottomRight: (1, 1)
            case .bottom: (0, 1)
            case .bottomLeft: (-1, 1)
            case .left: (-1, 0)
            }
        }

        var isCorner: Bool { unit.x != 0 && unit.y != 0 }
    }

    @ViewBuilder
    private func selection(for shape: SlideShape, scale: CGFloat) -> some View {
        let frame = shape.frame.points
        let rect = CGRect(x: frame.minX * scale, y: frame.minY * scale, width: frame.width * scale, height: frame.height * scale)
        ZStack(alignment: .topLeading) {
            Rectangle()
                .strokeBorder(Color.accentColor, lineWidth: 1.5)
                .frame(width: max(rect.width, 1), height: max(rect.height, 1))
                .offset(x: rect.minX, y: rect.minY)
                .allowsHitTesting(false)

            if shape.isEditable {
                if shape.canRotate {
                    rotationHandle(for: shape, in: rect, scale: scale)
                }
                ForEach(handles(for: rect)) { handle in
                    let point = position(of: handle, in: rect)
                    Circle()
                        .fill(.white)
                        .overlay(Circle().strokeBorder(Color.accentColor, lineWidth: 1.5))
                        .frame(width: 12, height: 12)
                        .padding(10)
                        .contentShape(.circle)
                        .offset(x: point.x - 16, y: point.y - 16)
                        .gesture(resizeGesture(handle, shape: shape, scale: scale))
                        .accessibilityHidden(true)
                }
            } else {
                // Kept but not editable: say so where the user is looking.
                Image(systemName: "lock.fill")
                    .font(.system(size: 11, weight: .semibold))
                    .padding(5)
                    .background(.regularMaterial, in: .circle)
                    .offset(x: rect.maxX - 12, y: rect.minY - 12)
                    .allowsHitTesting(false)
            }
        }
        .rotationEffect(.degrees(shape.rotation), anchor: UnitPoint(
            x: rect.midX / max(presentation.slideSize.points.width * scale, 1),
            y: rect.midY / max(presentation.slideSize.points.height * scale, 1)
        ))
    }

    /// One of several selected shapes: its frame alone, without handles.
    private func outline(for shape: SlideShape, scale: CGFloat) -> some View {
        let frame = shape.frame.points
        let rect = CGRect(x: frame.minX * scale, y: frame.minY * scale, width: frame.width * scale, height: frame.height * scale)
        return Rectangle()
            .strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 1.5, dash: [5, 3]))
            .frame(width: max(rect.width, 1), height: max(rect.height, 1))
            .rotationEffect(.degrees(shape.rotation))
            .offset(x: rect.minX, y: rect.minY)
            .allowsHitTesting(false)
    }

    /// Lines have no height or no width; their edge handles would sit on
    /// top of their corner handles.
    private func handles(for rect: CGRect) -> [Handle] {
        if rect.height < 4 { return [.left, .right] }
        if rect.width < 4 { return [.top, .bottom] }
        return Handle.allCases
    }

    private func position(of handle: Handle, in rect: CGRect) -> CGPoint {
        CGPoint(x: rect.midX + handle.unit.x * rect.width / 2, y: rect.midY + handle.unit.y * rect.height / 2)
    }

    private func resizeGesture(_ handle: Handle, shape: SlideShape, scale: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                let original = interaction?.originals[shape.id]?.frame ?? shape.frame.points
                // The drag, turned into the shape's own unturned space.
                let drag = Self.rotate(
                    CGPoint(x: value.translation.width / scale, y: value.translation.height / scale),
                    around: .zero, by: -shape.rotation
                )
                let keepsAspect = handle.isCorner && shape.isPicture
                var local = Self.resized(original, by: handle, dx: drag.x, dy: drag.y, keepsAspect: keepsAspect)
                // A square-on shape's moving edges settle onto nearby lines.
                if shape.rotation == 0, !keepsAspect {
                    let snapping = snapping(on: state.selectedSlide(in: presentation), excluding: [shape.id], scale: scale)
                    let (offset, settled) = snapping.adjustment(
                        for: local, x: Self.lines(handle.unit.x), y: Self.lines(handle.unit.y)
                    )
                    local = Self.resized(
                        original, by: handle, dx: drag.x + offset.width, dy: drag.y + offset.height, keepsAspect: false
                    )
                    if settled != guides { guides = settled }
                }
                // The side opposite the handle stays put on the slide: the
                // centre moves by the size change, turned back onto the slide.
                let shift = Self.rotate(
                    CGPoint(x: local.midX - original.midX, y: local.midY - original.midY), around: .zero, by: shape.rotation
                )
                let frame = CGRect(
                    x: original.midX + shift.x - local.width / 2, y: original.midY + shift.y - local.height / 2,
                    width: local.width, height: local.height
                )
                var current = interaction ?? Interaction(shapes: [shape])
                current.current[shape.id]?.frame = frame
                interaction = current
            }
            .onEnded { _ in
                guides = []
                if let interaction { commit(interaction) }
                interaction = nil
            }
    }

    /// The edge a handle moves along one axis, for snapping.
    private static func lines(_ unit: CGFloat) -> Snapping.Lines {
        unit < 0 ? .minimum : (unit > 0 ? .maximum : [])
    }

    // MARK: - Snapping

    private func snapping(on slide: Slide?, excluding ids: Set<SlideShape.ID>, scale: CGFloat) -> Snapping {
        Snapping(
            slide: presentation.slideSize.points,
            others: slide?.shapes.filter { !ids.contains($0.id) }.map(\.boundingBox) ?? [],
            threshold: Self.snapDistance / scale
        )
    }

    /// The guides the shape being moved has settled on, across the slide.
    private func guideLines(scale: CGFloat, size: CGSize) -> some View {
        Path { path in
            for guide in guides {
                let position = guide.position * scale
                switch guide.axis {
                case .vertical:
                    path.move(to: CGPoint(x: position, y: 0))
                    path.addLine(to: CGPoint(x: position, y: size.height))
                case .horizontal:
                    path.move(to: CGPoint(x: 0, y: position))
                    path.addLine(to: CGPoint(x: size.width, y: position))
                }
            }
        }
        .stroke(Color.pink, style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
        .frame(width: size.width, height: size.height)
        .allowsHitTesting(false)
    }

    /// `rect` with the edges `handle` moves moved, kept at least a little
    /// size, and for a picture pulled by a corner, kept in proportion.
    private static func resized(_ original: CGRect, by handle: Handle, dx: CGFloat, dy: CGFloat, keepsAspect: Bool) -> CGRect {
        var minX = original.minX
        var maxX = original.maxX
        var minY = original.minY
        var maxY = original.maxY
        if handle.unit.x < 0 { minX += dx }
        if handle.unit.x > 0 { maxX += dx }
        if handle.unit.y < 0 { minY += dy }
        if handle.unit.y > 0 { maxY += dy }
        let minimum: CGFloat = 4
        // A line keeps its zero thickness; anything else keeps some size.
        if original.width >= minimum { maxX = max(maxX, minX + minimum) }
        if original.height >= minimum { maxY = max(maxY, minY + minimum) }
        var frame = CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)

        if keepsAspect, original.width > 0, original.height > 0 {
            let ratio = max(frame.width / original.width, frame.height / original.height)
            let width = original.width * ratio
            let height = original.height * ratio
            frame = CGRect(
                x: handle.unit.x < 0 ? original.maxX - width : original.minX,
                y: handle.unit.y < 0 ? original.maxY - height : original.minY,
                width: width, height: height
            )
        }
        return frame
    }

    // MARK: - Rotation

    /// A handle on a stalk above the shape, dragged round its centre to turn it.
    private func rotationHandle(for shape: SlideShape, in rect: CGRect, scale: CGFloat) -> some View {
        let top = CGPoint(x: rect.midX, y: rect.minY - Self.rotationHandleDistance)
        return ZStack(alignment: .topLeading) {
            Path { path in
                path.move(to: CGPoint(x: rect.midX, y: rect.minY))
                path.addLine(to: top)
            }
            .stroke(Color.accentColor, lineWidth: 1.5)
            .allowsHitTesting(false)

            Image(systemName: "arrow.clockwise")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(Color.accentColor)
                .frame(width: 18, height: 18)
                .background(.white, in: .circle)
                .overlay(Circle().strokeBorder(Color.accentColor, lineWidth: 1.5))
                .padding(9)
                .contentShape(.circle)
                .offset(x: top.x - 18, y: top.y - 18)
                .gesture(rotationGesture(shape: shape, center: CGPoint(x: rect.midX, y: rect.midY)))
                .accessibilityIdentifier("rotationHandle")
                .accessibilityLabel("Canvas.Rotate")
        }
    }

    /// Turns the shape to face the finger. Within a few degrees of a
    /// multiple of 15 it settles on the multiple, so square is easy to find.
    private func rotationGesture(shape: SlideShape, center: CGPoint) -> some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .named(Self.coordinateSpace))
            .onChanged { value in
                // The handle starts straight up from the centre, at 0°; the
                // selection is drawn turned, so its location is in canvas space.
                let angle = atan2(value.location.x - center.x, center.y - value.location.y) * 180 / .pi
                var degrees = (angle + 360).truncatingRemainder(dividingBy: 360)
                let nearest = (degrees / 15).rounded() * 15
                if abs(degrees - nearest) < 4 { degrees = nearest.truncatingRemainder(dividingBy: 360) }
                var current = interaction ?? Interaction(shapes: [shape])
                current.current[shape.id]?.rotation = degrees
                interaction = current
            }
            .onEnded { _ in
                if let interaction { commit(interaction) }
                interaction = nil
            }
    }

    // MARK: - Committing

    private func commit(_ interaction: Interaction) {
        guard interaction.isChange else { return }
        if interaction.current.count == 1, let (id, placement) = interaction.current.first {
            state.setTransform(frame: placement.frame, rotation: placement.rotation, of: id, in: &presentation)
        } else {
            state.setFrames(interaction.current.mapValues(\.frame), in: &presentation)
        }
    }

    private static let coordinateSpace = "slideCanvas"
    /// The space the slide is fitted, zoomed and moved in, which stays put
    /// while the slide pans.
    private static let viewportSpace = "slideCanvasViewport"

    /// `point` turned `degrees` clockwise round `center`, in a y-down space.
    static func rotate(_ point: CGPoint, around center: CGPoint, by degrees: Double) -> CGPoint {
        guard degrees != 0 else { return point }
        let radians = degrees * .pi / 180
        let dx = point.x - center.x
        let dy = point.y - center.y
        return CGPoint(x: center.x + dx * cos(radians) - dy * sin(radians), y: center.y + dx * sin(radians) + dy * cos(radians))
    }
}
