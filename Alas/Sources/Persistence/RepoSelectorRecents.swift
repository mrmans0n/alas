import Foundation

/// Mutable, value-typed recents store used by the repo selector. Lives on
/// `AppConfig` as two plain fields; this struct is the in-memory shape +
/// mutation helpers so the persistence layer doesn't carry behavior.
struct RepoSelectorRecents: Equatable {
    static let projectCap = 5
    static let worktreeCapPerProject = 5
    static let recentWorktreeRefCap = 5

    /// A (project, worktree) pair used by the global RECENT list. We need
    /// the project id because the worktree id alone isn't enough to look
    /// up its project in `visibleWorktrees`.
    struct RecentWorktreeRef: Codable, Equatable {
        let projectId: String
        let worktreeId: String
    }

    var projectIds: [String] = []
    var worktreeIdsByProject: [String: [String]] = [:]
    /// Cross-project, globally-recency-ordered worktree list. Capped at
    /// `recentWorktreeRefCap`. Newer entries are at the front.
    var recentWorktreeRefs: [RecentWorktreeRef] = []

    init(
        projectIds: [String] = [],
        worktreeIdsByProject: [String: [String]] = [:],
        recentWorktreeRefs: [RecentWorktreeRef] = []
    ) {
        self.projectIds = projectIds
        self.worktreeIdsByProject = worktreeIdsByProject
        self.recentWorktreeRefs = recentWorktreeRefs
    }

    mutating func bumpProject(_ id: String) {
        projectIds.removeAll { $0 == id }
        projectIds.insert(id, at: 0)
        if projectIds.count > Self.projectCap {
            projectIds.removeLast(projectIds.count - Self.projectCap)
        }
    }

    mutating func bumpWorktree(_ id: String, in projectId: String) {
        var list = worktreeIdsByProject[projectId] ?? []
        list.removeAll { $0 == id }
        list.insert(id, at: 0)
        if list.count > Self.worktreeCapPerProject {
            list.removeLast(list.count - Self.worktreeCapPerProject)
        }
        worktreeIdsByProject[projectId] = list

        // Maintain the flat cross-project recency list. Dedupe by the
        // (projectId, worktreeId) pair, prepend, and trim to the cap.
        recentWorktreeRefs.removeAll {
            $0.projectId == projectId && $0.worktreeId == id
        }
        recentWorktreeRefs.insert(
            RecentWorktreeRef(projectId: projectId, worktreeId: id),
            at: 0
        )
        if recentWorktreeRefs.count > Self.recentWorktreeRefCap {
            recentWorktreeRefs.removeLast(
                recentWorktreeRefs.count - Self.recentWorktreeRefCap
            )
        }
    }

    /// Returns projectIds filtered to those still present in the supplied
    /// set, preserving recency order.
    func liveProjectIds(validProjectIds: Set<String>) -> [String] {
        projectIds.filter { validProjectIds.contains($0) }
    }

    /// Returns the recents for a project filtered to ids still present.
    func liveWorktreeIds(in projectId: String, validWorktreeIds: Set<String>) -> [String] {
        (worktreeIdsByProject[projectId] ?? []).filter { validWorktreeIds.contains($0) }
    }

    /// Returns `recentWorktreeRefs` filtered to refs whose worktree is
    /// still visible in its project. Refs whose `projectId` isn't in the
    /// map are dropped entirely.
    func liveRecentWorktreeRefs(
        projectsWithVisibleWorktrees: [String: Set<String>]
    ) -> [RecentWorktreeRef] {
        recentWorktreeRefs.filter { ref in
            guard let visible = projectsWithVisibleWorktrees[ref.projectId] else { return false }
            return visible.contains(ref.worktreeId)
        }
    }
}
