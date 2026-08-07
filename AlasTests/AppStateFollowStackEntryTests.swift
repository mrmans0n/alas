import Foundation
import Testing
@testable import Alas

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
}
