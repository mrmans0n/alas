import Foundation
import Observation

struct HarnessActivityTransition: Equatable {
    let sessionID: String
    let owner: SessionOwnerID?
    let agent: AgentKind
    let previousState: ActivityState?
    let state: ActivityState?
    let body: String?
    let occurredAt: Date
    var isSnapshot = false
    var requiresUserInput = false
}

@Observable
final class HarnessService {
    let detector = HarnessDetector()
    let socketServer: AgentHookSocketServer
    let notifications = NotificationService()

    private(set) var activityBySession: [String: HarnessActivityState] = [:]
    private(set) var harnessBySession: [String: HarnessKind] = [:]
    private(set) var activeHarnessBySession: [String: HarnessKind] = [:]

    var onClickThrough: ((String, String, String) -> Void)?
    var onContextClickThrough: ((NotificationClickContext) -> Void)?
    var onActivityTransition: ((HarnessActivityTransition) -> Void)?
    var onWorktreeActivityEvent: ((String) -> Void)?

    struct HarnessActivityState: Equatable {
        var agent: AgentKind
        var state: ActivityState
        var pid: pid_t?
        var lastBody: String?
        var updatedAt: Date
        var requiresUserInput = false
    }

    private struct DeferredForegroundIdle {
        let event: AgentHookEvent
        let shouldNotifyOnCommit: Bool
    }

    /// Cursor notifications are less reliable than Claude's and frequently
    /// flap `idle -> busy -> idle` for a single ongoing turn. We debounce
    /// `.idle` events for Cursor so the `run` badge stays visible until
    /// work has actually settled.
    private var cursorIdleDebouncers: [String: DebounceTimer] = [:]
    private var pendingCursorIdleEvents: [String: AgentHookEvent] = [:]
    private var backgroundActivityIdsBySession: [String: Set<String>] = [:]
    private var completedBackgroundActivityIdsBySession: [String: Set<String>] = [:]
    private var deferredForegroundIdleBySession: [String: DeferredForegroundIdle] = [:]
    private var detachedSocketSessions: Set<String> = []
    private var activeSocketLifecycleBySession: [String: String] = [:]
    private var retiredSocketLifecycleIdsBySession: [String: Set<String>] = [:]
    private let cursorIdleDebounceInterval: TimeInterval

    init(cursorIdleDebounceInterval: TimeInterval = 2.0) {
        self.cursorIdleDebounceInterval = cursorIdleDebounceInterval
        socketServer = AgentHookSocketServer()
    }

    init(socketServer: AgentHookSocketServer, cursorIdleDebounceInterval: TimeInterval = 2.0) {
        self.cursorIdleDebounceInterval = cursorIdleDebounceInterval
        self.socketServer = socketServer
    }

    /// Main-actor isolated: it wires handlers that all run on the main queue
    /// (the detector and socket server both dispatch there) and writes
    /// `NotificationDelegate`'s main-actor state. Called from
    /// `AppState.startHarness()`.
    @MainActor
    func start(
        stateLookup: @escaping (String) -> (projectId: String, worktreeId: String)?,
        ownerLookup: @escaping (String) -> SessionOwnerID? = { _ in nil },
        shouldNotifyOnAwaiting: @escaping () -> Bool = { true }
    ) {
        detector.onUpdate = { [weak self] sid, kind in
            guard let self else { return }
            self.recordHarnessDetection(sessionId: sid, kind: kind)
        }
        detector.start()

        notifications.setup { [weak self] context in
            self?.onContextClickThrough?(context)
            if case .workspaceCheckout = context.owner {
                return
            }
            if let projectId = context.projectId, let worktreeId = context.worktreeId {
                self?.onClickThrough?(projectId, worktreeId, context.sessionId)
            }
        }

        socketServer.onEvent = { [weak self] event in
            self?.handleSocketEvent(event, stateLookup: stateLookup, ownerLookup: ownerLookup, shouldNotifyOnAwaiting: shouldNotifyOnAwaiting)
        }
    }

    func recordHarnessDetection(sessionId: String, kind: HarnessKind?) {
        if let kind {
            if harnessBySession[sessionId] != kind { harnessBySession[sessionId] = kind }
            if activeHarnessBySession[sessionId] != kind { activeHarnessBySession[sessionId] = kind }
            // Seed running activity for users without hooks installed (or for
            // the gap before the first hook fires). Don't clobber an existing
            // hook-driven state — socket events are authoritative once they
            // start arriving.
            if activityBySession[sessionId] == nil {
                activityBySession[sessionId] = HarnessActivityState(
                    agent: kind.asAgentKind,
                    state: .busy,
                    pid: nil,
                    lastBody: nil,
                    updatedAt: Date()
                )
            }
        } else {
            if activeHarnessBySession[sessionId] != nil {
                activeHarnessBySession.removeValue(forKey: sessionId)
            }
            // Process exited. Drop the running badge but preserve
            // awaiting/idle state — those carry the last notification
            // context, and the stop-hook may still race process exit.
            if let current = activityBySession[sessionId], current.state == .busy {
                activityBySession.removeValue(forKey: sessionId)
            }
        }
    }

    func handleSocketEvent(
        _ event: AgentHookEvent,
        stateLookup: @escaping (String) -> (projectId: String, worktreeId: String)?,
        ownerLookup: @escaping (String) -> SessionOwnerID? = { _ in nil },
        shouldNotifyOnAwaiting: () -> Bool
    ) {
        if let lifecycleId = event.lifecycleId {
            if retiredSocketLifecycleIdsBySession[event.sessionId]?.contains(lifecycleId) == true {
                return
            }
            let activeLifecycleId = activeSocketLifecycleBySession[event.sessionId]
            if event.event == .detached {
                retiredSocketLifecycleIdsBySession[event.sessionId, default: []].insert(lifecycleId)
                if let activeLifecycleId, activeLifecycleId != lifecycleId {
                    return
                }
                activeSocketLifecycleBySession.removeValue(forKey: event.sessionId)
            } else if activeLifecycleId != lifecycleId {
                if let activeLifecycleId {
                    retiredSocketLifecycleIdsBySession[event.sessionId, default: []].insert(activeLifecycleId)
                }
                backgroundActivityIdsBySession.removeValue(forKey: event.sessionId)
                completedBackgroundActivityIdsBySession.removeValue(forKey: event.sessionId)
                deferredForegroundIdleBySession.removeValue(forKey: event.sessionId)
                activityBySession.removeValue(forKey: event.sessionId)
                activeSocketLifecycleBySession[event.sessionId] = lifecycleId
            }
        } else if event.agent == .pi {
            if event.event == .attached {
                detachedSocketSessions.remove(event.sessionId)
            } else if event.event != .detached, detachedSocketSessions.contains(event.sessionId) {
                return
            }
        }
        emitWorktreeActivityEventIfNeeded(event: event, stateLookup: stateLookup, ownerLookup: ownerLookup)
        let previousState = activityBySession[event.sessionId]?.state
        let previous = activityBySession[event.sessionId]
        var transitionHandledSeparately = event.event == .idle
        // Idle commits separately because Cursor may defer the authoritative change.
        defer {
            if !transitionHandledSeparately {
                emitActivityTransition(sessionID: event.sessionId, previous: previous, owner: ownerLookup(event.sessionId))
            }
        }

        switch event.event {
        case .attached, .busy:
            deferredForegroundIdleBySession.removeValue(forKey: event.sessionId)
            // Cancel any pending cursor-idle debounce — work is actually ongoing.
            if event.agent == .cursor {
                cursorIdleDebouncers.removeValue(forKey: event.sessionId)?.cancel()
                pendingCursorIdleEvents.removeValue(forKey: event.sessionId)
            }
            activityBySession[event.sessionId] = HarnessActivityState(
                agent: event.agent, state: .busy, pid: event.pid,
                lastBody: nil, updatedAt: Date()
            )

        case .backgroundStarted:
            guard let activityId = event.activityId else { return }
            if completedBackgroundActivityIdsBySession[event.sessionId]?.remove(activityId) != nil {
                if completedBackgroundActivityIdsBySession[event.sessionId]?.isEmpty == true {
                    completedBackgroundActivityIdsBySession.removeValue(forKey: event.sessionId)
                }
                if backgroundActivityIdsBySession[event.sessionId]?.isEmpty != false,
                   let deferredIdle = deferredForegroundIdleBySession[event.sessionId] {
                    transitionHandledSeparately = true
                    commitIdle(
                        event: deferredIdle.event,
                        stateLookup: stateLookup,
                        ownerLookup: ownerLookup,
                        shouldNotifyOnCommit: deferredIdle.shouldNotifyOnCommit
                    )
                }
                return
            }
            backgroundActivityIdsBySession[event.sessionId, default: []].insert(activityId)
            let foregroundState = activityBySession[event.sessionId]?.state
            if foregroundState != .awaitingInput, foregroundState != .permissionRequest {
                activityBySession[event.sessionId] = HarnessActivityState(
                    agent: event.agent, state: .busy, pid: event.pid,
                    lastBody: nil, updatedAt: Date()
                )
            }

        case .backgroundEnded:
            guard let activityId = event.activityId else { return }
            guard backgroundActivityIdsBySession[event.sessionId]?.remove(activityId) != nil else {
                completedBackgroundActivityIdsBySession[event.sessionId, default: []].insert(activityId)
                return
            }
            if backgroundActivityIdsBySession[event.sessionId]?.isEmpty == true {
                backgroundActivityIdsBySession.removeValue(forKey: event.sessionId)
                if let deferredIdle = deferredForegroundIdleBySession[event.sessionId] {
                    transitionHandledSeparately = true
                    commitIdle(
                        event: deferredIdle.event,
                        stateLookup: stateLookup,
                        ownerLookup: ownerLookup,
                        shouldNotifyOnCommit: deferredIdle.shouldNotifyOnCommit
                    )
                }
            }

        case .awaitingInput:
            deferredForegroundIdleBySession.removeValue(forKey: event.sessionId)
            // Hooks also report idle prompts here, so they cannot establish input intent.
            // Cancel pending cursor-idle debounce; awaiting is a real state change.
            if event.agent == .cursor {
                cursorIdleDebouncers.removeValue(forKey: event.sessionId)?.cancel()
                pendingCursorIdleEvents.removeValue(forKey: event.sessionId)
            }
            activityBySession[event.sessionId] = HarnessActivityState(
                agent: event.agent, state: .awaitingInput, pid: event.pid,
                lastBody: event.body, updatedAt: Date()
            )
            if previousState != .awaitingInput, shouldNotifyOnAwaiting(),
               let lookup = stateLookup(event.sessionId) {
                notifications.notifyHarnessAwaiting(
                    agent: event.agent, body: event.body,
                    projectId: lookup.projectId, worktreeId: lookup.worktreeId,
                    sessionId: event.sessionId,
                    owner: ownerLookup(event.sessionId)
                )
            }

        case .permissionRequest:
            deferredForegroundIdleBySession.removeValue(forKey: event.sessionId)
            // Older Cursor installs reported every shell and MCP execution as
            // a permission request. Cursor has no hook for actual approval
            // prompts, so keep stale installs accurate until their hooks are
            // updated.
            if event.agent == .cursor {
                cursorIdleDebouncers.removeValue(forKey: event.sessionId)?.cancel()
                pendingCursorIdleEvents.removeValue(forKey: event.sessionId)
                activityBySession[event.sessionId] = HarnessActivityState(
                    agent: event.agent, state: .busy, pid: event.pid,
                    lastBody: nil, updatedAt: Date()
                )
                return
            }
            activityBySession[event.sessionId] = HarnessActivityState(
                agent: event.agent, state: .permissionRequest, pid: event.pid,
                lastBody: event.body, updatedAt: Date(), requiresUserInput: true
            )
            if previousState != .permissionRequest, shouldNotifyOnAwaiting(),
               let lookup = stateLookup(event.sessionId) {
                notifications.notifyHarnessPermission(
                    agent: event.agent, body: event.body,
                    projectId: lookup.projectId, worktreeId: lookup.worktreeId,
                    sessionId: event.sessionId,
                    owner: ownerLookup(event.sessionId)
                )
            }

        case .idle:
            if event.agent == .cursor {
                // Debounce cursor idle: keep the badge alive briefly in case
                // a follow-up busy arrives (which cancels this timer).
                let sid = event.sessionId
                pendingCursorIdleEvents[sid] = event
                if let existing = cursorIdleDebouncers[sid] {
                    existing.poke()
                } else {
                    let debouncer = DebounceTimer(
                        interval: cursorIdleDebounceInterval,
                        queue: .main
                    )
                    debouncer.onFire = { [weak self] in
                        guard let self else { return }
                        if let event = self.pendingCursorIdleEvents.removeValue(forKey: sid) {
                            self.commitIdle(event: event, stateLookup: stateLookup, ownerLookup: ownerLookup)
                        }
                        self.cursorIdleDebouncers.removeValue(forKey: sid)
                    }
                    cursorIdleDebouncers[sid] = debouncer
                    debouncer.poke()
                }
            } else {
                commitIdle(event: event, stateLookup: stateLookup, ownerLookup: ownerLookup)
            }

        case .detached:
            if event.agent == .pi, event.lifecycleId == nil {
                detachedSocketSessions.insert(event.sessionId)
            }
            cursorIdleDebouncers.removeValue(forKey: event.sessionId)?.cancel()
            pendingCursorIdleEvents.removeValue(forKey: event.sessionId)
            backgroundActivityIdsBySession.removeValue(forKey: event.sessionId)
            completedBackgroundActivityIdsBySession.removeValue(forKey: event.sessionId)
            deferredForegroundIdleBySession.removeValue(forKey: event.sessionId)
            activityBySession.removeValue(forKey: event.sessionId)
        }
    }

    private func commitIdle(
        event: AgentHookEvent,
        stateLookup: @escaping (String) -> (projectId: String, worktreeId: String)?,
        ownerLookup: @escaping (String) -> SessionOwnerID?,
        shouldNotifyOnCommit: Bool = true
    ) {
        let previous = activityBySession[event.sessionId]
        if backgroundActivityIdsBySession[event.sessionId]?.isEmpty == false {
            deferredForegroundIdleBySession[event.sessionId] = DeferredForegroundIdle(
                event: event,
                shouldNotifyOnCommit: shouldNotifyOnCommit
            )
            activityBySession[event.sessionId] = HarnessActivityState(
                agent: event.agent, state: .busy, pid: event.pid,
                lastBody: nil, updatedAt: Date()
            )
            emitActivityTransition(sessionID: event.sessionId, previous: previous, owner: ownerLookup(event.sessionId))
            return
        }
        activityBySession[event.sessionId] = HarnessActivityState(
            agent: event.agent, state: .idle, pid: event.pid,
            lastBody: event.body, updatedAt: Date()
        )
        if shouldNotifyOnCommit, let lookup = stateLookup(event.sessionId) {
            notifications.notifyHarnessFinished(
                agent: event.agent, body: event.body,
                projectId: lookup.projectId, worktreeId: lookup.worktreeId,
                sessionId: event.sessionId,
                owner: ownerLookup(event.sessionId)
            )
        }
        deferredForegroundIdleBySession[event.sessionId] = DeferredForegroundIdle(
            event: event,
            shouldNotifyOnCommit: false
        )
        emitActivityTransition(sessionID: event.sessionId, previous: previous, owner: ownerLookup(event.sessionId))
    }

    private func emitWorktreeActivityEventIfNeeded(
        event: AgentHookEvent,
        stateLookup: (String) -> (projectId: String, worktreeId: String)?,
        ownerLookup: (String) -> SessionOwnerID?
    ) {
        guard Self.shouldRefreshWorktreeStatus(after: event.event) else { return }
        if case .workspaceCheckout = ownerLookup(event.sessionId) { return }
        guard let lookup = stateLookup(event.sessionId) else { return }
        onWorktreeActivityEvent?(lookup.worktreeId)
    }

    nonisolated static func shouldRefreshWorktreeStatus(after event: ActivityEvent) -> Bool {
        switch event {
        case .busy, .backgroundStarted, .backgroundEnded, .idle, .awaitingInput, .permissionRequest, .detached:
            return true
        case .attached:
            return false
        }
    }

    nonisolated static func shouldRefreshWorktreeStatus(after state: ActivityState) -> Bool {
        switch state {
        case .busy, .idle, .awaitingInput, .permissionRequest:
            return true
        }
    }

    func stop() {
        detector.stop()
        socketServer.shutdown()
        for debouncer in cursorIdleDebouncers.values { debouncer.cancel() }
        cursorIdleDebouncers.removeAll()
        pendingCursorIdleEvents.removeAll()
        backgroundActivityIdsBySession.removeAll()
        completedBackgroundActivityIdsBySession.removeAll()
        deferredForegroundIdleBySession.removeAll()
        detachedSocketSessions.removeAll()
        activeSocketLifecycleBySession.removeAll()
        retiredSocketLifecycleIdsBySession.removeAll()
    }

    func forgetSession(_ sessionId: String) {
        let previous = activityBySession[sessionId]
        harnessBySession.removeValue(forKey: sessionId)
        activeHarnessBySession.removeValue(forKey: sessionId)
        activityBySession.removeValue(forKey: sessionId)
        cursorIdleDebouncers.removeValue(forKey: sessionId)?.cancel()
        pendingCursorIdleEvents.removeValue(forKey: sessionId)
        backgroundActivityIdsBySession.removeValue(forKey: sessionId)
        completedBackgroundActivityIdsBySession.removeValue(forKey: sessionId)
        deferredForegroundIdleBySession.removeValue(forKey: sessionId)
        emitActivityTransition(sessionID: sessionId, previous: previous, owner: nil)
    }

    /// Clear ACP foreground activity without dropping a hook-reported
    /// background workflow owned by the same session.
    func finishExternalActivity(
        sessionId: String,
        owner: SessionOwnerID?,
        agent: AgentKind,
        recordIdleTransition: Bool
    ) {
        let existingDeferredIdle = deferredForegroundIdleBySession[sessionId]
        let idleEvent = AgentHookEvent(
            version: 1, event: .idle, agent: agent, sessionId: sessionId,
            pid: nil, timestamp: nil, body: nil
        )
        if backgroundActivityIdsBySession[sessionId]?.isEmpty == false {
            setExternalActivity(sessionId: sessionId, owner: owner, agent: agent, state: .busy)
            deferredForegroundIdleBySession[sessionId] = DeferredForegroundIdle(
                event: idleEvent,
                shouldNotifyOnCommit: existingDeferredIdle?.shouldNotifyOnCommit ?? true
            )
            return
        }
        if recordIdleTransition {
            setExternalActivity(sessionId: sessionId, owner: owner, agent: agent, state: .idle)
        }
        let completedBackgroundActivityIds = completedBackgroundActivityIdsBySession[sessionId]
        forgetSession(sessionId)
        if let completedBackgroundActivityIds {
            completedBackgroundActivityIdsBySession[sessionId] = completedBackgroundActivityIds
        }
        deferredForegroundIdleBySession[sessionId] = DeferredForegroundIdle(
            event: idleEvent,
            shouldNotifyOnCommit: existingDeferredIdle?.shouldNotifyOnCommit ?? true
        )
    }

    /// Peer-write entry point alongside socket events. Lets non-hook sources
    /// (currently the ACP bridge) report activity for sessions they own.
    /// No notification side effects — those remain socket-driven so we don't
    /// double-fire when both hooks and ACP cover the same session.
    func setExternalActivity(sessionId: String, owner: SessionOwnerID? = nil, agent: AgentKind, state: ActivityState, body: String? = nil, isSnapshot: Bool = false, requiresUserInput: Bool = false) {
        if state != .idle {
            deferredForegroundIdleBySession.removeValue(forKey: sessionId)
        }
        let previous = activityBySession[sessionId]
        activityBySession[sessionId] = HarnessActivityState(
            agent: agent, state: state, pid: nil,
            lastBody: body, updatedAt: Date(), requiresUserInput: requiresUserInput || state == .permissionRequest
        )
        if !isSnapshot,
           Self.shouldRefreshWorktreeStatus(after: state),
           case .worktree(let worktreeId) = owner {
            onWorktreeActivityEvent?(worktreeId)
        }
        emitActivityTransition(sessionID: sessionId, previous: previous, owner: owner, isSnapshot: isSnapshot)
    }

    private func emitActivityTransition(sessionID: String, previous: HarnessActivityState?, owner: SessionOwnerID?, isSnapshot: Bool = false) {
        let current = activityBySession[sessionID]
        let bodyChanged = current?.lastBody != previous?.lastBody
            && (current?.state == .awaitingInput || current?.state == .permissionRequest)
        let inputIntentChanged = current?.requiresUserInput != previous?.requiresUserInput
        guard current?.state != previous?.state || current?.agent != previous?.agent || bodyChanged || inputIntentChanged,
              let agent = current?.agent ?? previous?.agent else { return }
        onActivityTransition?(HarnessActivityTransition(
            sessionID: sessionID, owner: owner, agent: agent, previousState: previous?.state, state: current?.state,
            body: current?.lastBody, occurredAt: current?.updatedAt ?? Date(), isSnapshot: isSnapshot,
            requiresUserInput: current?.requiresUserInput ?? false
        ))
    }

    enum AggregatedState: String, Equatable {
        case running, awaiting
    }

    struct WorktreeHarnessSession: Equatable, Identifiable {
        let id: String
        let state: AggregatedState
        let agent: AgentKind
    }

    struct WorktreeHarnessSummary: Equatable {
        let sessions: [WorktreeHarnessSession]
        let state: AggregatedState
        let agent: AgentKind
        let primarySessionId: String
        let runningSessionCount: Int
        let awaitingSessionCount: Int
    }

    func summary(forSessionIds ids: [String]) -> WorktreeHarnessSummary? {
        let sessions = ids.enumerated().compactMap { offset, id -> (session: WorktreeHarnessSession, updatedAt: Date, offset: Int)? in
            guard let activity = activityBySession[id] else { return nil }
            switch activity.state {
            case .awaitingInput, .permissionRequest:
                return (WorktreeHarnessSession(id: id, state: .awaiting, agent: activity.agent), activity.updatedAt, offset)
            case .busy:
                return (WorktreeHarnessSession(id: id, state: .running, agent: activity.agent), activity.updatedAt, offset)
            case .idle:
                return nil
            }
        }
        .sorted { lhs, rhs in
            if lhs.session.state != rhs.session.state { return lhs.session.state == .awaiting }
            if lhs.updatedAt != rhs.updatedAt { return lhs.updatedAt > rhs.updatedAt }
            return lhs.offset < rhs.offset
        }

        guard let primary = sessions.first else { return nil }
        return WorktreeHarnessSummary(
            sessions: sessions.map(\.session),
            state: primary.session.state,
            agent: primary.session.agent,
            primarySessionId: primary.session.id,
            runningSessionCount: sessions.count { $0.session.state == .running },
            awaitingSessionCount: sessions.count { $0.session.state == .awaiting }
        )
    }

    #if DEBUG
    func setStateForTesting(sessionId: String, agent: AgentKind, state: ActivityState) {
        activityBySession[sessionId] = HarnessActivityState(
            agent: agent, state: state, pid: nil, lastBody: nil, updatedAt: Date(),
            requiresUserInput: state == .permissionRequest
        )
    }
    #endif
}
