import AppKit
import Combine
import Foundation
import os

private let sessionRecapLogger = Logger(subsystem: "io.nlopez.alas", category: "session-recap")

/// Lifetimes for the return-recap trigger. Independent of local-text
/// observers: seen-tracking must keep working while local text is off.
@MainActor
final class SessionRecapRuntime {
    /// App-focus and power-state notification observers.
    var sessionRecapObservers: [AnyCancellable] = []
    /// One in-flight return check per session, so a seen/unseen flap never
    /// stacks two waits.
    private var pendingChecks: [ACPSession.ID: (token: UUID, task: Task<Void, Never>)] = [:]
    /// Owner of each session the precompute scheduler holds, so a job can
    /// find its manager even when the session is not loaded.
    var precomputeOwners: [ACPSession.ID: SessionOwnerID] = [:]
    /// Activity observation for each scheduled session that was live when
    /// it was scheduled, keyed to the session object it observes.
    var precomputeActivity: [ACPSession.ID: (session: ObjectIdentifier, subscription: ChangeSubscription)] = [:]
    /// Away origin of each offered return recap that has not settled yet.
    /// Leaving mid-load resets the seen tracker's clock, so this keeps the
    /// original origin until the card reaches a result, is dismissed, or a
    /// prompt cancels it.
    var pendingRecapAwayOrigin: [ACPSession.ID: Date] = [:]

    func startCheck(sessionId: ACPSession.ID, _ operation: @escaping @MainActor (UUID) async -> Void) {
        cancelCheck(sessionId: sessionId)
        let token = UUID()
        pendingChecks[sessionId] = (token, Task { await operation(token) })
    }

    func cancelCheck(sessionId: ACPSession.ID) {
        pendingChecks.removeValue(forKey: sessionId)?.task.cancel()
    }

    /// Drops the entry only if it still belongs to the finishing check.
    func finishCheck(sessionId: ACPSession.ID, token: UUID) {
        guard pendingChecks[sessionId]?.token == token else { return }
        pendingChecks[sessionId] = nil
    }
}

/// Whether a returning session can be checked for a recap yet. Idleness and
/// the coordinator both need hydrated history and a connected agent. Agent
/// readiness also implies the tail-first transcript backfill is done:
/// `ACPSessionManager.attach` awaits the backfill before it marks the agent
/// `.ready`.
enum SessionRecapReadiness: Equatable {
    case ready
    case waiting
    case failed

    static func readiness(
        hydration: ACPSession.HydrationState,
        agent: ACPSession.AgentState,
        setup: ACPSession.SetupState
    ) -> SessionRecapReadiness {
        switch (hydration, agent, setup) {
        case (.failed, _, _), (_, .failed, _),
             (_, _, .needsSetup), (_, _, .setupError), (_, _, .needsAuth):
            return .failed
        case (.ready, .ready, _):
            return .ready
        default:
            // `.disconnected` reattaches on its own, so it is not terminal.
            return .waiting
        }
    }
}

extension AppState {
    /// Covers a relaunch: hydration plus the agent reconnecting.
    static let sessionRecapReadinessTimeout: Duration = .seconds(30)

    /// Startup wiring: the coordinator's store lookup and app-focus forwarding.
    func installSessionRecap() {
        sessionSummaryCoordinator.storeProvider = { [weak self] session in
            self?.acpManager(forSession: session.id)?.persistence
        }
        let focus: [(Notification.Name, Bool)] = [
            (NSApplication.didBecomeActiveNotification, true),
            (NSApplication.didResignActiveNotification, false),
        ]
        for (name, active) in focus {
            let token = NotificationCenter.default.addObserver(
                forName: name, object: nil, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.setSessionsAppActive(active) }
            }
            sessionRecapRuntime.sessionRecapObservers.append(
                AnyCancellable { NotificationCenter.default.removeObserver(token) }
            )
        }
        sessionRecapPrecomputeScheduler.isSuspended = ProcessInfo.processInfo.isLowPowerModeEnabled
        let power = NotificationCenter.default.addObserver(
            forName: .NSProcessInfoPowerStateDidChange, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.sessionRecapPrecomputeScheduler.isSuspended = ProcessInfo.processInfo.isLowPowerModeEnabled
            }
        }
        sessionRecapRuntime.sessionRecapObservers.append(
            AnyCancellable { NotificationCenter.default.removeObserver(power) }
        )
    }

    /// Called once for every ACP manager AppState creates.
    func installSessionRecapHandler(on manager: ACPSessionManager) {
        manager.seenTracker.onEvent = { [weak self, weak manager] event in
            guard let self, let manager else { return }
            self.handleSeenEvent(event, manager: manager)
        }
        manager.seenTracker.setAppActive(NSApp?.isActive ?? false)
        // Runs after the caller's synchronous tab restore for this owner.
        Task { [weak self, weak manager] in
            guard let self, let manager else { return }
            await self.scheduleRecapPrecomputeForOpenTabs(of: manager)
        }
    }

    private func setSessionsAppActive(_ active: Bool) {
        for manager in core.sessionManagers.values {
            manager.seenTracker.setAppActive(active)
        }
    }

    /// The single route for seen-tracker events.
    func handleSeenEvent(_ event: SessionSeenTracker.Event, manager: ACPSessionManager) {
        switch event {
        case .becameSeen(let sessionId, let seenAwayFrom):
            dropRecapPrecompute(sessionId: sessionId)
            // A recap that was cleared before its result keeps the earlier origin.
            let pending = sessionRecapRuntime.pendingRecapAwayOrigin[sessionId]
            let awayFrom = [seenAwayFrom, pending].compactMap { $0 }.min()
            sessionRecapRuntime.startCheck(sessionId: sessionId) { [weak self, weak manager] token in
                guard let self else { return }
                defer { self.sessionRecapRuntime.finishCheck(sessionId: sessionId, token: token) }
                guard let manager else { return }
                await self.offerReturnRecap(sessionId: sessionId, awayFrom: awayFrom, manager: manager)
            }
        case .becameUnseen(let sessionId, let at):
            sessionRecapRuntime.cancelCheck(sessionId: sessionId)
            if let incarnation = manager.liveSession(for: sessionId)?.incarnation,
               sessionSummaryCoordinator.boundSessionIncarnation == incarnation {
                sessionSummaryCoordinator.dismissCard()
            }
            guard hasOpenACPTab(sessionId: sessionId, owner: manager.owner) else {
                sessionRecapRuntime.pendingRecapAwayOrigin[sessionId] = nil
                return
            }
            // With a pending origin the job is due at once and runs hidden.
            let origin = sessionRecapRuntime.pendingRecapAwayOrigin[sessionId] ?? at
            scheduleRecapPrecompute(sessionId: sessionId, lastSeenAt: origin, manager: manager)
        }
    }

    private var sessionRecapAvailable: Bool {
        sessionSummariesRuntimeEnabled
            && config.sessionRecapThreshold != .off
            && localTextModelState == .ready
    }

    private func offerReturnRecap(
        sessionId: ACPSession.ID,
        awayFrom: Date?,
        manager: ACPSessionManager
    ) async {
        // Only `.becameUnseen` (or a newer check) cancels this task, and it
        // also dismisses a loading card, so the pending away origin survives.
        // Any other exit means the card reached a result, failed, was
        // dismissed with ×, a prompt cleared it, or no recap was due; either
        // way the origin is used up and must not stretch a later absence.
        defer {
            if !Task.isCancelled { sessionRecapRuntime.pendingRecapAwayOrigin[sessionId] = nil }
        }
        // Only settings gates here: on relaunch the runtime flag and the model
        // state turn ready asynchronously, after the visible tab is seen. The
        // full availability check runs once the session is ready.
        guard config.sessionSummariesEnabled, config.sessionRecapThreshold != .off else { return }
        guard let session = await Self.readySession(
            id: sessionId,
            manager: manager,
            timeout: Self.sessionRecapReadinessTimeout
        ) else { return }
        guard !Task.isCancelled, manager.seenTracker.isSeen(sessionId) else { return }

        let isIdle = SessionSummaryIdleFacts.current(session: session, composer: session.composer).isIdle
        let completeTurnCount = SessionSummaryContext.completeTurnCount(
            session: session,
            limit: SessionRecapPolicy.minimumCompleteTurns
        )
        guard isIdle, completeTurnCount >= SessionRecapPolicy.minimumCompleteTurns else { return }

        var lastSeenAt = awayFrom
        var updatedAt = Date()
        if lastSeenAt == nil {
            do {
                lastSeenAt = try await manager.persistence.loadLastSeenAt(id: sessionId)
                    .map { Date(timeIntervalSince1970: TimeInterval($0)) }
                if lastSeenAt == nil, let row = try await manager.persistence.loadSession(id: sessionId) {
                    updatedAt = Date(timeIntervalSince1970: TimeInterval(row.updatedAt))
                }
            } catch {
                sessionRecapLogger.error("loading the last-seen time failed: \(String(describing: error))")
                return
            }
        }
        guard !Task.isCancelled, manager.seenTracker.isSeen(sessionId), sessionRecapAvailable,
              manager.liveSession(for: sessionId) === session,
              SessionRecapPolicy.shouldOffer(
                  lastSeenAt: lastSeenAt,
                  updatedAt: updatedAt,
                  now: Date(),
                  threshold: config.sessionRecapThreshold,
                  isIdle: SessionSummaryIdleFacts.current(session: session, composer: session.composer).isIdle,
                  completeTurnCount: completeTurnCount
              ) else { return }

        sessionRecapRuntime.pendingRecapAwayOrigin[sessionId] = lastSeenAt ?? updatedAt
        sessionSummaryCoordinator.bind(to: session)
        await sessionSummaryCoordinator.summary(for: session, mode: .recap)
    }

    /// Waits until the session exists, has hydrated, and its agent is ready,
    /// re-checking whenever the manager or the session announce a change.
    /// Nil on a terminal failure, timeout, or cancellation.
    private static func readySession(
        id: ACPSession.ID,
        manager: ACPSessionManager,
        timeout: Duration
    ) async -> ACPSession? {
        func readiness() -> (SessionRecapReadiness, ACPSession?) {
            guard let session = manager.liveSession(for: id) else { return (.waiting, nil) }
            let state = SessionRecapReadiness.readiness(
                hydration: session.hydrationState,
                agent: session.agentState,
                setup: session.setupState
            )
            // Belt and braces: agent-ready already implies backfill is done.
            // A flip of this flag alone is caught by the timeout's re-check.
            if state == .ready, session.transcript.isBackfillingOlderMessages { return (.waiting, session) }
            return (state, session)
        }
        func ready() -> ACPSession? {
            let (state, session) = readiness()
            return state == .ready ? session : nil
        }
        switch readiness() {
        case (.ready, let session): return session
        case (.failed, _): return nil
        case (.waiting, _): break
        }
        let waiter = HydrationWaiter()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<ACPSession?, Never>) in
                waiter.start(continuation: continuation)
                // Change signals fire before the mutation lands, so re-check on
                // the next main-actor turn.
                func recheck() {
                    Task { @MainActor in
                        switch readiness() {
                        case (.ready, let session): waiter.finish(session)
                        case (.failed, _): waiter.finish(nil)
                        case (.waiting, let session): waiter.observeSession(session, onChange: recheck)
                        }
                    }
                }
                waiter.observeManager(manager.willChange.observe { _ in recheck() })
                waiter.observeSession(manager.liveSession(for: id), onChange: recheck)
                waiter.setTimeout(Task { @MainActor in
                    try? await Task.sleep(for: timeout)
                    waiter.finish(ready())
                })
            }
        } onCancel: {
            Task { @MainActor in waiter.finish(nil) }
        }
    }
}

/// Single-shot continuation plus the observations racing to resume it.
@MainActor
private final class HydrationWaiter {
    private var continuation: CheckedContinuation<ACPSession?, Never>?
    private var managerObservation: ChangeSubscription?
    private var sessionObservation: ChangeSubscription?
    private weak var observedSession: ACPSession?
    private var timeout: Task<Void, Never>?
    private var finished = false

    nonisolated init() {}

    func start(continuation: CheckedContinuation<ACPSession?, Never>) {
        if finished {
            continuation.resume(returning: nil)
        } else {
            self.continuation = continuation
        }
    }

    func observeManager(_ subscription: ChangeSubscription) {
        guard !finished else { return subscription.cancel() }
        managerObservation = subscription
    }

    func observeSession(_ session: ACPSession?, onChange: @escaping () -> Void) {
        guard !finished, let session, session !== observedSession else { return }
        observedSession = session
        sessionObservation = session.willChange.observe { _ in onChange() }
    }

    func setTimeout(_ task: Task<Void, Never>) {
        guard !finished else { return task.cancel() }
        timeout = task
    }

    func finish(_ session: ACPSession?) {
        guard !finished else { return }
        finished = true
        managerObservation?.cancel()
        sessionObservation?.cancel()
        timeout?.cancel()
        continuation?.resume(returning: session)
        continuation = nil
    }
}

extension AppState {
    /// Synchronous on purpose: the process is exiting, so no actor hop. A
    /// second store handle writes `last_seen_at = now` for every session the
    /// user can see right now.
    func stampSeenSessionsForTermination(now: Date = Date()) {
        let seconds = Int64(now.timeIntervalSince1970)
        for manager in core.sessionManagers.values {
            let seen = manager.sessions.keys.filter { manager.seenTracker.isSeen($0) }
            guard !seen.isEmpty,
                  let store = try? ACPSessionStore(path: manager.persistence.path) else { continue }
            for id in seen {
                try? store.setLastSeenAt(id: id, at: seconds)
            }
        }
    }
}

// MARK: - Background precompute for open tabs

extension AppState {
    /// Summaries on, a recap threshold set, and the local model usable.
    private var recapPrecomputeAllowed: Bool {
        config.sessionSummariesEnabled && sessionRecapAvailable
    }

    func sessionSummariesRuntimeEnabledChanged() {
        if sessionSummariesRuntimeEnabled {
            rescheduleRecapPrecompute()
        } else {
            dropAllRecapPrecompute()
        }
    }

    /// Clears every entry and reschedules each open ACP tab the user cannot
    /// see. Call after the recap threshold changes.
    func rescheduleRecapPrecompute() {
        dropAllRecapPrecompute()
        guard recapPrecomputeAllowed else { return }
        let managers = Array(core.sessionManagers.values)
        Task { [weak self] in
            for manager in managers {
                await self?.scheduleRecapPrecomputeForOpenTabs(of: manager)
            }
        }
    }

    /// Schedules the hidden open ACP tabs of `manager`'s owner, timed from
    /// the persisted away origin. The store is read rather than
    /// `sessionRows`, which can be empty before a manager hydrates.
    func scheduleRecapPrecomputeForOpenTabs(of manager: ACPSessionManager) async {
        guard recapPrecomputeAllowed else { return }
        let sessionIds = tabs.tabs(for: manager.owner).compactMap { tab -> ACPSession.ID? in
            guard case .acpSession(let state) = tab else { return nil }
            return state.sessionId
        }
        for sessionId in sessionIds where !manager.seenTracker.isSeen(sessionId) {
            let snapshot: StoredSummarySourceSnapshot?
            do {
                snapshot = try await manager.persistence.loadSummarySourceSnapshot(sessionId: sessionId)
            } catch {
                sessionRecapLogger.error("loading a recap source failed: \(String(describing: error))")
                continue
            }
            guard let snapshot, acpManager(for: manager.owner) === manager,
                  !manager.seenTracker.isSeen(sessionId),
                  // A seen event since the scan started has fresher timing.
                  !sessionRecapPrecomputeScheduler.pendingSessionIds.contains(sessionId)
            else { continue }
            let origin = Date(timeIntervalSince1970: TimeInterval(snapshot.lastSeenAt ?? snapshot.updatedAt))
            scheduleRecapPrecompute(sessionId: sessionId, lastSeenAt: origin, manager: manager)
        }
    }

    func scheduleRecapPrecompute(sessionId: ACPSession.ID, lastSeenAt: Date, manager: ACPSessionManager) {
        guard recapPrecomputeAllowed,
              let threshold = config.sessionRecapThreshold.duration,
              hasOpenACPTab(sessionId: sessionId, owner: manager.owner),
              !manager.seenTracker.isSeen(sessionId) else { return }
        sessionRecapRuntime.precomputeOwners[sessionId] = manager.owner
        if let session = manager.liveSession(for: sessionId),
           sessionRecapRuntime.precomputeActivity[sessionId]?.session != ObjectIdentifier(session) {
            sessionRecapRuntime.precomputeActivity[sessionId]?.subscription.cancel()
            // A busy session is dropped and only rescheduled on its next
            // `.becameUnseen`, so an open tab that goes busy and then idle
            // while hidden is not precomputed until the user leaves it again.
            // The signal fires before the change lands, so check on the next
            // turn; activity that leaves the session idle keeps its entry.
            let subscription = session.nextPromptActivity.observe { [weak self, weak session, weak manager] in
                Task { @MainActor in
                    guard let self, let session, let manager, manager.liveSession(for: sessionId) === session,
                          !SessionSummaryIdleFacts.current(session: session, composer: session.composer).isIdle
                    else { return }
                    self.dropRecapPrecompute(sessionId: sessionId)
                }
            }
            sessionRecapRuntime.precomputeActivity[sessionId] = (ObjectIdentifier(session), subscription)
        }
        sessionRecapPrecomputeScheduler.schedule(sessionId: sessionId, lastSeenAt: lastSeenAt, threshold: threshold)
    }

    /// Seen, busy, or tab closed. Cancels the model work if its job is running.
    func dropRecapPrecompute(sessionId: ACPSession.ID) {
        let scheduler = sessionRecapPrecomputeScheduler
        let wasRunning = scheduler.runningSessionId == sessionId
        scheduler.drop(sessionId: sessionId)
        sessionRecapRuntime.precomputeOwners[sessionId] = nil
        sessionRecapRuntime.precomputeActivity.removeValue(forKey: sessionId)?.subscription.cancel()
        // The scheduler cancels the job's task; this stops a generation the
        // engine already started.
        if wasRunning {
            let coordinator = sessionSummaryCoordinator
            Task { await coordinator.cancelPrecompute(sessionId: sessionId) }
        }
    }

    func dropAllRecapPrecompute() {
        let scheduler = sessionRecapPrecomputeScheduler
        let running = scheduler.runningSessionId
        scheduler.dropAll()
        sessionRecapRuntime.precomputeOwners.removeAll()
        for entry in sessionRecapRuntime.precomputeActivity.values { entry.subscription.cancel() }
        sessionRecapRuntime.precomputeActivity.removeAll()
        if let running {
            let coordinator = sessionSummaryCoordinator
            Task { await coordinator.cancelPrecompute(sessionId: running) }
        }
    }

    private func hasOpenACPTab(sessionId: ACPSession.ID, owner: SessionOwnerID) -> Bool {
        tabs.tabs(for: owner).contains {
            guard case .acpSession(let tab) = $0 else { return false }
            return tab.sessionId == sessionId
        }
    }

    /// The scheduler's job: summarize an idle, hidden session from memory when
    /// it is loaded, otherwise from the store.
    func runRecapPrecompute(sessionId: ACPSession.ID) async {
        // Activity stays observed during the job, so going busy cancels it.
        // Afterwards the bookkeeping goes unless the id was scheduled again.
        defer {
            if !sessionRecapPrecomputeScheduler.pendingSessionIds.contains(sessionId) {
                sessionRecapRuntime.precomputeOwners[sessionId] = nil
                sessionRecapRuntime.precomputeActivity.removeValue(forKey: sessionId)?.subscription.cancel()
            }
        }
        guard recapPrecomputeAllowed,
              let owner = sessionRecapRuntime.precomputeOwners[sessionId],
              let manager = acpManager(for: owner),
              hasOpenACPTab(sessionId: sessionId, owner: owner),
              !manager.seenTracker.isSeen(sessionId) else { return }

        let minimumTurns = SessionRecapPolicy.minimumCompleteTurns
        let context: SessionSummaryContext?
        // Live only when hydrated with a ready agent; agent readiness implies
        // the transcript backfill is done, since attach awaits it. Otherwise
        // the store has the full history.
        if let session = manager.liveSession(for: sessionId), session.hydrationState == .ready,
           session.agentState == .ready, !session.transcript.isBackfillingOlderMessages {
            guard SessionSummaryIdleFacts.current(session: session, composer: session.composer).isIdle,
                  SessionSummaryContext.completeTurnCount(session: session, limit: minimumTurns) >= minimumTurns
            else { return }
            context = SessionSummaryContext.snapshot(session: session)
        } else {
            let snapshot: StoredSummarySourceSnapshot?
            do {
                snapshot = try await manager.persistence.loadSummarySourceSnapshot(sessionId: sessionId)
            } catch {
                sessionRecapLogger.error("loading a recap source failed: \(String(describing: error))")
                return
            }
            guard let snapshot, snapshot.isIdle, snapshot.source.turns.count >= minimumTurns else { return }
            context = SessionSummaryContext.snapshot(source: snapshot.source)
        }
        // A drop during the awaits above cancels this task; re-check everything.
        guard let context, !Task.isCancelled, recapPrecomputeAllowed,
              acpManager(for: owner) === manager,
              hasOpenACPTab(sessionId: sessionId, owner: owner),
              !manager.seenTracker.isSeen(sessionId) else { return }
        _ = await sessionSummaryCoordinator.precompute(
            sessionId: sessionId,
            context: context,
            store: manager.persistence
        )
    }
}
