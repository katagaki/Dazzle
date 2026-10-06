import SwiftUI

/// A colour on offer in the format panels: one of the presentation's theme
/// colours, or one of the Human Interface Guidelines system colours.
///
/// Theme colours come first and are written as theme references, so text
/// coloured "Accent 1" still follows the theme in PowerPoint.
struct ColorChoice: Identifiable, Hashable {
    let id: String
    let label: String
    let value: DrawingColor
    /// What it looks like in this presentation.
    let display: Color

    static func themeChoices(in style: SlideStyleContext) -> [ColorChoice] {
        let slots: [(String, String)] = [
            ("tx1", "Color.Theme.Text"), ("bg1", "Color.Theme.Background"),
            ("tx2", "Color.Theme.Text2"), ("bg2", "Color.Theme.Background2"),
            ("accent1", "Color.Theme.Accent1"), ("accent2", "Color.Theme.Accent2"),
            ("accent3", "Color.Theme.Accent3"), ("accent4", "Color.Theme.Accent4"),
            ("accent5", "Color.Theme.Accent5"), ("accent6", "Color.Theme.Accent6"),
        ]
        return slots.map { slot, key in
            let value = DrawingColor.scheme(slot)
            return ColorChoice(
                id: "theme.\(slot)", label: String(localized: String.LocalizationValue(key)),
                value: value, display: Color(cgColor: style.color(value).cgColor)
            )
        }
    }

    /// The HIG system colours, light-appearance values: a stored colour has
    /// to mean one fixed thing in the file.
    static let system: [ColorChoice] = [
        ("red", "Color.Red", 0xFF3B30), ("orange", "Color.Orange", 0xFF9500),
        ("yellow", "Color.Yellow", 0xFFCC00), ("green", "Color.Green", 0x34C759),
        ("mint", "Color.Mint", 0x00C7BE), ("teal", "Color.Teal", 0x30B0C7),
        ("cyan", "Color.Cyan", 0x32ADE6), ("blue", "Color.Blue", 0x007AFF),
        ("indigo", "Color.Indigo", 0x5856D6), ("purple", "Color.Purple", 0xAF52DE),
        ("pink", "Color.Pink", 0xFF2D55), ("brown", "Color.Brown", 0xA2845E),
        ("black", "Color.Black", 0x000000), ("gray", "Color.Grey", 0x8E8E93),
        ("gray4", "Color.LightGrey", 0xD1D1D6), ("white", "Color.White", 0xFFFFFF),
    ].map { id, key, hex in
        ColorChoice(
            id: id, label: String(localized: String.LocalizationValue(key)), value: .rgb(UInt32(hex)),
            display: Color(cgColor: RGBAColor(hex: UInt32(hex)).cgColor)
        )
    }
}

/// A horizontal carousel of colour swatches, led by the system colour
/// picker. Runs edge to edge in a form row, as Tables' does.
struct ColorSwatches: View {
    let identifier: String
    let choices: [ColorChoice]
    /// The colour currently applied, so its swatch can show as chosen.
    let selected: DrawingColor?
    /// Offer "none" as a choice — for fills and outlines, not for text.
    var allowsNone = false
    var isNoneSelected = false
    let onSelect: (DrawingColor?) -> Void

    private let swatchSize: CGFloat = 28

    var body: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 10) {
                ColorPicker("ColorSwatches.MoreColours", selection: customColor, supportsOpacity: false)
                    .labelsHidden()
                    .frame(width: swatchSize, height: swatchSize)
                    .padding(3)
                    .accessibilityIdentifier("\(identifier).more")

                Divider().frame(height: swatchSize)

                if allowsNone { noneSwatch }

                ForEach(choices) { choice in
                    let isSelected = !isNoneSelected && selected == choice.value
                    Button {
                        onSelect(choice.value)
                    } label: {
                        Circle()
                            .fill(choice.display)
                            .frame(width: swatchSize, height: swatchSize)
                            .overlay(Circle().strokeBorder(Color.primary.opacity(0.15), lineWidth: 1))
                            .overlay {
                                if isSelected {
                                    Circle().strokeBorder(Color.accentColor, lineWidth: 3).padding(-3)
                                }
                            }
                            .padding(3)
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("\(identifier).\(choice.id)")
                    .accessibilityLabel(choice.label)
                    .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
        }
        .scrollIndicators(.hidden)
        .listRowInsets(EdgeInsets())
    }

    private var customColor: Binding<Color> {
        Binding(
            get: { choices.first { $0.value == selected }?.display ?? .accentColor },
            set: { color in
                let resolved = color.resolve(in: EnvironmentValues())
                let rgb = RGBAColor(red: Double(resolved.red), green: Double(resolved.green), blue: Double(resolved.blue))
                onSelect(.rgb(rgb.hexValue))
            }
        )
    }

    /// "No colour": an empty ring with a rule through it.
    private var noneSwatch: some View {
        Button {
            onSelect(nil)
        } label: {
            Circle()
                .strokeBorder(Color.secondary.opacity(0.55), lineWidth: 1.5)
                .overlay {
                    Path { path in
                        let inset = swatchSize / 2 * (1 - 1 / sqrt(2))
                        path.move(to: CGPoint(x: inset, y: swatchSize - inset))
                        path.addLine(to: CGPoint(x: swatchSize - inset, y: inset))
                    }
                    .stroke(Color.red.opacity(0.8), style: StrokeStyle(lineWidth: 1.5, lineCap: .round))
                }
                .frame(width: swatchSize, height: swatchSize)
                .overlay {
                    if isNoneSelected {
                        Circle().strokeBorder(Color.accentColor, lineWidth: 3).padding(-3)
                    }
                }
                .padding(3)
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("\(identifier).none")
        .accessibilityLabel("ColorSwatches.None")
        .accessibilityAddTraits(isNoneSelected ? [.isButton, .isSelected] : .isButton)
    }
}
