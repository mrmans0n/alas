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
        if case .agentMessageChunk(let chunk) = firstUpdate, case .text(let t) = chunk.content {
            #expect(t == "hi")
        } else { Issue.record("expected agent_message_chunk 'hi'") }
        await client.shutdown()
    }

    private final class ResultBox<T>: @unchecked Sendable {
        private let lock = NSLock()
        private var value: T?
        func set(_ v: T) {
            lock.lock()
            value = v
            lock.unlock()
        }

        func get() -> T? {
            lock.lock()
            defer { lock.unlock() }
            return value
        }
    }

    /// Runs `work` in a detached task and returns its result, or nil if it
    /// does not finish within roughly `steps * step`. A work item that never
    /// completes (e.g. a parked continuation on a regressed drain) is
    /// abandoned rather than awaited, so a regression surfaces as a bounded
    /// nil result instead of hanging the whole test run.
    private func boundedResult<T: Sendable>(
        steps: Int = 150,
        step: Duration = .milliseconds(20),
        _ work: @escaping @Sendable () async -> T
    ) async -> T? {
        let box = ResultBox<T>()
        let task = Task.detached { box.set(await work()) }
        for _ in 0..<steps {
            if let v = box.get() { return v }
            try? await Task.sleep(for: step)
        }
        task.cancel()
        return box.get()
    }

    @Test("shutdown resumes an in-flight request even when the transport never emits .exited")
    func shutdownDrainsPendingWithoutExit() async {
        let transport = FakeJSONRPCTransport()
        transport.emitExitOnTerminate = false // real-transport behaviour: no synchronous .exited
        let client = ACPStdioClient.makeForTesting(transport: transport)
        try? client.start()

        // Fire a request the fake never answers; shutdown must unblock it.
        async let threw = boundedResult { () -> Bool in
            do {
                _ = try await client.send(ACPRequest(
                    method: "session/prompt",
                    params: ACPSessionPromptParams(sessionId: "s", prompt: [])))
                return false
            } catch {
                return true
            }
        }
        try? await Task.sleep(for: .milliseconds(100)) // let send() register in `pending`
        await client.shutdown()

        #expect(await threw == true)
    }

    @Test("shutdown drain is idempotent with a transport that also emits .exited")
    func shutdownDrainIsIdempotent() async {
        let transport = FakeJSONRPCTransport() // emitExitOnTerminate defaults to true
        let client = ACPStdioClient.makeForTesting(transport: transport)
        try? client.start()

        async let threw = boundedResult { () -> Bool in
            do {
                _ = try await client.send(ACPRequest(
                    method: "session/prompt",
                    params: ACPSessionPromptParams(sessionId: "s", prompt: [])))
                return false
            } catch { return true }
        }
        try? await Task.sleep(for: .milliseconds(100))
        await client.shutdown()
        // If the .exited handler re-resumed the same continuation the process
        // would have already trapped; reaching this line means it did not.
        #expect(await threw == true)
    }

    @Test("ACPConnection.shutdown unwinds an in-flight prompt")
    func connectionShutdownUnwindsPrompt() async {
        let transport = FakeJSONRPCTransport()
        transport.emitExitOnTerminate = false
        let client = ACPStdioClient.makeForTesting(transport: transport)
        try? client.start()
        let connection = ACPConnection(client: client)

        async let threw = boundedResult { () -> Bool in
            do {
                try await connection.prompt(sessionId: "s", blocks: [])
                return false
            } catch {
                return true
            }
        }
        try? await Task.sleep(for: .milliseconds(100))
        await connection.shutdown()
        #expect(await threw == true)
    }
}
