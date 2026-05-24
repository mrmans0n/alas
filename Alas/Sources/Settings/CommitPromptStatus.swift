enum CommitPromptStatus {
    static func label(for prompt: String) -> String {
        prompt == AppConfig.defaultCommitPrompt ? "Default prompt" : "Custom prompt"
    }
}
