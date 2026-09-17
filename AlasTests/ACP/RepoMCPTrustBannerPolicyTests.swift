import Foundation
import Testing
@testable import Alas

@Suite("Repo MCP trust banner policy")
struct RepoMCPTrustBannerPolicyTests {
    private func repoServer(_ name: String) -> ProjectMCPServer {
        ProjectMCPServer(
            id: "repo:\(name)",
            name: name,
            transport: .http(url: "https://mcp.example.com", headers: [])
        )
    }

    private func project(
        host: String? = nil,
        mcpServers: [ProjectMCPServer] = [],
        repoServers: [ProjectMCPServer],
        disabled: [String] = [],
        trust: [String: RepoMCPTrustState] = [:]
    ) -> (project: ProjectConfig, repoConfig: RepoConfig?) {
        let config = ProjectConfig(
            id: "p1",
            name: "repo",
            path: "/repo",
            color: "#5fb7c4",
            addedAt: Date(),
            mcpServers: mcpServers
        )
        var configured = config
        configured.host = host
        configured.disabledRepoMCPServers = disabled
        configured.repoMCPTrust = trust
        let repoConfig = RepoConfig(mcpServers: repoServers)
        return (configured, repoConfig)
    }

    private func decision(
        host: String? = nil,
        mcpServers: [ProjectMCPServer] = [],
        repoServers: [ProjectMCPServer],
        disabled: [String] = [],
        trust: [String: RepoMCPTrustState] = [:]
    ) -> RepoMCPTrustBannerDecision {
        let (project, repoConfig) = self.project(
            host: host,
            mcpServers: mcpServers,
            repoServers: repoServers,
            disabled: disabled,
            trust: trust
        )
        return RepoMCPTrustBannerPolicy.decision(project: project, repoConfig: repoConfig)
    }

    @Test("untrusted repo servers are pending, in file order")
    func pendingServers() {
        let decision = decision(repoServers: [repoServer("a"), repoServer("b")])
        #expect(decision.isVisible)
        #expect(decision.pendingServers.map(\.name) == ["a", "b"])
    }

    @Test("remote projects stay silent")
    func remoteProjectIsSilent() {
        let decision = decision(host: "box", repoServers: [repoServer("a")])
        #expect(!decision.isVisible)
    }

    @Test("missing or malformed repo config stays silent")
    func missingRepoConfigIsSilent() {
        let decision = decision(repoServers: [], trust: [:])
        #expect(!decision.isVisible)
    }

    @Test("approved and declined servers are no longer pending")
    func decidedServersAreNotPending() {
        let approved = repoServer("a")
        let declined = repoServer("b")
        let decision = decision(
            repoServers: [approved, declined],
            trust: [
                RepoMCPTrust.hash(for: approved): .approved,
                RepoMCPTrust.hash(for: declined): .declined,
            ]
        )
        #expect(!decision.isVisible)
    }

    @Test("disabled and app-shadowed servers are not pending")
    func disabledAndShadowedServersAreNotPending() {
        let disabled = repoServer("a")
        let shadowed = repoServer("b")
        let decision = decision(
            mcpServers: [.stdio(name: "b", command: "mine")],
            repoServers: [disabled, shadowed],
            disabled: ["a"],
            trust: [RepoMCPTrust.hash(for: shadowed): .approved]
        )
        #expect(!decision.isVisible)
    }

    @Test("a changed server config re-enters pending")
    func editedServerReprompts() {
        let original = repoServer("a")
        let edited = ProjectMCPServer(
            id: original.id,
            name: "a",
            transport: .stdio(command: "npx", args: ["other"], environment: [])
        )
        let decided = decision(
            repoServers: [original],
            trust: [RepoMCPTrust.hash(for: original): .approved]
        )
        #expect(!decided.isVisible)

        let reprompted = decision(
            repoServers: [edited],
            trust: [RepoMCPTrust.hash(for: original): .approved]
        )
        #expect(reprompted.pendingServers.map(\.name) == ["a"])
    }
}