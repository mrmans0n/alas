import Foundation
import Testing
@testable import Alas

@MainActor
@Suite("AlasMCPHTTPSupervisor")
struct AlasMCPHTTPSupervisorTests {
    @Test("parses the PORT announcement line")
    func parsesPort() {
        #expect(AlasMCPHTTPSupervisor.parsePort(from: "PORT 5599") == 5599)
        #expect(AlasMCPHTTPSupervisor.parsePort(from: "PORT 5599\n".trimmingCharacters(in: .whitespacesAndNewlines)) == 5599)
        #expect(AlasMCPHTTPSupervisor.parsePort(from: "garbage") == nil)
    }

    @Test("workspace-only sessions export checkout scope to HTTP MCP process")
    func workspaceOnlyEnvironment() {
        let scoped = AlasMCPHTTPSupervisor.environment(
            base: [:],
            socketPath: "/socket",
            worktreePath: "/checkout",
            sessionId: "session",
            token: "token",
            parentSessionId: nil,
            workspaceOnly: true
        )
        let regular = AlasMCPHTTPSupervisor.environment(
            base: [:],
            socketPath: "/socket",
            worktreePath: "/worktree",
            sessionId: "session",
            token: "token",
            parentSessionId: nil
        )

        #expect(scoped["ALAS_MCP_WORKSPACE_ONLY"] == "1")
        #expect(regular["ALAS_MCP_WORKSPACE_ONLY"] == nil)
    }

    /// A stand-in for `alas mcp --http`: announces the requested port (40001
    /// without one), refuses `takenPort` the way a failed bind does, then
    /// serves until its stdin closes.
    private func fakeServer(takenPort: Int = 0) throws -> String {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("alas-mcp-supervisor-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let script = directory.appendingPathComponent("alas")
        try """
        #!/bin/sh
        port=40001
        while [ $# -gt 0 ]; do
          if [ "$1" = "--port" ]; then port="$2"; fi
          shift
        done
        [ "$port" = "\(takenPort)" ] && exit 1
        echo "PORT $port"
        exec cat >/dev/null
        """.write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        return script.path
    }

    private func endpoint(
        _ supervisor: AlasMCPHTTPSupervisor, binaryPath: String
    ) async -> BuiltInAlasMCP.HTTPEndpoint? {
        await supervisor.endpoint(
            binaryPath: binaryPath, socketPath: "/socket", worktreePath: "/worktree",
            sessionId: "session", parentSessionId: nil
        )
    }

    @Test("after an app restart the server comes back at the address the agent already has")
    func respawnsAtRememberedAddress() async throws {
        let binary = try fakeServer()
        let state = BuiltInMCPSessionState()
        let first = AlasMCPHTTPSupervisor(state: state)
        let original = try #require(await endpoint(first, binaryPath: binary))
        first.shutdown()

        let relaunched = AlasMCPHTTPSupervisor(state: state)
        defer { relaunched.shutdown() }
        #expect(await endpoint(relaunched, binaryPath: binary) == original)
    }

    @Test("a remembered port that is taken falls back to a fresh address")
    func takenRememberedPortFallsBackToFreshAddress() async throws {
        let binary = try fakeServer(takenPort: 40002)
        let state = BuiltInMCPSessionState()
        state.setHTTPEndpoint(.init(port: 40002, token: "old"), sessionId: "session")
        let supervisor = AlasMCPHTTPSupervisor(state: state)
        defer { supervisor.shutdown() }

        let endpoint = try #require(await endpoint(supervisor, binaryPath: binary))
        #expect(endpoint.url == "http://localhost:40001/mcp")
        #expect(endpoint.token != "old")
        #expect(state.httpEndpoint(sessionId: "session") == .init(port: 40001, token: endpoint.token))
    }
}
