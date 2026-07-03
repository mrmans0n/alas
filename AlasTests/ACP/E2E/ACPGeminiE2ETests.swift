import Foundation
import Testing
@testable import Alas

@Suite(.disabled(if: !FileManager.default.isExecutableFile(atPath: "/opt/homebrew/bin/gemini")
                  && !FileManager.default.isExecutableFile(atPath: "/usr/local/bin/gemini")))
struct ACPGeminiE2ETests {
    @Test("gemini --experimental-acp answers a trivial prompt")
    func smoke() async throws {
        let binary = ["/opt/homebrew/bin/gemini", "/usr/local/bin/gemini"]
            .first { FileManager.default.isExecutableFile(atPath: $0) }!
        let client = try ACPStdioClient(executable: URL(fileURLWithPath: binary),
                                        arguments: ["--experimental-acp"],
                                        environment: nil)
        try client.start()
        let conn = ACPConnection(client: client)
        try await conn.initialize()
        let new = try await conn.newSession(cwd: FileManager.default.temporaryDirectory.path)
        try await conn.prompt(sessionId: new.sessionId, blocks: [.text("say hi in three words")])

        let got = await withTimeout(seconds: 30) { () async -> String? in
            var collected = ""
            for await u in client.incomingUpdates {
                if case .agentMessageChunk(let chunk) = u.update,
                   case .text(let s) = chunk.content {
                    collected += s
                    if collected.count > 3 { return collected }
                }
            }
            return collected.isEmpty ? nil : collected
        }
        await conn.shutdown()
        #expect(got != nil, "expected at least one agent_message_chunk")
    }
}

private func withTimeout<T>(seconds: TimeInterval, _ work: @escaping () async -> T?) async -> T? {
    await withTaskGroup(of: T?.self) { group in
        group.addTask { await work() }
        group.addTask { try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
        return nil }
        let first = await group.next()!
        group.cancelAll()
        return first
    }
}
