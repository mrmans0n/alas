import Foundation
import Combine

/// Bridge from ACP session activity (`ACPSession.streamingState`) into the
/// `HarnessService` activity dictionary, so worktree work badges in the
/// sidebar surface ACP work alongside terminal-harness work.
///
/// Manager-attach (Task 3) wires this into `AppState.acpManager(for:)` so
/// every session that enters a manager's `sessions` dict gets observed
/// automatically. Detach removes the entry from `HarnessService` so the
/// badge disappears when the session is closed.
@MainActor
final class ACPHarnessBridge {
    private let harness: HarnessService
    private var sessionCancellables: [ACPSession.ID: AnyCancellable] = [:]
    private var managerCancellables: [String: AnyCancellable] = [:]
    private var observedSessionsByManager: [String: Set<ACPSession.ID>] = [:]

    init(harness: HarnessService) {
        self.harness = harness
    }

    /// Subscribe to a session's `streamingState` and mirror it into the
    /// harness service. Idempotent — re-observing a session replaces the
    /// existing subscription.
    func observe(session: ACPSession) {
        sessionCancellables[session.id] = session.transcript.$streamingState
            .sink { [weak self, weak session] state in
                guard let self, let session else { return }
                self.apply(state: state, session: session)
            }
    }

    /// Stop observing a session and drop its harness entry. Called when
    /// the session leaves its manager's `sessions` dict.
    func forget(sessionId: ACPSession.ID) {
        sessionCancellables[sessionId] = nil
        harness.forgetSession(sessionId)
    }

    /// Attach a manager. Subscribes to its `$sessions` so every session
    /// that ever enters the dict gets observed, and every session that
    /// leaves gets forgotten. Idempotent per worktree.
    func attach(manager: ACPSessionManager) {
        let worktreeId = manager.worktreeId
        // Drop any prior attachment for the same worktree to avoid double-subs.
        detach(worktreeId: worktreeId)

        managerCancellables[worktreeId] = manager.$sessions
            .sink { [weak self] sessions in
                guard let self else { return }
                self.reconcile(worktreeId: worktreeId, sessions: sessions)
            }
    }

    /// Detach a manager. Cancels the sessions-dict subscription and forgets
    /// every session previously observed for that worktree.
    func detach(worktreeId: String) {
        managerCancellables[worktreeId] = nil
        if let ids = observedSessionsByManager.removeValue(forKey: worktreeId) {
            for id in ids { forget(sessionId: id) }
        }
    }

    private func reconcile(worktreeId: String, sessions: [ACPSession.ID: ACPSession]) {
        let current = Set(sessions.keys)
        let previous = observedSessionsByManager[worktreeId] ?? []

        // Newly added: observe.
        for id in current.subtracting(previous) {
            if let session = sessions[id] { observe(session: session) }
        }
        // Removed: forget.
        for id in previous.subtracting(current) {
            forget(sessionId: id)
        }
        observedSessionsByManager[worktreeId] = current
    }

    private func apply(state: ACPSession.StreamingState, session: ACPSession) {
        let agent = Self.agentKind(for: session.agentId)
        switch state {
        case .idle:
            harness.forgetSession(session.id)
        case .sending, .streaming:
            harness.setExternalActivity(sessionId: session.id, agent: agent, state: .busy)
        case .awaitingPermission:
            harness.setExternalActivity(sessionId: session.id, agent: agent, state: .permissionRequest)
        }
    }

    /// Map the ACP `agentId` string (free-form, sourced from
    /// `AgentBuiltins.catalog`) to `AgentKind`. Unknown ids fall back to
    /// `.claude` — badge rendering is state-driven, not agent-driven, so
    /// the only consumer of `agent` is the click-activation path which
    /// works purely off `sessionId`.
    static func agentKind(for agentId: String) -> AgentKind {
        switch agentId {
        case "claude":       return .claude
        case "codex":        return .codex
        case "cursor-agent": return .cursor
        case "gemini":       return .gemini
        case "opencode":     return .opencode
        case "pi":           return .pi
        case "copilot":      return .copilot
        default:             return .claude
        }
    }
}
