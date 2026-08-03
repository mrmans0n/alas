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

    @Test func fullURLContinuesPastAProjectWhoseRemotesAreUnavailable() async throws {
        let resolver = MissionIssueResolver(environment: .init(
            projects: { [Self.cloneA, Self.cloneB] },
            selectedProjectId: { Self.cloneB.id },
            remotes: { project in
                if project.id == Self.cloneA.id {
                    throw CodeHostProviderError.commandFailed(
                        command: "git remote -v",
                        stderr: "Repository unavailable"
                    )
                }
                return [GitRemote(name: "origin", url: "git@github.com:mrmans0n/alas.git")]
            },
            providers: Self.registry
        ))

        let resolved = try await resolver.resolve("https://github.com/mrmans0n/alas/issues/1842")

        #expect(resolved.candidateProjectIds == [Self.cloneB.id])
        #expect(resolved.selectedProjectId == Self.cloneB.id)
    }

    @Test func fullURLContinuesPastAPreferredCloneWhoseProviderIsUnavailable() async throws {
        let provider = FakeIssueProvider(unavailablePaths: [Self.cloneA.path])
        let resolver = MissionIssueResolver(environment: .init(
            projects: { [Self.cloneA, Self.cloneB] },
            selectedProjectId: { Self.cloneA.id },
            remotes: { _ in [GitRemote(name: "origin", url: "git@github.com:mrmans0n/alas.git")] },
            providers: .init([provider])
        ))

        let resolved = try await resolver.resolve("https://github.com/mrmans0n/alas/issues/1842")

        #expect(resolved.candidateProjectIds == [Self.cloneA.id, Self.cloneB.id])
        #expect(resolved.selectedProjectId == Self.cloneB.id)
    }

    @Test func redirectedFullURLResolvesAgainstTheConfiguredCanonicalRemote() async throws {
        let provider = FakeIssueProvider(
            canonicalRepositorySlug: "openai/renamed-alas",
            acceptedRepositorySlugs: ["mrmans0n/alas"]
        )
        let resolver = MissionIssueResolver(environment: .init(
            projects: { [Self.cloneA] },
            selectedProjectId: { Self.cloneA.id },
            remotes: { _ in [GitRemote(name: "origin", url: "git@github.com:openai/renamed-alas.git")] },
            providers: .init([provider])
        ))

        let resolved = try await resolver.resolve("https://github.com/mrmans0n/alas/issues/1842")

        #expect(resolved.remote.repositorySlug == "openai/renamed-alas")
        #expect(resolved.snapshot.identity.repositorySlug == "openai/renamed-alas")
        #expect(resolved.selectedProjectId == Self.cloneA.id)
    }

    @Test func redirectedFullURLRejectsAnUnconfiguredCanonicalRepository() async {
        let provider = FakeIssueProvider(
            canonicalRepositorySlug: "unrelated/project",
            acceptedRepositorySlugs: ["mrmans0n/alas"]
        )
        let resolver = MissionIssueResolver(environment: .init(
            projects: { [Self.cloneA] },
            selectedProjectId: { Self.cloneA.id },
            remotes: { _ in [GitRemote(name: "origin", url: "git@github.com:openai/renamed-alas.git")] },
            providers: .init([provider])
        ))

        await #expect(throws: CodeHostProviderError.malformedOutput(
            "The redirected issue repository does not match a configured project."
        )) {
            try await resolver.resolve("https://github.com/mrmans0n/alas/issues/1842")
        }
    }

    @Test func exactStaleRemoteRejectsAnUnconfiguredRedirectTarget() async {
        let provider = FakeIssueProvider(
            canonicalRepositorySlug: "openai/renamed-alas",
            acceptedRepositorySlugs: ["mrmans0n/alas"]
        )
        let resolver = MissionIssueResolver(environment: .init(
            projects: { [Self.cloneA] },
            selectedProjectId: { Self.cloneA.id },
            remotes: { _ in [GitRemote(name: "origin", url: "git@github.com:mrmans0n/alas.git")] },
            providers: .init([provider])
        ))

        await #expect(throws: CodeHostProviderError.malformedOutput(
            "The redirected issue repository does not match a configured project."
        )) {
            try await resolver.resolve("https://github.com/mrmans0n/alas/issues/1842")
        }
    }

    @Test func redirectedFullURLSelectsTheCloneThatCompletedTheProbe() async throws {
        let provider = FakeIssueProvider(
            unavailablePaths: [Self.cloneA.path],
            canonicalRepositorySlug: "openai/renamed-alas",
            acceptedRepositorySlugs: ["mrmans0n/alas"]
        )
        let resolver = MissionIssueResolver(environment: .init(
            projects: { [Self.cloneA, Self.cloneB] },
            selectedProjectId: { Self.cloneA.id },
            remotes: { _ in [GitRemote(name: "origin", url: "git@github.com:openai/renamed-alas.git")] },
            providers: .init([provider])
        ))

        let resolved = try await resolver.resolve("https://github.com/mrmans0n/alas/issues/1842")

        #expect(resolved.candidateProjectIds == [Self.cloneA.id, Self.cloneB.id])
        #expect(resolved.selectedProjectId == Self.cloneB.id)
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

    @Test func shortReferenceProbesAProviderForACustomHost() async throws {
        let resolver = MissionIssueResolver(environment: .init(
            projects: { [Self.cloneA] },
            selectedProjectId: { Self.cloneA.id },
            remotes: { _ in [GitRemote(name: "origin", url: "git@code.acme.internal:mrmans0n/alas.git")] },
            providers: Self.registry
        ))

        let resolved = try await resolver.resolve("#1842")

        #expect(resolved.remote.kind == .github)
        #expect(resolved.remote.host == "code.acme.internal")
        #expect(resolved.snapshot.identity.provider == .github)
    }

    @Test func shortReferenceContinuesFromForkToUpstreamRemote() async throws {
        let provider = FakeIssueProvider(missingRepositorySlugs: ["nacho/alas"])
        let resolver = MissionIssueResolver(environment: .init(
            projects: { [Self.cloneA] },
            selectedProjectId: { Self.cloneA.id },
            remotes: { _ in [
                GitRemote(name: "origin", url: "git@github.com:nacho/alas.git"),
                GitRemote(name: "upstream", url: "git@github.com:mrmans0n/alas.git"),
            ] },
            providers: .init([provider])
        ))

        let resolved = try await resolver.resolve("#1842")

        #expect(resolved.remote.remoteName == "upstream")
        #expect(resolved.snapshot.identity.repositorySlug == "mrmans0n/alas")
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
        var unavailablePaths: Set<String> = []
        var missingRepositorySlugs: Set<String> = []
        var canonicalRepositorySlug: String?
        var acceptedRepositorySlugs: Set<String> = []

        func isAvailable(cwd: URL) async -> Bool { available && !unavailablePaths.contains(cwd.path) }
        func isAuthenticated(remote: CodeHostRemote, cwd: URL) async -> Bool { authenticated }
        func issue(remote: CodeHostRemote, number: Int, cwd: URL) async throws -> MissionIssueSnapshot {
            if !acceptedRepositorySlugs.isEmpty,
               !acceptedRepositorySlugs.contains(remote.repositorySlug) {
                throw CodeHostIssueProviderError.notFound(
                    provider: remote.kind,
                    repositorySlug: remote.repositorySlug,
                    number: number
                )
            }
            if missingRepositorySlugs.contains(remote.repositorySlug) {
                throw CodeHostIssueProviderError.notFound(
                    provider: remote.kind,
                    repositorySlug: remote.repositorySlug,
                    number: number
                )
            }
            let canonicalRepositorySlug = canonicalRepositorySlug ?? remote.repositorySlug
            return MissionIssueSnapshot(
                identity: .init(provider: remote.kind, host: remote.host, repositorySlug: canonicalRepositorySlug, number: number),
                canonicalURL: URL(string: "https://\(remote.host)/\(canonicalRepositorySlug)/issues/\(number)")!,
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
