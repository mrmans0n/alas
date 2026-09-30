import Foundation

@MainActor
enum ACPNewChatEmptyStatePolicy {
    static func isVisible(for session: ACPSession) -> Bool {
        guard !session.restoredFromPersistence else { return false }
        guard session.transcript.messages.isEmpty else { return false }
        // A queued prompt (plain or scheduled) means the user has already
        // addressed this session; the transcript shows its queue rows, so
        // the "What should we work on?" intro must yield to it. A queued
        // delegated prompt has no row but still addresses the session, so
        // it hides the intro too.
        guard session.queue.isEmpty else { return false }
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
