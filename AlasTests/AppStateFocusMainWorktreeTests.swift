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

    // MARK: - Sidebar upstream pull click semantics

    /// Seeds a project whose feature worktree is selected, and returns the
    /// ids needed to drive the sidebar's `↓N` badge clicks on its main.
    private func makePullClickFixture() -> (state: AppState, mainID: String) {
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
        return (state, main.id)
    }

    @Test func sidebarPullKeepsSelectionOnFirstClick() {
        let (state, mainID) = makePullClickFixture()

        state.pullWorktreeFromSidebar(id: mainID)

        // The pull may not have been admitted (the path has no git repo),
        // but either way the first click must not move the selection.
        #expect(state.selectedWorktreeId != mainID)
        #expect(state.worktreeUpstreamStatusStore.isPullingUpstream(worktreeID: mainID))
    }

    @Test func sidebarPullSecondClickWhileInFlightSelectsWorktree() {
        let (state, mainID) = makePullClickFixture()
        state.worktreeUpstreamStatusStore.markPullingUpstream(worktreeID: mainID)

        state.pullWorktreeFromSidebar(id: mainID)

        #expect(state.selectedWorktreeId == mainID)
        // The in-flight pull is untouched: the second click routes to
        // selection only.
        #expect(state.worktreeUpstreamStatusStore.isPullingUpstream(worktreeID: mainID))
    }
}
