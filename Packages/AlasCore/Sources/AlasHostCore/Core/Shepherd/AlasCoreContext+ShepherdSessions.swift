import Foundation
import AlasModel
import AlasAgents
import AlasSessions
import AlasIntegrations

/// How the PR and stack shepherds reach their chat sessions: prompt
/// delivery and the busy/idle judgement. The caller resolves the worktree's
/// session manager.
extension AlasCoreContext {
    /// Queues `prompt` on the session as a shepherd prompt, shown as its
    /// card. Hydrates a session with no open tab, like the orchestration
    /// coordinator's delivery, then brings its agent up the way the composer
    /// does, which claims the writer lease, so the prompt runs after any turn
    /// in progress. `.failed` when the session is missing or archived, when
    /// another instance owns it (this one is a read-only mirror), or when the
    /// queue could not be saved under the lease. `.superseded` when
    /// `isStillWanted` turns false while the session is brought up.
    public func deliverShepherdPrompt(
        sessionID: String,
        worktreeID: String,
        prompt: ShepherdPrompt,
        isStillWanted: @MainActor () -> Bool,
        in manager: ACPSessionManager
    ) async -> ReviewShepherd.Delivery {
        guard let row = await manager.persistedSessionRow(id: sessionID),
              !row.archived,
              manager.placeholderSession(id: sessionID) != nil
        else { return .failed }
        await manager.hydrateIfNeeded(id: sessionID)
        guard manager.liveSession(for: sessionID)?.hydrationState == .ready else { return .failed }
        // Attaches an idle, disconnected or failed agent, claiming the writer
        // lease first; a no-op while it is spawning or ready. When another
        // instance holds the lease, the attach leaves a mirror without one and
        // the fenced enqueue below refuses.
        await manager.reattach(to: sessionID)
        // The enqueue waits for a transcript backfill before touching the
        // queue; drain it here so the check below is the last suspension.
        await manager.awaitBackfill(id: sessionID)
        // Stop, rebind or a newer decision while the session came up: the
        // queue is left alone.
        guard isStillWanted() else { return .superseded }
        let recordKey = stackShepherd.record(forSession: sessionID).flatMap { $0.isFinished ? nil : $0.id.storageKey }
            ?? reviewShepherd.record(forSession: sessionID)?.id.storageKey
            ?? worktreeID
        let source = ACPDelegatedPromptSource.shepherd(recordKey: recordKey, messageID: UUID(), card: prompt.card)
        let queued = await manager.enqueueDelegatedPrompt(text: prompt.text, source: source, into: sessionID, requiringWriter: true)
        return queued ? .delivered : .failed
    }

    public func shepherdSessionState(sessionID: String, in manager: ACPSessionManager) async -> ShepherdSessionState {
        guard let row = await manager.persistedSessionRow(id: sessionID) else { return .missing }
        if row.archived { return .archived }
        guard let placeholder = manager.liveSession(for: sessionID) else {
            return row.directTurnInFlight ? .busy : .idle
        }
        // A loading placeholder has an idle transcript and an empty queue
        // until its persisted state is restored.
        if placeholder.hydrationState == .loading {
            await manager.hydrateIfNeeded(id: sessionID)
        }
        if let session = manager.liveSession(for: sessionID), session.hydrationState == .ready {
            return Self.shepherdSessionIsBusy(session, now: Date()) ? .busy : .idle
        }
        // Hydration did not finish: judge by the stored turn marker and queue.
        if row.directTurnInFlight { return .busy }
        let queue = (try? await manager.persistence.loadQueue(sessionId: sessionID)) ?? []
        return queue.contains { Self.shepherdQueueItemIsDue($0, now: Date()) } ? .busy : .idle
    }

    /// Busy while a turn runs or waits on the user, while the agent starts,
    /// or while a ready agent has a queued prompt (a shepherd prompt
    /// included) that has not started. A prompt held behind an agent that
    /// failed, disconnected or never attached is not busy, so a stuck fix
    /// ends in a no-progress escalation instead of waiting forever.
    private static func shepherdSessionIsBusy(_ session: ACPSession, now: Date) -> Bool {
        if session.transcript.streamingState != .idle { return true }
        switch session.agentState {
        case .spawning:
            return true
        case .ready:
            return session.queue.contains { shepherdQueueItemIsDue($0, now: now) }
        case .idle, .disconnected, .failed:
            return false
        }
    }

    /// A queued prompt that will run as soon as the agent is free: no error,
    /// not scheduled for later.
    private static func shepherdQueueItemIsDue(_ item: QueuedPrompt, now: Date) -> Bool {
        item.lastError == nil && (item.scheduledAt ?? .distantPast) <= now
    }
}
