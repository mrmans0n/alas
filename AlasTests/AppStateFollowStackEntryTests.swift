import Foundation
import Testing
@testable import Alas

@MainActor
struct AppStateFollowStackEntryTests {
    private struct MemoryStore: PersistenceStoreProtocol {
        let projects: ProjectsFile

        func write<T: Encodable>(_: T, to _: URL) throws {}

        func readIfExists<T: Decodable>(_ type: T.Type, from _: URL) throws -> T? {
            type == ProjectsFile.self ? projects as? T : nil
        }
    }

    @Test func noPrefillRoutesToTheExpressionPrompt() {
        #expect(FollowRevisionPromptRoute.route(prefill: nil, stackEntrySupported: true)
            == .expressionPrompt(prefill: nil, isEditing: false))
    }

    @Test func expressionPrefillRoutesToTheExpressionPrompt() {
        #expect(FollowRevisionPromptRoute.route(prefill: .expression("HEAD~2"), stackEntrySupported: true)
            == .expressionPrompt(prefill: "HEAD~2", isEditing: true))
    }

    @Test func stackEntryPrefillRoutesToThePicker() {
        #expect(FollowRevisionPromptRoute.route(prefill: .stackEntry(ggID: "c-abc1234"), stackEntrySupported: true)
            == .stackEntryPicker(isEditing: true))
    }

    @Test func stackEntryPrefillFallsBackWhenGGWentInactive() {
        // gg mode was turned off while a tab was following an entry: editing
        // must still offer something rather than opening a picker that
        // cannot load.
        #expect(FollowRevisionPromptRoute.route(prefill: .stackEntry(ggID: "c-abc1234"), stackEntrySupported: false)
            == .expressionPrompt(prefill: nil, isEditing: true))
    }

    @Test func presentationExposesTheSelectedEntry() {
        var presentation = GGFollowEntryPresentation(
            worktreeID: "wt",
            tabID: "tab",
            isEditing: false,
            state: .loading
        )
        #expect(presentation.selectedGGID == nil)

        presentation.state = .loaded(GGFollowEntryModel.make(
            entries: [GGStackEntry(position: 1, sha: "aaa1111", title: "base", ggId: "c-aaa1111")],
            currentGGID: nil,
            displayedSHA: nil
        ))

        #expect(presentation.selectedGGID == "c-aaa1111")
        #expect(presentation.id == "wt:tab")
    }

    /// `ggFollowSupported` must read the cached, observable gg context that
    /// `rightPaneStore` already maintains rather than recomputing it from
    /// disk — it's called from SwiftUI view bodies on every re-evaluation.
    @Test func ggFollowSupportedReadsTheCachedRightPaneContext() {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("alas-gg-follow-supported-\(UUID().uuidString)")
        let worktree = Worktree(
            id: Worktree.makeId(path: path),
            projectId: "test-project",
            name: "feature",
            branch: "feature",
            path: path,
            status: .clean,
            lastActivity: Date()
        )
        let state = AppState()

        // No right pane state has been activated for this worktree yet:
        // fall back to false rather than recomputing the gate from disk.
        #expect(!state.ggFollowSupported(worktreeID: worktree.id))

        let rightPaneState = state.rightPaneStore.state(
            for: worktree,
            baseBranch: "main",
            comparisonMode: .manual
        )
        rightPaneState.ggContext = .active(stackName: "stack")
        #expect(state.ggFollowSupported(worktreeID: worktree.id))

        rightPaneState.ggContext = .inactive(reason: .policyOff)
        #expect(!state.ggFollowSupported(worktreeID: worktree.id))
    }

    @Test func pickerUsesTheLoadedChangesStackImmediately() throws {
        let path = URL(fileURLWithPath: "/tmp/alas-follow-stack")
        let project = ProjectConfig(
            id: "project", name: "Alas", path: path.path, color: "blue", addedAt: .distantPast
        )
        let worktree = Worktree(
            id: Worktree.makeId(path: path),
            projectId: project.id,
            name: "feature",
            branch: "feature",
            path: path,
            status: .clean,
            lastActivity: .distantPast
        )
        let state = AppState(store: MemoryStore(projects: .init(projects: [project])))
        state.projectsManager.insertOptimisticWorktree(worktree)
        let rightPaneState = state.rightPaneStore.state(
            for: worktree,
            baseBranch: "main",
            comparisonMode: .manual
        )
        rightPaneState.currentBranch = worktree.branch
        rightPaneState.ggContext = .active(stackName: "stack")
        rightPaneState.ggStack = GGStack(
            name: "stack",
            base: "main",
            totalCommits: 1,
            syncedCommits: 0,
            currentPosition: 1,
            behindBase: 0,
            entries: [GGStackEntry(
                position: 1,
                sha: "abc1234",
                title: "Fast picker",
                ggId: "c-abc1234"
            )]
        )
        rightPaneState.ggStackLoadState = .loaded
        rightPaneState.ggStackCommitsKey = rightPaneState.currentGGStackCommitsKey
        let tab = state.tabs.appendCommit(worktreeId: worktree.id, sha: "abc1234", title: "Fast picker")

        state.promptFollowStackEntry(worktreeID: worktree.id, tabID: tab.id)

        let presentation = try #require(state.pendingFollowStackEntry)
        guard case .loaded(let model) = presentation.state else {
            Issue.record("Expected the picker to reuse the loaded Changes stack")
            return
        }
        #expect(model.candidates.map(\.ggID) == ["c-abc1234"])
    }
}
