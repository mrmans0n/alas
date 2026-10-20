import Foundation
import Observation
import AlasFoundation
import AlasModel
import AlasPlatform
import AlasFeatures
import AlasCode

public struct HarnessActivityTransition: Equatable, Sendable {
    public let sessionID: String
    public let owner: SessionOwnerID?
    public let agent: AgentKind
    public let previousState: ActivityState?
    public let state: ActivityState?
    public let body: String?
    public let occurredAt: Date
    public var isSnapshot = false
    public var requiresUserInput = false

    public init(sessionID: String, owner: SessionOwnerID?, agent: AgentKind, previousState: ActivityState?, state: ActivityState?, body: String?, occurredAt: Date, isSnapshot: Bool = false, requiresUserInput: Bool = false) {
        self.sessionID = sessionID
        self.owner = owner
        self.agent = agent
        self.previousState = previousState
        self.state = state
        self.body = body
        self.occurredAt = occurredAt
        self.isSnapshot = isSnapshot
        self.requiresUserInput = requiresUserInput
    }
}

@Observable
public final class HarnessService {
    public let detector = HarnessDetector()
    public let socketServer: AgentHookSocketServer
    public let notifications = NotificationService()

    public private(set) var activityBySession: [String: HarnessActivityState] = [:]
    public private(set) var harnessBySession: [String: HarnessKind] = [:]
    public private(set) var activeHarnessBySession: [String: HarnessKind] = [:]

    public var onClickThrough: ((String, String, String) -> Void)?
    public var onContextClickThrough: ((NotificationClickContext) -> Void)?
    public var onActivityTransition: ((HarnessActivityTransition) -> Void)?
    public var onWorktreeActivityEvent: ((String) -> Void)?

    public struct HarnessActivityState: Equatable, Sendable {
        public var agent: AgentKind
        public var state: ActivityState
        public var pid: pid_t?
        public var lastBody: String?
        public var updatedAt: Date
        public var requiresUserInput = false

        public init(agent: AgentKind, state: ActivityState, pid: pid_t? = nil, lastBody: String? = nil, updatedAt: Date, requiresUserInput: Bool = false) {
            self.agent = agent
            self.state = state
            self.pid = pid
            self.lastBody = lastBody
            self.updatedAt = updatedAt
            self.requiresUserInput = requiresUserInput
        }
    }

    private struct DeferredForegroundIdle {
        let event: AgentHookEvent
        let shouldNotifyOnCommit: Bool

        public init(event: AgentHookEvent, shouldNotifyOnCommit: Bool) {
            self.event = event
            self.shouldNotifyOnCommit = shouldNotifyOnCommit
        }
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
    private var latestSocketLifecycleOrderBySession: [String: UInt64] = [:]
    private var retiredSocketLifecycleIdsBySession: [String: Set<String>] = [:]
    private let cursorIdleDebounceInterval: TimeInterval

    public init(cursorIdleDebounceInterval: TimeInterval = 2.0) {
        self.cursorIdleDebounceInterval = cursorIdleDebounceInterval
        socketServer = AgentHookSocketServer()
    }

    public init(socketServer: AgentHookSocketServer, cursorIdleDebounceInterval: TimeInterval = 2.0) {
        self.cursorIdleDebounceInterval = cursorIdleDebounceInterval
        self.socketServer = socketServer
    }

    /// Main-actor isolated: it wires handlers that all run on the main queue
    /// (the detector and socket server both dispatch there) and writes
    /// `NotificationDelegate`'s main-actor state. Called from
    /// `AppState.startHarness()`.
    @MainActor
    public func start(
        stateLookup: @escaping (String) -> (projectId: String, worktreeId: String)?,
        ownerLookup: @escaping (String) -> SessionOwnerID? = { _ in nil },
        shouldNotifyOnAwaiting: @escaping () -> Bool = { true },
        isExternalSession: @escaping (String) -> Bool = { _ in false }
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
            self?.handleSocketEvent(event, stateLookup: stateLookup, ownerLookup: ownerLookup, shouldNotifyOnAwaiting: shouldNotifyOnAwaiting, isExternalSession: isExternalSession)
        }
    }

    public func recordHarnessDetection(sessionId: String, kind: HarnessKind?) {
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

    public func handleSocketEvent(
        _ event: AgentHookEvent,
        stateLookup: @escaping (String) -> (projectId: String, worktreeId: String)?,
        ownerLookup: @escaping (String) -> SessionOwnerID? = { _ in nil },
        shouldNotifyOnAwaiting: () -> Bool,
        isExternalSession: (String) -> Bool = { _ in false }
    ) {
        let previous = activityBySession[event.sessionId]
        let previousState = previous?.state
        if let lifecycleId = event.lifecycleId {
            if retiredSocketLifecycleIdsBySession[event.sessionId]?.contains(lifecycleId) == true {
                return
            }
            let activeLifecycleId = activeSocketLifecycleBySession[event.sessionId]
            if activeLifecycleId != lifecycleId {
                if let watermark = latestSocketLifecycleOrderBySession[event.sessionId] {
                    guard let lifecycleOrder = event.lifecycleOrder, lifecycleOrder > watermark else {
                        retiredSocketLifecycleIdsBySession[event.sessionId, default: []].insert(lifecycleId)
                        return
                    }
                }
                if let activeLifecycleId {
                    retiredSocketLifecycleIdsBySession[event.sessionId, default: []].insert(activeLifecycleId)
                    backgroundActivityIdsBySession.removeValue(forKey: event.sessionId)
                    completedBackgroundActivityIdsBySession.removeValue(forKey: event.sessionId)
                    deferredForegroundIdleBySession.removeValue(forKey: event.sessionId)
                    activityBySession.removeValue(forKey: event.sessionId)
                }
            }
            if let lifecycleOrder = event.lifecycleOrder,
               lifecycleOrder > (latestSocketLifecycleOrderBySession[event.sessionId] ?? 0) {
                latestSocketLifecycleOrderBySession[event.sessionId] = lifecycleOrder
            }
            if event.event == .detached {
                retiredSocketLifecycleIdsBySession[event.sessionId, default: []].insert(lifecycleId)
                activeSocketLifecycleBySession.removeValue(forKey: event.sessionId)
            } else {
                activeSocketLifecycleBySession[event.sessionId] = lifecycleId
            }
        } else if event.agent == .pi {
            if event.event == .attached {
                detachedSocketSessions.remove(event.sessionId)
            } else if event.event != .detached, detachedSocketSessions.contains(event.sessionId) {
                return
            }
        }
        // ACP sessions export ALAS_SESSION_ID, so the agent's own hooks fire
        // too. Claude's hook reports idle prompts and permissions that auto-run
        // grants anyway; ACP already reports real questions and permissions.
        if event.event == .awaitingInput || event.event == .permissionRequest,
           isExternalSession(event.sessionId) {
            return
        }
        emitWorktreeActivityEventIfNeeded(event: event, stateLookup: stateLookup, ownerLookup: ownerLookup)
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
            // Background work does not answer a question or a failed turn;
            // `hasBackgroundActivity` reports its liveness instead.
            if foregroundState != .awaitingInput, foregroundState != .permissionRequest,
               foregroundState != .failed {
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
        // A hook idle after an ACP failure is the same turn ending (Pi maps
        // `agent_end` to idle); a new turn passes through busy first.
        if previous?.state == .failed { return }
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

    public nonisolated static func shouldRefreshWorktreeStatus(after event: ActivityEvent) -> Bool {
        switch event {
        case .busy, .backgroundStarted, .backgroundEnded, .idle, .awaitingInput, .permissionRequest, .detached:
            return true
        case .attached:
            return false
        }
    }

    public nonisolated static func shouldRefreshWorktreeStatus(after state: ActivityState) -> Bool {
        switch state {
        case .busy, .idle, .awaitingInput, .permissionRequest, .limited, .failed:
            return true
        }
    }

    public func stop() {
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
        latestSocketLifecycleOrderBySession.removeAll()
        retiredSocketLifecycleIdsBySession.removeAll()
    }

    /// Whether a hook-reported background workflow is still running for the
    /// session, independent of the foreground state it shows.
    public func hasBackgroundActivity(sessionId: String) -> Bool {
        backgroundActivityIdsBySession[sessionId]?.isEmpty == false
    }

    public func forgetSession(_ sessionId: String) {
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
    public func finishExternalActivity(
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
    public func setExternalActivity(sessionId: String, owner: SessionOwnerID? = nil, agent: AgentKind, state: ActivityState, body: String? = nil, isSnapshot: Bool = false, requiresUserInput: Bool = false) {
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

    public enum AggregatedState: String, Equatable, Sendable {
        case running, awaiting, limited, failed
    }

    public struct WorktreeHarnessSession: Equatable, Identifiable, Sendable {
        public let id: String
        public let state: AggregatedState
        public let agent: AgentKind

        public init(id: String, state: AggregatedState, agent: AgentKind) {
            self.id = id
            self.state = state
            self.agent = agent
        }
    }

    public struct WorktreeHarnessSummary: Equatable, Sendable {
        public let sessions: [WorktreeHarnessSession]
        public let state: AggregatedState
        public let agent: AgentKind
        public let primarySessionId: String
        public let runningSessionCount: Int
        public let awaitingSessionCount: Int

        public init(sessions: [WorktreeHarnessSession], state: AggregatedState, agent: AgentKind, primarySessionId: String, runningSessionCount: Int, awaitingSessionCount: Int) {
            self.sessions = sessions
            self.state = state
            self.agent = agent
            self.primarySessionId = primarySessionId
            self.runningSessionCount = runningSessionCount
            self.awaitingSessionCount = awaitingSessionCount
        }
    }

    public func summary(forSessionIds ids: [String]) -> WorktreeHarnessSummary? {
        let sessions = ids.enumerated().compactMap { offset, id -> (session: WorktreeHarnessSession, updatedAt: Date, offset: Int)? in
            guard let activity = activityBySession[id] else { return nil }
            switch activity.state {
            case .awaitingInput, .permissionRequest:
                return (WorktreeHarnessSession(id: id, state: .awaiting, agent: activity.agent), activity.updatedAt, offset)
            case .busy:
                return (WorktreeHarnessSession(id: id, state: .running, agent: activity.agent), activity.updatedAt, offset)
            case .limited:
                return (WorktreeHarnessSession(id: id, state: .limited, agent: activity.agent), activity.updatedAt, offset)
            case .failed:
                return (WorktreeHarnessSession(id: id, state: .failed, agent: activity.agent), activity.updatedAt, offset)
            case .idle:
                return nil
            }
        }
        .sorted { lhs, rhs in
            if lhs.session.state != rhs.session.state {
                return lhs.session.state.rollUpRank < rhs.session.state.rollUpRank
            }
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
    public func setStateForTesting(sessionId: String, agent: AgentKind, state: ActivityState) {
        activityBySession[sessionId] = HarnessActivityState(
            agent: agent, state: state, pid: nil, lastBody: nil, updatedAt: Date(),
            requiresUserInput: state == .permissionRequest
        )
    }
    #endif
}

extension HarnessService.AggregatedState {
    /// Worktree roll-up priority: awaiting > failed > running > limited.
    /// A failed turn needs the user, so it outranks work still in progress.
    public var rollUpRank: Int {
        switch self {
        case .awaiting: 0
        case .failed: 1
        case .running: 2
        case .limited: 3
        }
    }

    /// Lowercase status word for sidebar tooltips and notes.
    public var statusNote: String {
        switch self {
        case .running: "running"
        case .awaiting: "waiting"
        case .limited: "limited"
        case .failed: "failed"
        }
    }
}
