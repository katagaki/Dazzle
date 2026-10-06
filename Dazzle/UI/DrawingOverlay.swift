import PencilKit
import SwiftUI

/// Freehand drawing over the slide, with Apple Pencil or a finger.
///
/// The ink stays live while drawing. When done, it becomes a transparent
/// picture placed exactly where it was drawn, so it opens as a picture in
/// PowerPoint, Keynote, or anything else.
struct DrawingOverlay: View {
    /// View points per slide point.
    var scale: CGFloat
    let done: (PreparedMedia, CGRect) -> Void
    let cancel: () -> Void

    @State private var drawing = PKDrawing()

    var body: some View {
        DrawingCanvasView(drawing: $drawing)
            .overlay(alignment: .top) {
                HStack(spacing: 2) {
                    Button("Drawing.Cancel", role: .cancel, action: cancel)
                        .padding(.horizontal, 14)
                        .frame(height: 40)
                        .accessibilityIdentifier("cancelDrawing")
                    Divider().frame(height: 22)
                    Button("Drawing.Clear") { drawing = PKDrawing() }
                        .padding(.horizontal, 14)
                        .frame(height: 40)
                        .disabled(drawing.strokes.isEmpty)
                    Divider().frame(height: 22)
                    Button("Drawing.Done", action: finish)
                        .fontWeight(.semibold)
                        .padding(.horizontal, 14)
                        .frame(height: 40)
                        .disabled(drawing.strokes.isEmpty)
                        .accessibilityIdentifier("finishDrawing")
                }
                .buttonStyle(.plain)
                .glassEffect(.regular.interactive(), in: .capsule)
                .padding(.top, 10)
            }
    }

    private func finish() {
        let bounds = drawing.bounds.insetBy(dx: -4, dy: -4)
        guard !drawing.strokes.isEmpty, bounds.width > 0, bounds.height > 0 else { return cancel() }
        // Ink adapts to dark mode on screen; the picture has to keep the
        // colours as drawn, on a slide that is usually white.
        var image = UIImage()
        UITraitCollection(userInterfaceStyle: .light).performAsCurrent {
            image = drawing.image(from: bounds, scale: max(3, 2 / scale))
        }
        guard let png = image.pngData() else { return cancel() }
        let frame = CGRect(
            x: bounds.minX / scale, y: bounds.minY / scale, width: bounds.width / scale, height: bounds.height / scale
        )
        done(PreparedMedia(png: png, size: frame.size), frame)
    }
}

/// `PKCanvasView`, with the system tool picker.
private struct DrawingCanvasView: UIViewRepresentable {
    @Binding var drawing: PKDrawing

    func makeCoordinator() -> Coordinator { Coordinator(drawing: $drawing) }

    func makeUIView(context: Context) -> PKCanvasView {
        let canvas = PKCanvasView()
        canvas.backgroundColor = .clear
        canvas.isOpaque = false
        canvas.drawingPolicy = .anyInput
        // Ink is drawn as it will look on the slide, not inverted for dark mode.
        canvas.overrideUserInterfaceStyle = .light
        canvas.tool = PKInkingTool(.pen, color: .black, width: 5)
        canvas.drawing = drawing
        canvas.delegate = context.coordinator
        canvas.accessibilityIdentifier = "drawingCanvas"

        let picker = context.coordinator.toolPicker
        picker.overrideUserInterfaceStyle = .light
        picker.addObserver(canvas)
        picker.setVisible(true, forFirstResponder: canvas)
        Task { @MainActor in canvas.becomeFirstResponder() }
        return canvas
    }

    func updateUIView(_ canvas: PKCanvasView, context: Context) {
        if canvas.drawing != drawing { canvas.drawing = drawing }
    }

    static func dismantleUIView(_ canvas: PKCanvasView, coordinator: Coordinator) {
        coordinator.toolPicker.setVisible(false, forFirstResponder: canvas)
        coordinator.toolPicker.removeObserver(canvas)
        canvas.resignFirstResponder()
    }

    final class Coordinator: NSObject, PKCanvasViewDelegate {
        let toolPicker = PKToolPicker()
        var drawing: Binding<PKDrawing>

        init(drawing: Binding<PKDrawing>) {
            self.drawing = drawing
        }

        func canvasViewDrawingDidChange(_ canvasView: PKCanvasView) {
            drawing.wrappedValue = canvasView.drawing
        }
    }
}
