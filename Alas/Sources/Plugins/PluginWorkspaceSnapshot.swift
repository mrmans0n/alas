import Foundation

/// What `workspace.read` exposes: one project's worktrees and their agent
/// sessions. Always the whole project, so plugins never reconcile diffs.
struct PluginWorkspaceSnapshot: Codable, Equatable, Sendable {
    struct WorktreeEntry: Codable, Equatable, Sendable {
        let id: String
        let branch: String
        let current: Bool
        /// Omitted until the first status scan finishes.
        let dirty: Dirty?
        let sessions: [Session]
        /// True on the project's main worktree, omitted on the others.
        var main: Bool?
    }

    struct Dirty: Codable, Equatable, Sendable {
        let files: Int
        let conflicts: Int
    }

    struct Session: Codable, Equatable, Sendable {
        let id: String
        let agent: String
        let title: String
        let state: String
        let plan: Plan?
    }

    struct Plan: Codable, Equatable, Sendable {
        let completed: Int
        let total: Int
    }

    let worktrees: [WorktreeEntry]
}

extension PluginWorkspaceSnapshot {
    struct SessionInput {
        let id: String
        let agent: String
        let title: String
        let state: AgentSidebarState
        let plan: AgentSidebarPlanProgress?
    }

    struct WorktreeInput {
        let worktree: Worktree
        let dirty: WorktreeDirtyState
        let sessions: [SessionInput]
        var isMain = false
    }

    init(worktrees: [WorktreeInput], selectedWorktreeId: String?) {
        self.init(worktrees: worktrees.map { input in
            let dirty: Dirty? = switch input.dirty {
            case .unknown: nil
            case .clean: Dirty(files: 0, conflicts: 0)
            case let .dirty(files, conflicts): Dirty(files: files, conflicts: conflicts)
            }
            return WorktreeEntry(
                id: input.worktree.id,
                branch: input.worktree.branch,
                current: input.worktree.id == selectedWorktreeId,
                dirty: dirty,
                sessions: input.sessions.map { session in
                    Session(
                        id: session.id, agent: session.agent, title: session.title,
                        state: Self.wireName(session.state),
                        plan: session.plan.map { Plan(completed: $0.completed, total: $0.total) })
                },
                main: input.isMain ? true : nil)
        })
    }

    static func wireName(_ state: AgentSidebarState) -> String {
        switch state {
        case .running: "running"
        case .awaitingInput: "awaiting_input"
        case .permissionRequest: "permission_request"
        case .idle: "idle"
        case .failed: "failed"
        case .detached: "detached"
        case .unknown: "unknown"
        }
    }
}

extension PluginWorkspaceSnapshot.SessionInput {
    init(row: AgentSidebarRow) {
        let id: String = switch row.id {
        case .acp(let sessionID): sessionID
        case .terminal(_, let sessionID): sessionID
        }
        self.init(id: id, agent: row.agentID, title: row.title, state: row.state, plan: row.plan)
    }
}

/// One event's params. Each event sets only its own fields; the rest are omitted.
struct PluginEventParams: Codable, Equatable, Sendable {
    var session: String?
    var worktree: String?
    /// `session/state`: the session's state. `review/changed`: the pull request's, or `none`.
    var state: String?
    var script: String?
    var run: String?
    /// `run/finished`: `succeeded`, `failed`, `stopped` or `unknown`, and the exit code when the command reported one.
    var outcome: String?
    var exitCode: Int?
    var number: Int?
    var checks: PluginReviewChecks?
}

struct PluginEventMessage: Equatable, Sendable {
    let event: PluginEvent
    let params: PluginEventParams
}

/// The latest run of one script in one worktree.
struct PluginRunState: Equatable, Sendable {
    let run: String
    let worktree: String
    let script: String
    /// Nil while the run is going.
    var outcome: RunOutcome?
}

struct PluginReviewChecks: Codable, Equatable, Sendable {
    let passed: Int
    let failed: Int
    let pending: Int
}

/// A worktree's pull request as the review loop last saw it.
struct PluginReviewState: Equatable, Sendable {
    let worktree: String
    /// `open`, `closed`, `merged`, or `none` without a pull request.
    let state: String
    var number: Int?
    var checks: PluginReviewChecks?
}

/// Everything plugin events are derived from, compared between two polls.
struct PluginEventState: Equatable, Sendable {
    var workspace: PluginWorkspaceSnapshot
    var runs: [PluginRunState] = []
    var reviews: [PluginReviewState] = []
    /// Every run id seen so far, so a run that comes back (a failed launch rolling the record back to it) is not
    /// reported again. ponytail: grows by one id per run for the life of the host.
    var seenRuns: Set<String> = []

    /// What changed since `old`. Polls are half a second apart, so that is how often a worktree's `git.changed`
    /// can fire; a dirty count that is first learned (the scan finishing) is not a change.
    func events(since old: PluginEventState) -> [PluginEventMessage] {
        var events: [PluginEventMessage] = []
        let before = Dictionary(old.workspace.worktrees.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let now = Set(workspace.worktrees.map(\.id))
        // Parents before children: a worktree is created before its sessions are reported, and its sessions and
        // runs end before it is removed, which is the last thing reported.
        for worktree in workspace.worktrees where before[worktree.id] == nil {
            events.append(PluginEventMessage(event: .worktreeCreated, params: PluginEventParams(worktree: worktree.id)))
            // Created and selected between two polls: the move to it is still a focus change.
            if worktree.current {
                events.append(PluginEventMessage(event: .focusChanged, params: PluginEventParams(worktree: worktree.id)))
            }
        }
        events += workspace.sessionEvents(since: old.workspace)
        for worktree in workspace.worktrees {
            guard let previous = before[worktree.id] else { continue }
            if previous.dirty != nil, worktree.dirty != nil, previous.dirty != worktree.dirty {
                events.append(PluginEventMessage(event: .gitChanged, params: PluginEventParams(worktree: worktree.id)))
            }
            if worktree.current, !previous.current {
                events.append(PluginEventMessage(event: .focusChanged, params: PluginEventParams(worktree: worktree.id)))
            }
        }
        let runsBefore = Dictionary(old.runs.map { ($0.run, $0) }, uniquingKeysWith: { first, _ in first })
        // A run still going at the last poll that a restart replaced before this one: its end was never seen.
        let runsNow = Set(runs.map(\.run))
        for run in old.runs where run.outcome == nil && !runsNow.contains(run.run) {
            var finished = PluginEventParams(worktree: run.worktree, script: run.script, run: run.run)
            finished.outcome = "unknown"
            events.append(PluginEventMessage(event: .runFinished, params: finished))
        }
        for run in runs {
            let previous = runsBefore[run.run]
            if previous == nil, old.seenRuns.contains(run.run) { continue }
            let params = PluginEventParams(worktree: run.worktree, script: run.script, run: run.run)
            if previous == nil { events.append(PluginEventMessage(event: .runStarted, params: params)) }
            // A run that started and finished between two polls gets both.
            if let outcome = run.outcome, previous?.outcome == nil {
                var finished = params
                (finished.outcome, finished.exitCode) = switch outcome {
                case .succeeded: ("succeeded", 0)
                case .failed(let code): ("failed", Int(code))
                case .stopped: ("stopped", nil)
                case .unknown: ("unknown", nil)
                }
                events.append(PluginEventMessage(event: .runFinished, params: finished))
            }
        }
        let reviewsBefore = Dictionary(old.reviews.map { ($0.worktree, $0) }, uniquingKeysWith: { first, _ in first })
        for review in reviews where reviewsBefore[review.worktree] != review {
            events.append(PluginEventMessage(event: .reviewChanged, params: PluginEventParams(
                worktree: review.worktree, state: review.state, number: review.number, checks: review.checks)))
        }
        for worktree in old.workspace.worktrees where !now.contains(worktree.id) {
            events.append(PluginEventMessage(event: .worktreeRemoved, params: PluginEventParams(worktree: worktree.id)))
        }
        return events
    }
}

extension PluginWorkspaceSnapshot {
    /// What changed for sessions since `old`: a state event for every session that is new or changed state,
    /// a finished event when one went from running to idle, and a `gone` state for one that left the snapshot
    /// (closed, or disconnected and detached), so a subscriber never keeps a stale state.
    func sessionEvents(since old: PluginWorkspaceSnapshot) -> [PluginEventMessage] {
        let before = Dictionary(
            old.worktrees.flatMap { $0.sessions.map { ($0.id, $0.state) } }, uniquingKeysWith: { first, _ in first })
        let now = Set(worktrees.flatMap { $0.sessions.map(\.id) })
        var events: [PluginEventMessage] = []
        func state(_ session: String, _ worktree: String, _ state: String) -> PluginEventMessage {
            PluginEventMessage(event: .sessionState, params: PluginEventParams(session: session, worktree: worktree, state: state))
        }
        for worktree in old.worktrees {
            for session in worktree.sessions where !now.contains(session.id) {
                events.append(state(session.id, worktree.id, "gone"))
            }
        }
        for worktree in worktrees {
            for session in worktree.sessions where before[session.id] != session.state {
                events.append(state(session.id, worktree.id, session.state))
                if before[session.id] == "running", session.state == "idle" {
                    events.append(PluginEventMessage(
                        event: .sessionFinished, params: PluginEventParams(session: session.id, worktree: worktree.id)))
                }
            }
        }
        return events
    }
}

extension PluginReviewState {
    /// Kept small: the pull request's number and state, and its checks counted by result.
    init(snapshot: ReviewLoopSnapshot, worktree: String) {
        guard let request = snapshot.reviewRequest else {
            self.init(worktree: worktree, state: "none")
            return
        }
        let buckets = request.checks.map(\.bucket)
        self.init(
            worktree: worktree, state: request.state.rawValue, number: request.number,
            checks: PluginReviewChecks(
                passed: buckets.filter { $0 == .pass }.count,
                failed: buckets.filter { $0 == .fail || $0 == .cancel }.count,
                pending: buckets.filter { $0 == .pending }.count))
    }
}
