import PhotosUI
import SwiftUI

/// How the selected shape's text looks: all of it, or while typing, the
/// part selected.
struct TextPanel: View {
    @Binding var presentation: Presentation
    @Bindable var state: EditorState

    private var style: RunProperties { state.effectiveRunProperties(in: presentation) }
    private var paragraph: ParagraphProperties { state.effectiveParagraphProperties(in: presentation) }
    private var styleContext: SlideStyleContext? {
        state.selectedSlide(in: presentation).map { SlideStyleContext(presentation: presentation, slide: $0) }
    }
    private var themeChoices: [ColorChoice] {
        styleContext.map(ColorChoice.themeChoices(in:)) ?? []
    }

    var body: some View {
        Form {
            Section("Format.Section.Font") {
                NavigationLink {
                    FontPicker(theme: styleContext?.theme ?? .office, selected: style.latinFont) { family in
                        state.setFontFamily(family, in: &presentation)
                    }
                } label: {
                    LabeledContent("Format.Font", value: fontName)
                }
                .accessibilityIdentifier("fontFamily")

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
                    StyleToggle(symbol: "strikethrough", label: "Format.Strikethrough", isOn: style.isStruckThrough ?? false) {
                        state.toggleStrikethrough(in: &presentation)
                    }
                    StyleToggle(symbol: "textformat.superscript", label: "Format.Superscript", isOn: (style.baseline ?? 0) > 0) {
                        state.toggleBaseline(superscript: true, in: &presentation)
                    }
                    StyleToggle(symbol: "textformat.subscript", label: "Format.Subscript", isOn: (style.baseline ?? 0) < 0) {
                        state.toggleBaseline(superscript: false, in: &presentation)
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
            }

            Section("Format.Section.TextColor") {
                ColorSwatches(
                    identifier: "textColor", choices: themeChoices + ColorChoice.system, selected: style.color
                ) { color in
                    if let color { state.setTextColor(color, in: &presentation) }
                }
            }

            Section("Format.Section.Paragraph") {
                Picker("Format.Alignment", selection: Binding(
                    get: { state.effectiveAlignment(in: presentation) },
                    set: { state.setAlignment($0, in: &presentation) }
                )) {
                    ForEach(ParagraphAlignment.allCases, id: \.self) { alignment in
                        Image(systemName: alignment.symbolName).tag(alignment)
                    }
                }
                .pickerStyle(.segmented)

                Picker("Format.List", selection: Binding(
                    get: { state.listStyle(in: presentation) },
                    set: { state.setListStyle($0, in: &presentation) }
                )) {
                    Text("Format.List.None").tag(EditorState.ListStyleChoice.none)
                    Text("Format.List.Bullets").tag(EditorState.ListStyleChoice.bullets)
                    Text("Format.List.Numbers").tag(EditorState.ListStyleChoice.numbers)
                }
                .accessibilityIdentifier("listStyle")

                LabeledContent("Format.Indent.Level") {
                    HStack(spacing: 12) {
                        StyleToggle(symbol: "decrease.indent", label: "Format.Outdent", isOn: false) {
                            state.changeIndent(by: -1, in: &presentation)
                        }
                        .disabled((paragraph.level ?? 0) == 0)
                        StyleToggle(symbol: "increase.indent", label: "Format.Indent", isOn: false) {
                            state.changeIndent(by: 1, in: &presentation)
                        }
                    }
                }

                Picker("Format.LineSpacing", selection: Binding(
                    get: { lineSpacing },
                    set: { state.setLineSpacing($0, in: &presentation) }
                )) {
                    ForEach([1.0, 1.15, 1.5, 2.0, 2.5, 3.0], id: \.self) { multiple in
                        Text(verbatim: multiple.formatted(.number.precision(.fractionLength(0...2)))).tag(multiple)
                    }
                }
                .accessibilityIdentifier("lineSpacing")
            }
        }
    }

    private var fontName: String {
        guard let font = style.latinFont else { return styleContext?.theme.minorFont ?? "" }
        switch font {
        case "+mj-lt", "+mj-ea": return String(format: String(localized: "Format.Font.Headings"), styleContext?.theme.majorFont ?? "")
        case "+mn-lt", "+mn-ea": return String(format: String(localized: "Format.Font.Body"), styleContext?.theme.minorFont ?? "")
        default: return font
        }
    }

    private var lineSpacing: Double {
        if case .percent(let value) = paragraph.lineSpacing {
            return [1.0, 1.15, 1.5, 2.0, 2.5, 3.0].min { abs($0 - value) < abs($1 - value) } ?? 1
        }
        return 1
    }
}

/// Every typeface the device has, led by the theme's own two.
struct FontPicker: View {
    let theme: Theme
    let selected: String?
    let onSelect: (String) -> Void

    @State private var search = ""
    @Environment(\.dismiss) private var dismiss

    private static let families = UIFont.familyNames.sorted()

    var body: some View {
        List {
            if search.isEmpty {
                Section("Format.Font.Theme") {
                    row(value: "+mj-lt", display: theme.majorFont,
                        label: String(format: String(localized: "Format.Font.Headings"), theme.majorFont))
                    row(value: "+mn-lt", display: theme.minorFont,
                        label: String(format: String(localized: "Format.Font.Body"), theme.minorFont))
                }
            }
            Section("Format.Font.All") {
                ForEach(Self.families.filter { search.isEmpty || $0.localizedCaseInsensitiveContains(search) }, id: \.self) { family in
                    row(value: family, display: family, label: family)
                }
            }
        }
        .searchable(text: $search)
        .navigationTitle("Format.Font")
    }

    private func row(value: String, display: String, label: String) -> some View {
        Button {
            onSelect(value)
            dismiss()
        } label: {
            HStack {
                Text(verbatim: label)
                    .font(Font(FontResolver.shared.font(family: display, size: 17, bold: false, italic: false) as UIFont))
                    .foregroundStyle(.primary)
                Spacer()
                if selected == value {
                    Image(systemName: "checkmark").foregroundStyle(Color.accentColor)
                }
            }
        }
    }
}

/// A shape's fill, outline and stacking; or, with nothing selected, the slide's.
struct FormatPanel: View {
    @Binding var presentation: Presentation
    @Bindable var state: EditorState

    @State private var replacement: PhotosPickerItem?
    /// A slide size picked, waiting on how to scale to it.
    @State private var pendingSize: SlideSizeConverter.Preset?

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
                FillEditor(
                    identifier: "fillColor", fill: shape.fill ?? inheritedFill(of: shape), choices: themeChoices + ColorChoice.system,
                    onChange: { state.setFill($0 ?? .none, in: &presentation) },
                    onPicture: { state.setFillPicture($0, tiled: $1, in: &presentation) }
                )
            }
        }
        if case .table(let table) = shape.kind {
            tableSections(table)
        }
        if case .picture(let picture) = shape.kind, !state.hasMultipleSelection {
            pictureSection(shape, picture: picture)
        }
        if case .shape = shape.kind {
            outlineSection(shape)
        } else if case .connector = shape.kind {
            outlineSection(shape)
        } else if shape.isPicture {
            outlineSection(shape)
        }
        switch shape.kind {
        case .shape, .connector, .picture: shadowSection(shape)
        default: EmptyView()
        }
        Section("Format.Section.Arrange") {
            Button("Arrange.Front", systemImage: "square.3.layers.3d.top.filled") {
                state.arrangeSelectedShape(.front, in: &presentation)
            }
            Button("Arrange.Back", systemImage: "square.3.layers.3d.bottom.filled") {
                state.arrangeSelectedShape(.back, in: &presentation)
            }
        }
        AlignButtons(presentation: $presentation, state: state)
        GroupButtons(presentation: $presentation, state: state)
        if !state.hasMultipleSelection {
            descriptionSection(shape)
        }
        if shape.canRotate, !state.hasMultipleSelection {
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

    /// The fill a shape with none of its own gets from its style or layout.
    private func inheritedFill(of shape: SlideShape) -> Fill? {
        guard let slide else { return nil }
        let style = SlideStyleContext(presentation: presentation, slide: slide)
        return style.fill(for: shape, sources: style.sources(for: shape))?.fill
    }

    private func pictureSection(_ shape: SlideShape, picture: SlideShape.Picture) -> some View {
        Section("Format.Section.Picture") {
            PhotosPicker(selection: $replacement, matching: .images) {
                Label("Picture.Replace", systemImage: "photo.badge.arrow.down")
            }
            .accessibilityIdentifier("replacePicture")
            .onChange(of: replacement) { _, item in
                guard let item else { return }
                replacement = nil
                Task {
                    guard let data = try? await item.loadTransferable(type: Data.self),
                          let media = await Task.detached(operation: { PreparedMedia(data: data) }).value else {
                        state.errorMessage = String(localized: "Error.UnreadablePicture")
                        return
                    }
                    state.replacePicture(with: media, in: &presentation)
                }
            }
            if shape.rotation == 0 {
                Button(state.croppingShapeID == shape.id ? "Picture.DoneCropping" : "Picture.Crop", systemImage: "crop") {
                    state.croppingShapeID = state.croppingShapeID == shape.id ? nil : shape.id
                    if state.croppingShapeID != nil { state.presentedPanel = nil }
                }
            }
            Button("Picture.ResetCrop", systemImage: "arrow.counterclockwise") {
                state.resetCrop(in: &presentation)
            }
            .disabled(picture.cropLeft == 0 && picture.cropTop == 0 && picture.cropRight == 0 && picture.cropBottom == 0)
        }
    }

    /// What a screen reader says in place of the shape.
    private func descriptionSection(_ shape: SlideShape) -> some View {
        Section {
            TextField("Format.AltText.Placeholder", text: Binding(
                get: { shape.altText ?? "" },
                set: { state.setAltText($0, in: &presentation) }
            ), axis: .vertical)
            .lineLimit(1...4)
            .accessibilityIdentifier("altText")
        } header: {
            Text("Format.Section.AltText")
        } footer: {
            Text("Format.AltText.Footer")
        }
    }

    @ViewBuilder
    private func tableSections(_ table: SlideTable) -> some View {
        Section("Format.Section.Table") {
            Toggle("Table.HeaderRow", isOn: Binding(
                get: { table.hasHeaderRow },
                set: { state.setTableHeaderRow($0, in: &presentation) }
            ))
            Toggle("Table.BandedRows", isOn: Binding(
                get: { table.hasBandedRows },
                set: { state.setTableBandedRows($0, in: &presentation) }
            ))
        }
        if let position = state.selectedCell, let cell = table.cell(at: position) {
            Section("Format.Section.CellFill") {
                ColorSwatches(
                    identifier: "cellFill", choices: themeChoices + ColorChoice.system,
                    selected: { if case .solid(let color) = cell.fill { return color } else { return nil } }(),
                    allowsNone: true, isNoneSelected: cell.fill == Fill.none
                ) { color in
                    state.setCellFill(color.map(Fill.solid) ?? Fill.none, in: &presentation)
                }
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
            Picker("Format.Outline.Dash", selection: Binding(
                get: { shape.line?.dash ?? "solid" },
                set: { dash in state.setLine({ $0.dash = dash }, in: &presentation) }
            )) {
                ForEach(Self.dashes, id: \.0) { value, label in
                    Text(label).tag(value)
                }
            }
            .accessibilityIdentifier("lineDash")
            // Arrowheads only show on lines that have ends.
            if shape.kind == .connector || PresetGeometry.isOpen(shape.geometry.presetName ?? "") {
                Picker("Format.Outline.Start", selection: Binding(
                    get: { shape.line?.head ?? "none" },
                    set: { head in state.setLine({ $0.head = head == "none" ? nil : head }, in: &presentation) }
                )) {
                    ForEach(Self.lineEnds, id: \.0) { value, label in Text(label).tag(value) }
                }
                .accessibilityIdentifier("lineStart")
                Picker("Format.Outline.End", selection: Binding(
                    get: { shape.line?.tail ?? "none" },
                    set: { tail in state.setLine({ $0.tail = tail == "none" ? nil : tail }, in: &presentation) }
                )) {
                    ForEach(Self.lineEnds, id: \.0) { value, label in Text(label).tag(value) }
                }
                .accessibilityIdentifier("lineEnd")
            }
        }
    }

    private func shadowSection(_ shape: SlideShape) -> some View {
        Section("Format.Section.Shadow") {
            Picker("Format.Shadow", selection: Binding(
                get: { Self.shadows.first { $0.shadow == shape.shadow }?.id ?? (shape.shadow == nil ? "none" : "custom") },
                set: { id in
                    guard let choice = Self.shadows.first(where: { $0.id == id }) else { return }
                    state.setShadow(choice.shadow, in: &presentation)
                }
            )) {
                ForEach(Self.shadows, id: \.id) { choice in
                    Text(choice.label).tag(choice.id)
                }
                if shape.shadow != nil, !Self.shadows.contains(where: { $0.shadow == shape.shadow }) {
                    Text("Shadow.Custom").tag("custom")
                }
            }
            .accessibilityIdentifier("shadow")
        }
    }

    private struct ShadowChoice {
        let id: String
        let label: LocalizedStringKey
        let shadow: Shadow?
    }

    /// PowerPoint's most used outer shadows.
    private static let shadows = [
        ShadowChoice(id: "none", label: "Shadow.None", shadow: nil),
        ShadowChoice(id: "drop", label: "Shadow.Drop", shadow: Shadow(
            blur: 50_800, distance: 38_100, direction: 45, color: Shadow.black(opacity: 0.4)
        )),
        ShadowChoice(id: "soft", label: "Shadow.Soft", shadow: Shadow(
            blur: 152_400, distance: 50_800, direction: 90, color: Shadow.black(opacity: 0.35)
        )),
        ShadowChoice(id: "close", label: "Shadow.Close", shadow: Shadow(
            blur: 25_400, distance: 19_050, direction: 45, color: Shadow.black(opacity: 0.6)
        )),
        ShadowChoice(id: "below", label: "Shadow.Below", shadow: Shadow(
            blur: 76_200, distance: 76_200, direction: 90, color: Shadow.black(opacity: 0.3)
        )),
    ]

    private static let dashes: [(String, LocalizedStringKey)] = [
        ("solid", "Line.Solid"), ("sysDash", "Line.Dash"), ("sysDot", "Line.Dot"),
        ("dashDot", "Line.DashDot"), ("lgDash", "Line.LongDash"),
    ]

    private static let lineEnds: [(String, LocalizedStringKey)] = [
        ("none", "Line.End.None"), ("triangle", "Line.End.Triangle"), ("arrow", "Line.End.Arrow"),
        ("stealth", "Line.End.Stealth"), ("oval", "Line.End.Oval"), ("diamond", "Line.End.Diamond"),
    ]

    @ViewBuilder
    private var slideSections: some View {
        if let slide {
            Section {
                FillEditor(
                    identifier: "background",
                    fill: { if case .fill(let fill) = slide.background { return fill } else { return nil } }(),
                    choices: themeChoices + ColorChoice.system, noneIsAutomatic: true,
                    onChange: { state.setBackground($0, in: &presentation) },
                    onPicture: { state.setBackgroundPicture($0, tiled: $1, in: &presentation) }
                )
            } header: {
                Text("Format.Section.Background")
            } footer: {
                Text("Format.Background.Footer")
            }

            Section("Format.Section.Presentation") {
                Picker("Format.SlideSize", selection: Binding(
                    get: { SlideSizeConverter.Preset.matching(presentation.slideSize) },
                    set: { pendingSize = $0 }
                )) {
                    ForEach(SlideSizeConverter.Preset.allCases) { preset in
                        Text(preset.label).tag(Optional(preset))
                    }
                    if SlideSizeConverter.Preset.matching(presentation.slideSize) == nil {
                        Text("SlideSize.Custom").tag(SlideSizeConverter.Preset?.none)
                    }
                }
                .accessibilityIdentifier("slideSize")
                .confirmationDialog(
                    "SlideSize.Scaling.Title", isPresented: Binding(get: { pendingSize != nil }, set: { if !$0 { pendingSize = nil } }),
                    titleVisibility: .visible
                ) {
                    Button("SlideSize.Scaling.EnsureFit") {
                        if let pendingSize { state.setSlideSize(pendingSize, scaling: .ensureFit, in: &presentation) }
                        pendingSize = nil
                    }
                    Button("SlideSize.Scaling.Maximize") {
                        if let pendingSize { state.setSlideSize(pendingSize, scaling: .maximize, in: &presentation) }
                        pendingSize = nil
                    }
                } message: {
                    Text("SlideSize.Scaling.Message")
                }
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
    /// The movie made for sharing, and how far making it has got.
    @State private var video: URL?
    @State private var videoProgress: Double?
    @State private var videoTask: Task<Void, Never>?

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
                    Text("Export.Format.Video").tag(ExportOptions.Format.video)
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

            if options.format == .pdf {
                Section("Export.Section.Layout") {
                    Picker("Export.Layout", selection: Binding(
                        get: { Self.layoutKind(options.pageLayout) },
                        set: { kind in
                            options.pageLayout = switch kind {
                            case 1: .notes
                            case 2: .handouts(perPage: 3)
                            default: .slides
                            }
                        }
                    )) {
                        Text("Export.Layout.Slides").tag(0)
                        Text("Export.Layout.Notes").tag(1)
                        Text("Export.Layout.Handouts").tag(2)
                    }
                    if case .handouts(let count) = options.pageLayout {
                        Picker("Export.Layout.PerPage", selection: Binding(
                            get: { count }, set: { options.pageLayout = .handouts(perPage: $0) }
                        )) {
                            ForEach(SlideExporter.PageLayout.handoutCounts, id: \.self) { count in
                                Text(verbatim: String(count)).tag(count)
                            }
                        }
                    }
                }
            }

            if options.format == .video {
                Section("Export.Section.Video") {
                    Picker("Export.Resolution", selection: $options.resolution) {
                        Text(verbatim: "720p").tag(ExportOptions.Resolution.standard)
                        Text(verbatim: "1080p").tag(ExportOptions.Resolution.high)
                        Text(verbatim: "4K").tag(ExportOptions.Resolution.ultra)
                    }
                    LabeledContent("Export.SecondsPerSlide") {
                        Stepper(value: $options.secondsPerSlide, in: 1...60, step: 1) {
                            Text(String(format: String(localized: "Export.Seconds"), Int(options.secondsPerSlide)))
                                .monospacedDigit()
                        }
                        .fixedSize()
                    }
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
                if options.format == .pdf {
                    Button("Export.Print", systemImage: "printer") { print() }
                        .frame(maxWidth: .infinity)
                        .disabled(slides.isEmpty)
                        .accessibilityIdentifier("print")
                }
            } footer: {
                Text(String.localizedStringWithFormat(String(localized: "Export.Count"), slides.count))
                    .frame(maxWidth: .infinity)
            }
        }
        .onChange(of: options) { _, _ in video = nil }
        .onDisappear { videoTask?.cancel() }
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
                item: PDFExport(presentation: presentation, slides: slides, name: name, layout: options.pageLayout),
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
        case .video:
            if let video {
                ShareLink(item: video) { label }
                    .accessibilityIdentifier("shareVideo")
            } else if let videoProgress {
                VStack(spacing: 6) {
                    ProgressView(value: videoProgress)
                    Button("Common.Cancel", role: .cancel) {
                        videoTask?.cancel()
                        videoTask = nil
                        self.videoProgress = nil
                    }
                }
            } else {
                Button {
                    makeVideo()
                } label: {
                    Label("Export.MakeVideo", systemImage: "film").fontWeight(.semibold)
                }
                .accessibilityIdentifier("makeVideo")
            }
        }
    }

    private static func layoutKind(_ layout: SlideExporter.PageLayout) -> Int {
        switch layout {
        case .slides: 0
        case .notes: 1
        case .handouts: 2
        }
    }

    private func print() {
        let data = SlideExporter.pdf(of: slides, in: presentation, title: name, layout: options.pageLayout)
        let controller = UIPrintInteractionController.shared
        let info = UIPrintInfo.printInfo()
        info.jobName = name
        info.outputType = .general
        controller.printInfo = info
        controller.printingItem = data
        controller.present(animated: true)
    }

    /// Renders the movie in the background, then offers it to share.
    private func makeVideo() {
        let slides = slides
        let presentation = presentation
        let width = options.resolution.rawValue
        let durations = slides.map { _ in options.secondsPerSlide }
        let name = name
        videoProgress = 0
        videoTask = Task {
            do {
                let directory = FileManager.default.temporaryDirectory
                    .appending(path: "Share-\(UUID().uuidString)", directoryHint: .isDirectory)
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                let url = directory.appending(path: "\(ExportFile.sanitized(name)).mp4")
                try await Task.detached(priority: .userInitiated) {
                    try await VideoExporter.export(
                        slides, of: presentation, width: width, durations: durations, to: url
                    ) { fraction in
                        Task { @MainActor in if videoProgress != nil { videoProgress = fraction } }
                    }
                }.value
                video = url
            } catch is CancellationError {
                // Stopped by the person waiting for it.
            } catch {
                state.errorMessage = error.localizedDescription
            }
            videoProgress = nil
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

extension SlideSizeConverter.Preset {
    var label: LocalizedStringKey {
        switch self {
        case .widescreen: "SlideSize.Widescreen"
        case .standard: "SlideSize.Standard"
        case .widescreen16x10: "SlideSize.Widescreen16x10"
        case .a4: "SlideSize.A4"
        }
    }
}
