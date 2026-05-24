import Testing
@testable import Alas

struct CommitPromptStatusTests {
    @Test func defaultPromptUsesDefaultStatus() {
        #expect(CommitPromptStatus.label(for: AppConfig.defaultCommitPrompt) == "Default")
    }

    @Test func modifiedPromptUsesCustomStatus() {
        #expect(CommitPromptStatus.label(for: AppConfig.defaultCommitPrompt + "\nExtra instruction.") == "Custom")
    }
}
