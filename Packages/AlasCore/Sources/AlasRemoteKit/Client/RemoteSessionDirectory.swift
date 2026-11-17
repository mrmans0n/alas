import Foundation

/// Native port of `repo-filter.js` and the grouping in `session-ordering.js`.
public enum RemoteSessionFilter: CaseIterable, Sendable { case all, running, dirty }

public struct RemoteWorktreeEntry: Identifiable, Equatable, Sendable {
    public let id: String
    public let title: String
    public let summary: RemoteWorktreeSummary?
    public let activeSessions: [RemoteSessionSummary]
    public let closedSessions: [RemoteSessionSummary]

    /// An open session whose agent is mid-turn or parked on a prompt.
    public var isRunning: Bool { activeSessions.contains { $0.status != "idle" } }
    public var isDirty: Bool { (summary?.changedFileCount ?? 0) > 0 }
    public var needsAttention: Bool { activeSessions.contains(where: \.isAwaitingUser) }

    /// The session a tap on the worktree opens: one waiting on the user, else
    /// one mid-turn, else the newest open one, else the newest closed one.
    public var leadSession: RemoteSessionSummary? {
        activeSessions.first(where: \.isAwaitingUser)
            ?? activeSessions.first { $0.status != "idle" }
            ?? activeSessions.first
            ?? closedSessions.first
    }

    var recency: Int64 {
        (activeSessions + closedSessions).map(\.updatedAt).max() ?? 0
    }
}

public struct RemoteRepoSection: Identifiable, Equatable, Sendable {
    public let id: String
    public let title: String
    /// The owning Mac's name for federated rows; nil for the local host.
    public let hostName: String?
    public let worktrees: [RemoteWorktreeEntry]

    /// The repository its worktrees report, when the host knows it.
    public var repositoryKey: String? { worktrees.lazy.compactMap { $0.summary?.repositoryKey }.first }
}

public enum RemoteSessionDirectory {
    // `localHostName` is accepted for the caller's convenience; local sections carry a nil `hostName`.
    public static func sections(_ sessions: [RemoteSessionSummary], localHostName: String) -> [RemoteRepoSection] {
        struct WorktreeBucket {
            var title: String
            var summary: RemoteWorktreeSummary?
            var active: [RemoteSessionSummary] = []
            var closed: [RemoteSessionSummary] = []
        }
        struct SectionBucket {
            var title: String
            var hostName: String?
            var worktrees: [String: WorktreeBucket] = [:]
        }
        var buckets: [String: SectionBucket] = [:]
        for s in sessions {
            // A Machine checkout's sessions join its local project's section.
            let project = s.worktree?.linkedProjectId ?? s.projectId ?? s.worktree?.projectName ?? "Other"
            let sectionKey = "\(s.serverId ?? "")|\(project)"
            let worktreeKey = s.worktreeId ?? s.worktree?.path ?? s.id
            var section = buckets[sectionKey] ?? SectionBucket(title: s.worktree?.projectName ?? project, hostName: s.serverId == nil ? nil : s.serverName)
            var wt = section.worktrees[worktreeKey] ?? WorktreeBucket(title: s.worktree?.worktreeName ?? s.title, summary: s.worktree)
            if s.isActive { wt.active.append(s) } else { wt.closed.append(s) }
            section.worktrees[worktreeKey] = wt
            buckets[sectionKey] = section
        }
        let newestFirst: (RemoteSessionSummary, RemoteSessionSummary) -> Bool = {
            $0.updatedAt != $1.updatedAt ? $0.updatedAt > $1.updatedAt : ($0.title, $0.id) < ($1.title, $1.id)
        }
        return buckets.map { key, section in
            let worktrees = section.worktrees.map { id, wt in
                RemoteWorktreeEntry(id: id, title: wt.title, summary: wt.summary, activeSessions: wt.active.sorted(by: newestFirst), closedSessions: wt.closed.sorted(by: newestFirst))
            }.sorted { ($0.recency, $1.title, $1.id) > ($1.recency, $0.title, $0.id) }
            return RemoteRepoSection(id: key, title: section.title, hostName: section.hostName, worktrees: worktrees)
        }.sorted {
            let (a, b) = ($0.worktrees.map(\.recency).max() ?? 0, $1.worktrees.map(\.recency).max() ?? 0)
            return a != b ? a > b : ($0.title, $0.id) < ($1.title, $1.id)
        }
    }

    /// Worktrees waiting on the user first, then running ones, each group
    /// keeping the recency order `sections` gave it.
    public static func attentionFirst(_ worktrees: [RemoteWorktreeEntry]) -> [RemoteWorktreeEntry] {
        attentionFirst(worktrees, by: \.self)
    }

    static func attentionFirst<Item>(_ items: [Item], by worktree: (Item) -> RemoteWorktreeEntry) -> [Item] {
        func rank(_ w: RemoteWorktreeEntry) -> Int { w.needsAttention ? 0 : w.isRunning ? 1 : 2 }
        return items.enumerated()
            .sorted { (rank(worktree($0.element)), $0.offset) < (rank(worktree($1.element)), $1.offset) }
            .map(\.element)
    }

    public static func filter(_ sections: [RemoteRepoSection], by filter: RemoteSessionFilter, query: String) -> [RemoteRepoSection] {
        sections.filter { matches(title: $0.title, worktrees: $0.worktrees, filter: filter, query: query) }
    }

    public static func counts(_ sections: [RemoteRepoSection]) -> [RemoteSessionFilter: Int] {
        Dictionary(uniqueKeysWithValues: RemoteSessionFilter.allCases.map { f in
            (f, sections.filter { matches(title: $0.title, worktrees: $0.worktrees, filter: f, query: "") }.count)
        })
    }

    static func matches(title: String, worktrees: [RemoteWorktreeEntry], filter: RemoteSessionFilter, query: String) -> Bool {
        let kept = switch filter {
        case .all: true
        case .running: worktrees.contains(where: \.isRunning)
        case .dirty: worktrees.contains(where: \.isDirty)
        }
        guard kept else { return false }
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if needle.isEmpty { return true }
        let hit = { (text: String?) in text?.localizedCaseInsensitiveContains(needle) ?? false }
        return hit(title) || worktrees.contains { w in
            hit(w.title) || hit(w.summary?.branch)
                || (w.activeSessions + w.closedSessions).contains { hit($0.title) }
        }
    }
}

extension RemoteSessionSummary {
    /// The agent is parked on a permission prompt or a question.
    public var isAwaitingUser: Bool { status == "awaitingPermission" || status == "awaitingInput" }
}
