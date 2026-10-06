import SwiftUI

/// A slide, drawn to fill the view. Give it the slide's aspect ratio.
struct SlideView: View {
    var presentation: Presentation
    var slide: Slide
    var options = SlideRenderer.Options.presentation

    var body: some View {
        Canvas(rendersAsynchronously: false) { context, size in
            context.withCGContext { cgContext in
                SlideRenderer(presentation: presentation, slide: slide, options: options).draw(in: cgContext, size: size)
            }
        }
        .accessibilityElement()
        .accessibilityLabel(slide.title ?? String(localized: "Slide.Untitled"))
    }
}

/// A slide thumbnail with its number, as the slide navigator shows it.
struct SlideThumbnail: View {
    var presentation: Presentation
    var slide: Slide
    var number: Int
    var isSelected: Bool

    var body: some View {
        SlideView(presentation: presentation, slide: slide)
            .aspectRatio(presentation.slideSize.aspectRatio, contentMode: .fit)
            .opacity(slide.isHidden ? 0.45 : 1)
            .clipShape(.rect(cornerRadius: 6, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .strokeBorder(isSelected ? Color.accentColor : Color.primary.opacity(0.12), lineWidth: isSelected ? 3 : 1)
            }
            .overlay(alignment: .bottomTrailing) {
                if slide.isHidden {
                    Image(systemName: "eye.slash.fill")
                        .font(.system(size: 10, weight: .semibold))
                        .padding(4)
                        .background(.regularMaterial, in: .circle)
                        .padding(4)
                }
            }
            .accessibilityElement()
            .accessibilityLabel(String(
                format: String(localized: "Slide.Accessibility"), number, slide.title ?? String(localized: "Slide.Untitled")
            ))
            .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }
}
