import Foundation

struct CodexAdapter: CommitAIAdapter {
    var tool: CommitAITool { .codex }

    func generate(input: String, prompt: String) async throws -> GeneratedMessage {
        try await CommitAIRunner.run(binary: "codex", args: ["exec", prompt], input: input)
    }
}
