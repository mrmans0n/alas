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

@Suite("Project MCP config importer")
struct ProjectMCPConfigImporterTests {
    @Test func importsSupportedTransportsFromWrappedConfig() throws {
        let text = #"""
        {
          "mcpServers": {
            "local": {
              "command": "npx",
              "args": ["-y", "server"],
              "env": { "TOKEN": "${MCP_TOKEN}" }
            },
            "remote": {
              "url": "https://mcp.example.com/mcp",
              "headers": { "Authorization": "Bearer ${MCP_TOKEN}" }
            },
            "events": {
              "type": "sse",
              "url": "https://mcp.example.com/sse"
            }
          }
        }
        """#

        let servers = ProjectMCPConfigImporter.servers(from: text)
        let local = try #require(servers.first { $0.name == "local" })
        let remote = try #require(servers.first { $0.name == "remote" })
        let events = try #require(servers.first { $0.name == "events" })

        #expect(servers.count == 3)
        guard case let .stdio(command, args, environment) = local.transport else {
            Issue.record("Expected stdio transport")
            return
        }
        #expect(command == "npx")
        #expect(args == ["-y", "server"])
        #expect(environment.count == 1)
        #expect(environment.first?.name == "TOKEN")
        #expect(environment.first?.value == "${MCP_TOKEN}")
        guard case let .http(url, headers) = remote.transport else {
            Issue.record("Expected HTTP transport")
            return
        }
        #expect(url == "https://mcp.example.com/mcp")
        #expect(headers.count == 1)
        #expect(headers.first?.name == "Authorization")
        #expect(headers.first?.value == "Bearer ${MCP_TOKEN}")
        #expect(events.transport == .sse(url: "https://mcp.example.com/sse", headers: []))
    }

    @Test func importsBraceLessConfigWithSmartQuotes() throws {
        let text = #"“mcpServers”: { “scout”: { “type”: “http”, “url”: “http://localhost:3001/mcp”, “disabled”: false } }"#

        let servers = ProjectMCPConfigImporter.servers(from: text)
        let scout = try #require(servers.first)

        #expect(servers.count == 1)
        #expect(scout.name == "scout")
        #expect(scout.transport == .http(url: "http://localhost:3001/mcp", headers: []))
    }

    @Test func skipsDisabledMalformedUnsupportedAndExistingServers() {
        let text = #"""
        {
          "mcpServers": {
            "existing": { "type": "http", "url": "https://replacement.example.com" },
            "disabled": { "type": "http", "url": "https://disabled.example.com", "disabled": true },
            "broken": { "type": "http", "url": "not a url" },
            "unsupported": { "type": "websocket", "url": "wss://example.com" },
            "usable": { "type": "stdio", "command": "mcp-server" }
          }
        }
        """#
        let existing = [ProjectMCPServer.stdio(name: " existing ", command: "keep-me")]

        let servers = ProjectMCPConfigImporter.servers(from: text, excluding: existing)

        #expect(servers.count == 1)
        #expect(servers.first?.name == "usable")
        #expect(servers.first?.transport == .stdio(command: "mcp-server", args: [], environment: []))
        #expect(ProjectMCPConfigImporter.servers(from: "not JSON").isEmpty)
    }
}
