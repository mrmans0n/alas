import Foundation

@MainActor
enum ACPNewChatEmptyStatePolicy {
    static func isVisible(for session: ACPSession) -> Bool {
        guard !session.restoredFromPersistence else { return false }
        guard session.transcript.messages.isEmpty else { return false }
        guard session.hydrationState == .ready else { return false }
        guard session.lastError == nil else { return false }

        if case .ready = session.setupState {
            // continue
        } else {
            return false
        }

        if case .ready = session.agentState {
            return true
        }
        return false
    }
}
