import AppKit
import Combine
import Foundation
import os

private let sessionRecapLogger = Logger(subsystem: "io.nlopez.alas", category: "session-recap")

/// Lifetimes for the return-recap trigger. Independent of local-text
/// observers: seen-tracking must keep working while local text is off.
@MainActor
final class SessionRecapRuntime {
    var appFocusObservers: [AnyCancellable] = []
    /// One in-flight return check per session, so a seen/unseen flap never
    /// stacks two waits.
    private var pendingChecks: [ACPSession.ID: (token: UUID, task: Task<Void, Never>)] = [:]

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
/// the coordinator both need hydrated history and a connected agent.
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
            sessionRecapRuntime.appFocusObservers.append(
                AnyCancellable { NotificationCenter.default.removeObserver(token) }
            )
        }
    }

    /// Called once for every ACP manager AppState creates.
    func installSessionRecapHandler(on manager: ACPSessionManager) {
        manager.seenTracker.onEvent = { [weak self, weak manager] event in
            guard let self, let manager else { return }
            self.handleSeenEvent(event, manager: manager)
        }
        manager.seenTracker.setAppActive(NSApp?.isActive ?? false)
    }

    private func setSessionsAppActive(_ active: Bool) {
        for manager in core.sessionManagers.values {
            manager.seenTracker.setAppActive(active)
        }
    }

    /// The single route for seen-tracker events.
    func handleSeenEvent(_ event: SessionSeenTracker.Event, manager: ACPSessionManager) {
        switch event {
        case .becameSeen(let sessionId, let awayFrom):
            sessionRecapRuntime.startCheck(sessionId: sessionId) { [weak self, weak manager] token in
                guard let self else { return }
                defer { self.sessionRecapRuntime.finishCheck(sessionId: sessionId, token: token) }
                guard let manager else { return }
                await self.offerReturnRecap(sessionId: sessionId, awayFrom: awayFrom, manager: manager)
            }
        case .becameUnseen(let sessionId, _):
            sessionRecapRuntime.cancelCheck(sessionId: sessionId)
            if let incarnation = manager.liveSession(for: sessionId)?.incarnation,
               sessionSummaryCoordinator.boundSessionIncarnation == incarnation {
                sessionSummaryCoordinator.dismissCard()
            }
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
        guard sessionRecapAvailable else { return }
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
            return (SessionRecapReadiness.readiness(
                hydration: session.hydrationState,
                agent: session.agentState,
                setup: session.setupState
            ), session)
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
