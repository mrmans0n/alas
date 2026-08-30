import Testing
@testable import Alas

@Suite("MCP attachment planner")
struct MCPAttachmentPlannerTests {
    @Test("stdio is requested for every remote capability combination")
    func stdioIsAlwaysRequested() {
        for capabilities in [
            ACPMCPServerCapabilities(http: false, sse: false),
            ACPMCPServerCapabilities(http: true, sse: false),
            ACPMCPServerCapabilities(http: false, sse: true),
            ACPMCPServerCapabilities(http: true, sse: true),
        ] {
            let plan = MCPAttachmentPlanner.plan(.init(
                configuredServers: [.stdio(name: "local", command: "npx")],
                projectDirectory: "/project",
                worktreeDirectory: "/worktree",
                environment: [:],
                capabilities: capabilities
            ))

            #expect(plan.wireServers == [.stdio(name: "local", command: "npx", args: [], env: [])])
            #expect(plan.statuses == [.init(id: "0", name: "local", transport: .stdio, disposition: .requested)])
        }
    }

    @Test("remote transports respect advertised capabilities and configured order")
    func remoteCapabilities() {
        let servers = [
            ProjectMCPServer.stdio(name: "local", command: "npx"),
            .init(id: "http", name: "remote", transport: .http(url: "https://mcp.example.com", headers: [])),
            .init(id: "sse", name: "events", transport: .sse(url: "https://mcp.example.com/sse", headers: [])),
        ]

        let neither = plan(servers, capabilities: .init())
        #expect(neither.wireServers.map(serverName) == ["local"])
        #expect(neither.statuses.map(\.disposition) == [
            .requested,
            .skipped(.unsupportedTransport),
            .skipped(.unsupportedTransport),
        ])

        let httpOnly = plan(servers, capabilities: .init(http: true))
        #expect(httpOnly.wireServers.map(serverName) == ["local", "remote"])
        #expect(httpOnly.statuses.map(\.disposition) == [
            .requested,
            .requested,
            .skipped(.unsupportedTransport),
        ])

        let sseOnly = plan(servers, capabilities: .init(sse: true))
        #expect(sseOnly.wireServers.map(serverName) == ["local", "events"])
        #expect(sseOnly.statuses.map(\.disposition) == [
            .requested,
            .skipped(.unsupportedTransport),
            .requested,
        ])

        let both = plan(servers, capabilities: .init(http: true, sse: true))
        #expect(both.wireServers.map(serverName) == ["local", "remote", "events"])
        #expect(both.statuses.allSatisfy { $0.disposition == .requested })
    }

    @Test("interpolates all supported values and reserves directory variables")
    func interpolation() {
        let servers = [
            ProjectMCPServer(
                id: "stdio",
                name: "local",
                transport: .stdio(
                    command: "${BIN}",
                    args: ["--root=${PROJECT_DIR}", "${WORKTREE_DIR}/${NAME}", "${NAME}-${NAME}"],
                    environment: [.init(id: "token", name: "TOKEN", value: "${PREFIX}-${TOKEN}")]
                )
            ),
            ProjectMCPServer(
                id: "remote",
                name: "remote",
                transport: .http(
                    url: "https://${HOST}/${PROJECT_DIR}",
                    headers: [.init(id: "header", name: "Authorization", value: "Bearer ${TOKEN} ${TOKEN}")]
                )
            ),
        ]

        let result = plan(
            servers,
            environment: [
                "BIN": "node",
                "HOST": "mcp.example.com",
                "NAME": "service",
                "PREFIX": "secret",
                "TOKEN": "token",
                "PROJECT_DIR": "untrusted-project",
                "WORKTREE_DIR": "untrusted-worktree",
            ],
            capabilities: .init(http: true)
        )

        #expect(result.wireServers == [
            .stdio(
                name: "local",
                command: "node",
                args: ["--root=/project", "/worktree/service", "service-service"],
                env: [.init(name: "TOKEN", value: "secret-token")]
            ),
            .http(
                name: "remote",
                url: "https://mcp.example.com//project",
                headers: [.init(name: "Authorization", value: "Bearer token token")]
            ),
        ])
        #expect(result.statuses.allSatisfy { $0.disposition == .requested })
    }

    @Test("a missing variable skips only its server without exposing configuration values")
    func missingVariable() {
        let secret = "top-secret-token"
        let result = plan([
            .init(
                id: "bad",
                name: "bad",
                transport: .stdio(
                    command: "npx",
                    args: ["${MISSING}"],
                    environment: [.init(id: "secret", name: "TOKEN", value: secret)]
                )
            ),
            .stdio(name: "good", command: "node"),
        ])

        #expect(result.wireServers == [.stdio(name: "good", command: "node", args: [], env: [])])
        #expect(result.statuses == [
            .init(id: "0", name: "bad", transport: .stdio, disposition: .skipped(.missingVariable("MISSING"))),
            .init(id: "1", name: "good", transport: .stdio, disposition: .requested),
        ])
        #expect(!String(describing: result.statuses).contains(secret))
    }

    @Test("an empty resolved command skips only its server")
    func emptyResolvedCommand() {
        let result = plan([
            .init(id: "empty", name: "empty", transport: .stdio(command: "${CMD}", args: [], environment: [])),
            .stdio(name: "good", command: "node"),
        ], environment: ["CMD": ""])

        #expect(result.wireServers == [.stdio(name: "good", command: "node", args: [], env: [])])
        #expect(result.statuses[0].disposition == .skipped(.invalidConfiguration("The server configuration is invalid.")))
    }

    @Test("a whitespace-surrounded resolved command skips only its server")
    func untrimmedResolvedCommand() {
        let result = plan([
            .init(id: "untrimmed", name: "untrimmed", transport: .stdio(command: "${CMD}", args: [], environment: [])),
            .stdio(name: "good", command: "node"),
        ], environment: ["CMD": " npx "])

        #expect(result.wireServers == [.stdio(name: "good", command: "node", args: [], env: [])])
        #expect(result.statuses[0].disposition == .skipped(.invalidConfiguration("The server configuration is invalid.")))
    }

    @Test("invalid configurations skip before capability checks and keep a safe explanation")
    func invalidConfiguration() {
        let result = plan([
            .init(id: "invalid", name: "remote", transport: .http(url: "not a URL", headers: [])),
            .stdio(name: "good", command: "node"),
        ])

        #expect(result.wireServers == [.stdio(name: "good", command: "node", args: [], env: [])])
        #expect(result.statuses[0].disposition == .skipped(.invalidConfiguration("The server configuration is invalid.")))
        #expect(!String(describing: result.statuses[0]).contains("not a URL"))
    }

    @Test("duplicate invalid server names retain unique status identities")
    func duplicateServerStatusesHaveUniqueIDs() {
        let result = plan([
            .init(id: "first", name: "duplicate", transport: .stdio(command: "", args: [], environment: [])),
            .init(id: "second", name: "duplicate", transport: .stdio(command: "", args: [], environment: [])),
        ])

        #expect(result.statuses.map(\.id) == ["0", "1"])
        #expect(result.statuses.allSatisfy {
            $0.disposition == .skipped(.invalidConfiguration("The server configuration is invalid."))
        })
    }

    @Test("configuration fingerprints exclude edit IDs and include persisted values")
    func configurationFingerprint() {
        let original = ProjectMCPServer(
            id: "server-a",
            name: "remote",
            transport: .http(
                url: "https://mcp.example.com",
                headers: [.init(id: "header-a", name: "Authorization", value: "Bearer one")]
            )
        )
        let differentIDs = ProjectMCPServer(
            id: "server-b",
            name: "remote",
            transport: .http(
                url: "https://mcp.example.com",
                headers: [.init(id: "header-b", name: "Authorization", value: "Bearer one")]
            )
        )
        let changedValue = ProjectMCPServer(
            id: "server-c",
            name: "remote",
            transport: .http(
                url: "https://mcp.example.com",
                headers: [.init(id: "header-c", name: "Authorization", value: "Bearer two")]
            )
        )

        let fingerprint = MCPAttachmentPlanner.configurationFingerprint(for: [original])
        #expect(fingerprint.count == 64)
        #expect(fingerprint == MCPAttachmentPlanner.configurationFingerprint(for: [differentIDs]))
        #expect(fingerprint != MCPAttachmentPlanner.configurationFingerprint(for: [changedValue]))
    }

    @Test("empty configuration has no attachment requests")
    func emptyConfiguration() {
        let result = plan([])

        #expect(result.wireServers.isEmpty)
        #expect(result.statuses.isEmpty)
        #expect(result.configurationFingerprint == MCPAttachmentPlanner.configurationFingerprint(for: []))
    }

    @Test("frozen descriptors take precedence over current project configuration")
    func frozenDescriptorsAreUsed() throws {
        let frozen = WorkspaceMCPServerDescriptor(
            id: "member-a:before",
            server: .stdio(name: "before", command: "${PROJECT_DIR}/before"),
            projectDirectory: "/frozen-project",
            worktreeDirectory: "/frozen-worktree",
            checkoutRoot: "/frozen-checkout"
        )
        let result = MCPAttachmentPlanner.plan(.init(
            configuredServers: [.stdio(name: "after", command: "after")],
            projectDirectory: "/live-project",
            worktreeDirectory: "/live-worktree",
            environment: [:],
            capabilities: .init(),
            frozenServerDescriptors: [frozen]
        ))

        let wire = try #require(result.wireServers.first)
        #expect(serverName(wire) == "before")
        if case let .stdio(_, command, _, _) = wire {
            #expect(command == "/frozen-checkout/before")
        } else {
            Issue.record("Expected a stdio MCP server")
        }
        #expect(result.statuses.first?.id == "member-a:before")
    }

    private func plan(
        _ servers: [ProjectMCPServer],
        environment: [String: String] = [:],
        capabilities: ACPMCPServerCapabilities = .init()
    ) -> MCPAttachmentPlan {
        MCPAttachmentPlanner.plan(.init(
            configuredServers: servers,
            projectDirectory: "/project",
            worktreeDirectory: "/worktree",
            environment: environment,
            capabilities: capabilities
        ))
    }

    private func serverName(_ server: ACPMCPServer) -> String {
        switch server {
        case let .stdio(name, _, _, _), let .http(name, _, _), let .sse(name, _, _):
            name
        }
    }
}
