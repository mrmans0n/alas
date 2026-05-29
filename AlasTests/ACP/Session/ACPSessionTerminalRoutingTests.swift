import Foundation
import Testing
@testable import Alas

@MainActor
@Suite("ACP terminal routing")
struct ACPSessionTerminalRoutingTests {
    @Test("terminal/create routes to the session host and responds with an id")
    func createRoundTrip() async throws {
        let (runner, mock) = try makeRunner()
        runner.start()
        defer { runner.stop() }

        let params = ACPTerminalCreateParams(
            sessionId: "s", command: "/bin/echo",
            args: ["hi"], env: nil, cwd: nil, outputByteLimit: nil)
        mock.emitTerminal(.create(id: .number(1), params: params))

        for _ in 0..<50 {
            if mock.terminalResponses[.number(1)] != nil { break }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        guard case .success(let body)? = mock.terminalResponses[.number(1)] else {
            Issue.record("expected success response")
            return
        }
        let res = try JSONDecoder().decode(ACPTerminalCreateResult.self, from: body)
        #expect(!res.terminalId.isEmpty)
        #expect(runner.session.terminalHost.terminal(id: res.terminalId) != nil)
    }

    @Test("terminal/output on unknown id responds with JSON-RPC error -32602")
    func unknownTerminalErrors() async throws {
        let (runner, mock) = try makeRunner()
        runner.start()
        defer { runner.stop() }

        mock.emitTerminal(.output(id: .number(2),
            params: ACPTerminalOutputParams(sessionId: "s", terminalId: "nope")))
        for _ in 0..<50 {
            if mock.terminalResponses[.number(2)] != nil { break }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        guard case .failure(let err)? = mock.terminalResponses[.number(2)] else {
            Issue.record("expected error response")
            return
        }
        #expect(err.code == -32602)
    }

    @Test("runner seeds terminal host with the supplied agentEnv")
    func runnerPropagatesAgentEnv() async throws {
        let (runner, _) = try makeRunner(agentEnv: ["ALAS_TEST_TOKEN": "ok", "PATH": "/bin:/usr/bin"])
        runner.start()
        defer { runner.stop() }
        // The same env was handed to the agent process; the terminal
        // host should mirror it so agent-spawned commands see the same
        // sanitized view (no CLAUDECODE/CLAUDE_SESSION_ID leakage).
        let env = runner.session.terminalHost.sessionEnv
        #expect(env["ALAS_TEST_TOKEN"] == "ok")
        #expect(env["PATH"] == "/bin:/usr/bin")
    }

    @Test("runner.stop() kills agent-spawned terminals")
    func stopKillsTerminals() async throws {
        let (runner, mock) = try makeRunner()
        runner.start()

        // Spawn a long-running terminal via the routing path.
        mock.emitTerminal(.create(id: .number(7),
            params: ACPTerminalCreateParams(
                sessionId: "s", command: "/bin/sleep",
                args: ["60"], env: nil, cwd: "/tmp", outputByteLimit: nil)))
        for _ in 0..<50 {
            if mock.terminalResponses[.number(7)] != nil { break }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        guard case .success(let body)? = mock.terminalResponses[.number(7)] else {
            Issue.record("expected terminal/create success")
            return
        }
        let res = try JSONDecoder().decode(ACPTerminalCreateResult.self, from: body)
        let term = runner.session.terminalHost.terminal(id: res.terminalId)
        #expect(term != nil)
        #expect(term?.exitStatus == nil)

        runner.stop()

        // killAll → SIGTERM → process should exit within a couple seconds.
        let status = await term!.waitForExit()
        #expect(status.signal != nil || (status.exitCode ?? 0) != 0)
    }

    private func makeRunner(agentEnv: [String: String] = ProcessInfo.processInfo.environment)
        throws -> (ACPSessionRunner, ACPMockClient)
    {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("rn-\(UUID()).sqlite")
        let store = try ACPSessionStore(path: url.path)
        try store.upsertSession(.init(id: "s", agentId: "claude", title: "t",
            currentModel: nil, currentMode: nil, autoRun: false,
            createdAt: 0, updatedAt: 0, lastOpenedAt: 0, archived: false))
        let mock = ACPMockClient()
        let session = ACPSession(id: "s", agentId: "claude", worktreeId: "wt", title: "t")
        let runner = ACPSessionRunner(
            session: session,
            connection: ACPConnection(client: mock),
            store: store,
            sessionId: "s",
            worktreePath: FileManager.default.temporaryDirectory.path,
            agentEnv: agentEnv)
        return (runner, mock)
    }
}
