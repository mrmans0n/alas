import Foundation
import Testing
@testable import Alas

/// Click semantics of the sidebar's `↓N` pull badge: the first click starts
/// the pull without stealing selection, a second click while the pull is still
/// running selects the worktree instead.
@MainActor
@Suite(.serialized)
struct SidebarUpstreamPullClickTests {
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

    private func makeState() -> AppState {
        let project = ProjectConfig(
            id: "p1",
            name: "p1",
            path: "/repo",
            color: "blue",
            addedAt: Date()
        )
        let state = AppState(store: MemoryStore(projectsFile: ProjectsFile(projects: [project])))
        func worktree(_ path: String, _ branch: String) -> Worktree {
            let url = URL(fileURLWithPath: path)
            return Worktree(
                id: Worktree.makeId(path: url),
                projectId: "p1",
                name: branch,
                branch: branch,
                path: url,
                status: .clean,
                lastActivity: Date()
            )
        }
        state.projectsManager.insertOptimisticWorktree(worktree("/repo/wts/feature", "feature"))
        state.projectsManager.insertOptimisticWorktree(worktree("/repo", "main"))
        state.selectedWorktreeId = state.projectsManager.worktrees(projectId: "p1")
            .first { $0.branch == "feature" }!.id
        return state
    }

    private func mainWorktreeID(_ state: AppState) -> String {
        state.projectsManager.worktrees(projectId: "p1").first { $0.branch == "main" }!.id
    }

    @Test func firstClickPullsWithoutChangingSelection() {
        let state = makeState()
        let mainID = mainWorktreeID(state)

        state.pullWorktreeFromSidebar(id: mainID)

        // The pull may not have been admitted (the path has no git repo), but
        // either way the first click must not move the selection.
        #expect(state.selectedWorktreeId != mainID)
        #expect(state.worktreeUpstreamStatusStore.isPullingUpstream(worktreeID: mainID))
    }

    @Test func secondClickWhilePullInFlightSelectsWorktree() {
        let state = makeState()
        let mainID = mainWorktreeID(state)
        state.worktreeUpstreamStatusStore.markPullingUpstream(worktreeID: mainID)

        state.pullWorktreeFromSidebar(id: mainID)

        #expect(state.selectedWorktreeId == mainID)
        // The in-flight pull is untouched: the second click routes to
        // selection only.
        #expect(state.worktreeUpstreamStatusStore.isPullingUpstream(worktreeID: mainID))
    }
}