import Foundation

/// Mutable, value-typed recents store used by the repo selector. Lives on
/// `AppConfig` as two plain fields; this struct is the in-memory shape +
/// mutation helpers so the persistence layer doesn't carry behavior.
struct RepoSelectorRecents: Equatable {
    static let projectCap = 5
    static let worktreeCapPerProject = 5

    var projectIds: [String] = []
    var worktreeIdsByProject: [String: [String]] = [:]

    init(
        projectIds: [String] = [],
        worktreeIdsByProject: [String: [String]] = [:]
    ) {
        self.projectIds = projectIds
        self.worktreeIdsByProject = worktreeIdsByProject
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
}
