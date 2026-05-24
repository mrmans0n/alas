enum CommitPromptStatus {
    static func chipLabel(for prompt: String) -> String? {
        prompt == AppConfig.defaultCommitPrompt ? nil : "Custom"
    }
}
