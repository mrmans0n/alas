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
    public var needsAttention: Bool {
        activeSessions.contains { $0.status == "awaitingPermission" || $0.status == "awaitingInput" }
    }

    fileprivate var recency: Int64 {
        (activeSessions + closedSessions).map(\.updatedAt).max() ?? 0
    }
}

public struct RemoteRepoSection: Identifiable, Equatable, Sendable {
    public let id: String
    public let title: String
    /// The owning Mac's name for federated rows; nil for the local host.
    public let hostName: String?
    public let worktrees: [RemoteWorktreeEntry]
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
            let project = s.projectId ?? s.worktree?.projectName ?? "Other"
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

    public static func filter(_ sections: [RemoteRepoSection], by filter: RemoteSessionFilter, query: String) -> [RemoteRepoSection] {
        sections.filter { matches($0, filter) && matches($0, query: query) }
    }

    public static func counts(_ sections: [RemoteRepoSection]) -> [RemoteSessionFilter: Int] {
        Dictionary(uniqueKeysWithValues: RemoteSessionFilter.allCases.map { f in
            (f, sections.filter { matches($0, f) }.count)
        })
    }

    private static func matches(_ section: RemoteRepoSection, _ filter: RemoteSessionFilter) -> Bool {
        switch filter {
        case .all: true
        case .running: section.worktrees.contains(where: \.isRunning)
        case .dirty: section.worktrees.contains(where: \.isDirty)
        }
    }

    private static func matches(_ section: RemoteRepoSection, query: String) -> Bool {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if needle.isEmpty { return true }
        let hit = { (text: String?) in text?.localizedCaseInsensitiveContains(needle) ?? false }
        return hit(section.title) || section.worktrees.contains { w in
            hit(w.title) || hit(w.summary?.branch)
                || (w.activeSessions + w.closedSessions).contains { hit($0.title) }
        }
    }
}
