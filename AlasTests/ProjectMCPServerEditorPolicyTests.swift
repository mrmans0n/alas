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
        let fullURLTemplate = ProjectMCPServer(
            id: "full-url",
            name: "full-url",
            transport: .http(url: "${MCP_URL}", headers: [])
        )

        #expect(!ProjectMCPServerEditorPolicy.canSave([incomplete]))
        #expect(ProjectMCPServerEditorPolicy.canSave([deferred]))
        #expect(ProjectMCPServerEditorPolicy.canSave([fullURLTemplate]))
    }

    @Test func canSaveRejectsStructurallyInvalidURLTemplates() {
        let wrongScheme = ProjectMCPServer(
            id: "wrong-scheme",
            name: "wrong-scheme",
            transport: .http(url: "ftp://${HOST}/mcp", headers: [])
        )
        let malformed = ProjectMCPServer(
            id: "malformed",
            name: "malformed",
            transport: .http(url: "https://example.com/${TOKEN} not-valid", headers: [])
        )

        #expect(!ProjectMCPServerEditorPolicy.canSave([wrongScheme]))
        #expect(!ProjectMCPServerEditorPolicy.canSave([malformed]))
    }

    @Test func canSaveRejectsLiteralRemoteURLsWithWhitespace() {
        let server = ProjectMCPServer(
            id: "literal",
            name: "literal",
            transport: .http(url: "https://mcp.example.com/a path", headers: [])
        )

        #expect(!ProjectMCPServerEditorPolicy.canSave([server]))
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

    @Test func stdioSummaryNeverIncludesArguments() {
        let server = ProjectMCPServer(
            id: "stdio",
            name: "stdio",
            transport: .stdio(
                command: "mcp-files",
                args: ["--token", "literal-secret"],
                environment: []
            )
        )

        #expect(ProjectMCPServerEditorPolicy.summary(for: server) == "mcp-files")
    }

    @Test func labelsSSEAsLegacy() {
        #expect(ProjectMCPServerEditorPolicy.transportLabel(for: .sse(url: "https://example.com/sse", headers: [])) == "Legacy SSE")
    }
}
