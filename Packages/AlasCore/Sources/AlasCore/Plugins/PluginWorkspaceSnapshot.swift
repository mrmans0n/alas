import Foundation

/// What `workspace.read` exposes: one project's worktrees and their agent
/// sessions. Always the whole project, so plugins never reconcile diffs.
public struct PluginWorkspaceSnapshot: Codable, Equatable, Sendable {
    public struct WorktreeEntry: Codable, Equatable, Sendable {
        public let id: String
        public let branch: String
        public let current: Bool
        /// Omitted until the first status scan finishes.
        public let dirty: Dirty?
        public let sessions: [Session]
        /// True on the project's main worktree, omitted on the others.
        public var main: Bool?

        public init(id: String, branch: String, current: Bool, dirty: Dirty?, sessions: [Session], main: Bool? = nil) {
            self.id = id
            self.branch = branch
            self.current = current
            self.dirty = dirty
            self.sessions = sessions
            self.main = main
        }
    }

    public struct Dirty: Codable, Equatable, Sendable {
        public let files: Int
        public let conflicts: Int

        public init(files: Int, conflicts: Int) {
            self.files = files
            self.conflicts = conflicts
        }
    }

    public struct Session: Codable, Equatable, Sendable {
        public let id: String
        public let agent: String
        public let title: String
        public let state: String
        public let plan: Plan?

        public init(id: String, agent: String, title: String, state: String, plan: Plan?) {
            self.id = id
            self.agent = agent
            self.title = title
            self.state = state
            self.plan = plan
        }
    }

    public struct Plan: Codable, Equatable, Sendable {
        public let completed: Int
        public let total: Int

        public init(completed: Int, total: Int) {
            self.completed = completed
            self.total = total
        }
    }

    public let worktrees: [WorktreeEntry]

    public init(worktrees: [WorktreeEntry]) {
        self.worktrees = worktrees
    }
}

extension PluginWorkspaceSnapshot {
    public struct SessionInput: Sendable {
        public let id: String
        public let agent: String
        public let title: String
        public let state: AgentSidebarState
        public let plan: AgentSidebarPlanProgress?

        public init(id: String, agent: String, title: String, state: AgentSidebarState, plan: AgentSidebarPlanProgress?) {
            self.id = id
            self.agent = agent
            self.title = title
            self.state = state
            self.plan = plan
        }
    }

    public struct WorktreeInput: Sendable {
        public let worktree: Worktree
        public let dirty: WorktreeDirtyState
        public let sessions: [SessionInput]
        public var isMain = false

        public init(worktree: Worktree, dirty: WorktreeDirtyState, sessions: [SessionInput], isMain: Bool = false) {
            self.worktree = worktree
            self.dirty = dirty
            self.sessions = sessions
            self.isMain = isMain
        }
    }

    public init(worktrees: [WorktreeInput], selectedWorktreeId: String?) {
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

    public static func wireName(_ state: AgentSidebarState) -> String {
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
    public init(row: AgentSidebarRow) {
        let id: String = switch row.id {
        case .acp(let sessionID): sessionID
        case .terminal(_, let sessionID): sessionID
        }
        self.init(id: id, agent: row.agentID, title: row.title, state: row.state, plan: row.plan)
    }
}

/// One event's params. Each event sets only its own fields; the rest are omitted.
public struct PluginEventParams: Codable, Equatable, Sendable {
    public var session: String?
    public var worktree: String?
    /// `session/state`: the session's state. `review/changed`: the pull request's, or `none`.
    public var state: String?
    public var script: String?
    public var run: String?
    /// `run/finished`: `succeeded`, `failed`, `stopped` or `unknown`, and the exit code when the command reported one.
    public var outcome: String?
    public var exitCode: Int?
    public var number: Int?
    public var checks: PluginReviewChecks?
    /// `turn/finished` (API 12).
    public var turn: UsageTurn?

    public init(session: String? = nil, worktree: String? = nil, state: String? = nil, script: String? = nil, run: String? = nil, outcome: String? = nil, exitCode: Int? = nil, number: Int? = nil, checks: PluginReviewChecks? = nil, turn: UsageTurn? = nil) {
        self.session = session
        self.worktree = worktree
        self.state = state
        self.script = script
        self.run = run
        self.outcome = outcome
        self.exitCode = exitCode
        self.number = number
        self.checks = checks
        self.turn = turn
    }
}

public struct PluginEventMessage: Equatable, Sendable {
    public let event: PluginEvent
    public let params: PluginEventParams

    public init(event: PluginEvent, params: PluginEventParams) {
        self.event = event
        self.params = params
    }
}

/// The latest run of one script in one worktree.
public struct PluginRunState: Equatable, Sendable {
    public let run: String
    public let worktree: String
    public let script: String
    /// Nil while the run is going.
    public var outcome: RunOutcome?

    public init(run: String, worktree: String, script: String, outcome: RunOutcome? = nil) {
        self.run = run
        self.worktree = worktree
        self.script = script
        self.outcome = outcome
    }
}

public struct PluginReviewChecks: Codable, Equatable, Sendable {
    public let passed: Int
    public let failed: Int
    public let pending: Int

    public init(passed: Int, failed: Int, pending: Int) {
        self.passed = passed
        self.failed = failed
        self.pending = pending
    }
}

/// A worktree's pull request as the review loop last saw it.
public struct PluginReviewState: Equatable, Sendable {
    public let worktree: String
    /// `open`, `closed`, `merged`, or `none` without a pull request.
    public let state: String
    public var number: Int?
    public var checks: PluginReviewChecks?

    public init(worktree: String, state: String, number: Int? = nil, checks: PluginReviewChecks? = nil) {
        self.worktree = worktree
        self.state = state
        self.number = number
        self.checks = checks
    }
}

/// Everything plugin events are derived from, compared between two polls.
public struct PluginEventState: Equatable, Sendable {
    public var workspace: PluginWorkspaceSnapshot
    public var runs: [PluginRunState] = []
    public var reviews: [PluginReviewState] = []
    /// Every run id seen so far, so a run that comes back (a failed launch rolling the record back to it) is not
    /// reported again. ponytail: grows by one id per run for the life of the host.
    public var seenRuns: Set<String> = []
    /// Worktrees listed since the baseline whose review status has not been read yet: the first status read for
    /// one is its baseline, not a change, so a restart does not report every review.
    public var unloadedReviews: Set<String> = []

    /// The worktrees still waiting for their first review status once this state follows `previous`: at the
    /// baseline every listed one, since statuses are read after a start; later those of `previous` still listed,
    /// so a worktree removed and created again at the same path reports its first status.
    public func unloadedReviews(after previous: PluginEventState?) -> Set<String> {
        let listed = Set(workspace.worktrees.map(\.id))
        return (previous.map { $0.unloadedReviews.intersection(listed) } ?? listed).subtracting(reviews.map(\.worktree))
    }

    /// What changed since `old`. Polls are half a second apart, so that is how often a worktree's `git.changed`
    /// can fire; a dirty count that is first learned (the scan finishing) is not a change.
    public func events(since old: PluginEventState) -> [PluginEventMessage] {
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
            if reviewsBefore[review.worktree] == nil, old.unloadedReviews.contains(review.worktree) { continue }
            events.append(PluginEventMessage(event: .reviewChanged, params: PluginEventParams(
                worktree: review.worktree, state: review.state, number: review.number, checks: review.checks)))
        }
        for worktree in old.workspace.worktrees where !now.contains(worktree.id) {
            events.append(PluginEventMessage(event: .worktreeRemoved, params: PluginEventParams(worktree: worktree.id)))
        }
        return events
    }

    public init(
        workspace: PluginWorkspaceSnapshot,
        runs: [PluginRunState] = [],
        reviews: [PluginReviewState] = [],
        seenRuns: Set<String> = [],
        unloadedReviews: Set<String> = []
    ) {
        self.workspace = workspace
        self.runs = runs
        self.reviews = reviews
        self.seenRuns = seenRuns
        self.unloadedReviews = unloadedReviews
    }
}

extension PluginWorkspaceSnapshot {
    /// What changed for sessions since `old`: a state event for every session that is new or changed state,
    /// a finished event when one went from running to idle, and a `gone` state for one that left the snapshot
    /// (closed, or disconnected and detached), so a subscriber never keeps a stale state.
    public func sessionEvents(since old: PluginWorkspaceSnapshot) -> [PluginEventMessage] {
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
    public init(snapshot: ReviewLoopSnapshot, worktree: String) {
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
