import Foundation
import Testing
@testable import Alas

@Suite(.serialized)
@MainActor
struct CenterSelectionStateResolverTests {
    @Test func emptyWhenNoSelection() {
        let mgr = ProjectsManager(persistedProjects: [])
        let resolver = CenterSelectionStateResolver(
            selectedWorktreeId: nil,
            projects: [],
            projectsManager: mgr
        )
        let result = resolver.resolve()
        #expect(result == .empty)
    }

    @Test func returnsWorktreeWhenNoOperationState() {
        let project = ProjectConfig(id: "p1", name: "A", path: "/tmp/a", color: "#fff", addedAt: Date())
        let wt = Worktree(id: "wt1", projectId: "p1", name: "main", branch: "main", path: URL(fileURLWithPath: "/tmp/a"), status: .clean, lastActivity: Date())
        let mgr = ProjectsManager(persistedProjects: [project])
        mgr.insertOptimisticWorktree(wt)
        let resolver = CenterSelectionStateResolver(
            selectedWorktreeId: wt.id,
            projects: [project],
            projectsManager: mgr
        )
        let result = resolver.resolve()
        if case .worktree(let returned) = result {
            #expect(returned.id == wt.id)
        } else {
            Issue.record("Expected .worktree, got \(result)")
        }
    }

    @Test func returnsDeletingWhenDeletingState() {
        let project = ProjectConfig(id: "p1", name: "A", path: "/tmp/a", color: "#fff", addedAt: Date())
        let wt = Worktree(id: "wt1", projectId: "p1", name: "main", branch: "main", path: URL(fileURLWithPath: "/tmp/a"), status: .clean, lastActivity: Date())
        let mgr = ProjectsManager(persistedProjects: [project])
        mgr.insertOptimisticWorktree(wt)
        mgr.setOperationState(id: wt.id, state: .deleting)
        let resolver = CenterSelectionStateResolver(
            selectedWorktreeId: wt.id,
            projects: [project],
            projectsManager: mgr
        )
        let result = resolver.resolve()
        if case .deleting(let returned) = result {
            #expect(returned.id == wt.id)
        } else {
            Issue.record("Expected .deleting, got \(result)")
        }
    }

    @Test func returnsDeleteFailedWhenDeleteFailedState() {
        let project = ProjectConfig(id: "p1", name: "A", path: "/tmp/a", color: "#fff", addedAt: Date())
        let wt = Worktree(id: "wt1", projectId: "p1", name: "main", branch: "main", path: URL(fileURLWithPath: "/tmp/a"), status: .clean, lastActivity: Date())
        let mgr = ProjectsManager(persistedProjects: [project])
        mgr.insertOptimisticWorktree(wt)
        mgr.setOperationState(id: wt.id, state: .deleteFailed(message: "permission denied"))
        let resolver = CenterSelectionStateResolver(
            selectedWorktreeId: wt.id,
            projects: [project],
            projectsManager: mgr
        )
        let result = resolver.resolve()
        if case .deleteFailed(let returned, let message) = result {
            #expect(returned.id == wt.id)
            #expect(message == "permission denied")
        } else {
            Issue.record("Expected .deleteFailed, got \(result)")
        }
    }

    @Test func returnsCreatingForCreatingState() {
        let project = ProjectConfig(id: "p1", name: "A", path: "/tmp/a", color: "#fff", addedAt: Date())
        let wt = Worktree(id: "wt1", projectId: "p1", name: "main", branch: "main", path: URL(fileURLWithPath: "/tmp/a"), status: .clean, lastActivity: Date())
        let mgr = ProjectsManager(persistedProjects: [project])
        mgr.insertOptimisticWorktree(wt)
        mgr.setOperationState(id: wt.id, state: .creating)
        let resolver = CenterSelectionStateResolver(
            selectedWorktreeId: wt.id,
            projects: [project],
            projectsManager: mgr
        )
        let result = resolver.resolve()
        if case .creating(let returned) = result {
            #expect(returned.id == wt.id)
        } else {
            Issue.record("Expected .creating, got \(result)")
        }
    }

    @Test func returnsEmptyForCreateFailedState() {
        let project = ProjectConfig(id: "p1", name: "A", path: "/tmp/a", color: "#fff", addedAt: Date())
        let wt = Worktree(id: "wt1", projectId: "p1", name: "main", branch: "main", path: URL(fileURLWithPath: "/tmp/a"), status: .clean, lastActivity: Date())
        let mgr = ProjectsManager(persistedProjects: [project])
        mgr.insertOptimisticWorktree(wt)
        mgr.setOperationState(
            id: wt.id,
            state: .createFailed(message: "disk full", base: "main", ggWorktreeMode: .inherit)
        )
        let resolver = CenterSelectionStateResolver(
            selectedWorktreeId: wt.id,
            projects: [project],
            projectsManager: mgr
        )
        let result = resolver.resolve()
        #expect(result == .empty)
    }
}
