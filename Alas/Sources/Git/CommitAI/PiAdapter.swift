import Foundation

struct PiAdapter: CommitAIAdapter {
    var tool: CommitAITool { .pi }

    func generate(input: String, prompt: String) async throws -> GeneratedMessage {
        try await CommitAIRunner.run(binary: "pi", args: ["-p", prompt], input: input)
    }
}
