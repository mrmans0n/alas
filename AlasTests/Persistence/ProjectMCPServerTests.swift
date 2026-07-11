import Foundation
import Testing
@testable import Alas

@Suite("Project MCP server")
struct ProjectMCPServerTests {
    @Test func roundTripsAllTransports() throws {
        let servers = [
            ProjectMCPServer(
                id: "stdio",
                name: "filesystem",
                transport: .stdio(
                    command: "npx",
                    args: ["-y", "server", "${WORKTREE_DIR}"],
                    environment: [.init(id: "env", name: "API_TOKEN", value: "${TOKEN}")]
                )
            ),
            ProjectMCPServer(
                id: "http",
                name: "linear",
                transport: .http(
                    url: "https://mcp.linear.app/mcp",
                    headers: [.init(id: "header", name: "Authorization", value: "Bearer ${LINEAR_TOKEN}")]
                )
            ),
            ProjectMCPServer(
                id: "sse",
                name: "legacy",
                transport: .sse(url: "https://example.com/sse", headers: [])
            ),
        ]

        let data = try JSONEncoder().encode(servers)
        let objects = try #require(JSONSerialization.jsonObject(with: data) as? [[String: Any]])
        let stdio = try #require(objects[0]["transport"] as? [String: Any])
        let http = try #require(objects[1]["transport"] as? [String: Any])
        let sse = try #require(objects[2]["transport"] as? [String: Any])

        #expect(stdio["kind"] as? String == "stdio")
        #expect(stdio["command"] as? String == "npx")
        #expect(stdio["args"] as? [String] == ["-y", "server", "${WORKTREE_DIR}"])
        #expect(stdio["environment"] as? [[String: String]] == [[
            "id": "env", "name": "API_TOKEN", "value": "${TOKEN}",
        ]])
        #expect(http["kind"] as? String == "http")
        #expect(http["url"] as? String == "https://mcp.linear.app/mcp")
        #expect(http["headers"] as? [[String: String]] == [[
            "id": "header", "name": "Authorization", "value": "Bearer ${LINEAR_TOKEN}",
        ]])
        #expect(sse["kind"] as? String == "sse")
        #expect(sse["url"] as? String == "https://example.com/sse")
        #expect(sse["headers"] as? [[String: String]] == [])
        #expect(try JSONDecoder().decode([ProjectMCPServer].self, from: data) == servers)
    }

    @Test func validationRejectsDuplicateServerNames() {
        let issues = ProjectMCPValidation.validate([
            .stdio(name: "filesystem", command: "first"),
            .stdio(name: " filesystem ", command: "second"),
        ])

        #expect(issues == [.duplicateServerName("filesystem")])
    }

    @Test func validationRejectsEmptyNamesAndCommands() {
        let server = ProjectMCPServer(
            id: "server",
            name: "  ",
            transport: .stdio(command: "\n", args: [], environment: [])
        )

        #expect(ProjectMCPValidation.validate([server]) == [
            .emptyServerName(serverId: "server"),
            .emptyCommand(serverName: ""),
        ])
    }

    @Test func validationRejectsFileURL() {
        let server = ProjectMCPServer(
            id: "server",
            name: "remote",
            transport: .http(url: "file:///tmp/mcp", headers: [])
        )

        #expect(ProjectMCPValidation.validate([server]) == [.invalidURL(serverName: "remote")])
    }

    @Test(arguments: ["ftp://mcp.example.com", "https:///missing-host", "not a url", " https://mcp.example.com "])
    func validationRejectsInvalidRemoteURLs(_ url: String) {
        let server = ProjectMCPServer(
            id: "server",
            name: "remote",
            transport: .http(url: url, headers: [])
        )

        #expect(ProjectMCPValidation.validate([server]) == [.invalidURL(serverName: "remote")])
    }

    @Test func validationRejectsInvalidAndDuplicateEnvironmentNames() {
        let server = ProjectMCPServer(
            id: "server",
            name: "filesystem",
            transport: .stdio(
                command: "npx",
                args: [],
                environment: [
                    .init(id: "one", name: "1INVALID", value: "a"),
                    .init(id: "two", name: " TOKEN ", value: "b"),
                    .init(id: "three", name: "TOKEN", value: "c"),
                ]
            )
        )

        #expect(ProjectMCPValidation.validate([server]) == [
            .invalidEnvironmentName(serverName: "filesystem", name: "1INVALID"),
            .invalidEnvironmentName(serverName: "filesystem", name: " TOKEN "),
        ])
    }

    @Test func validationRejectsWhitespaceAroundHeaderNames() {
        let server = ProjectMCPServer(
            id: "server",
            name: "remote",
            transport: .sse(
                url: "https://mcp.example.com/sse",
                headers: [
                    .init(id: "one", name: " Authorization ", value: "a"),
                    .init(id: "two", name: "authorization", value: "b"),
                ]
            )
        )

        #expect(ProjectMCPValidation.validate([server]) == [
            .invalidHeaderName(serverName: "remote", name: " Authorization "),
        ])
    }

    @Test func validationRejectsDuplicateHeaderNamesCaseInsensitively() {
        let server = ProjectMCPServer(
            id: "server",
            name: "remote",
            transport: .sse(
                url: "https://mcp.example.com/sse",
                headers: [
                    .init(id: "one", name: "Authorization", value: "a"),
                    .init(id: "two", name: "authorization", value: "b"),
                ]
            )
        )

        #expect(ProjectMCPValidation.validate([server]) == [
            .duplicateHeaderName(serverName: "remote", name: "authorization"),
        ])
    }

    @Test func validationRejectsEmptyHeaderNames() {
        let server = ProjectMCPServer(
            id: "server",
            name: "remote",
            transport: .http(
                url: "https://mcp.example.com",
                headers: [.init(id: "header", name: " \n ", value: "token")]
            )
        )

        #expect(ProjectMCPValidation.validate([server]) == [.emptyHeaderName(serverName: "remote")])
    }

    @Test func validationAcceptsEmptyArgumentsEnvironmentAndHeaders() {
        let servers = [
            ProjectMCPServer.stdio(name: "filesystem", command: "npx"),
            ProjectMCPServer(id: "http", name: "remote", transport: .http(url: "https://mcp.example.com", headers: [])),
            ProjectMCPServer(id: "sse", name: "events", transport: .sse(url: "https://mcp.example.com/sse", headers: [])),
        ]

        #expect(ProjectMCPValidation.validate(servers).isEmpty)
    }
}
