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

    @Test func loadingProjectWhenProjectExistsBeforeWorktreesResolve() {
        let project = ProjectConfig.fixture
        let mgr = ProjectsManager(persistedProjects: [project])
        let resolver = CenterSelectionStateResolver(
            selectedWorktreeId: nil,
            projects: [project],
            projectsManager: mgr,
            isRefreshingProjectTopologies: true
        )
        let result = resolver.resolve()
        #expect(result == .loadingProject)
    }

    @Test func emptyWhenProjectExistsWithoutSelectionOrRefresh() {
        let project = ProjectConfig.fixture
        let mgr = ProjectsManager(persistedProjects: [project])
        let resolver = CenterSelectionStateResolver(
            selectedWorktreeId: nil,
            projects: [project],
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

    @Test func checkoutScopeRejectsAStaleRepositoryFocus() {
        let project = ProjectConfig.fixture
        let worktree = Worktree.fixture()
        let mgr = ProjectsManager(persistedProjects: [project])
        mgr.insertOptimisticWorktree(worktree)
        let resolver = CenterSelectionStateResolver(
            selectedWorktreeId: worktree.id,
            projects: [project],
            projectsManager: mgr,
            allowedWorktreeIDs: []
        )
        #expect(resolver.resolve() == .empty)
    }

    @Test func checkoutScopeQualifiesDuplicateWorktreeIDsByProjectAndLocation() {
        let wrongProject = ProjectConfig(
            id: "wrong-project",
            name: "Wrong",
            path: "/repos/wrong",
            color: "#fff",
            addedAt: Date(timeIntervalSince1970: 0),
            host: "wrong-host"
        )
        let focusedProject = ProjectConfig(
            id: "focused-project",
            name: "Focused",
            path: "/repos/focused",
            color: "#fff",
            addedAt: Date(timeIntervalSince1970: 0),
            host: "focused-host"
        )
        let duplicateID = "/srv/checkouts/member"
        let wrong = Worktree.fixture(id: duplicateID, projectId: wrongProject.id, path: "/srv/checkouts/member")
        let focused = Worktree.fixture(id: duplicateID, projectId: focusedProject.id, path: "/srv/checkouts/member")
        let mgr = ProjectsManager(persistedProjects: [wrongProject, focusedProject])
        mgr.insertOptimisticWorktree(wrong)
        mgr.insertOptimisticWorktree(focused)

        let resolver = CenterSelectionStateResolver(
            selectedWorktreeId: duplicateID,
            projects: [wrongProject, focusedProject],
            projectsManager: mgr,
            allowedWorktreeIDs: [duplicateID],
            checkoutFocusedWorktreeScope: CheckoutFocusedWorktreeScope(
                worktreeID: duplicateID,
                projectID: focusedProject.id,
                executionLocation: .ssh("focused-host")
            )
        )

        if case .worktree(let returned) = resolver.resolve() {
            #expect(returned.projectId == focusedProject.id)
        } else {
            Issue.record("Expected scoped duplicate worktree to resolve to focused project")
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
            state: .createFailed(
                projectId: project.id,
                message: "disk full",
                base: "main",
                ggWorktreeMode: .inherit,
                launchSurface: .none,
                issueAttachment: nil
            )
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

private extension ProjectConfig {
    static let fixture = ProjectConfig(
        id: "project-1",
        name: "Alas",
        path: "/tmp/alas",
        color: "#5fb7c4",
        addedAt: Date(timeIntervalSince1970: 0)
    )
}

private extension Worktree {
    static func fixture(
        id: String = "worktree-1",
        projectId: String = "project-1",
        path: String = "/tmp/alas"
    ) -> Worktree {
        Worktree(
            id: id,
            projectId: projectId,
            name: "main",
            branch: "main",
            path: URL(fileURLWithPath: path),
            status: .clean,
            lastActivity: Date(timeIntervalSince1970: 0)
        )
    }
}
