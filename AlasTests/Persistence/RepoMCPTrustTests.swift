import Foundation
import Testing
@testable import Alas

@Suite("Repo MCP trust")
struct RepoMCPTrustTests {
    private func makeProject(
        trust: [String: RepoMCPTrustState] = [:],
        disabled: [String] = []
    ) -> ProjectConfig {
        var project = ProjectConfig(
            id: "p1",
            name: "N",
            path: "/tmp/n",
            color: "#5fb7c4",
            addedAt: Date(timeIntervalSinceReferenceDate: 700_000_000)
        )
        project.repoMCPTrust = trust
        project.disabledRepoMCPServers = disabled
        return project
    }

    @Test func hashIsStableAcrossIdsAndChangesWithConfig() {
        let original = ProjectMCPServer(
            id: "repo:linear",
            name: "linear",
            transport: .stdio(
                command: "npx",
                args: ["-y", "db-mcp"],
                environment: [.init(id: "env-1", name: "DB_URL", value: "${DB_URL}")]
            )
        )
        // Same name + transport, different id: the hash must be id-independent,
        // so a deterministic repo:<name> id does not change trust across loads.
        let sameConfigOtherId = ProjectMCPServer(
            id: "other-id",
            name: "linear",
            transport: .stdio(
                command: "npx",
                args: ["-y", "db-mcp"],
                environment: [.init(id: "whatever", name: "DB_URL", value: "${DB_URL}")]
            )
        )
        #expect(RepoMCPTrust.hash(for: original) == RepoMCPTrust.hash(for: sameConfigOtherId))
        #expect(!RepoMCPTrust.hash(for: original).isEmpty)

        var edited = original
        edited.transport = .stdio(
            command: "npx",
            args: ["-y", "db-mcp", "--verbose"],
            environment: edited.transportEnvironment
        )
        #expect(RepoMCPTrust.hash(for: edited) != RepoMCPTrust.hash(for: original))

        var renamed = original
        renamed.name = "linear2"
        #expect(RepoMCPTrust.hash(for: renamed) != RepoMCPTrust.hash(for: original))
    }

    @Test func httpAndSSETransportsHashOnURLAndHeaders() {
        let http = ProjectMCPServer(
            id: "repo:remote",
            name: "remote",
            transport: .http(url: "https://mcp.example/mcp", headers: [])
        )
        let differentURL = ProjectMCPServer(
            id: "repo:remote",
            name: "remote",
            transport: .http(url: "https://other.example/mcp", headers: [])
        )
        #expect(RepoMCPTrust.hash(for: http) != RepoMCPTrust.hash(for: differentURL))
    }

    @Test func projectConfigRoundTripsTrustFields() throws {
        let project = makeProject(
            trust: ["abc": .approved, "def": .declined],
            disabled: ["linear"]
        )
        let data = try JSONEncoder().encode(project)
        let decoded = try JSONDecoder().decode(ProjectConfig.self, from: data)
        #expect(decoded.repoMCPTrust == ["abc": .approved, "def": .declined])
        #expect(decoded.disabledRepoMCPServers == ["linear"])
    }

    @Test func legacyFileWithoutTrustKeysDecodesWithEmptyDefaults() throws {
        let json = ##"{"id": "p1", "name": "N", "path": "/tmp/n", "color": "#5fb7c4", "addedAt": 700000000.0}"##
        let decoded = try JSONDecoder().decode(ProjectConfig.self, from: Data(json.utf8))
        #expect(decoded.repoMCPTrust.isEmpty)
        #expect(decoded.disabledRepoMCPServers.isEmpty)
    }

    @Test func defaultProjectEncodesWithoutTrustKeys() throws {
        let project = makeProject()
        let data = try JSONEncoder().encode(project)
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(object["repoMCPTrust"] == nil)
        #expect(object["disabledRepoMCPServers"] == nil)
    }
}

private extension ProjectMCPServer {
    /// The transport's environment with the id stripped of meaning but the
    /// entry kept, for building same-config variants in hash tests.
    var transportEnvironment: [MCPKeyValue] {
        if case let .stdio(_, _, environment) = transport {
            return environment
        }
        return []
    }
}