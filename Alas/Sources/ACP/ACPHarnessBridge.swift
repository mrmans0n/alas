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
    private let acknowledgeSessionInteraction: (SessionOwnerID, ACPSession.ID) -> Void
    private var sessionCancellables: [ACPSession.ID: AnyCancellable] = [:]
    private var managerCancellables: [String: AnyCancellable] = [:]
    private var observedSessionsByManager: [String: Set<ACPSession.ID>] = [:]

    init(
        harness: HarnessService,
        acknowledgeSessionInteraction: @escaping (SessionOwnerID, ACPSession.ID) -> Void = { _, _ in }
    ) {
        self.harness = harness
        self.acknowledgeSessionInteraction = acknowledgeSessionInteraction
    }

    /// Subscribe to a session's `streamingState` and mirror it into the
    /// harness service. Idempotent — re-observing a session replaces the
    /// existing subscription.
    func observe(session: ACPSession) {
        var isSnapshot = true
        // Hidden `/btw` side sessions never badge or notify; a promoted one
        // starts reporting from its current state.
        let resumeScheduled = session.$queue
            .map { $0.contains { $0.usageLimit != nil } }
            .removeDuplicates()
        sessionCancellables[session.id] = session.$readOnlyRestricted
            .combineLatest(
                session.transcript.$streamingState,
                session.$usageLimit.map { $0 != nil }.removeDuplicates(),
                resumeScheduled
            )
            .filter { restricted, _, _, _ in !restricted }
            .sink { [weak self, weak session] _, state, limited, resumeScheduled in
                guard let self, let session else { return }
                self.apply(state: state, limited: limited, resumeScheduled: resumeScheduled,
                           session: session, isSnapshot: isSnapshot)
                isSnapshot = false
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

    private func apply(
        state: ACPSession.StreamingState, limited: Bool, resumeScheduled: Bool, session: ACPSession, isSnapshot: Bool) {
        let agent = Self.agentKind(for: session.agentId)
        let previousState = harness.activityBySession[session.id]?.state
        switch state {
        case .idle:
            if limited {
                // A limit is not a finish: no completion history, keep a badge.
                harness.setExternalActivity(
                    sessionId: session.id, owner: session.owner, agent: agent, state: .limited,
                    isSnapshot: isSnapshot, requiresUserInput: !resumeScheduled
                )
                return
            }
            // A completed turn and removal both clear the badge, but only a
            // real transition to idle contributes completion history.
            acknowledgeIfUserAddressedAttention(previousState: previousState, session: session, isSnapshot: isSnapshot)
            harness.finishExternalActivity(
                sessionId: session.id,
                owner: session.owner,
                agent: agent,
                recordIdleTransition: !isSnapshot && session.agentState == .ready
                    && harness.activityBySession[session.id] != nil
            )
        case .sending, .streaming:
            acknowledgeIfUserAddressedAttention(previousState: previousState, session: session, isSnapshot: isSnapshot)
            harness.setExternalActivity(sessionId: session.id, owner: session.owner, agent: agent, state: .busy, isSnapshot: isSnapshot)
        case .awaitingPermission:
            harness.setExternalActivity(sessionId: session.id, owner: session.owner, agent: agent, state: .permissionRequest, isSnapshot: isSnapshot, requiresUserInput: true)
        case .awaitingInput:
            harness.setExternalActivity(sessionId: session.id, owner: session.owner, agent: agent, state: .awaitingInput, isSnapshot: isSnapshot, requiresUserInput: true)
        }
    }

    private func acknowledgeIfUserAddressedAttention(
        previousState: ActivityState?,
        session: ACPSession,
        isSnapshot: Bool
    ) {
        guard !isSnapshot,
              previousState == .awaitingInput || previousState == .permissionRequest
        else { return }
        acknowledgeSessionInteraction(session.owner, session.id)
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
        case "omp":          return .omp
        case "copilot":      return .copilot
        default:             return .claude
        }
    }
}
