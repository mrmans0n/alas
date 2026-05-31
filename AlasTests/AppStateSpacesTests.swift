import Foundation
import Testing
@testable import Alas

@MainActor
@Suite(.serialized)
struct AppStateSpacesTests {
    private struct MemoryStore: PersistenceStoreProtocol {
        var projectsFile: ProjectsFile = ProjectsFile(projects: [])
        var spacesFile: SpacesFile?
        var writes: ((Any, URL) -> Void)?

        func write<T: Encodable>(_ value: T, to url: URL) throws {
            writes?(value, url)
        }

        func readIfExists<T: Decodable>(_ type: T.Type, from url: URL) throws -> T? {
            if type == ProjectsFile.self { return projectsFile as? T }
            if type == SpacesFile.self { return spacesFile as? T }
            if type == AppConfig.self { return AppConfig.defaults as? T }
            return nil
        }
    }

    private func project(_ id: String) -> ProjectConfig {
        ProjectConfig(id: id, name: id, path: "/tmp/\(id)", color: "#5fb7c4", addedAt: Date(timeIntervalSince1970: 0))
    }

    private func worktree(_ id: String, projectId: String) -> Worktree {
        Worktree(
            id: id,
            projectId: projectId,
            name: "main",
            branch: "main",
            path: URL(fileURLWithPath: "/tmp/\(projectId)"),
            status: .clean,
            lastActivity: Date(timeIntervalSince1970: 0)
        )
    }

    @Test func migratesSpacesWhenMissingSpacesFile() {
        let state = AppState(store: MemoryStore(projectsFile: ProjectsFile(projects: [project("p1"), project("p2")])))

        #expect(state.spacesManager.spaces.count == 1)
        #expect(state.activeSpaceProjects.map(\.id) == ["p1", "p2"])
        #expect(!state.spacesManager.shouldShowSpaceAffordance)
    }

    @Test func activeSpaceProjectsUseSpaceMembershipOrder() {
        let spaces = SpacesFile(
            version: 1,
            activeSpaceId: "s1",
            spaces: [
                SpaceConfig(id: "s1", name: "Work", emoji: "💼", projectIds: ["p2"], lastSelectedWorktreeId: nil, createdAt: Date())
            ]
        )
        let state = AppState(store: MemoryStore(projectsFile: ProjectsFile(projects: [project("p1"), project("p2")]), spacesFile: spaces))

        #expect(state.activeSpaceProjects.map(\.id) == ["p2"])
        #expect(state.projects.map(\.id) == ["p1", "p2"])
    }

    @Test func selectingWorktreeStoresLastSelectionForActiveSpace() {
        let state = AppState(store: MemoryStore(projectsFile: ProjectsFile(projects: [project("p1")])))

        state.selectWorktree(id: "wt1")

        #expect(state.selectedWorktreeId == "wt1")
        #expect(state.spacesManager.activeSpace?.lastSelectedWorktreeId == "wt1")
    }

    @Test func switchingSpacesRestoresLastSelectionThenFallback() {
        let p1 = project("p1")
        let p2 = project("p2")
        let spaces = SpacesFile(
            version: 1,
            activeSpaceId: "s1",
            spaces: [
                SpaceConfig(id: "s1", name: "Work", emoji: "💼", projectIds: ["p1"], lastSelectedWorktreeId: "wt1", createdAt: Date()),
                SpaceConfig(id: "s2", name: "Home", emoji: "🏠", projectIds: ["p2"], lastSelectedWorktreeId: "wt2", createdAt: Date())
            ]
        )
        let state = AppState(store: MemoryStore(projectsFile: ProjectsFile(projects: [p1, p2]), spacesFile: spaces))
        state.projectsManager.insertOptimisticWorktree(worktree("wt1", projectId: "p1"))
        state.projectsManager.insertOptimisticWorktree(worktree("wt2", projectId: "p2"))

        state.switchToSpace(id: "s2")

        #expect(state.spacesManager.activeSpaceId == "s2")
        #expect(state.selectedWorktreeId == "wt2")
    }

    @Test func switchingSpacesFallsBackToFirstVisibleWorktreeWhenRememberedSelectionIsStale() {
        let p1 = project("p1")
        let p2 = project("p2")
        let spaces = SpacesFile(
            version: 1,
            activeSpaceId: "s1",
            spaces: [
                SpaceConfig(id: "s1", name: "Work", emoji: "💼", projectIds: ["p1"], lastSelectedWorktreeId: nil, createdAt: Date()),
                SpaceConfig(id: "s2", name: "Home", emoji: "🏠", projectIds: ["p2"], lastSelectedWorktreeId: "missing", createdAt: Date())
            ]
        )
        let state = AppState(store: MemoryStore(projectsFile: ProjectsFile(projects: [p1, p2]), spacesFile: spaces))
        state.projectsManager.insertOptimisticWorktree(worktree("wt2", projectId: "p2"))

        state.switchToSpace(id: "s2")

        #expect(state.spacesManager.activeSpaceId == "s2")
        #expect(state.selectedWorktreeId == "wt2")
        #expect(state.spacesManager.activeSpace?.lastSelectedWorktreeId == "wt2")
    }

    @Test func switchingSpacesFallsBackToFirstVisibleWorktreeWhenRememberedSelectionIsNil() {
        let p1 = project("p1")
        let p2 = project("p2")
        let spaces = SpacesFile(
            version: 1,
            activeSpaceId: "s1",
            spaces: [
                SpaceConfig(id: "s1", name: "Work", emoji: "💼", projectIds: ["p1"], lastSelectedWorktreeId: nil, createdAt: Date()),
                SpaceConfig(id: "s2", name: "Home", emoji: "🏠", projectIds: ["p2"], lastSelectedWorktreeId: nil, createdAt: Date())
            ]
        )
        let state = AppState(store: MemoryStore(projectsFile: ProjectsFile(projects: [p1, p2]), spacesFile: spaces))
        state.projectsManager.insertOptimisticWorktree(worktree("wt2", projectId: "p2"))

        state.switchToSpace(id: "s2")

        #expect(state.spacesManager.activeSpaceId == "s2")
        #expect(state.selectedWorktreeId == "wt2")
        #expect(state.spacesManager.activeSpace?.lastSelectedWorktreeId == "wt2")
    }

    @Test func focusingGlobalWorktreeSwitchesToContainingSpace() {
        let p1 = project("p1")
        let p2 = project("p2")
        let spaces = SpacesFile(
            version: 1,
            activeSpaceId: "s1",
            spaces: [
                SpaceConfig(id: "s1", name: "Work", emoji: "💼", projectIds: ["p1"], lastSelectedWorktreeId: nil, createdAt: Date()),
                SpaceConfig(id: "s2", name: "Home", emoji: "🏠", projectIds: ["p2"], lastSelectedWorktreeId: nil, createdAt: Date())
            ]
        )
        let state = AppState(store: MemoryStore(projectsFile: ProjectsFile(projects: [p1, p2]), spacesFile: spaces))

        state.focusGlobalWorktree(id: "wt2", projectId: "p2")

        #expect(state.spacesManager.activeSpaceId == "s2")
        #expect(state.selectedWorktreeId == "wt2")
    }
}
