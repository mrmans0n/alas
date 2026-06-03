enum CommitPromptStatus {
    static func chipLabel(for prompt: String) -> String? {
        chipLabel(for: prompt, defaultPrompt: AppConfig.defaultCommitPrompt)
    }

    static func chipLabel(for prompt: String, defaultPrompt: String) -> String? {
        prompt == defaultPrompt ? nil : "Custom"
    }
}
