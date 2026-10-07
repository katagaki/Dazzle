import SwiftUI
import UIKit

@main
struct DazzleApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        DazzleLaunchScene()
        DocumentGroup(newDocument: DazzleDocument()) { configuration in
            DeckView(document: configuration.$document, fileName: configuration.fileURL?.lastPathComponent)
        }
    }
}

final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        RemoteControlServer.shared.activate()
        return true
    }

    /// A display connected by cable or AirPlay arrives as a scene of its own.
    /// Giving it a delegate is what makes it show the audience's view rather
    /// than mirror the device; every other scene is left to SwiftUI.
    func application(
        _ application: UIApplication, configurationForConnecting connectingSceneSession: UISceneSession,
        options: UIScene.ConnectionOptions
    ) -> UISceneConfiguration {
        let configuration = UISceneConfiguration(name: nil, sessionRole: connectingSceneSession.role)
        if connectingSceneSession.role == .windowExternalDisplayNonInteractive {
            configuration.delegateClass = ExternalDisplaySceneDelegate.self
        }
        return configuration
    }
}
