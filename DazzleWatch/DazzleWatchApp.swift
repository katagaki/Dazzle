import SwiftUI

@main
struct DazzleWatchApp: App {
    init() {
        RemoteConnection.shared.activate()
    }

    var body: some Scene {
        WindowGroup {
            RemoteView()
        }
    }
}
