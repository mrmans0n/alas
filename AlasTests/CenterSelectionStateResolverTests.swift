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

    @Test func globalMissionTakesPrecedenceOverSelectedWorktree() {
        let project = ProjectConfig.fixture
        let worktree = Worktree.fixture(projectId: project.id)
        let manager = ProjectsManager(persistedProjects: [project])
        manager.insertOptimisticWorktree(worktree)
        let missionTab = MissionTabState.fixture

        let result = CenterSelectionStateResolver(
            selectedWorktreeId: worktree.id,
            projects: [project],
            projectsManager: manager,
            activeGlobalMissionTab: missionTab
        ).resolve()

        #expect(result == .globalMission(missionTab))
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

    @Test func returnsHiddenWorktreeOnlyForExplicitMissionSelection() {
        let project = ProjectConfig(
            id: "p1",
            name: "A",
            path: "/tmp/a",
            color: "#fff",
            addedAt: Date(),
            hiddenWorktreePaths: ["/tmp/a-hidden"]
        )
        let worktree = Worktree(
            id: "wt-hidden",
            projectId: project.id,
            name: "archived",
            branch: "archived",
            path: URL(fileURLWithPath: "/tmp/a-hidden"),
            status: .clean,
            lastActivity: Date()
        )
        let manager = ProjectsManager(persistedProjects: [project])
        manager.insertOptimisticWorktree(worktree)

        let ordinary = CenterSelectionStateResolver(
            selectedWorktreeId: worktree.id,
            projects: [project],
            projectsManager: manager
        ).resolve()
        let mission = CenterSelectionStateResolver(
            selectedWorktreeId: worktree.id,
            projects: [project],
            projectsManager: manager,
            allowsHiddenSelectedWorktree: true
        ).resolve()

        #expect(ordinary == .empty)
        if case .worktree(let resolved) = mission {
            #expect(resolved == worktree)
        } else {
            Issue.record("Expected hidden Mission worktree")
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
                ggWorktreeMode: .inherit
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
    static func fixture(projectId: String = "project-1") -> Worktree {
        Worktree(
            id: "worktree-1",
            projectId: projectId,
            name: "main",
            branch: "main",
            path: URL(fileURLWithPath: "/tmp/alas"),
            status: .clean,
            lastActivity: Date(timeIntervalSince1970: 0)
        )
    }
}

private extension MissionTabState {
    static let fixture = MissionTabState(
        missionID: MissionID(rawValue: "mission-1"),
        title: "Fix parser crash"
    )
}
