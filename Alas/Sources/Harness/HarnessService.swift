import Foundation
import Observation

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
    }

    func stop() {
        detector.stop()
        socketServer.shutdown()
        for debouncer in cursorIdleDebouncers.values { debouncer.cancel() }
        cursorIdleDebouncers.removeAll()
        pendingCursorIdleEvents.removeAll()
    }

    func forgetSession(_ sessionId: String) {
        harnessBySession.removeValue(forKey: sessionId)
        activeHarnessBySession.removeValue(forKey: sessionId)
        activityBySession.removeValue(forKey: sessionId)
        cursorIdleDebouncers.removeValue(forKey: sessionId)?.cancel()
        pendingCursorIdleEvents.removeValue(forKey: sessionId)
    }

    /// Peer-write entry point alongside socket events. Lets non-hook sources
    /// (currently the ACP bridge) report activity for sessions they own.
    /// No notification side effects — those remain socket-driven so we don't
    /// double-fire when both hooks and ACP cover the same session.
    func setExternalActivity(sessionId: String, agent: AgentKind, state: ActivityState) {
        activityBySession[sessionId] = HarnessActivityState(
            agent: agent, state: state, pid: nil,
            lastBody: nil, updatedAt: Date()
        )
    }

    enum AggregatedState: String, Equatable {
        case running, awaiting
    }

    struct WorktreeHarnessSummary: Equatable {
        let state: AggregatedState
        let agent: AgentKind
        let primarySessionId: String
        let runningSessionCount: Int
        let awaitingSessionCount: Int
    }

    func summary(forSessionIds ids: [String]) -> WorktreeHarnessSummary? {
        var awaitingIds: [String] = []
        var runningIds: [String] = []
        for id in ids {
            guard let activity = activityBySession[id] else { continue }
            switch activity.state {
            case .awaitingInput, .permissionRequest: awaitingIds.append(id)
            case .busy:          runningIds.append(id)
            case .idle:          break
            }
        }
        if let s = pickSummary(state: .awaiting, ids: awaitingIds,
                               runningCount: runningIds.count, awaitingCount: awaitingIds.count) { return s }
        if let s = pickSummary(state: .running, ids: runningIds,
                               runningCount: runningIds.count, awaitingCount: awaitingIds.count) { return s }
        return nil
    }

    private func pickSummary(
        state: AggregatedState, ids: [String],
        runningCount: Int, awaitingCount: Int
    ) -> WorktreeHarnessSummary? {
        guard let primary = ids.first,
              let activity = activityBySession[primary] else { return nil }
        return WorktreeHarnessSummary(
            state: state, agent: activity.agent,
            primarySessionId: primary,
            runningSessionCount: runningCount,
            awaitingSessionCount: awaitingCount
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
