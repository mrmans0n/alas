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
                })
        })
    }

    static func wireName(_ state: AgentSidebarState) -> String {
        switch state {
        case .running: "running"
        case .awaitingInput: "awaiting_input"
        case .permissionRequest: "permission_request"
        case .idle: "idle"
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

/// `session/state` and `session/finished` params; `state` is only sent with `session/state`.
struct PluginSessionEventParams: Codable, Equatable, Sendable {
    let session: String
    let worktree: String
    var state: String?
}

struct PluginSessionEvent: Equatable, Sendable {
    let event: PluginEvent
    let session: String
    let worktree: String
    var state: String?

    var params: PluginSessionEventParams { PluginSessionEventParams(session: session, worktree: worktree, state: state) }
}

extension PluginWorkspaceSnapshot {
    /// What changed for sessions since `old`: a state event for every session that is new or changed state,
    /// a finished event when one went from running to idle, and a `gone` state for one that left the snapshot
    /// (closed, or disconnected and detached), so a subscriber never keeps a stale state.
    func sessionEvents(since old: PluginWorkspaceSnapshot) -> [PluginSessionEvent] {
        let before = Dictionary(
            old.worktrees.flatMap { $0.sessions.map { ($0.id, $0.state) } }, uniquingKeysWith: { first, _ in first })
        let now = Set(worktrees.flatMap { $0.sessions.map(\.id) })
        var events: [PluginSessionEvent] = []
        for worktree in old.worktrees {
            for session in worktree.sessions where !now.contains(session.id) {
                events.append(PluginSessionEvent(event: .sessionState, session: session.id, worktree: worktree.id, state: "gone"))
            }
        }
        for worktree in worktrees {
            for session in worktree.sessions where before[session.id] != session.state {
                events.append(PluginSessionEvent(
                    event: .sessionState, session: session.id, worktree: worktree.id, state: session.state))
                if before[session.id] == "running", session.state == "idle" {
                    events.append(PluginSessionEvent(event: .sessionFinished, session: session.id, worktree: worktree.id))
                }
            }
        }
        return events
    }
}
