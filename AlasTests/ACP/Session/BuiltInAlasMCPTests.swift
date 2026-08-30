import Foundation
import Testing
@testable import Alas

@Suite("Built-in alas MCP injection")
struct BuiltInAlasMCPTests {
    private func make(
        enabled: Bool = true,
        configuredServers: [ProjectMCPServer] = [],
        binaryPath: String? = "/support/bin/alas",
        socketPath: String? = "/tmp/alas-501/pid-42",
        worktreePath: String = "/repos/proj/wt",
        sessionId: String = "acp-1"
    ) -> BuiltInAlasMCP.Injection? {
        BuiltInAlasMCP.injection(
            enabled: enabled,
            configuredServers: configuredServers,
            binaryPath: binaryPath,
            socketPath: socketPath,
            worktreePath: worktreePath,
            sessionId: sessionId
        )
    }

    @Test("builds the stdio entry with session-scoped env")
    func buildsWireEntry() {
        let injection = make()
        #expect(injection?.server == .stdio(
            name: "alas",
            command: "/support/bin/alas",
            args: ["mcp"],
            env: [
                .init(name: "ALAS_SOCKET_PATH", value: "/tmp/alas-501/pid-42"),
                .init(name: "ALAS_WORKTREE_DIR", value: "/repos/proj/wt"),
                .init(name: "ALAS_SESSION_ID", value: "acp-1"),
            ]
        ))
        #expect(injection?.status == .init(
            id: "builtin-alas", name: "alas", transport: .stdio, disposition: .requested
        ))
    }

    @Test("skips when disabled or prerequisites are missing")
    func skipsWhenUnavailable() {
        #expect(make(enabled: false) == nil)
        #expect(make(binaryPath: nil) == nil)
        #expect(make(socketPath: nil) == nil)
    }

    @Test("a project server named alas suppresses the built-in")
    func userOverrideWins() {
        #expect(make(configuredServers: [.stdio(name: "alas", command: "/dev/alas")]) == nil)
        #expect(make(configuredServers: [.stdio(name: "  alas  ", command: "/dev/alas")]) == nil)
        #expect(make(configuredServers: [.stdio(name: "other", command: "npx")]) != nil)
    }

    @Test("is dropped for remote sessions like any stdio server")
    func remoteFilterDropsIt() {
        let injection = make()!
        let split = ACPRemoteMCPFilter.split([injection.server])
        #expect(split.kept.isEmpty)
        #expect(split.droppedStdio == ["alas"])
    }

    @Test("builds an http wire entry when given an endpoint")
    func buildsHTTPWireEntry() {
        let injection = BuiltInAlasMCP.injection(
            enabled: true,
            configuredServers: [],
            binaryPath: "/bin/alas",
            socketPath: "/tmp/s.sock",
            worktreePath: "/wt",
            sessionId: "S1",
            httpEndpoint: .init(url: "http://localhost:5599/mcp", token: "TOK"))
        guard case let .http(name, url, headers)? = injection?.server else {
            Issue.record("expected http server")
            return
        }
        #expect(name == "alas")
        #expect(url == "http://localhost:5599/mcp")
        #expect(headers.contains(ACPMCPKeyValue(name: "Authorization", value: "Bearer TOK")))
        #expect(injection?.status.transport == .http)
    }

    @Test("shouldInject mirrors the injection guards")
    func shouldInjectGuards() {
        // Disabled or missing prerequisites suppress injection.
        #expect(BuiltInAlasMCP.shouldInject(
            enabled: false, configuredServers: [],
            binaryPath: "/bin/alas", socketPath: "/tmp/s.sock") == false)
        #expect(BuiltInAlasMCP.shouldInject(
            enabled: true, configuredServers: [],
            binaryPath: nil, socketPath: "/tmp/s.sock") == false)
        #expect(BuiltInAlasMCP.shouldInject(
            enabled: true, configuredServers: [],
            binaryPath: "/bin/alas", socketPath: nil) == false)
        // A project server named "alas" is an intentional override.
        #expect(BuiltInAlasMCP.shouldInject(
            enabled: true,
            configuredServers: [.stdio(name: "  alas  ", command: "/dev/alas")],
            binaryPath: "/bin/alas", socketPath: "/tmp/s.sock") == false)
        // Otherwise the built-in should be injected.
        #expect(BuiltInAlasMCP.shouldInject(
            enabled: true,
            configuredServers: [.stdio(name: "other", command: "npx")],
            binaryPath: "/bin/alas", socketPath: "/tmp/s.sock") == true)
    }

    @Test("injection marks delegated sessions")
    func injectionMarksDelegated() throws {
        let root = try #require(BuiltInAlasMCP.injection(
            enabled: true, configuredServers: [],
            binaryPath: "/bin/alas", socketPath: "/tmp/s.sock",
            worktreePath: "/repos/proj/wt", sessionId: "s1"))
        #expect(root.isDelegated == false)

        let child = try #require(BuiltInAlasMCP.injection(
            enabled: true, configuredServers: [],
            binaryPath: "/bin/alas", socketPath: "/tmp/s.sock",
            worktreePath: "/repos/proj/wt", sessionId: "s2",
            parentSessionId: "s1"))
        #expect(child.isDelegated == true)
    }

    @Test("checkout context is an allow-listed payload")
    func checkoutContextContainsOnlyIdentityRootAndMemberAvailability() throws {
        let checkoutID = UUID()
        let context = BuiltInAlasMCP.WorkspaceContext(
            checkoutID: checkoutID,
            rootPath: "/checkout",
            members: [.init(id: UUID(), availability: .available)]
        )
        let injection = try #require(BuiltInAlasMCP.injection(
            enabled: true, configuredServers: [], binaryPath: "/bin/alas", socketPath: "/tmp/s.sock",
            worktreePath: "/checkout", sessionId: "s", workspaceContext: context
        ))
        guard case let .stdio(_, _, _, environment) = injection.server,
              let value = environment.first(where: { $0.name == "ALAS_WORKSPACE_CONTEXT" })?.value,
              let data = value.data(using: .utf8)
        else { Issue.record("Expected checkout context")
        return }
        #expect(try JSONDecoder().decode(BuiltInAlasMCP.WorkspaceContext.self, from: data) == context)
        #expect(value.contains("script") == false)
        #expect(value.contains("secret") == false)
    }
}
