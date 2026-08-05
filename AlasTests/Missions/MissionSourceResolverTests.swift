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
        #expect(result.source.providerLabel == "jira.example.com")
        #expect(result.source.contentOrigin == .manual)
        #expect(result.repositoryLocator == nil)
        #expect(result.candidateProjectIDs == ["project-a", "project-b"])
        #expect(result.selectedProjectID == "project-b")
        #expect(await recorder.resolveCount == 0)
    }

    @Test func arbitraryURLPrefillsMetadataAndInfersRepositoryProject() async throws {
        let fetcher = WebPageMetadataFetcher { url in
            let html = """
            <meta property="og:title" content="ALAS-123 Fix delayed refresh | Linear">
            <meta property="og:description" content="Update the sync logic.">
            <a href="https://github.com/acme/alas/pull/99">Implementation</a>
            """
            return .init(
                data: Data(html.utf8),
                url: url,
                mimeType: "text/html",
                textEncodingName: "utf-8"
            )
        }
        let resolver = MissionSourceResolver(environment: Self.environment(
            providers: .init([ManualMissionSourceProvider(metadataFetcher: fetcher)]),
            remotes: { project in
                let slug = project.id == Self.projectA.id ? "acme/alas" : "other/project"
                return [GitRemote(name: "origin", url: "git@github.com:\(slug).git")]
            }
        ))

        let result = try await resolver.resolve(
            "https://linear.app/acme/issue/ALAS-123/fix-delayed-refresh"
        )

        #expect(result.source.providerLabel == "Linear")
        #expect(result.source.displayReference == "ALAS-123")
        #expect(result.source.title == "ALAS-123 Fix delayed refresh")
        #expect(result.source.body == "Update the sync logic.")
        #expect(result.source.contentOrigin == .manual)
        #expect(result.source.isEditable)
        #expect(result.candidateProjectIDs == ["project-a", "project-b"])
        #expect(result.selectedProjectID == "project-a")
    }

    @Test func failedArbitraryURLFetchStillProducesBlankManualSource() async throws {
        let fetcher = WebPageMetadataFetcher { _ in
            throw URLError(.notConnectedToInternet)
        }
        let resolver = MissionSourceResolver(environment: Self.environment(
            providers: .init([ManualMissionSourceProvider(metadataFetcher: fetcher)])
        ))

        let result = try await resolver.resolve("https://example.com/tickets/ALAS-123")

        #expect(result.source.title.isEmpty)
        #expect(result.source.body.isEmpty)
        #expect(result.source.providerLabel == "example.com")
        #expect(result.selectedProjectID == "project-b")
    }

    @Test func loginPageMetadataDoesNotReplaceOriginalTicketURL() async throws {
        let fetcher = WebPageMetadataFetcher { _ in
            let html = """
            <html>
              <head>
                <title>Log in - Jira</title>
                <link rel="canonical" href="https://jira.example.com/login.jsp">
              </head>
            </html>
            """
            return .init(
                data: Data(html.utf8),
                url: URL(string: "https://jira.example.com/login.jsp")!,
                mimeType: "text/html",
                textEncodingName: "utf-8"
            )
        }
        let resolver = MissionSourceResolver(environment: Self.environment(
            providers: .init([ManualMissionSourceProvider(metadataFetcher: fetcher)])
        ))

        let result = try await resolver.resolve("https://jira.example.com/browse/ALAS-123")

        #expect(result.source.identity == .init(
            providerID: .manual,
            stableID: "https://jira.example.com/browse/ALAS-123"
        ))
        #expect(result.source.canonicalURL.absoluteString == "https://jira.example.com/browse/ALAS-123")
        #expect(result.source.title.isEmpty)
        #expect(result.source.body.isEmpty)
        #expect(result.source.providerLabel == "jira.example.com")
    }

    @Test func unconfiguredIssuesURLBecomesPlainManualSource() async throws {
        let recorder = SourceProviderRecorder()
        let resolver = MissionSourceResolver(environment: Self.environment(recorder: recorder))

        let result = try await resolver.resolve("https://linear.example.com/acme/app/issues/42")

        #expect(result.source.identity == .init(
            providerID: .manual,
            stableID: "https://linear.example.com/acme/app/issues/42"
        ))
        #expect(result.source.providerLabel == "linear.example.com")
        #expect(result.source.repositoryLocator == nil)
        #expect(result.source.contentOrigin == .manual)
        #expect(!result.source.isRefreshable)
        #expect(result.repositoryLocator == nil)
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

    @Test func urlFallbackUsesMatchingRepositoryProjects() async {
        let resolver = MissionSourceResolver(environment: Self.environment(
            providerError: CodeHostProviderError.unauthenticated("github.com"),
            remotes: { project in
                if project.id == Self.projectA.id {
                    [GitRemote(name: "origin", url: "git@github.com:acme/alas.git")]
                } else {
                    [GitRemote(name: "origin", url: "git@github.com:other/project.git")]
                }
            }
        ))

        do {
            _ = try await resolver.resolve("https://github.com/acme/alas/issues/42")
            Issue.record("Expected adapter fallback")
        } catch let error as MissionSourceResolutionFailure {
            #expect(error.fallback.candidateProjectIDs == ["project-a"])
            #expect(error.fallback.selectedProjectID == "project-a")
            #expect(error.fallback.repositoryLocator == .init(provider: .github, host: "github.com", repositorySlug: "acme/alas"))
            #expect(error.fallback.source.isRefreshable)
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test func unresolvedCodeHostURLCarriesManualFallback() async {
        let resolver = MissionSourceResolver(environment: Self.environment(
            remotes: { _ in [GitRemote(name: "origin", url: "git@github.com:other/project.git")] }
        ))

        do {
            _ = try await resolver.resolve("https://github.com/acme/alas/issues/42")
            Issue.record("Expected adapter fallback")
        } catch let error as MissionSourceResolutionFailure {
            #expect(error.fallback.source.identity == .init(providerID: .github, stableID: "github.com/acme/alas#42"))
            #expect(error.fallback.source.canonicalURL.absoluteString == "https://github.com/acme/alas/issues/42")
            #expect(error.fallback.repositoryLocator == .init(provider: .github, host: "github.com", repositorySlug: "acme/alas"))
            #expect(error.fallback.source.contentOrigin == .manual)
            #expect(error.fallback.source.isEditable)
            #expect(error.fallback.source.isRefreshable)
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test func manualURLRemovesFragmentsAndDefaultPortsWhileKeepingPathAndQuery() async throws {
        let resolver = MissionSourceResolver(environment: Self.environment())

        let result = try await resolver.resolve("https://user:token@tracker.example.com:443/a/b?state=open#details")

        #expect(result.source.canonicalURL.absoluteString == "https://tracker.example.com/a/b?state=open")
        #expect(result.source.identity.stableID == "https://tracker.example.com/a/b?state=open")
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
            providers: .init([CodeHostMissionSourceProvider(kind: .gitlab, providers: .init([FakeIssueProvider(kind: .gitlab)])), ManualMissionSourceProvider()]),
            remotes: { _ in [GitRemote(name: "origin", url: "git@gitlab.example.com:platform/mobile/alas.git")] }
        ))

        let result = try await resolver.resolve("https://gitlab.example.com/platform/mobile/alas/-/issues/77")

        #expect(result.source.identity.providerID == .gitlab)
        #expect(result.repositoryLocator?.repositorySlug == "platform/mobile/alas")
    }

    @Test func gitLabSourceRefreshRoutesThroughGitLabAdapter() async throws {
        let recorder = SourceProviderRecorder()
        let provider = FakeIssueProvider(kind: .gitlab, recorder: recorder)
        let registry = MissionSourceProviderRegistry([
            CodeHostMissionSourceProvider(kind: .gitlab, providers: .init([provider])),
            ManualMissionSourceProvider(),
        ])
        let resolver = MissionSourceResolver(environment: .init(
            projects: { [Self.projectA] },
            selectedProjectID: { Self.projectA.id },
            remotes: { _ in [GitRemote(name: "origin", url: "git@gitlab.example.com:platform/mobile/alas.git")] },
            providers: registry
        ))
        let source = try await resolver.resolve("https://gitlab.example.com/platform/mobile/alas/-/issues/77").source

        let refreshProvider = try #require(registry.provider(for: .gitlab))
        let refreshed = try await refreshProvider.refresh(
            source,
            project: Self.projectA,
            remotes: { _ in [GitRemote(name: "origin", url: "git@gitlab.example.com:platform/mobile/alas.git")] }
        )

        #expect(refreshed.identity.providerID == .gitlab)
        #expect(await recorder.resolveCount == 2)
    }

    @Test func shortReferenceMissingCLICarriesRemoteManualFallback() async {
        await Self.expectShortReferenceManualFallback(
            provider: FakeIssueProvider(isAvailable: false),
            errorDescription: "host is not installed or is not available on PATH."
        )
    }

    @Test func shortReferenceAuthenticationFailureCarriesRemoteManualFallback() async {
        await Self.expectShortReferenceManualFallback(
            provider: FakeIssueProvider(isAuthenticated: false),
            errorDescription: "Authentication is required for github.com."
        )
    }

    @Test func shortReferenceProviderFailureCarriesRemoteManualFallback() async {
        await Self.expectShortReferenceManualFallback(
            provider: FakeIssueProvider(error: CodeHostIssueProviderError.permissionDenied(host: "github.com")),
            errorDescription: "Permission to read issues on github.com was denied."
        )
    }

    @Test func gitLabShortReferenceFailureCarriesGitLabManualFallback() async {
        let resolver = MissionSourceResolver(environment: Self.environment(
            providers: .init([
                CodeHostMissionSourceProvider(
                    kind: .github,
                    providers: .init([FakeIssueProvider()])
                ),
                CodeHostMissionSourceProvider(
                    kind: .gitlab,
                    providers: .init([FakeIssueProvider(
                        kind: .gitlab,
                        error: CodeHostIssueProviderError.permissionDenied(host: "gitlab.example.com")
                    )])
                ),
                ManualMissionSourceProvider(),
            ]),
            remotes: { _ in [GitRemote(name: "origin", url: "git@gitlab.example.com:platform/mobile/alas.git")] }
        ))

        do {
            _ = try await resolver.resolve("#42")
            Issue.record("Expected adapter fallback")
        } catch let error as MissionSourceResolutionFailure {
            #expect(error.fallback.source.identity == .init(providerID: .gitlab, stableID: "gitlab.example.com/platform/mobile/alas#42"))
            #expect(error.fallback.source.canonicalURL.absoluteString == "https://gitlab.example.com/platform/mobile/alas/-/issues/42")
            #expect(error.fallback.repositoryLocator == .init(
                provider: .gitlab,
                host: "gitlab.example.com",
                repositorySlug: "platform/mobile/alas"
            ))
            #expect(error.fallback.source.contentOrigin == .manual)
            #expect(error.fallback.source.isEditable)
            #expect(error.fallback.source.isRefreshable)
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test func shortReferenceUsesSelectedProjectsPreferredRemoteKind() async throws {
        let issueProviders = CodeHostIssueProviderRegistry([
            FakeIssueProvider(kind: .github),
            FakeIssueProvider(kind: .gitlab),
        ])
        let resolver = MissionSourceResolver(environment: Self.environment(
            providers: .init([
                CodeHostMissionSourceProvider(
                    kind: .github,
                    providers: issueProviders
                ),
                CodeHostMissionSourceProvider(
                    kind: .gitlab,
                    providers: issueProviders
                ),
                ManualMissionSourceProvider(),
            ]),
            remotes: { _ in [
                GitRemote(name: "origin", url: "git@gitlab.example.com:platform/mobile/alas.git"),
                GitRemote(name: "upstream", url: "git@github.com:acme/alas.git"),
            ] }
        ))

        let result = try await resolver.resolve("#42")

        #expect(result.source.identity.providerID == .gitlab)
        #expect(result.source.identity.stableID == "gitlab.example.com/platform/mobile/alas#42")
        #expect(result.repositoryLocator == .init(
            provider: .gitlab,
            host: "gitlab.example.com",
            repositorySlug: "platform/mobile/alas"
        ))
    }

    @Test func shortReferenceTriesLaterAdaptersBeforeManualFallback() async throws {
        let issueProviders = CodeHostIssueProviderRegistry([
            FakeIssueProvider(kind: .github, isAuthenticated: false),
            FakeIssueProvider(kind: .gitlab),
        ])
        let resolver = MissionSourceResolver(environment: Self.environment(
            providers: .init([
                CodeHostMissionSourceProvider(
                    kind: .github,
                    providers: issueProviders
                ),
                CodeHostMissionSourceProvider(
                    kind: .gitlab,
                    providers: issueProviders
                ),
                ManualMissionSourceProvider(),
            ]),
            remotes: { _ in [
                GitRemote(name: "origin", url: "git@git.company.com:platform/mobile/alas.git"),
            ] }
        ))

        let result = try await resolver.resolve("#42")

        #expect(result.source.identity.providerID == .gitlab)
        #expect(result.source.identity.stableID == "git.company.com/platform/mobile/alas#42")
        #expect(result.repositoryLocator == .init(
            provider: .gitlab,
            host: "git.company.com",
            repositorySlug: "platform/mobile/alas"
        ))
    }

    @Test func shortReferenceDoesNotLetRecognizedUpstreamPreemptUnclassifiedOrigin() async throws {
        let issueProviders = CodeHostIssueProviderRegistry([
            FakeIssueProvider(kind: .github, isAuthenticated: false),
            FakeIssueProvider(kind: .gitlab),
        ])
        let resolver = MissionSourceResolver(environment: Self.environment(
            providers: .init([
                CodeHostMissionSourceProvider(
                    kind: .github,
                    providers: issueProviders
                ),
                CodeHostMissionSourceProvider(
                    kind: .gitlab,
                    providers: issueProviders
                ),
                ManualMissionSourceProvider(),
            ]),
            remotes: { _ in [
                GitRemote(name: "origin", url: "git@git.company.com:platform/mobile/alas.git"),
                GitRemote(name: "upstream", url: "git@github.com:acme/alas.git"),
            ] }
        ))

        let result = try await resolver.resolve("#42")

        #expect(result.source.identity.providerID == .gitlab)
        #expect(result.source.identity.stableID == "git.company.com/platform/mobile/alas#42")
        #expect(result.repositoryLocator == .init(
            provider: .gitlab,
            host: "git.company.com",
            repositorySlug: "platform/mobile/alas"
        ))
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

    private static func expectShortReferenceManualFallback(
        provider: FakeIssueProvider,
        errorDescription: String
    ) async {
        let resolver = MissionSourceResolver(environment: Self.environment(
            providers: .init([
                CodeHostMissionSourceProvider(providers: .init([provider])),
                ManualMissionSourceProvider(),
            ])
        ))

        do {
            _ = try await resolver.resolve("#42")
            Issue.record("Expected adapter fallback")
        } catch let error as MissionSourceResolutionFailure {
            #expect(error.errorDescription == errorDescription)
            #expect(error.fallback.source.identity == .init(providerID: .github, stableID: "github.com/acme/alas#42"))
            #expect(error.fallback.source.canonicalURL.absoluteString == "https://github.com/acme/alas/issues/42")
            #expect(error.fallback.repositoryLocator == .init(provider: .github, host: "github.com", repositorySlug: "acme/alas"))
            #expect(error.fallback.source.contentOrigin == .manual)
            #expect(error.fallback.source.isEditable)
            #expect(error.fallback.source.isRefreshable)
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    private actor SourceProviderRecorder {
        private(set) var resolveCount = 0

        func recordResolve() {
            resolveCount += 1
        }
    }

    private struct FakeIssueProvider: CodeHostIssueProviding {
        let kind: CodeHostKind
        let executable = "host"
        let isAvailable: Bool
        let isAuthenticated: Bool
        let error: Error?
        let recorder: SourceProviderRecorder?

        init(
            kind: CodeHostKind = .github,
            isAvailable: Bool = true,
            isAuthenticated: Bool = true,
            error: Error? = nil,
            recorder: SourceProviderRecorder? = nil
        ) {
            self.kind = kind
            self.isAvailable = isAvailable
            self.isAuthenticated = isAuthenticated
            self.error = error
            self.recorder = recorder
        }

        func isAvailable(cwd: URL) async -> Bool { isAvailable }
        func isAuthenticated(remote: CodeHostRemote, cwd: URL) async -> Bool { isAuthenticated }

        func issue(remote: CodeHostRemote, number: Int, cwd: URL) async throws -> MissionIssueSnapshot {
            await recorder?.recordResolve()
            if let error { throw error }
            return MissionIssueSnapshot(
                identity: .init(provider: remote.kind, host: remote.host, repositorySlug: remote.repositorySlug, number: number),
                canonicalURL: remote.webURL.appendingPathComponent(
                    remote.kind == .gitlab ? "-/issues/\(number)" : "issues/\(number)"
                ),
                title: "Issue \(number)", body: "", state: .open, labels: [], assignees: [],
                providerUpdatedAt: nil, capturedAt: .distantPast, refreshError: nil
            )
        }
    }
}
