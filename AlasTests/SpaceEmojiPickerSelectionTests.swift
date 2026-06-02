import Testing
@testable import Alas

@MainActor
struct SpaceEmojiPickerSelectionTests {
    @Test func validEmojiSelectionCommitsAndDismissesPicker() {
        var selections: [String] = []
        var dismissCount = 0

        let didCommit = SpaceEmojiPickerSelection.commit(
            "🚀",
            onSelect: { selections.append($0) },
            dismissPicker: { dismissCount += 1 }
        )

        #expect(didCommit)
        #expect(selections == ["🚀"])
        #expect(dismissCount == 1)
    }

    @Test func invalidEmojiSelectionDoesNotDismissPicker() {
        var selections: [String] = []
        var dismissCount = 0

        let didCommit = SpaceEmojiPickerSelection.commit(
            "work",
            onSelect: { selections.append($0) },
            dismissPicker: { dismissCount += 1 }
        )

        #expect(!didCommit)
        #expect(selections.isEmpty)
        #expect(dismissCount == 0)
    }
}
