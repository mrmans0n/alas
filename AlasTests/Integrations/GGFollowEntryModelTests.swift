import Foundation
import Testing
@testable import Alas

struct GGFollowEntryModelTests {
    private let entries = [
        GGStackEntry(position: 1, sha: "aaa1111", title: "base work", ggId: "c-aaa1111"),
        GGStackEntry(position: 2, sha: "bbb2222", title: "middle", ggId: "c-bbb2222"),
        GGStackEntry(position: 3, sha: "ccc3333", title: "tip", ggId: "c-ccc3333"),
    ]

    @Test func listsTipFirst() {
        let model = GGFollowEntryModel.make(entries: entries, currentGGID: nil, displayedSHA: nil)

        #expect(model.candidates.map(\.position) == [3, 2, 1])
        #expect(model.candidates.first?.title == "tip")
    }

    @Test func preselectsTheCurrentlyFollowedEntry() {
        let model = GGFollowEntryModel.make(
            entries: entries,
            currentGGID: "c-bbb2222",
            displayedSHA: "ccc3333000000000000000000000000000000000"
        )

        #expect(model.selectedID == "c-bbb2222")
        #expect(model.canFollow)
    }

    @Test func fallsBackToTheDisplayedCommit() {
        // Alas holds a full SHA, gg reports an abbreviated one.
        let model = GGFollowEntryModel.make(
            entries: entries,
            currentGGID: nil,
            displayedSHA: "bbb2222000000000000000000000000000000000"
        )

        #expect(model.selectedID == "c-bbb2222")
    }

    @Test func fallsBackToTheTipWhenNothingMatches() {
        let model = GGFollowEntryModel.make(
            entries: entries,
            currentGGID: "c-gone",
            displayedSHA: "unrelated"
        )

        #expect(model.selectedID == "c-ccc3333")
    }

    @Test func entriesWithoutAGGIDAreListedButNotSelectable() {
        let model = GGFollowEntryModel.make(
            entries: [GGStackEntry(position: 1, sha: "aaa1111", title: "unstacked")],
            currentGGID: nil,
            displayedSHA: nil
        )

        #expect(model.candidates.count == 1)
        #expect(!(model.candidates[0].isSelectable))
        #expect(model.selectedID == nil)
        #expect(!model.canFollow)
    }

    @Test func carriesForgeStateForTheRows() {
        let model = GGFollowEntryModel.make(
            entries: [
                GGStackEntry(
                    position: 1,
                    sha: "aaa1111",
                    title: "base work",
                    ggId: "c-aaa1111",
                    prNumber: 42,
                    prState: .open,
                    ciStatus: .success
                ),
            ],
            currentGGID: nil,
            displayedSHA: nil
        )

        #expect(model.candidates[0].prNumber == 42)
        #expect(model.candidates[0].prState == .open)
        #expect(model.candidates[0].ciStatus == .success)
    }
}
