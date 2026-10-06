import Foundation
import WatchConnectivity

/// The iPhone's end of the watch remote: tells the watch where the
/// slideshow is, and carries out what the watch asks.
@MainActor
final class RemoteControlServer: NSObject {
    static let shared = RemoteControlServer()

    private var lastPublished: RemoteState?

    func activate() {
        guard WCSession.isSupported() else { return }
        WCSession.default.delegate = self
        WCSession.default.activate()
    }

    func publish(_ state: RemoteState) {
        guard state != lastPublished else { return }
        lastPublished = state
        send(state)
    }

    private func send(_ state: RemoteState) {
        let session = WCSession.default
        guard WCSession.isSupported(), session.activationState == .activated,
              session.isPaired, session.isWatchAppInstalled else { return }
        // The application context always holds the latest state, so a watch
        // that was asleep catches up as soon as it wakes.
        try? session.updateApplicationContext(state.context)
    }

    fileprivate func sessionActivated() {
        if let lastPublished { send(lastPublished) }
    }
}

extension RemoteControlServer: WCSessionDelegate {
    nonisolated func session(
        _ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: (any Error)?
    ) {
        guard activationState == .activated else { return }
        Task { @MainActor in self.sessionActivated() }
    }

    nonisolated func sessionDidBecomeInactive(_ session: WCSession) {
        // Nothing to tidy: the next activation sends the state again.
    }

    nonisolated func sessionDidDeactivate(_ session: WCSession) {
        // Switching watches deactivates the session; take up the new one.
        session.activate()
    }

    nonisolated func session(_ session: WCSession, didReceiveMessage message: [String: Any]) {
        guard let command = RemoteCommand(message: message) else { return }
        Task { @MainActor in PresentationSession.shared.handle(command) }
    }
}
