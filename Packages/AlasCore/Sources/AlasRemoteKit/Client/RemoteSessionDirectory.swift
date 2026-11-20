import Foundation

/// Native port of `repo-filter.js` and the grouping in `session-ordering.js`.
public enum RemoteSessionFilter: CaseIterable, Sendable { case all, running, dirty }

/// The Mac sidebar's worktree orders, less Manual: a peer never sees the Mac's drag order.
public enum RemoteWorktreeSort: String, CaseIterable, Sendable {
    case lastUpdateDesc, lastUpdateAsc, creationDesc, creationAsc, branchAsc
}

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

    /// The host's project it is listed under: a Machine checkout's local
    /// project, which is where the host creates its new worktrees.
    public var projectId: String? {
        summary?.linkedProjectId ?? (activeSessions + closedSessions).lazy.compactMap(\.projectId).first
    }

    /// The session a tap on the worktree opens: one waiting on the user, else
    /// one mid-turn, else the newest open one, else the newest closed one.
    public var leadSession: RemoteSessionSummary? {
        activeSessions.first(where: \.isAwaitingUser)
            ?? activeSessions.first { $0.status != "idle" }
            ?? activeSessions.first
            ?? closedSessions.first
    }

    /// `activeSessions` as the list shows them: each delegated session right after
    /// its parent, groups needing the user first, then running ones, then idle,
    /// each rank keeping newest-first order.
    public var sessionRows: [RemoteSessionRow] {
        let ids = Set(activeSessions.map(\.id))
        var children: [String: [RemoteSessionSummary]] = [:]
        var roots: [RemoteSessionSummary] = []
        for s in activeSessions {
            if let p = s.parentSessionId, p != s.id, ids.contains(p) {
                children[p, default: []].append(s)
            } else {
                roots.append(s)
            }
        }
        func rank(_ s: RemoteSessionSummary) -> Int { s.isAwaitingUser ? 0 : s.status != "idle" ? 1 : 2 }
        func groupRank(_ s: RemoteSessionSummary, _ seen: inout Set<String>) -> Int {
            guard seen.insert(s.id).inserted else { return 2 }
            return (children[s.id] ?? []).reduce(rank(s)) { min($0, groupRank($1, &seen)) }
        }
        var emitted = Set<String>()
        var rows: [RemoteSessionRow] = []
        func emit(_ s: RemoteSessionSummary, depth: Int) {
            guard emitted.insert(s.id).inserted else { return }
            rows.append(RemoteSessionRow(session: s, depth: depth))
            for c in children[s.id] ?? [] { emit(c, depth: 1) }
        }
        let ranked = roots.enumerated().map { i, s in
            var seen = Set<String>()
            return (rank: groupRank(s, &seen), index: i, session: s)
        }
        for r in ranked.sorted(by: { ($0.rank, $0.index) < ($1.rank, $1.index) }) { emit(r.session, depth: 0) }
        // Sessions that only reach each other through a parent cycle have no root; list them last.
        for s in activeSessions { emit(s, depth: 0) }
        return rows
    }

    var recency: Int64 {
        (activeSessions + closedSessions).map(\.updatedAt).max() ?? 0
    }
}

public struct RemoteSessionRow: Identifiable, Equatable, Sendable {
    public let session: RemoteSessionSummary
    /// 0 for a top-level session, 1 for one delegated by a session listed above it (deeper nesting clamps to 1).
    public let depth: Int
    public var id: String { session.id }
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

    /// `worktrees`, recency-ordered as `sections` gives them, under `sort`.
    /// Ties keep that order.
    public static func sorted(_ worktrees: [RemoteWorktreeEntry], by sort: RemoteWorktreeSort) -> [RemoteWorktreeEntry] {
        sorted(worktrees, by: sort, \.self)
    }

    static func sorted<Item>(_ items: [Item], by sort: RemoteWorktreeSort,
                             _ worktree: (Item) -> RemoteWorktreeEntry) -> [Item] {
        func by<K: Comparable>(descending: Bool = false, _ key: (RemoteWorktreeEntry) -> K) -> [Item] {
            items.enumerated().sorted { l, r in
                let (lk, rk) = (key(worktree(l.element)), key(worktree(r.element)))
                if lk != rk { return descending ? lk > rk : lk < rk }
                return l.offset < r.offset
            }.map(\.element)
        }
        switch sort {
        case .lastUpdateDesc: return items
        case .lastUpdateAsc: return by(\.recency)
        // As on the Mac: a host that predates `createdAt` sends none, so keep the order.
        case .creationDesc, .creationAsc:
            guard items.allSatisfy({ worktree($0).summary?.createdAt != nil }) else { return items }
            return by(descending: sort == .creationDesc) { $0.summary?.createdAt ?? 0 }
        case .branchAsc: return by { ($0.summary?.branch ?? $0.title).localizedLowercase }
        }
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
