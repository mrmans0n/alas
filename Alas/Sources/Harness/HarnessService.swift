import Foundation
import Observation

struct HarnessActivityTransition: Equatable {
    let sessionID: String
    let agent: AgentKind
    let state: ActivityState?
    let body: String?
    let occurredAt: Date
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

    struct HarnessActivityState: Equatable {
        var agent: AgentKind
        var state: ActivityState
        var pid: pid_t?
        var lastBody: String?
        var updatedAt: Date
    }

    /// Cursor notifications are less reliable than Claude's and frequently
    /// flap `idle -> busy -> idle` for a single ongoing turn. We debounce
    /// `.idle` events for Cursor so the `run` badge stays visible until
    /// work has actually settled.
    private var cursorIdleDebouncers: [String: DebounceTimer] = [:]
    private var pendingCursorIdleEvents: [String: AgentHookEvent] = [:]
    private let cursorIdleDebounceInterval: TimeInterval

    init(cursorIdleDebounceInterval: TimeInterval = 2.0) {
        self.cursorIdleDebounceInterval = cursorIdleDebounceInterval
        socketServer = AgentHookSocketServer()
    }

    init(socketServer: AgentHookSocketServer, cursorIdleDebounceInterval: TimeInterval = 2.0) {
        self.cursorIdleDebounceInterval = cursorIdleDebounceInterval
        self.socketServer = socketServer
    }

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
        let previousState = activityBySession[event.sessionId]?.state
        let previous = activityBySession[event.sessionId]
        // Idle commits separately because Cursor may defer the authoritative change.
        defer {
            if event.event != .idle {
                emitActivityTransition(sessionID: event.sessionId, previous: previous)
            }
        }

        switch event.event {
        case .attached, .busy:
            // Cancel any pending cursor-idle debounce — work is actually ongoing.
            if event.agent == .cursor {
                cursorIdleDebouncers.removeValue(forKey: event.sessionId)?.cancel()
                pendingCursorIdleEvents.removeValue(forKey: event.sessionId)
            }
            activityBySession[event.sessionId] = HarnessActivityState(
                agent: event.agent, state: .busy, pid: event.pid,
                lastBody: nil, updatedAt: Date()
            )

        case .awaitingInput:
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
                lastBody: event.body, updatedAt: Date()
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
            cursorIdleDebouncers.removeValue(forKey: event.sessionId)?.cancel()
            pendingCursorIdleEvents.removeValue(forKey: event.sessionId)
            activityBySession.removeValue(forKey: event.sessionId)
        }
    }

    private func commitIdle(
        event: AgentHookEvent,
        stateLookup: @escaping (String) -> (projectId: String, worktreeId: String)?,
        ownerLookup: @escaping (String) -> SessionOwnerID?
    ) {
        let previous = activityBySession[event.sessionId]
        activityBySession[event.sessionId] = HarnessActivityState(
            agent: event.agent, state: .idle, pid: event.pid,
            lastBody: event.body, updatedAt: Date()
        )
        if let lookup = stateLookup(event.sessionId) {
            notifications.notifyHarnessFinished(
                agent: event.agent, body: event.body,
                projectId: lookup.projectId, worktreeId: lookup.worktreeId,
                sessionId: event.sessionId,
                owner: ownerLookup(event.sessionId)
            )
        }
        emitActivityTransition(sessionID: event.sessionId, previous: previous)
    }

    func stop() {
        detector.stop()
        socketServer.shutdown()
        for debouncer in cursorIdleDebouncers.values { debouncer.cancel() }
        cursorIdleDebouncers.removeAll()
        pendingCursorIdleEvents.removeAll()
    }

    func forgetSession(_ sessionId: String) {
        let previous = activityBySession[sessionId]
        harnessBySession.removeValue(forKey: sessionId)
        activeHarnessBySession.removeValue(forKey: sessionId)
        activityBySession.removeValue(forKey: sessionId)
        cursorIdleDebouncers.removeValue(forKey: sessionId)?.cancel()
        pendingCursorIdleEvents.removeValue(forKey: sessionId)
        emitActivityTransition(sessionID: sessionId, previous: previous)
    }

    /// Peer-write entry point alongside socket events. Lets non-hook sources
    /// (currently the ACP bridge) report activity for sessions they own.
    /// No notification side effects — those remain socket-driven so we don't
    /// double-fire when both hooks and ACP cover the same session.
    func setExternalActivity(sessionId: String, agent: AgentKind, state: ActivityState) {
        let previous = activityBySession[sessionId]
        activityBySession[sessionId] = HarnessActivityState(
            agent: agent, state: state, pid: nil,
            lastBody: nil, updatedAt: Date()
        )
        emitActivityTransition(sessionID: sessionId, previous: previous)
    }

    private func emitActivityTransition(sessionID: String, previous: HarnessActivityState?) {
        let current = activityBySession[sessionID]
        let bodyChanged = current?.lastBody != previous?.lastBody
            && (current?.state == .awaitingInput || current?.state == .permissionRequest)
        guard current?.state != previous?.state || current?.agent != previous?.agent || bodyChanged,
              let agent = current?.agent ?? previous?.agent else { return }
        onActivityTransition?(HarnessActivityTransition(
            sessionID: sessionID, agent: agent, state: current?.state,
            body: current?.lastBody, occurredAt: current?.updatedAt ?? Date()
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
            agent: agent, state: state, pid: nil, lastBody: nil, updatedAt: Date()
        )
    }
    #endif
}
