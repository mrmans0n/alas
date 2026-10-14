import Foundation
import Testing
@_spi(Testing) @testable import AlasCore

@MainActor
struct AlasHostTests {
    /// A worktree's snapshot carries the operation holding it and whether it
    /// is archived; archived worktrees are listed only when asked for.
    @Test func worktreeSnapshotsCarryTheirOperationAndArchivedState() {
        let project = ProjectConfig(id: "p", name: "p", path: "/srv/repo", color: "blue", addedAt: .distantPast)
        let projects = ProjectsManager(persistedProjects: [project])
        func worktree(_ name: String) -> Worktree {
            let path = URL(fileURLWithPath: "/srv/\(name)")
            return Worktree(
                id: Worktree.makeId(path: path), projectId: "p", name: name, branch: name,
                path: path, status: .clean, lastActivity: .distantPast
            )
        }
        let busy = worktree("busy")
        let archived = worktree("archived")
        projects.insertOptimisticWorktree(busy)
        projects.insertOptimisticWorktree(archived)
        projects.setOperationState(for: busy, state: .deleting(projectId: "p"))
        projects.setWorktreeHidden(projectId: "p", path: archived.path, hidden: true)
        let host = AlasHost(core: AlasCoreContext(projects: projects, runHistoryStore: nil))

        #expect(host.worktrees.list() == [
            WorktreeSnapshot(worktree: busy, operation: .deleting(projectId: "p"), isArchived: false),
        ])
        #expect(Set(host.worktrees.list(includingArchived: true).map(\.worktree.id)) == [busy.id, archived.id])
        #expect(host.worktrees.list(includingArchived: true).first { $0.worktree.id == archived.id }?.isArchived == true)
    }
}
