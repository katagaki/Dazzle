import PhotosUI
import SwiftUI

/// The Liquid Glass bar that floats over the slide, keeping what is added
/// and changed most within thumb reach.
struct FloatingActionBar: View {
    @Binding var presentation: Presentation
    @Bindable var state: EditorState
    /// Lets the panels this bar opens zoom out of the button that opened them.
    var namespace: Namespace.ID

    @State private var photo: PhotosPickerItem?

    private static let selectionActionsID = "selectionActions"

    private var selectedShape: SlideShape? { state.selectedShape(in: presentation) }
    private var canEdit: Bool { state.selectedSlide(in: presentation)?.canEditShapes ?? false }

    var body: some View {
        // The full set of groups is wider than an iPhone, so the bar scrolls
        // sideways rather than clipping its end groups.
        ScrollViewReader { proxy in
            ScrollView(.horizontal) {
                GlassEffectContainer(spacing: 10) {
                    HStack(spacing: 10) {
                        insertGroup
                        slideGroup
                        if let selectedShape {
                            selectionGroup(for: selectedShape)
                                .id(Self.selectionActionsID)
                        }
                    }
                }
                .padding(.horizontal, 12)
                .animation(.snappy(duration: 0.2), value: state.selectedShapeID)
            }
            .scrollIndicators(.hidden)
            .scrollBounceBehavior(.basedOnSize)
            .onChange(of: state.selectedShapeID) { _, selected in
                guard selected != nil else { return }
                withAnimation(.snappy(duration: 0.3)) { proxy.scrollTo(Self.selectionActionsID, anchor: .trailing) }
            }
        }
        .frame(height: 56)
        .onChange(of: photo) { _, item in
            guard let item else { return }
            photo = nil
            Task { await insert(item) }
        }
    }

    // MARK: - Groups

    private var insertGroup: some View {
        group {
            action("character.textbox", label: "ActionBar.TextBox") {
                state.insertTextBox(in: &presentation)
            }
            .accessibilityIdentifier("insertTextBox")
            shapeMenu
            PhotosPicker(selection: $photo, matching: .images) {
                ActionSymbol(name: "photo", isOn: false)
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("insertPhoto")
            .accessibilityLabel("ActionBar.Photo")
            action("pencil.tip.crop.circle", isOn: state.isDrawing, label: "ActionBar.Draw") {
                state.selectedShapeID = nil
                state.presentedPanel = nil
                state.isDrawing = true
            }
            .accessibilityIdentifier("draw")
        }
        .disabled(!canEdit)
    }

    private var slideGroup: some View {
        group {
            panelAction("note.text", label: "ActionBar.Notes", panel: .notes)
                .accessibilityIdentifier("notes")
            panelAction("paintpalette", label: "ActionBar.Format", panel: .format)
                .accessibilityIdentifier("format")
        }
    }

    private func selectionGroup(for shape: SlideShape) -> some View {
        group {
            action(
                "checkmark.circle", isOn: state.isSelectingMultiple, label: "ActionBar.SelectMultiple"
            ) {
                state.isSelectingMultiple.toggle()
            }
            .accessibilityIdentifier("selectMultiple")
            if shape.canHoldText, shape.isEditable, !state.hasMultipleSelection {
                panelAction("character.cursor.ibeam", label: "ActionBar.EditText", panel: .text)
                    .accessibilityIdentifier("editText")
            }
            if shape.isEditable {
                AlignMenu(presentation: $presentation, state: state) {
                    ActionSymbol(name: "align.horizontal.left", isOn: false)
                }
                .menuStyle(.button)
                .buttonStyle(.plain)
                .accessibilityIdentifier("align")
                .accessibilityLabel("ActionBar.Align")
                arrangeMenu(for: shape)
                action("plus.square.on.square", label: "ActionBar.Duplicate") {
                    state.duplicateSelectedShape(in: &presentation)
                }
                .accessibilityIdentifier("duplicateShape")
            }
            action("trash", label: "ActionBar.Delete") {
                state.deleteSelectedShape(in: &presentation)
            }
            .accessibilityIdentifier("deleteShape")
        }
        .transition(.scale.combined(with: .opacity))
    }

    // MARK: - Menus

    private var shapeMenu: some View {
        Menu {
            ForEach(ShapeChoice.all) { choice in
                Button(choice.label, systemImage: choice.symbol) {
                    state.insertShape(choice.preset, in: &presentation)
                }
            }
        } label: {
            ActionSymbol(name: "square.on.circle", isOn: false)
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .accessibilityIdentifier("insertShape")
        .accessibilityLabel("ActionBar.Shape")
    }

    private func arrangeMenu(for shape: SlideShape) -> some View {
        Menu {
            Button("Arrange.Front", systemImage: "square.3.layers.3d.top.filled") {
                state.arrangeSelectedShape(.front, in: &presentation)
            }
            Button("Arrange.Forward", systemImage: "square.2.layers.3d.top.filled") {
                state.arrangeSelectedShape(.forward, in: &presentation)
            }
            Button("Arrange.Backward", systemImage: "square.2.layers.3d.bottom.filled") {
                state.arrangeSelectedShape(.backward, in: &presentation)
            }
            Button("Arrange.Back", systemImage: "square.3.layers.3d.bottom.filled") {
                state.arrangeSelectedShape(.back, in: &presentation)
            }
            if shape.canRotate, !state.hasMultipleSelection {
                RotateAndFlipButtons(presentation: $presentation, state: state)
            }
        } label: {
            ActionSymbol(name: "square.3.layers.3d", isOn: false)
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .accessibilityIdentifier("arrange")
        .accessibilityLabel("ActionBar.Arrange")
    }

    // MARK: - Building blocks

    private func group<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        HStack(spacing: 2) {
            content()
        }
        .padding(.horizontal, 4)
        .glassEffect(.regular.interactive(), in: .capsule)
    }


    private func action(
        _ name: String, isOn: Bool = false, label: LocalizedStringKey, perform: @escaping () -> Void
    ) -> some View {
        Button(action: perform) {
            ActionSymbol(name: name, isOn: isOn)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }

    /// A button that opens a panel and acts as that panel's zoom source.
    private func panelAction(_ name: String, label: LocalizedStringKey, panel: EditorPanel) -> some View {
        action(name, isOn: state.presentedPanel == panel, label: label) {
            state.presentedPanel = panel
        }
        .matchedTransitionSource(id: panel, in: namespace)
    }

    private func insert(_ item: PhotosPickerItem) async {
        guard let data = try? await item.loadTransferable(type: Data.self) else { return }
        let media = await Task.detached { PreparedMedia(data: data) }.value
        guard let media else {
            state.errorMessage = String(localized: "Error.UnreadablePicture")
            return
        }
        state.insertPicture(media, in: &presentation)
    }
}

/// Lining shapes up: with each other when several are selected, with the
/// slide when one is.
struct AlignMenu<Label: View>: View {
    @Binding var presentation: Presentation
    @Bindable var state: EditorState
    @ViewBuilder var label: () -> Label

    var body: some View {
        Menu {
            AlignButtons(presentation: $presentation, state: state)
        } label: {
            label()
        }
    }
}

struct AlignButtons: View {
    @Binding var presentation: Presentation
    @Bindable var state: EditorState

    private static let choices: [(EditorState.Alignment, LocalizedStringKey, String)] = [
        (.left, "Align.Left", "align.horizontal.left"),
        (.center, "Align.Center", "align.horizontal.center"),
        (.right, "Align.Right", "align.horizontal.right"),
        (.top, "Align.Top", "align.vertical.top"),
        (.middle, "Align.Middle", "align.vertical.center"),
        (.bottom, "Align.Bottom", "align.vertical.bottom"),
    ]

    var body: some View {
        Section(state.hasMultipleSelection ? "Align.ToEachOther" : "Align.ToSlide") {
            ForEach(Self.choices, id: \.2) { alignment, label, symbol in
                Button(label, systemImage: symbol) {
                    state.alignSelectedShapes(alignment, in: &presentation)
                }
            }
        }
        if state.selectedShapeIDs.count > 2 {
            Section {
                Button("Align.DistributeHorizontally", systemImage: "distribute.horizontal.center") {
                    state.distributeSelectedShapes(horizontally: true, in: &presentation)
                }
                Button("Align.DistributeVertically", systemImage: "distribute.vertical.center") {
                    state.distributeSelectedShapes(horizontally: false, in: &presentation)
                }
            }
        }
    }
}

/// Quarter turns and flips, for the arrange menu and the format panel.
struct RotateAndFlipButtons: View {
    @Binding var presentation: Presentation
    @Bindable var state: EditorState

    var body: some View {
        Section {
            Button("Arrange.RotateLeft", systemImage: "rotate.left") {
                state.rotateSelectedShape(clockwise: false, in: &presentation)
            }
            Button("Arrange.RotateRight", systemImage: "rotate.right") {
                state.rotateSelectedShape(clockwise: true, in: &presentation)
            }
            Button("Arrange.FlipHorizontal", systemImage: "arrow.left.and.right.righttriangle.left.righttriangle.right") {
                state.flipSelectedShape(horizontally: true, in: &presentation)
            }
            Button("Arrange.FlipVertical", systemImage: "arrow.up.and.down.righttriangle.up.righttriangle.down") {
                state.flipSelectedShape(horizontally: false, in: &presentation)
            }
        }
    }
}

/// A glyph in the action bar.
private struct ActionSymbol: View {
    let name: String
    let isOn: Bool

    var body: some View {
        Image(systemName: name)
            .font(.system(size: 15, weight: .medium))
            .frame(width: 40, height: 40)
            .foregroundStyle(isOn ? Color.accentColor : .primary)
            // A round highlight, so an active control reads as a lit key.
            .background(isOn ? Color.accentColor.opacity(0.2) : .clear, in: .circle)
            .contentShape(.circle)
    }
}

/// The shapes the Shape menu offers, by DrawingML preset.
struct ShapeChoice: Identifiable {
    let preset: String
    let label: LocalizedStringKey
    let symbol: String

    var id: String { preset }

    @MainActor static let all = [
        ShapeChoice(preset: "rect", label: "Shape.Rectangle", symbol: "rectangle"),
        ShapeChoice(preset: "roundRect", label: "Shape.RoundedRectangle", symbol: "rectangle.roundedtop"),
        ShapeChoice(preset: "ellipse", label: "Shape.Oval", symbol: "circle"),
        ShapeChoice(preset: "triangle", label: "Shape.Triangle", symbol: "triangle"),
        ShapeChoice(preset: "diamond", label: "Shape.Diamond", symbol: "diamond"),
        ShapeChoice(preset: "star5", label: "Shape.Star", symbol: "star"),
        ShapeChoice(preset: "rightArrow", label: "Shape.Arrow", symbol: "arrow.right"),
        ShapeChoice(preset: "wedgeRoundRectCallout", label: "Shape.Callout", symbol: "bubble.left"),
        ShapeChoice(preset: "line", label: "Shape.Line", symbol: "line.diagonal"),
    ]
}
