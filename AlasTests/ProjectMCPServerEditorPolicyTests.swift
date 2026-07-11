import Testing
@testable import Alas

@Suite("Project MCP server editor policy")
struct ProjectMCPServerEditorPolicyTests {
    @Test func canSaveRequiresValidStructureButPermitsDeferredURLTemplates() {
        let incomplete = ProjectMCPServer.stdio(name: "filesystem", command: "  ")
        let deferred = ProjectMCPServer(
            id: "remote",
            name: "remote",
            transport: .http(url: "https://${MCP_HOST}/mcp", headers: [])
        )

        #expect(!ProjectMCPServerEditorPolicy.canSave([incomplete]))
        #expect(ProjectMCPServerEditorPolicy.canSave([deferred]))
    }

    @Test func extractsDistinctTemplateVariablesInEncounterOrder() {
        let server = ProjectMCPServer(
            id: "server",
            name: "filesystem",
            transport: .stdio(
                command: "mcp-${COMMAND}",
                args: ["${WORKTREE_DIR}", "${COMMAND}"],
                environment: [
                    .init(id: "one", name: "TOKEN", value: "${API_TOKEN}"),
                    .init(id: "two", name: "EMPTY", value: "${NOT-VALID!}"),
                ]
            )
        )

        #expect(ProjectMCPServerEditorPolicy.templateVariables(in: server) == [
            "COMMAND", "WORKTREE_DIR", "API_TOKEN",
        ])
    }

    @Test func summaryNeverIncludesRemoteCredentialsQueryOrFragment() {
        let server = ProjectMCPServer(
            id: "remote",
            name: "remote",
            transport: .http(
                url: "https://user:secret@mcp.example.com/v1?token=top-secret#private",
                headers: []
            )
        )

        #expect(ProjectMCPServerEditorPolicy.summary(for: server) == "https://mcp.example.com/v1")
    }

    @Test func labelsSSEAsLegacy() {
        #expect(ProjectMCPServerEditorPolicy.transportLabel(for: .sse(url: "https://example.com/sse", headers: [])) == "Legacy SSE")
    }
}
