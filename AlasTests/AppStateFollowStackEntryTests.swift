import Foundation
import Testing
@testable import Alas

@MainActor
struct AppStateFollowStackEntryTests {
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
}
