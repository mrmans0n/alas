import Testing
@testable import Alas

struct GGMCPInjectionTests {
    @Test func providerOnlyAttachesForActiveWorktreeContext() {
        #expect(AppState.shouldAttachGGMCP(
            context: .active(stackName: "feature")
        ))
        #expect(!AppState.shouldAttachGGMCP(
            context: .inactive(reason: .policyOff)
        ))
        #expect(!AppState.shouldAttachGGMCP(
            context: .inactive(reason: .branchPrefixMismatch(expectedPrefix: "nacho/"))
        ))
    }

    @Test func happyPathBuildsStdioServerWithRepoPath() throws {
        let injection = try #require(GGMCPInjection.injection(
            gatePassed: true,
            binaryPath: "/opt/homebrew/bin/gg-mcp",
            configuredServers: [],
            worktreePath: "/tmp/wt"
        ))
        guard case let .stdio(name, command, args, env) = injection.server else {
            Issue.record("expected stdio server")
            return
        }
        #expect(name == "git-gud")
        #expect(command == "/opt/homebrew/bin/gg-mcp")
        #expect(args.isEmpty)
        #expect(env.contains { $0.name == "GG_REPO_PATH" && $0.value == "/tmp/wt" })
        #expect(injection.status.name == "git-gud")
    }

    @Test func nilWhenGateFailsOrBinaryMissing() {
        #expect(GGMCPInjection.injection(
            gatePassed: false, binaryPath: "/x/gg-mcp", configuredServers: [], worktreePath: "/tmp/wt"
        ) == nil)
        #expect(GGMCPInjection.injection(
            gatePassed: true, binaryPath: nil, configuredServers: [], worktreePath: "/tmp/wt"
        ) == nil)
    }

    @Test func userConfiguredServerNamedGitGudWins() {
        let override = ProjectMCPServer.stdio(name: " git-gud ", command: "/custom/gg-mcp")
        #expect(GGMCPInjection.injection(
            gatePassed: true, binaryPath: "/x/gg-mcp", configuredServers: [override], worktreePath: "/tmp/wt"
        ) == nil)
    }
}
