import Testing
import Foundation
@testable import Alas

@MainActor
struct ProjectsManagerHeadUpdatesTests {
    private func makeManager() -> (ProjectsManager, ProjectConfig) {
        let project = ProjectConfig(
            id: "p1",
            name: "p1",
            path: "/repo",
            color: "blue",
            addedAt: Date()
        )
        let mgr = ProjectsManager(persistedProjects: [project])
        return (mgr, project)
    }

    private func seed(_ mgr: ProjectsManager, projectId: String, _ wts: [Worktree]) {
        for wt in wts { mgr.insertOptimisticWorktree(wt) }
        // insertOptimisticWorktree is the only public seed API; clear any
        // operation state it implicitly leaves so updates apply.
        for wt in wts { mgr.setOperationState(id: wt.id, state: nil) }
    }

    private func wt(path: String, branch: String, projectId: String = "p1") -> Worktree {
        let url = URL(fileURLWithPath: path)
        return Worktree(
            id: Worktree.makeId(path: url),
            projectId: projectId,
            name: branch,
            branch: branch,
            path: url,
            status: .clean,
            lastActivity: Date()
        )
    }

    @Test func updatesBranchForMatchingPath() {
        let (mgr, project) = makeManager()
        seed(mgr, projectId: project.id, [
            wt(path: "/repo", branch: "main"),
            wt(path: "/wts/feat", branch: "feat/foo"),
        ])

        mgr.applyHeadUpdates(
            projectId: project.id,
            branchByWorktreePath: [
                URL(fileURLWithPath: "/wts/feat"): "feat/bar"
            ]
        )

        let trees = mgr.worktrees(projectId: project.id)
        #expect(trees.first { $0.path.path == "/repo" }?.branch == "main")
        #expect(trees.first { $0.path.path == "/wts/feat" }?.branch == "feat/bar")
        #expect(trees.first { $0.path.path == "/wts/feat" }?.name == "feat/bar")
    }

    @Test func ignoresUnknownPaths() {
        let (mgr, project) = makeManager()
        seed(mgr, projectId: project.id, [wt(path: "/repo", branch: "main")])

        mgr.applyHeadUpdates(
            projectId: project.id,
            branchByWorktreePath: [
                URL(fileURLWithPath: "/wts/ghost"): "x"
            ]
        )

        #expect(mgr.worktrees(projectId: project.id).count == 1)
        #expect(mgr.worktrees(projectId: project.id).first?.branch == "main")
    }

    @Test func skipsRowsInCreatingState() {
        let (mgr, project) = makeManager()
        let row = wt(path: "/wts/feat", branch: "feat/intent")
        seed(mgr, projectId: project.id, [row])
        mgr.setOperationState(id: row.id, state: .creating)

        mgr.applyHeadUpdates(
            projectId: project.id,
            branchByWorktreePath: [row.path: "feat/disk"]
        )

        // Optimistic intent must win over disk truth while creating.
        #expect(mgr.worktrees(projectId: project.id).first?.branch == "feat/intent")
    }

    @Test func skipsRowsInCreateFailedState() {
        let (mgr, project) = makeManager()
        let row = wt(path: "/wts/feat", branch: "feat/intent")
        seed(mgr, projectId: project.id, [row])
        mgr.setOperationState(
            id: row.id,
            state: .createFailed(message: "x", base: "main", ggWorktreeMode: .inherit)
        )

        mgr.applyHeadUpdates(
            projectId: project.id,
            branchByWorktreePath: [row.path: "feat/disk"]
        )
        #expect(mgr.worktrees(projectId: project.id).first?.branch == "feat/intent")
    }

    @Test func updatesRowsInDeletingState() {
        // .deleting / .deleteFailed correspond to real git worktrees that
        // happen to have a pending UI op; the branch label is still git's
        // truth and should refresh.
        let (mgr, project) = makeManager()
        let row = wt(path: "/wts/feat", branch: "old")
        seed(mgr, projectId: project.id, [row])
        mgr.setOperationState(id: row.id, state: .deleting)

        mgr.applyHeadUpdates(
            projectId: project.id,
            branchByWorktreePath: [row.path: "new"]
        )
        #expect(mgr.worktrees(projectId: project.id).first?.branch == "new")
    }

    @Test func unknownProjectIdIsNoop() {
        let (mgr, _) = makeManager()
        mgr.applyHeadUpdates(
            projectId: "does-not-exist",
            branchByWorktreePath: [URL(fileURLWithPath: "/x"): "y"]
        )
        // No crash, no state change. Nothing to assert beyond that.
    }
}
