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
        let stop = session.$usageLimit.map { $0 != nil }.removeDuplicates()
            .combineLatest(resumeScheduled, session.$turnFailure.removeDuplicates())
            .map { IdleStop(limited: $0, resumeScheduled: $1, failure: $2) }
        // Read from the published values: a tracked property's signal fires
        // before the session stores the new value. Constant for sessions that
        // do not settle at result, so they see no extra emissions.
        let background = session.$backgroundTasks
            .combineLatest(session.$liveSubagentCount, session.$agentState, session.$settlesAtResult)
            .map { tasks, liveChildren, agentState, settles in
                BackgroundWork(
                    working: ACPSessionActivity.project(
                        foreground: .idle, settlesAtResult: settles, agentReady: agentState == .ready,
                        backgroundTasks: tasks, liveSubagentCount: liveChildren
                    ).backgroundWorking,
                    agentLost: settles && agentState != .ready
                )
            }
            .removeDuplicates()
        sessionCancellables[session.id] = session.$readOnlyRestricted
            .combineLatest(session.transcript.$streamingState, stop, background)
            .filter { restricted, _, _, _ in !restricted }
            .sink { [weak self, weak session] _, state, stop, background in
                guard let self, let session else { return }
                self.apply(state: state, stop: stop, background: background, session: session, isSnapshot: isSnapshot)
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

    /// Why an idle session stopped, when it is not a normal finish.
    private struct IdleStop: Equatable {
        let limited: Bool
        let resumeScheduled: Bool
        let failure: String?
    }

    /// Work a turn that settled at its result left running.
    private struct BackgroundWork: Equatable {
        let working: Bool
        /// The agent is no longer ready; `session.agentState` may still read
        /// the old value while this change is delivered.
        let agentLost: Bool
    }

    private func apply(
        state: ACPSession.StreamingState,
        stop: IdleStop,
        background: BackgroundWork,
        session: ACPSession,
        isSnapshot: Bool
    ) {
        let agent = Self.agentKind(for: session.agentId)
        let previousState = harness.activityBySession[session.id]?.state
        switch state {
        case .idle where background.working && stop.failure == nil && !stop.limited:
            // The turn settled at its result but its children or an
            // autonomous cycle still run: stay busy, and finish once all
            // work ends so the follow-up answer is what notifies.
            acknowledgeIfUserAddressedAttention(previousState: previousState, session: session, isSnapshot: isSnapshot)
            harness.setExternalActivity(sessionId: session.id, owner: session.owner, agent: agent, state: .busy, isSnapshot: isSnapshot)
        case .idle:
            if let failure = stop.failure {
                // A failed turn is not a finish: keep the badge until the next
                // turn replaces it. It is checked first because it always
                // describes the latest turn, while a usage limit outlives a
                // failed resume.
                harness.setExternalActivity(
                    sessionId: session.id, owner: session.owner, agent: agent, state: .failed,
                    body: failure, isSnapshot: isSnapshot
                )
                return
            }
            if stop.limited {
                // A limit is not a finish either: no completion history, keep a badge.
                harness.setExternalActivity(
                    sessionId: session.id, owner: session.owner, agent: agent, state: .limited,
                    isSnapshot: isSnapshot, requiresUserInput: !stop.resumeScheduled
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
                recordIdleTransition: !isSnapshot && session.agentState == .ready && !background.agentLost
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
              previousState == .awaitingInput || previousState == .permissionRequest || previousState == .failed
        else { return }
        acknowledgeSessionInteraction(session.owner, session.id)
    }

    static func agentKind(for agentId: String) -> AgentKind { AgentKind(acpAgentID: agentId) }
}
