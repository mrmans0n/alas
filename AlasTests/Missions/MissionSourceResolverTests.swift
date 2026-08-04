import Foundation
import Testing
@testable import Alas

@MainActor
struct MissionSourceResolverTests {
    @Test func arbitraryURLBecomesManualWithoutCallingCodeHostProviders() async throws {
        let recorder = SourceProviderRecorder()
        let resolver = MissionSourceResolver(environment: Self.environment(recorder: recorder))

        let result = try await resolver.resolve(
            "HTTPS://Jira.Example.com:443/browse/ALAS-123?view=full#activity"
        )

        #expect(result.source.identity == .init(
            providerID: .manual,
            stableID: "https://jira.example.com/browse/ALAS-123?view=full"
        ))
        #expect(result.source.canonicalURL.absoluteString == "https://jira.example.com/browse/ALAS-123?view=full")
        #expect(result.source.contentOrigin == .manual)
        #expect(result.repositoryLocator == nil)
        #expect(result.candidateProjectIDs == ["project-a", "project-b"])
        #expect(result.selectedProjectID == "project-b")
        #expect(await recorder.resolveCount == 0)
    }

    @Test func recognizedProviderFailureCarriesManualFallback() async {
        let resolver = MissionSourceResolver(environment: Self.environment(
            providerError: CodeHostProviderError.unauthenticated("github.com")
        ))

        do {
            _ = try await resolver.resolve("https://github.com/acme/alas/issues/42")
            Issue.record("Expected adapter fallback")
        } catch let error as MissionSourceResolutionFailure {
            #expect(error.errorDescription == "Authentication is required for github.com.")
            #expect(error.fallback.source.contentOrigin == .manual)
            #expect(error.fallback.source.identity.providerID == .github)
            #expect(error.fallback.repositoryLocator?.repositorySlug == "acme/alas")
            #expect(error.fallback.source.isRefreshable)
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test func manualURLRemovesFragmentsAndDefaultPortsWhileKeepingPathAndQuery() async throws {
        let resolver = MissionSourceResolver(environment: Self.environment())

        let result = try await resolver.resolve("https://tracker.example.com:443/a/b?state=open#details")

        #expect(result.source.canonicalURL.absoluteString == "https://tracker.example.com/a/b?state=open")
    }

    @Test func rejectsFileAndRelativeReferences() async {
        let resolver = MissionSourceResolver(environment: Self.environment())

        await #expect(throws: CodeHostProviderError.malformedOutput("Enter an issue number or an absolute HTTP(S) URL.")) {
            try await resolver.resolve("file:///tmp/ALAS-123")
        }
        await #expect(throws: CodeHostProviderError.malformedOutput("Enter an issue number or an absolute HTTP(S) URL.")) {
            try await resolver.resolve("browse/ALAS-123")
        }
    }

    @Test func gitLabSubgroupsResolveThroughCodeHostProvider() async throws {
        let resolver = MissionSourceResolver(environment: Self.environment(
            providers: .init([CodeHostMissionSourceProvider(providers: .init([FakeIssueProvider(kind: .gitlab)])), ManualMissionSourceProvider()]),
            remotes: { _ in [GitRemote(name: "origin", url: "git@gitlab.example.com:platform/mobile/alas.git")] }
        ))

        let result = try await resolver.resolve("https://gitlab.example.com/platform/mobile/alas/-/issues/77")

        #expect(result.source.identity.providerID == .gitlab)
        #expect(result.repositoryLocator?.repositorySlug == "platform/mobile/alas")
    }

    @Test func shortReferenceRequiresSelectedCodeHostProject() async {
        let resolver = MissionSourceResolver(environment: .init(
            projects: { [Self.projectA] },
            selectedProjectID: { nil },
            remotes: { _ in [GitRemote(name: "origin", url: "git@github.com:acme/alas.git")] },
            providers: .init([CodeHostMissionSourceProvider(providers: .init([FakeIssueProvider()])), ManualMissionSourceProvider()])
        ))

        await #expect(throws: CodeHostProviderError.malformedOutput("Select a project before resolving an issue.")) {
            try await resolver.resolve("#42")
        }
    }

    private static func environment(
        recorder: SourceProviderRecorder? = nil,
        providerError: Error? = nil,
        providers: MissionSourceProviderRegistry? = nil,
        remotes: @escaping @Sendable (ProjectConfig) async throws -> [GitRemote] = { _ in
            [GitRemote(name: "origin", url: "git@github.com:acme/alas.git")]
        }
    ) -> MissionSourceResolver.Environment {
        let provider = FakeIssueProvider(error: providerError, recorder: recorder)
        return .init(
            projects: { [projectA, projectB] },
            selectedProjectID: { projectB.id },
            remotes: remotes,
            providers: providers ?? .init([
                CodeHostMissionSourceProvider(providers: .init([provider])),
                ManualMissionSourceProvider(),
            ])
        )
    }

    private static let projectA = ProjectConfig(id: "project-a", name: "A", path: "/tmp/a", color: "blue", addedAt: .distantPast)
    private static let projectB = ProjectConfig(id: "project-b", name: "B", path: "/tmp/b", color: "green", addedAt: .distantPast)

    private actor SourceProviderRecorder {
        private(set) var resolveCount = 0

        func recordResolve() {
            resolveCount += 1
        }
    }

    private struct FakeIssueProvider: CodeHostIssueProviding {
        let kind: CodeHostKind
        let executable = "host"
        let error: Error?
        let recorder: SourceProviderRecorder?

        init(kind: CodeHostKind = .github, error: Error? = nil, recorder: SourceProviderRecorder? = nil) {
            self.kind = kind
            self.error = error
            self.recorder = recorder
        }

        func isAvailable(cwd: URL) async -> Bool { true }
        func isAuthenticated(remote: CodeHostRemote, cwd: URL) async -> Bool { true }

        func issue(remote: CodeHostRemote, number: Int, cwd: URL) async throws -> MissionIssueSnapshot {
            await recorder?.recordResolve()
            if let error { throw error }
            return MissionIssueSnapshot(
                identity: .init(provider: remote.kind, host: remote.host, repositorySlug: remote.repositorySlug, number: number),
                canonicalURL: URL(string: "https://\(remote.host)/\(remote.repositorySlug)/issues/\(number)")!,
                title: "Issue \(number)", body: "", state: .open, labels: [], assignees: [],
                providerUpdatedAt: nil, capturedAt: .distantPast, refreshError: nil
            )
        }
    }
}
