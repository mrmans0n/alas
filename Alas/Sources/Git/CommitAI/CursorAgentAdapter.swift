import Foundation

struct CursorAgentAdapter: CommitAIAdapter {
    var tool: CommitAITool { .cursorAgent }

    func generate(input: String, prompt: String) async throws -> GeneratedMessage {
        try await CommitAIRunner.run(binary: "cursor-agent", args: ["-p", prompt], input: input)
    }
}
