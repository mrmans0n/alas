import Foundation
import Testing
@testable import Alas

@MainActor
@Suite(.serialized)
struct AppStateFocusMainWorktreeTests {
    private struct MemoryStore: PersistenceStoreProtocol {
        let projectsFile: ProjectsFile

        func write<T: Encodable>(_: T, to _: URL) throws {}

        func readIfExists<T: Decodable>(_ type: T.Type, from url: URL) throws -> T? {
            if type == ProjectsFile.self {
                return projectsFile as? T
            }
            if type == AppConfig.self {
                return AppConfig.defaults as? T
            }
            return nil
        }
    }

    private func makeState(project: ProjectConfig) -> AppState {
        AppState(store: MemoryStore(projectsFile: ProjectsFile(projects: [project])))
    }

    private func worktree(path: String, branch: String, projectId: String = "p1") -> Worktree {
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

    @Test func focusesVisibleMainWorktreeForCurrentProject() {
        let project = ProjectConfig(
            id: "p1",
            name: "p1",
            path: "/repo",
            color: "blue",
            addedAt: Date()
        )
        let state = makeState(project: project)
        let main = worktree(path: "/repo", branch: "main")
        let feature = worktree(path: "/repo/wts/feature", branch: "feature")
        state.projectsManager.insertOptimisticWorktree(feature)
        state.projectsManager.insertOptimisticWorktree(main)
        state.selectedWorktreeId = feature.id

        state.focusMainWorktreeForCurrentProject()

        #expect(state.selectedWorktreeId == main.id)
        #expect(state.canFocusMainWorktreeForCurrentProject)
    }

    @Test func focusMainWorktreeNoOpsWhenMainIsNotVisible() {
        let project = ProjectConfig(
            id: "p1",
            name: "p1",
            path: "/repo",
            color: "blue",
            addedAt: Date(),
            hiddenWorktreePaths: ["/repo"]
        )
        let state = makeState(project: project)
        let main = worktree(path: "/repo", branch: "main")
        let feature = worktree(path: "/repo/wts/feature", branch: "feature")
        state.projectsManager.insertOptimisticWorktree(feature)
        state.projectsManager.insertOptimisticWorktree(main)
        state.selectedWorktreeId = feature.id

        state.focusMainWorktreeForCurrentProject()

        #expect(state.selectedWorktreeId == feature.id)
        #expect(!state.canFocusMainWorktreeForCurrentProject)
    }
}
