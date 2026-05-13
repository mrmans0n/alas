import Foundation
import Observation

@Observable
final class HarnessService {
    let detector = HarnessDetector()
    let socketServer: AgentHookSocketServer
    let notifications = NotificationService()

    private(set) var activityBySession: [String: HarnessActivityState] = [:]
    private(set) var harnessBySession: [String: HarnessKind] = [:]

    var onClickThrough: ((String, String, String) -> Void)?

    struct HarnessActivityState: Equatable {
        var agent: AgentKind
        var state: ActivityState
        var pid: pid_t?
        var lastBody: String?
        var updatedAt: Date
    }

    init() {
        socketServer = AgentHookSocketServer()
    }

    init(socketServer: AgentHookSocketServer) {
        self.socketServer = socketServer
    }

    func start(
        stateLookup: @escaping (String) -> (projectId: String, worktreeId: String)?,
        shouldNotifyOnAwaiting: @escaping () -> Bool = { true }
    ) {
        detector.onUpdate = { [weak self] sid, kind in
            guard let self else { return }
            self.recordHarnessDetection(sessionId: sid, kind: kind)
        }
        detector.start()

        notifications.setup { [weak self] p, w, s in
            self?.onClickThrough?(p, w, s)
        }

        socketServer.onEvent = { [weak self] event in
            self?.handleSocketEvent(event, stateLookup: stateLookup, shouldNotifyOnAwaiting: shouldNotifyOnAwaiting)
        }
    }

    func recordHarnessDetection(sessionId: String, kind: HarnessKind?) {
        if let kind {
            harnessBySession[sessionId] = kind
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
        stateLookup: (String) -> (projectId: String, worktreeId: String)?,
        shouldNotifyOnAwaiting: () -> Bool
    ) {
        let previousState = activityBySession[event.sessionId]?.state

        switch event.event {
        case .busy:
            activityBySession[event.sessionId] = HarnessActivityState(
                agent: event.agent, state: .busy, pid: event.pid,
                lastBody: nil, updatedAt: Date()
            )

        case .awaitingInput:
            activityBySession[event.sessionId] = HarnessActivityState(
                agent: event.agent, state: .awaitingInput, pid: event.pid,
                lastBody: event.body, updatedAt: Date()
            )
            if previousState != .awaitingInput, shouldNotifyOnAwaiting(),
               let lookup = stateLookup(event.sessionId) {
                notifications.notifyHarnessAwaiting(
                    agent: event.agent, body: event.body,
                    projectId: lookup.projectId, worktreeId: lookup.worktreeId,
                    sessionId: event.sessionId
                )
            }

        case .idle:
            activityBySession[event.sessionId] = HarnessActivityState(
                agent: event.agent, state: .idle, pid: event.pid,
                lastBody: event.body, updatedAt: Date()
            )
            if let lookup = stateLookup(event.sessionId) {
                notifications.notifyHarnessFinished(
                    agent: event.agent, body: event.body,
                    projectId: lookup.projectId, worktreeId: lookup.worktreeId,
                    sessionId: event.sessionId
                )
            }
        }
    }

    func stop() {
        detector.stop()
        socketServer.shutdown()
    }

    func forgetSession(_ sessionId: String) {
        harnessBySession.removeValue(forKey: sessionId)
        activityBySession.removeValue(forKey: sessionId)
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
            case .awaitingInput: awaitingIds.append(id)
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
