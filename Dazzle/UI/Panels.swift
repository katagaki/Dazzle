import SwiftUI

/// The selected shape's text, and how it looks.
struct TextPanel: View {
    @Binding var presentation: Presentation
    @Bindable var state: EditorState
    @FocusState private var isEditing: Bool

    private var style: RunProperties { state.effectiveRunProperties(in: presentation) }
    private var themeChoices: [ColorChoice] {
        state.selectedSlide(in: presentation).map {
            ColorChoice.themeChoices(in: SlideStyleContext(presentation: presentation, slide: $0))
        } ?? []
    }

    var body: some View {
        Form {
            Section {
                TextEditor(text: Binding(
                    get: { state.selectedShape(in: presentation)?.text?.plainText ?? "" },
                    set: { state.setText($0, in: &presentation) }
                ))
                .focused($isEditing)
                .frame(minHeight: 96)
                .accessibilityIdentifier("textEditor")
            }

            Section("Format.Section.Text") {
                HStack(spacing: 12) {
                    StyleToggle(symbol: "bold", label: "Format.Bold", isOn: style.isBold ?? false) {
                        state.toggleBold(in: &presentation)
                    }
                    StyleToggle(symbol: "italic", label: "Format.Italic", isOn: style.isItalic ?? false) {
                        state.toggleItalic(in: &presentation)
                    }
                    StyleToggle(symbol: "underline", label: "Format.Underline", isOn: style.isUnderlined ?? false) {
                        state.toggleUnderline(in: &presentation)
                    }
                }

                LabeledContent("Format.Text.Size") {
                    Stepper(
                        value: Binding(
                            get: { Double(style.size ?? 1_800) / 100 },
                            set: { state.stepFontSize(by: Int(($0 - Double(style.size ?? 1_800) / 100).rounded()), in: &presentation) }
                        ),
                        in: 6...400, step: 2
                    ) {
                        Text(verbatim: "\(Int((Double(style.size ?? 1_800) / 100).rounded())) pt")
                            .monospacedDigit()
                    }
                    .fixedSize()
                    .accessibilityIdentifier("fontSize")
                }

                Picker("Format.Alignment", selection: Binding(
                    get: { state.effectiveAlignment(in: presentation) },
                    set: { state.setAlignment($0, in: &presentation) }
                )) {
                    ForEach(ParagraphAlignment.allCases, id: \.self) { alignment in
                        Image(systemName: alignment.symbolName).tag(alignment)
                    }
                }
                .pickerStyle(.segmented)
            }

            Section("Format.Section.TextColor") {
                ColorSwatches(
                    identifier: "textColor", choices: themeChoices + ColorChoice.system, selected: style.color
                ) { color in
                    if let color { state.setTextColor(color, in: &presentation) }
                }
            }
        }
        .onAppear {
            // A shape with nothing in it yet is there to be typed into.
            if state.selectedShape(in: presentation)?.text?.isEmpty ?? true { isEditing = true }
        }
    }
}

/// A shape's fill, outline and stacking; or, with nothing selected, the slide's.
struct FormatPanel: View {
    @Binding var presentation: Presentation
    @Bindable var state: EditorState

    private var slide: Slide? { state.selectedSlide(in: presentation) }
    private var shape: SlideShape? { state.selectedShape(in: presentation) }
    private var themeChoices: [ColorChoice] {
        slide.map { ColorChoice.themeChoices(in: SlideStyleContext(presentation: presentation, slide: $0)) } ?? []
    }

    var body: some View {
        Form {
            if let shape, shape.isEditable {
                shapeSections(shape)
            } else {
                slideSections
            }
        }
    }

    @ViewBuilder
    private func shapeSections(_ shape: SlideShape) -> some View {
        if !shape.isPicture, case .shape = shape.kind, !PresetGeometry.isOpen(shape.geometry.presetName ?? "") {
            Section("Format.Section.Fill") {
                ColorSwatches(
                    identifier: "fillColor", choices: themeChoices + ColorChoice.system,
                    selected: { if case .solid(let color) = shape.fill { return color } else { return nil } }(),
                    allowsNone: true, isNoneSelected: shape.fill == Fill.none
                ) { color in
                    state.setFill(color.map(Fill.solid) ?? .none, in: &presentation)
                }
            }
        }
        if case .shape = shape.kind {
            outlineSection(shape)
        } else if case .connector = shape.kind {
            outlineSection(shape)
        } else if shape.isPicture {
            outlineSection(shape)
        }
        Section("Format.Section.Arrange") {
            Button("Arrange.Front", systemImage: "square.3.layers.3d.top.filled") {
                state.arrangeSelectedShape(.front, in: &presentation)
            }
            Button("Arrange.Back", systemImage: "square.3.layers.3d.bottom.filled") {
                state.arrangeSelectedShape(.back, in: &presentation)
            }
        }
        if shape.canRotate {
            Section("Format.Section.Rotate") {
                LabeledContent("Format.Rotation") {
                    Stepper(
                        value: Binding(
                            get: { shape.rotation.rounded() },
                            set: { value in
                                state.setTransform(frame: shape.frame.points, rotation: value, of: shape.id, in: &presentation)
                            }
                        ),
                        in: -360...720, step: 1
                    ) {
                        Text(verbatim: "\(Int(shape.rotation.rounded()))°")
                            .monospacedDigit()
                    }
                    .fixedSize()
                    .accessibilityIdentifier("rotation")
                }
                RotateAndFlipButtons(presentation: $presentation, state: state)
            }
        }
    }

    private func outlineSection(_ shape: SlideShape) -> some View {
        Section("Format.Section.Outline") {
            ColorSwatches(
                identifier: "lineColor", choices: themeChoices + ColorChoice.system,
                selected: { if case .solid(let color) = shape.line?.fill { return color } else { return nil } }(),
                allowsNone: true, isNoneSelected: shape.line?.fill == Fill.none
            ) { color in
                state.setLine({ $0.fill = color.map(Fill.solid) ?? Fill.none }, in: &presentation)
            }
            LabeledContent("Format.Outline.Width") {
                let width = EMU.points(shape.line?.width ?? 12_700)
                Stepper(
                    value: Binding(
                        get: { width },
                        set: { value in state.setLine({ $0.width = EMU.from(points: max(value, 0.25)) }, in: &presentation) }
                    ),
                    in: 0.25...24, step: 0.75
                ) {
                    Text(verbatim: String(format: "%.2g pt", width))
                        .monospacedDigit()
                }
                .fixedSize()
            }
        }
    }

    @ViewBuilder
    private var slideSections: some View {
        if let slide {
            Section {
                ColorSwatches(
                    identifier: "background", choices: themeChoices + ColorChoice.system,
                    selected: { if case .fill(.solid(let color)) = slide.background { return color } else { return nil } }(),
                    allowsNone: true, isNoneSelected: slide.background == nil
                ) { color in
                    state.setBackground(color.map(Fill.solid), in: &presentation)
                }
            } header: {
                Text("Format.Section.Background")
            } footer: {
                Text("Format.Background.Footer")
            }

            Section("Format.Section.Slide") {
                LabeledContent("Format.Slide.Layout", value: presentation.layout(for: slide)?.name ?? "")
                Toggle("Format.Slide.Hidden", isOn: Binding(
                    get: { slide.isHidden },
                    set: { _ in state.toggleHidden(slide.id, in: &presentation) }
                ))
            }
            if let shape, !shape.isEditable {
                Section {
                    Label("Format.Locked", systemImage: "lock")
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
}

/// The selected slide's speaker notes, as the presenter will see them.
struct NotesPanel: View {
    @Binding var presentation: Presentation
    @Bindable var state: EditorState

    var body: some View {
        TextEditor(text: Binding(
            get: { state.selectedSlide(in: presentation)?.notes ?? "" },
            set: { state.setNotes($0, in: &presentation) }
        ))
        .scrollContentBackground(.hidden)
        .padding(.horizontal, 12)
        .overlay(alignment: .topLeading) {
            if state.selectedSlide(in: presentation)?.notes.isEmpty ?? true {
                Text("Notes.Placeholder")
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 17)
                    .padding(.vertical, 8)
                    .allowsHitTesting(false)
            }
        }
        .accessibilityIdentifier("notesEditor")
    }
}

/// Exporting slides as a PDF or as pictures.
struct ExportPanel: View {
    var presentation: Presentation
    @Bindable var state: EditorState
    var name: String

    @State private var options = ExportOptions()

    private var slides: [Slide] {
        switch options.scope {
        case .current:
            return state.selectedSlide(in: presentation).map { [$0] } ?? []
        case .all:
            return presentation.slides.filter { options.includesHiddenSlides || !$0.isHidden }
        case .chosen:
            return presentation.slides.filter { options.chosenSlideIDs.contains($0.id) }
        }
    }

    var body: some View {
        Form {
            Section {
                Picker("Export.Format", selection: $options.format) {
                    Text("Export.Format.PDF").tag(ExportOptions.Format.pdf)
                    Text("Export.Format.Images").tag(ExportOptions.Format.images)
                }
                .pickerStyle(.segmented)
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets())
            }

            Section("Export.Section.Slides") {
                Picker("Export.Scope", selection: $options.scope) {
                    Text("Export.Scope.Current").tag(ExportOptions.Scope.current)
                    Text("Export.Scope.All").tag(ExportOptions.Scope.all)
                    Text("Export.Scope.Chosen").tag(ExportOptions.Scope.chosen)
                }
                if options.scope == .all, presentation.slides.contains(where: \.isHidden) {
                    Toggle("Export.IncludeHidden", isOn: $options.includesHiddenSlides)
                }
                if options.scope == .chosen {
                    slidePicker
                }
            }

            if options.format == .images {
                Section("Export.Section.Images") {
                    Picker("Export.ImageFormat", selection: $options.imageFormat) {
                        Text(verbatim: "PNG").tag(SlideExporter.ImageFormat.png)
                        Text(verbatim: "JPEG").tag(SlideExporter.ImageFormat.jpeg)
                    }
                    Picker("Export.Resolution", selection: $options.resolution) {
                        ForEach(ExportOptions.Resolution.allCases) { resolution in
                            Text(verbatim: "\(resolution.rawValue) × \(Int(Double(resolution.rawValue) / presentation.slideSize.aspectRatio))")
                                .tag(resolution)
                        }
                    }
                }
            }

            Section {
                shareButton
                    .frame(maxWidth: .infinity)
                    .disabled(slides.isEmpty)
            } footer: {
                Text(String.localizedStringWithFormat(String(localized: "Export.Count"), slides.count))
                    .frame(maxWidth: .infinity)
            }
        }
        .onAppear {
            options.format = state.exportFormat
            if let slide = state.selectedSlide(in: presentation) { options.chosenSlideIDs = [slide.id] }
        }
    }

    @ViewBuilder
    private var shareButton: some View {
        let label = Label("Export.Share", systemImage: "square.and.arrow.up").fontWeight(.semibold)
        switch options.format {
        case .pdf:
            ShareLink(
                item: PDFExport(presentation: presentation, slides: slides, name: name),
                preview: SharePreview(name, image: Image(systemName: "doc.richtext"))
            ) { label }
            .accessibilityIdentifier("sharePDF")
        case .images:
            let numbered = slides.map { slide in
                let number = (presentation.index(of: slide.id) ?? 0) + 1
                return SlideImageExport(
                    presentation: presentation, slide: slide,
                    name: slides.count == 1 && options.scope == .current
                        ? "\(name) \(number)" : String(format: "%@ %03d", name, number),
                    format: options.imageFormat, width: options.resolution.rawValue
                )
            }
            ShareLink(items: numbered) { export in
                SharePreview(export.name, image: Image(systemName: "photo"))
            } label: {
                label
            }
            .accessibilityIdentifier("shareImages")
        }
    }

    private var slidePicker: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 96), spacing: 10)], spacing: 10) {
            ForEach(Array(presentation.slides.enumerated()), id: \.element.id) { index, slide in
                let isChosen = options.chosenSlideIDs.contains(slide.id)
                Button {
                    if isChosen {
                        options.chosenSlideIDs.remove(slide.id)
                    } else {
                        options.chosenSlideIDs.insert(slide.id)
                    }
                } label: {
                    SlideThumbnail(presentation: presentation, slide: slide, number: index + 1, isSelected: isChosen)
                        .overlay(alignment: .topTrailing) {
                            Image(systemName: isChosen ? "checkmark.circle.fill" : "circle")
                                .symbolRenderingMode(.multicolor)
                                .font(.system(size: 18))
                                .foregroundStyle(isChosen ? Color.accentColor : .white)
                                .shadow(radius: 2)
                                .padding(4)
                        }
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.vertical, 6)
    }
}

/// A round toggle for a text style, lit when on.
struct StyleToggle: View {
    let symbol: String
    let label: LocalizedStringKey
    let isOn: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 17, weight: .medium))
                .frame(width: 40, height: 40)
                .foregroundStyle(isOn ? Color.accentColor : .primary)
                .background(isOn ? Color.accentColor.opacity(0.2) : Color.primary.opacity(0.06), in: .circle)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        .accessibilityAddTraits(isOn ? [.isButton, .isSelected] : .isButton)
    }
}
