import Testing
@testable import Alas

struct CommitPromptStatusTests {
    @Test func defaultPromptHasNoStatusChip() {
        #expect(CommitPromptStatus.chipLabel(for: AppConfig.defaultCommitPrompt) == nil)
    }

    @Test func modifiedPromptUsesCustomStatusChip() {
        #expect(CommitPromptStatus.chipLabel(for: AppConfig.defaultCommitPrompt + "\nExtra instruction.") == "Custom")
    }

    @Test func reviewRequestPromptStatusDetectsCustomPrompt() {
        #expect(CommitPromptStatus.chipLabel(
            for: AppConfig.defaultReviewRequestPrompt,
            defaultPrompt: AppConfig.defaultReviewRequestPrompt
        ) == nil)
        #expect(CommitPromptStatus.chipLabel(
            for: AppConfig.defaultReviewRequestPrompt + "\nExtra instruction.",
            defaultPrompt: AppConfig.defaultReviewRequestPrompt
        ) == "Custom")
    }
}
