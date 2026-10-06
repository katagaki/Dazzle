import Foundation
import WatchConnectivity

/// The watch's end of the remote: receives the slideshow's state from the
/// iPhone and sends it commands.
@MainActor
@Observable
final class RemoteConnection: NSObject {
    static let shared = RemoteConnection()

    private(set) var state = RemoteState.idle
    private(set) var isReachable = false
    /// Set when a command could not be delivered, until the next one is.
    private(set) var deliveryFailed = false

    func activate() {
        guard WCSession.isSupported() else { return }
        WCSession.default.delegate = self
        WCSession.default.activate()
    }

    func send(_ command: RemoteCommand) {
        let session = WCSession.default
        guard session.activationState == .activated, session.isReachable else {
            deliveryFailed = true
            return
        }
        deliveryFailed = false
        session.sendMessage(command.message, replyHandler: nil) { [weak self] _ in
            Task { @MainActor in self?.deliveryFailed = true }
        }
    }

    fileprivate func update(state: RemoteState?, isReachable: Bool) {
        if let state { self.state = state }
        self.isReachable = isReachable
        if isReachable { deliveryFailed = false }
    }
}

extension RemoteConnection: WCSessionDelegate {
    nonisolated func session(
        _ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: (any Error)?
    ) {
        let state = session.receivedApplicationContext.isEmpty ? nil : RemoteState(context: session.receivedApplicationContext)
        let isReachable = session.isReachable
        Task { @MainActor in self.update(state: state, isReachable: isReachable) }
    }

    nonisolated func session(_ session: WCSession, didReceiveApplicationContext applicationContext: [String: Any]) {
        let state = RemoteState(context: applicationContext)
        let isReachable = session.isReachable
        Task { @MainActor in self.update(state: state, isReachable: isReachable) }
    }

    nonisolated func sessionReachabilityDidChange(_ session: WCSession) {
        let isReachable = session.isReachable
        Task { @MainActor in self.update(state: nil, isReachable: isReachable) }
    }
}
