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
}
