import Foundation

@MainActor
enum ACPFirstRunConnectingPolicy {
    static func isVisible(for session: ACPSession) -> Bool {
        phase(for: session) != nil
    }

    static func phase(for session: ACPSession) -> ACPFirstRunConnectingPhase? {
        guard !session.restoredFromPersistence else { return nil }
        guard session.transcript.messages.isEmpty else { return nil }
        guard session.lastError == nil else { return nil }

        if case .failed = session.hydrationState { return nil }
        if case .needsSetup = session.setupState { return nil }
        if case .needsAuth = session.setupState { return nil }
        if case .disconnected = session.agentState { return nil }
        if case .failed = session.agentState { return nil }
        if case .ready = session.agentState { return nil }

        if let explicit = session.firstRunConnectingPhase {
            return explicit
        }

        guard ACPSessionAttachFreshness.isFresh(
            restoredFromPersistence: session.restoredFromPersistence,
            remoteSessionId: session.remoteSessionId
        ) else {
            return nil
        }

        if case .loading = session.hydrationState {
            return .checkingSetup
        }
        if case .checking = session.setupState {
            return .checkingSetup
        }
        if case .spawning = session.agentState {
            return .launchingAdapter
        }
        if case .idle = session.agentState {
            return .checkingSetup
        }
        return nil
    }

    static func showsChrome(firstRunConnecting: Bool) -> Bool {
        !firstRunConnecting
    }

    static func composerPlacement(
        firstRunConnecting: Bool,
        newEmptySession: Bool
    ) -> ACPComposerPlacement {
        (firstRunConnecting || newEmptySession) ? .raisedEmpty : .bottom
    }
}
