import Foundation
import Testing
@testable import Alas

@Suite(.serialized)
@MainActor
struct RightPaneSelectionStateResolverTests {
    @Test func emptyWhenNoSelection() {
        let mgr = ProjectsManager(persistedProjects: [])
        let resolver = RightPaneSelectionStateResolver(
            selectedWorktreeId: nil,
            projects: [],
            projectsManager: mgr
        )
        let result = resolver.resolve()
        #expect(result == .empty)
        #expect(!result.showsRightPane)
    }

    @Test func emptyWhenSelectionIdMissing() {
        let project = ProjectConfig(id: "p1", name: "A", path: "/tmp/a", color: "#fff", addedAt: Date())
        let mgr = ProjectsManager(persistedProjects: [project])
        let resolver = RightPaneSelectionStateResolver(
            selectedWorktreeId: "missing",
            projects: [project],
            projectsManager: mgr
        )
        let result = resolver.resolve()
        #expect(result == .empty)
        #expect(!result.showsRightPane)
    }

    @Test func activeWhenNoOperationState() {
        let project = ProjectConfig(id: "p1", name: "A", path: "/tmp/a", color: "#fff", addedAt: Date())
        let wt = Worktree(id: "wt1", projectId: "p1", name: "main", branch: "main", path: URL(fileURLWithPath: "/tmp/a"), status: .clean, lastActivity: Date())
        let mgr = ProjectsManager(persistedProjects: [project])
        mgr.insertOptimisticWorktree(wt)
        let resolver = RightPaneSelectionStateResolver(
            selectedWorktreeId: wt.id,
            projects: [project],
            projectsManager: mgr
        )
        let result = resolver.resolve()
        if case .active(let returned) = result {
            #expect(returned.id == wt.id)
            #expect(result.showsRightPane)
        } else {
            Issue.record("Expected .active, got \(result)")
        }
    }

    @Test func creatingWhenCreatingState() {
        let project = ProjectConfig(id: "p1", name: "A", path: "/tmp/a", color: "#fff", addedAt: Date())
        let wt = Worktree(id: "wt1", projectId: "p1", name: "main", branch: "main", path: URL(fileURLWithPath: "/tmp/a"), status: .clean, lastActivity: Date())
        let mgr = ProjectsManager(persistedProjects: [project])
        mgr.insertOptimisticWorktree(wt)
        mgr.setOperationState(id: wt.id, state: .creating)
        let resolver = RightPaneSelectionStateResolver(
            selectedWorktreeId: wt.id,
            projects: [project],
            projectsManager: mgr
        )
        let result = resolver.resolve()
        if case .creating(let returned) = result {
            #expect(returned.id == wt.id)
            #expect(result.showsRightPane)
        } else {
            Issue.record("Expected .creating, got \(result)")
        }
    }

    @Test func deletingWhenDeletingState() {
        let project = ProjectConfig(id: "p1", name: "A", path: "/tmp/a", color: "#fff", addedAt: Date())
        let wt = Worktree(id: "wt1", projectId: "p1", name: "main", branch: "main", path: URL(fileURLWithPath: "/tmp/a"), status: .clean, lastActivity: Date())
        let mgr = ProjectsManager(persistedProjects: [project])
        mgr.insertOptimisticWorktree(wt)
        mgr.setOperationState(id: wt.id, state: .deleting)
        let resolver = RightPaneSelectionStateResolver(
            selectedWorktreeId: wt.id,
            projects: [project],
            projectsManager: mgr
        )
        let result = resolver.resolve()
        if case .deleting(let returned) = result {
            #expect(returned.id == wt.id)
            #expect(result.showsRightPane)
        } else {
            Issue.record("Expected .deleting, got \(result)")
        }
    }

    @Test func createFailedWhenCreateFailedState() {
        let project = ProjectConfig(id: "p1", name: "A", path: "/tmp/a", color: "#fff", addedAt: Date())
        let wt = Worktree(id: "wt1", projectId: "p1", name: "main", branch: "main", path: URL(fileURLWithPath: "/tmp/a"), status: .clean, lastActivity: Date())
        let mgr = ProjectsManager(persistedProjects: [project])
        mgr.insertOptimisticWorktree(wt)
        mgr.setOperationState(
            id: wt.id,
            state: .createFailed(
                projectId: project.id,
                message: "disk full",
                base: "main",
                ggWorktreeMode: .inherit,
                launchSurface: .none,
                issueAttachment: nil
            )
        )
        let resolver = RightPaneSelectionStateResolver(
            selectedWorktreeId: wt.id,
            projects: [project],
            projectsManager: mgr
        )
        let result = resolver.resolve()
        if case .createFailed(let returned) = result {
            #expect(returned.id == wt.id)
            #expect(result.showsRightPane)
        } else {
            Issue.record("Expected .createFailed, got \(result)")
        }
    }

    @Test func activeWhenDeleteFailedState() {
        let project = ProjectConfig(id: "p1", name: "A", path: "/tmp/a", color: "#fff", addedAt: Date())
        let wt = Worktree(id: "wt1", projectId: "p1", name: "main", branch: "main", path: URL(fileURLWithPath: "/tmp/a"), status: .clean, lastActivity: Date())
        let mgr = ProjectsManager(persistedProjects: [project])
        mgr.insertOptimisticWorktree(wt)
        mgr.setOperationState(id: wt.id, state: .deleteFailed(message: "permission denied"))
        let resolver = RightPaneSelectionStateResolver(
            selectedWorktreeId: wt.id,
            projects: [project],
            projectsManager: mgr
        )
        let result = resolver.resolve()
        if case .active(let returned) = result {
            #expect(returned.id == wt.id)
            #expect(result.showsRightPane)
        } else {
            Issue.record("Expected .active, got \(result)")
        }
    }
}
