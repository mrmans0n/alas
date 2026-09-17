import Foundation
import Testing
@testable import Alas

@Suite("Repo MCP resolver")
struct RepoMCPResolverTests {
    private func repo(_ name: String, command: String = "npx") -> ProjectMCPServer {
        ProjectMCPServer(
            id: "repo:\(name)",
            name: name,
            transport: .stdio(command: command, args: [], environment: [])
        )
    }

    private func app(_ name: String) -> ProjectMCPServer {
        ProjectMCPServer(
            id: UUID().uuidString,
            name: name,
            transport: .stdio(command: "mine", args: [], environment: [])
        )
    }

    private func approved(_ server: ProjectMCPServer) -> [String: RepoMCPTrustState] {
        [RepoMCPTrust.hash(for: server): .approved]
    }

    @Test func appServerShadowsRepoServerByName() {
        let shadowed = repo("linear")
        let appServer = app("linear")
        let result = RepoMCPResolver.merge(
            appServers: [appServer],
            repoServers: [shadowed],
            disabledNames: ["linear"],
            trust: approved(shadowed)
        )
        // Shadowing wins over the disable list: the repo server never attaches
        // either way, and the reason explains which rule fired first.
        #expect(result.active == [appServer])
        #expect(result.skipped.count == 1)
        #expect(result.skipped.first?.reason == .shadowedByApp)
        #expect(result.skipped.first?.server == shadowed)
        #expect(result.pendingApproval.isEmpty)
    }

    @Test func disabledRepoServerIsSkippedAsDisabled() {
        let server = repo("db")
        let result = RepoMCPResolver.merge(
            appServers: [],
            repoServers: [server],
            disabledNames: ["db"],
            trust: approved(server)
        )
        #expect(result.active.isEmpty)
        #expect(result.pendingApproval.isEmpty)
        #expect(result.skipped.map(\.reason) == [.disabled])
    }

    @Test func approvedRepoServerAttaches() {
        let server = repo("linear")
        let result = RepoMCPResolver.merge(
            appServers: [],
            repoServers: [server],
            disabledNames: [],
            trust: approved(server)
        )
        #expect(result.active == [server])
        #expect(result.skipped.isEmpty)
        #expect(result.pendingApproval.isEmpty)
    }

    @Test func declinedRepoServerIsSkippedQuietly() {
        let server = repo("linear")
        let result = RepoMCPResolver.merge(
            appServers: [],
            repoServers: [server],
            disabledNames: [],
            trust: [RepoMCPTrust.hash(for: server): .declined]
        )
        #expect(result.active.isEmpty)
        #expect(result.pendingApproval.isEmpty)
        #expect(result.skipped.map(\.reason) == [.declined])
    }

    @Test func unknownTrustIsPendingAndInactive() {
        let server = repo("linear")
        let result = RepoMCPResolver.merge(
            appServers: [],
            repoServers: [server],
            disabledNames: [],
            trust: [:]
        )
        #expect(result.active.isEmpty)
        #expect(result.pendingApproval == [server])
        #expect(result.skipped.map(\.reason) == [.notApproved])
    }

    @Test func appServersComeFirstInStableOrder() {
        let first = repo("r1")
        let second = repo("r2")
        let result = RepoMCPResolver.merge(
            appServers: [app("a1"), app("a2")],
            repoServers: [second, first],
            disabledNames: [],
            trust: [
                RepoMCPTrust.hash(for: first): .approved,
                RepoMCPTrust.hash(for: second): .approved,
            ]
        )
        #expect(result.active.map(\.name) == ["a1", "a2", "r2", "r1"])
        #expect(result.skipped.isEmpty)
        #expect(result.pendingApproval.isEmpty)
    }

    @Test func trimmedAppNamesShadowRepoServers() {
        let result = RepoMCPResolver.merge(
            appServers: [app("  linear ")],
            repoServers: [repo("linear")],
            disabledNames: [],
            trust: [:]
        )
        #expect(result.skipped.map(\.reason) == [.shadowedByApp])
        #expect(result.pendingApproval.isEmpty)
    }

    // RepoConfig decoding deduplicates by name (first wins), so the resolver
    // assumes an already-deduplicated list and processes whatever it is
    // handed, independently, without its own dedup pass.
    @Test func duplicateRepoNamesAreProcessedIndependently() {
        let first = repo("dup", command: "one")
        let second = repo("dup", command: "two")
        let result = RepoMCPResolver.merge(
            appServers: [],
            repoServers: [first, second],
            disabledNames: [],
            trust: [:]
        )
        #expect(result.pendingApproval == [first, second])
        #expect(result.skipped.map(\.reason) == [.notApproved, .notApproved])
    }

    @Test func neverMutatesItsInputs() {
        var appServers = [app("linear")]
        var repoServers = [repo("linear")]
        let originalApp = appServers
        let originalRepo = repoServers
        _ = RepoMCPResolver.merge(
            appServers: appServers,
            repoServers: repoServers,
            disabledNames: [],
            trust: [:]
        )
        #expect(appServers == originalApp)
        #expect(repoServers == originalRepo)
    }
}