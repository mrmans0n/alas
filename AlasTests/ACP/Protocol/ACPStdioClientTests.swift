import Foundation
import Testing
@testable import Alas

@Suite("ACPStdioClient")
struct ACPStdioClientTests {
    /// The fake agent script reads one Content-Length framed request from stdin
    /// and writes back a canned response + one session/update notification.
    private func fakeAgentScript() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
        let url = dir.appendingPathComponent("fake-acp-agent-\(UUID()).sh")
        let body = #"""
        #!/bin/bash
        # ACP uses newline-delimited JSON. Read one request line, then write
        # the response + a notification as separate lines.
        IFS= read -r line
        echo '{"jsonrpc":"2.0","id":1,"result":{"protocolVersion":1,"authMethods":[]}}'
        echo '{"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"s","update":{"sessionUpdate":"agent_message_chunk","content":{"type":"text","text":"hi"}}}}'
        sleep 1
        """#
        try body.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url
    }

    @Test("request/response round-trip + receiving a notification")
    func roundtrip() async throws {
        let script = try fakeAgentScript()
        defer { try? FileManager.default.removeItem(at: script) }
        let client = try ACPStdioClient(executable: URL(fileURLWithPath: "/bin/bash"),
                                        arguments: [script.path],
                                        environment: nil)
        try client.start()

        let resp = try await client.send(ACPRequest(
            method: "initialize",
            params: ACPInitializeParams(
                protocolVersion: 1,
                clientCapabilities: .init(
                    fs: .init(readTextFile: true, writeTextFile: true),
                    terminal: true))
        ))
        let init_ = try JSONDecoder().decode(ACPInitializeResult.self, from: resp.body)
        #expect(init_.protocolVersion == 1)

        // First incoming update
        let firstUpdate = await { () async -> ACPSessionUpdate? in
            for await u in client.incomingUpdates { return u.update }
            return nil
        }()
        if case .agentMessageChunk(let block) = firstUpdate, case .text(let t) = block {
            #expect(t == "hi")
        } else { Issue.record("expected agent_message_chunk 'hi'") }
        await client.shutdown()
    }
}
