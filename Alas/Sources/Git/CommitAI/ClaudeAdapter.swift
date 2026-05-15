import Foundation

struct ClaudeAdapter: CommitAIAdapter {
    var tool: CommitAITool { .claude }

    func generate(input: String, prompt: String) async throws -> GeneratedMessage {
        try await CommitAIRunner.run(binary: "claude", args: ["-p", prompt], input: input)
    }
}
