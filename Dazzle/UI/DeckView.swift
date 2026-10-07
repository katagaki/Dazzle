import SwiftUI

/// The document's root view: the slides down the side or along the bottom,
/// the slide being edited, the floating action bar, and the toolbar.
struct DeckView: View {
    @Binding var document: DazzleDocument
    /// The file's name, which exports are named after.
    var fileName: String?

    @State private var state = EditorState()
    @State private var history = DeckHistory()
    /// Tells this window's slideshow apart from another window's.
    @State private var editorID = UUID()
    @Environment(\.undoManager) private var undoManager
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.scenePhase) private var scenePhase
    @Namespace private var panelTransition

    private var session: PresentationSession { .shared }
    private var presentation: Binding<Presentation> { $document.presentation }

    private var name: String {
        fileName.map { ($0 as NSString).deletingPathExtension } ?? String(localized: "Document.DefaultName")
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                if horizontalSizeClass != .compact {
                    sidebar
                        .frame(width: 216)
                    Divider()
                        .ignoresSafeArea(edges: .bottom)
                }
                SlideCanvas(
                    presentation: presentation, state: state, onSwipe: step,
                    isRaised: horizontalSizeClass == .compact && state.presentedPanel != nil
                )
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .overlay(alignment: .bottom) {
                        if !state.isDrawing {
                            FloatingActionBar(presentation: presentation, state: state, namespace: panelTransition)
                                .padding(.bottom, 8)
                        }
                    }
            }
            if horizontalSizeClass == .compact {
                Divider()
                SlideStrip(presentation: presentation, state: state, play: play) {
                    PlayMenu(play: play, current: { state.selectedIndex(in: document.presentation) }) {
                        Image(systemName: "play.fill")
                            .font(.system(size: 15, weight: .semibold))
                            .frame(width: 40, height: 40)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.white)
                    .glassEffect(.regular.tint(.accentColor).interactive(), in: .circle)
                }
                .background(.bar)
            }
        }
        .background(Color(.secondarySystemBackground))
        // Keyboard navigation belongs to the canvas, and only while no panel
        // or drawing is up — otherwise it holds focus away from them.
        .focusable(state.presentedPanel == nil && !state.isDrawing && state.editingTextShapeID == nil)
        .focusEffectDisabled()
        .onKeyPress(action: handleKeyPress)
        .toolbar { undoToolbar }
        .toolbar { moreToolbar }
        .toolbar { presentationToolbar }
        .sheet(item: $state.presentedPanel) { panel in
            NavigationStack {
                panelContent(panel)
                    .navigationTitle(panel.title)
                    .navigationBarTitleDisplayMode(.inline)
                    .navigationBarBackButtonHidden()
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button(role: .confirm) { state.presentedPanel = nil }
                        }
                    }
            }
            .navigationTransition(.zoom(sourceID: panel, in: panelTransition))
            // Formatting panels stay at half height, so the slide they change
            // is always in view; export needs the room for its slide picker.
            .presentationDetents(panel == .export ? [.large] : ([.find, .chart].contains(panel) ? [.medium, .large] : [.medium]))
            .presentationDragIndicator(.visible)
            .presentationBackground(.regularMaterial)
            // The slide stays live above a half-height panel, so changes can be
            // watched as they are made and another shape picked.
            .presentationBackgroundInteraction(.enabled(upThrough: .medium))
        }
        .sheet(isPresented: Binding(
            get: { horizontalSizeClass == .compact && state.isShowingUnsupportedFeatureNotice },
            set: { state.isShowingUnsupportedFeatureNotice = $0 }
        )) {
            UnsupportedFeatureNotice(report: document.presentation.unsupportedFeatures)
                .presentationDetents([.medium])
                .presentationDragIndicator(.visible)
        }
        .fullScreenCover(isPresented: slideshowBinding, onDismiss: {
            if let id = session.lastShownSlideID, document.presentation.index(of: id) != nil { state.selectSlide(id) }
        }) {
            SlideshowView(session: session)
        }
        .alert(
            "Alert.Error.Title",
            isPresented: Binding(get: { state.errorMessage != nil }, set: { if !$0 { state.errorMessage = nil } })
        ) {
            Button("Common.OK", role: .cancel) { state.errorMessage = nil }
        } message: {
            Text(state.errorMessage ?? "")
        }
        .onAppear {
            state.reconcile(with: document.presentation)
            attachHistory()
            offerToRemote()
        }
        .onDisappear { session.withdraw(editorID) }
        .onChange(of: undoManager) { _, _ in attachHistory() }
        .onChange(of: document.presentation) { old, new in
            history.record(from: old, to: new)
            state.reconcile(with: new)
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { offerToRemote() }
        }
        .onChange(of: state.isDrawing) { _, isDrawing in
            if isDrawing { state.presentedPanel = nil }
        }
    }

    // MARK: - Layout

    private var sidebar: some View {
        VStack(spacing: 0) {
            NewSlideMenu(presentation: presentation, state: state) {
                Label("Slide.New", systemImage: "plus")
                    .font(.subheadline.weight(.semibold))
                    .padding(.horizontal, 16)
                    .frame(height: 36)
            }
            .buttonStyle(.plain)
            .glassEffect(.regular.interactive(), in: .capsule)
            .padding(.vertical, 10)

            SlideNavigator(presentation: presentation, state: state, axis: .vertical, play: play)
        }
        .background(.bar)
    }

    @ViewBuilder
    private func panelContent(_ panel: EditorPanel) -> some View {
        switch panel {
        case .text: TextPanel(presentation: presentation, state: state)
        case .format: FormatPanel(presentation: presentation, state: state)
        case .notes: NotesPanel(presentation: presentation, state: state)
        case .export: ExportPanel(presentation: document.presentation, state: state, name: name)
        case .find: FindPanel(presentation: presentation, state: state)
        case .chart: ChartPanel(presentation: presentation, state: state)
        }
    }

    // MARK: - Slideshow

    private var slideshowBinding: Binding<Bool> {
        Binding(
            get: { session.isPresenting && session.ownerID == editorID },
            set: { if !$0 { session.end() } }
        )
    }

    private func play(from index: Int) {
        guard !session.isPresenting else { return }
        state.presentedPanel = nil
        state.isDrawing = false
        session.start(document.presentation, title: name, fromSlide: index, owner: editorID)
    }

    /// Lets the watch start this presentation, as the one most recently in front.
    private func offerToRemote() {
        session.offer(PresentationSession.Candidate(id: editorID, title: name) { [state] in
            play(from: state.selectedIndex(in: document.presentation))
        })
    }

    private func step(forward: Bool) {
        let slides = document.presentation.slides
        let index = state.selectedIndex(in: document.presentation) + (forward ? 1 : -1)
        guard slides.indices.contains(index) else { return }
        state.selectSlide(slides[index].id)
    }

    // MARK: - History

    private func attachHistory() {
        let document = $document
        let state = state
        history.attach(
            to: undoManager,
            read: { document.wrappedValue.presentation },
            write: { document.wrappedValue.presentation = $0 },
            restored: { state.reconcile(with: $0) }
        )
    }

    // MARK: - Toolbars

    @ToolbarContentBuilder
    private var undoToolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            Button("Toolbar.Undo", systemImage: "arrow.uturn.backward") { history.undo() }
                .disabled(!history.canUndo)
                .keyboardShortcut("z", modifiers: .command)
                .accessibilityIdentifier("undo")
            if horizontalSizeClass != .compact {
                redoButton
            }
        }
    }

    private var redoButton: some View {
        Button("Toolbar.Redo", systemImage: "arrow.uturn.forward") { history.redo() }
            .disabled(!history.canRedo)
            .keyboardShortcut("z", modifiers: [.command, .shift])
            .accessibilityIdentifier("redo")
    }

    @ToolbarContentBuilder
    private var presentationToolbar: some ToolbarContent {
        // Declared before the share button so it sits beside it on the inside.
        // An iPhone's bar holds three buttons, so there it moves to the "…" menu.
        if !document.presentation.unsupportedFeatures.isEmpty, horizontalSizeClass != .compact {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    state.isShowingUnsupportedFeatureNotice = true
                } label: {
                    Image(systemName: "exclamationmark.triangle")
                }
                .accessibilityIdentifier("unsupportedFeatures")
                .accessibilityLabel("Toolbar.UnsupportedFeatures")
                .popover(isPresented: $state.isShowingUnsupportedFeatureNotice) {
                    UnsupportedFeatureNotice(report: document.presentation.unsupportedFeatures)
                }
            }
        }
        ToolbarItem(placement: .primaryAction) {
            Menu {
                ShareLink(
                    item: PresentationShare(presentation: document.presentation, name: name),
                    preview: SharePreview(name, image: Image(systemName: "play.rectangle"))
                ) {
                    Label("Share.Presentation", systemImage: "doc")
                }
                Button("Share.PDF", systemImage: "doc.richtext") {
                    state.exportFormat = .pdf
                    state.presentedPanel = .export
                }
                .accessibilityIdentifier("exportPDF")
                Button("Share.Images", systemImage: "photo.on.rectangle") {
                    state.exportFormat = .images
                    state.presentedPanel = .export
                }
                .accessibilityIdentifier("exportImages")
            } label: {
                Image(systemName: "square.and.arrow.up")
            }
            .accessibilityIdentifier("share")
            .accessibilityLabel("Toolbar.Share")
        }
        // On iPhone the bar has no room for it; it leads the slide strip instead.
        if horizontalSizeClass != .compact {
            ToolbarSpacer(.fixed, placement: .primaryAction)
            ToolbarItem(placement: .primaryAction) {
                PlayMenu(play: play, current: { state.selectedIndex(in: document.presentation) }) {
                    Label("Toolbar.Play", systemImage: "play.fill")
                }
                .buttonStyle(.glassProminent)
            }
        }
    }

    /// Secondary actions are gathered into the navigation bar's "…" menu.
    @ToolbarContentBuilder
    private var moreToolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .secondaryAction) {
            // A narrow bar has no room for Redo and would push it into this
            // menu itself, below everything here. Placing it keeps Source Code last.
            if horizontalSizeClass == .compact {
                redoButton
                if !document.presentation.unsupportedFeatures.isEmpty {
                    Button("Toolbar.UnsupportedFeatures", systemImage: "exclamationmark.triangle") {
                        state.isShowingUnsupportedFeatureNotice = true
                    }
                    .accessibilityIdentifier("unsupportedFeatures")
                }
            }
            Button("Toolbar.Find", systemImage: "magnifyingglass") {
                state.endEditingText()
                state.presentedPanel = .find
            }
            .keyboardShortcut("f", modifiers: .command)
            .accessibilityIdentifier("find")
            Section {
                Link(destination: URL(string: "https://github.com/katagaki/Dazzle")!) {
                    Label("Toolbar.SourceCode", systemImage: "chevron.left.forwardslash.chevron.right")
                }
            }
        }
    }

    // MARK: - Keyboard

    private func handleKeyPress(_ press: KeyPress) -> KeyPress.Result {
        if press.modifiers.contains(.command) {
            switch press.characters.lowercased() {
            case "c":
                state.copySelection(in: document.presentation)
                return .handled
            case "x":
                state.cutSelection(in: &document.presentation)
                return .handled
            case "v":
                state.paste(in: &document.presentation)
                return .handled
            default:
                break
            }
        }
        let nudge = press.modifiers.contains(.shift) ? 10.0 : 1.0
        if let shape = state.selectedShape(in: document.presentation) {
            var offset = CGSize.zero
            switch press.key {
            case .delete, .deleteForward:
                state.deleteSelectedShape(in: &document.presentation)
                return .handled
            case .escape:
                state.selectedShapeID = nil
                return .handled
            case .return where shape.canHoldText && shape.isEditable:
                state.beginEditingText(shape.id)
                return .handled
            case .upArrow: offset.height = -nudge
            case .downArrow: offset.height = nudge
            case .leftArrow: offset.width = -nudge
            case .rightArrow: offset.width = nudge
            default:
                if press.modifiers.contains(.command), press.characters.lowercased() == "d" {
                    state.duplicateSelectedShape(in: &document.presentation)
                    return .handled
                }
                if press.modifiers.contains(.command), press.characters.lowercased() == "a" {
                    state.selectAllShapes(in: document.presentation)
                    return .handled
                }
                if press.modifiers.contains(.command), press.characters.lowercased() == "g" {
                    if press.modifiers.contains(.shift) {
                        state.ungroupSelectedShape(in: &document.presentation)
                    } else {
                        state.groupSelectedShapes(in: &document.presentation)
                    }
                    return .handled
                }
                return .ignored
            }
            guard shape.isEditable else { return .handled }
            let frames = Dictionary(uniqueKeysWithValues: state.selectedShapes(in: document.presentation).map {
                ($0.id, $0.frame.points.offsetBy(dx: offset.width, dy: offset.height))
            })
            state.setFrames(frames, in: &document.presentation)
            return .handled
        }
        if press.modifiers.contains(.command), press.characters.lowercased() == "a" {
            state.selectAllShapes(in: document.presentation)
            return .handled
        }
        switch press.key {
        case .upArrow, .leftArrow, .pageUp:
            step(forward: false)
        case .downArrow, .rightArrow, .pageDown:
            step(forward: true)
        default:
            return .ignored
        }
        return .handled
    }
}

/// Play, from the slide being edited; held, from the beginning instead.
private struct PlayMenu<Label: View>: View {
    let play: (Int) -> Void
    let current: () -> Int
    @ViewBuilder var label: () -> Label

    var body: some View {
        Menu {
            Button("Toolbar.PlayFromStart", systemImage: "backward.end") { play(0) }
            Button("Toolbar.PlayFromCurrent", systemImage: "play") { play(current()) }
        } label: {
            label()
        } primaryAction: {
            play(current())
        }
        .keyboardShortcut(.return, modifiers: [.command, .option])
        .accessibilityIdentifier("play")
        .accessibilityLabel("Toolbar.Play")
    }
}

/// What the toolbar's warning button says: which parts of the file Dazzle
/// keeps but cannot show or use.
///
/// A popover rather than an alert: nothing here needs deciding, so it has no
/// business stopping the user before they have seen their slides.
private struct UnsupportedFeatureNotice: View {
    var report: UnsupportedFeatureReport

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Notice.UnsupportedFeatures.Title", systemImage: "exclamationmark.triangle")
                .font(.headline)
                .labelStyle(.titleAndIcon)
            Text("Notice.UnsupportedFeatures.Intro")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Text(report.noticeMessage)
                .font(.callout)
                .foregroundStyle(.secondary)
                // A popover sizes itself to its content, and without this the
                // message is laid out on one unbroken line.
                .fixedSize(horizontal: false, vertical: true)
        }
        .multilineTextAlignment(.leading)
        .padding(20)
        .frame(idealWidth: 320, maxWidth: 360, alignment: .leading)
        // iPhone turns a popover into a sheet unless it is told not to.
        .presentationCompactAdaptation(.popover)
    }
}
