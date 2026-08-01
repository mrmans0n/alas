import Foundation
import Testing
@testable import Alas

@MainActor
struct MissionIssueResolverTests {
    @Test func parsesShortAndCanonicalURLsWithoutQueryOrFragment() throws {
        #expect(try MissionIssueInput.parse("#123") == .short(number: 123))
        #expect(try MissionIssueInput.parse("https://gitlab.example.com/platform/mobile/alas/-/issues/77?foo=bar#note_1") == .url(
            kind: .gitlab, host: "gitlab.example.com", repositorySlug: "platform/mobile/alas", number: 77
        ))
    }

    @Test func fullURLReturnsEveryMatchingProjectAndPrefersSelectedMatch() async throws {
        let resolver = MissionIssueResolver(environment: .init(
            projects: { [Self.cloneA, Self.cloneB] },
            selectedProjectId: { Self.cloneB.id },
            remotes: { _ in [GitRemote(name: "origin", url: "git@github.com:mrmans0n/alas.git")] },
            providers: Self.registry
        ))

        let resolved = try await resolver.resolve("https://github.com/mrmans0n/alas/issues/1842")
        #expect(resolved.candidateProjectIds == [Self.cloneA.id, Self.cloneB.id])
        #expect(resolved.selectedProjectId == Self.cloneB.id)
        #expect(resolved.snapshot.identity.number == 1842)
    }

    @Test func resolverReportsMissingCLIAndAuthenticationBeforeFetching() async {
        let missingCLI = MissionIssueResolver(environment: Self.environment(provider: FakeIssueProvider(available: false)))
        await #expect(throws: CodeHostProviderError.cliMissing("gh")) {
            try await missingCLI.resolve("#1842")
        }

        let unauthenticated = MissionIssueResolver(environment: Self.environment(provider: FakeIssueProvider(authenticated: false)))
        await #expect(throws: CodeHostProviderError.unauthenticated("github.com")) {
            try await unauthenticated.resolve("#1842")
        }
    }

    private static func environment(provider: FakeIssueProvider) -> MissionIssueResolver.Environment {
        .init(
            projects: { [cloneA] },
            selectedProjectId: { cloneA.id },
            remotes: { _ in [GitRemote(name: "origin", url: "git@github.com:mrmans0n/alas.git")] },
            providers: .init([provider])
        )
    }

    private static let cloneA = ProjectConfig(id: "clone-a", name: "Alas A", path: "/tmp/alas-a", color: "blue", addedAt: .distantPast)
    private static let cloneB = ProjectConfig(id: "clone-b", name: "Alas B", path: "/tmp/alas-b", color: "blue", addedAt: .distantPast)
    private static let registry = CodeHostIssueProviderRegistry([FakeIssueProvider()])

    private struct FakeIssueProvider: CodeHostIssueProviding {
        let kind: CodeHostKind = .github
        let executable = "gh"
        var available = true
        var authenticated = true

        func isAvailable(cwd: URL) async -> Bool { available }
        func isAuthenticated(remote: CodeHostRemote, cwd: URL) async -> Bool { authenticated }
        func issue(remote: CodeHostRemote, number: Int, cwd: URL) async throws -> MissionIssueSnapshot {
            MissionIssueSnapshot(
                identity: .init(provider: remote.kind, host: remote.host, repositorySlug: remote.repositorySlug, number: number),
                canonicalURL: URL(string: "https://\(remote.host)/\(remote.repositorySlug)/issues/\(number)")!,
                title: "Fix parser crash",
                body: "Issue body.",
                state: .open,
                labels: [],
                assignees: [],
                providerUpdatedAt: nil,
                capturedAt: .distantPast,
                refreshError: nil
            )
        }
    }
}
