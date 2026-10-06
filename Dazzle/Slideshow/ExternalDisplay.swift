import SwiftUI
import UIKit

/// Drives a connected display — AirPlay, or a cable — with the audience's
/// view of the slideshow, instead of a mirror of the device.
final class ExternalDisplaySceneDelegate: NSObject, UIWindowSceneDelegate {
    var window: UIWindow?

    func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options connectionOptions: UIScene.ConnectionOptions) {
        guard let windowScene = scene as? UIWindowScene else { return }
        let window = UIWindow(windowScene: windowScene)
        let host = UIHostingController(rootView: AudienceView(session: PresentationSession.shared, showsIdleBrand: true))
        host.view.backgroundColor = .black
        window.rootViewController = host
        window.isHidden = false
        self.window = window
        PresentationSession.shared.externalDisplayConnected()
    }

    func sceneDidDisconnect(_ scene: UIScene) {
        window = nil
        PresentationSession.shared.externalDisplayDisconnected()
    }
}

/// What the audience sees: the current slide, as large as it goes, on black.
struct AudienceView: View {
    var session: PresentationSession
    /// Between slideshows, an external display shows the app's mark rather
    /// than nothing, so the presenter can tell it is connected.
    var showsIdleBrand = false

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if session.isPresenting, let presentation = session.presentation, let slide = session.currentSlide {
                if !session.isBlanked {
                    SlideView(presentation: presentation, slide: slide)
                        .aspectRatio(presentation.slideSize.aspectRatio, contentMode: .fit)
                        .id(slide.id)
                        .transition(.opacity)
                }
            } else if showsIdleBrand {
                VStack(spacing: 12) {
                    Image(systemName: "play.rectangle.on.rectangle")
                        .font(.system(size: 64, weight: .light))
                    Text("ExternalDisplay.Idle")
                        .font(.title3)
                }
                .foregroundStyle(.white.opacity(0.35))
            }
        }
        .animation(.easeInOut(duration: 0.25), value: session.currentSlide?.id)
        .animation(.easeInOut(duration: 0.25), value: session.isBlanked)
        .ignoresSafeArea()
        .persistentSystemOverlays(.hidden)
    }
}
