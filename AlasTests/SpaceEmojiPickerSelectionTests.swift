import Testing
@testable import Alas

@MainActor
struct EmojiPickerSelectionTests {
    @Test func validEmojiSelectionCommitsAndDismissesPicker() {
        var selections: [String] = []
        var dismissCount = 0

        let didCommit = EmojiPickerSelection.commit(
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

        let didCommit = EmojiPickerSelection.commit(
            "work",
            onSelect: { selections.append($0) },
            dismissPicker: { dismissCount += 1 }
        )

        #expect(!didCommit)
        #expect(selections.isEmpty)
        #expect(dismissCount == 0)
    }
}
