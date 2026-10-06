import SwiftUI
import WatchKit

/// The remote: the slide on screen, where the presentation is up to, and
/// buttons to move through it. The Digital Crown and the double-tap gesture
/// move forward too, so the remote works without looking at it.
struct RemoteView: View {
    @State private var connection = RemoteConnection.shared
    @State private var crown = 0.0
    @State private var crownAnchor = 0.0

    private var state: RemoteState { connection.state }

    var body: some View {
        NavigationStack {
            Group {
                if state.isPresenting {
                    presenting
                } else {
                    idle
                }
            }
            .navigationTitle("Remote.Title")
            .navigationBarTitleDisplayMode(.inline)
        }
        .onChange(of: state.slideNumber) { old, new in
            guard old != 0, new != 0 else { return }
            WKInterfaceDevice.current().play(new > old ? .directionUp : .directionDown)
        }
    }

    // MARK: - Presenting

    private var presenting: some View {
        VStack(spacing: 6) {
            thumbnail
            HStack {
                Text(String(format: String(localized: "Remote.Position"), state.slideNumber, state.slideCount))
                    .font(.footnote.weight(.semibold))
                    .accessibilityIdentifier("slidePosition")
                Spacer()
                if let startedAt = state.startedAt {
                    Text(startedAt, style: .timer)
                        .font(.footnote.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
            HStack(spacing: 6) {
                Button {
                    send(.previous)
                } label: {
                    Image(systemName: "chevron.backward")
                        .frame(maxWidth: .infinity)
                }
                .disabled(state.slideNumber <= 1)
                .accessibilityLabel("Remote.Previous")

                Button {
                    send(.next)
                } label: {
                    Image(systemName: "chevron.forward")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                // A double tap of finger and thumb moves on, hands free.
                .handGestureShortcut(.primaryAction)
                .accessibilityLabel("Remote.Next")
            }
            .controlSize(.large)
        }
        .padding(.horizontal, 4)
        .focusable()
        .digitalCrownRotation(
            $crown, from: -10_000, through: 10_000, by: 1, sensitivity: .low,
            isContinuous: true, isHapticFeedbackEnabled: true
        )
        .onChange(of: crown) { _, value in
            // A full detent of the crown moves one slide.
            let steps = (value - crownAnchor).rounded(.towardZero)
            guard abs(steps) >= 1 else { return }
            crownAnchor = value
            send(steps > 0 ? .next : .previous)
        }
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button("Remote.End", systemImage: "xmark") { send(.end) }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button(
                    state.isBlanked ? "Remote.Unblank" : "Remote.Blank",
                    systemImage: state.isBlanked ? "eye" : "eye.slash"
                ) {
                    send(.toggleBlank)
                }
            }
        }
    }

    @ViewBuilder
    private var thumbnail: some View {
        let shape = RoundedRectangle(cornerRadius: 8, style: .continuous)
        Group {
            if state.isBlanked {
                shape.fill(.black)
                    .overlay {
                        Image(systemName: "eye.slash")
                            .foregroundStyle(.secondary)
                    }
            } else if let data = state.thumbnail, let image = UIImage(data: data) {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
                    .clipShape(shape)
            } else {
                shape.fill(.quaternary)
            }
        }
        .aspectRatio(16 / 9, contentMode: .fit)
        .overlay(shape.strokeBorder(.white.opacity(0.15)))
        .accessibilityHidden(true)
    }

    // MARK: - Idle

    private var idle: some View {
        ScrollView {
            VStack(spacing: 10) {
                Image(systemName: "play.rectangle.on.rectangle")
                    .font(.system(size: 34))
                    .foregroundStyle(.tint)
                Text("Remote.Idle.Title")
                    .font(.headline)
                    .multilineTextAlignment(.center)
                Text(connection.isReachable ? "Remote.Idle.Message" : "Remote.Idle.Unreachable")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                if state.canStart && connection.isReachable {
                    Button("Remote.Start", systemImage: "play.fill") { send(.start) }
                        .buttonStyle(.borderedProminent)
                        .padding(.top, 4)
                }
            }
            .padding(.horizontal, 6)
        }
    }

    private func send(_ command: RemoteCommand) {
        WKInterfaceDevice.current().play(.click)
        connection.send(command)
    }
}
