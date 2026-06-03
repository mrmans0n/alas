import Foundation
import Testing
@testable import Alas

@Suite(.serialized)
struct CodeHostProviderTests {
    @Test func registryReturnsProviderByKind() {
        let githubProvider = FakeCodeHostProvider(kind: .github)
        let registry = CodeHostProviderRegistry(providers: [.github: githubProvider])

        #expect(registry.provider(for: .github)?.kind == .github)
    }

    @Test func registryReturnsNilForMissingKind() {
        let registry = CodeHostProviderRegistry(providers: [.github: FakeCodeHostProvider(kind: .github)])

        #expect(registry.provider(for: .gitlab) == nil)
    }

    @Test func liveRegistryIncludesGitHubAndGitLabProviders() {
        let registry = CodeHostProviderRegistry.live()

        #expect(registry.provider(for: .github)?.kind == .github)
        #expect(registry.provider(for: .gitlab)?.kind == .gitlab)
    }

    @Test func liveGitHubProviderExposesDirectActionCapabilities() {
        let provider = CodeHostProviderRegistry.live().provider(for: .github)

        #expect(provider?.capabilities.canCreateReviewRequest == true)
        #expect(provider?.capabilities.canRerunFailedChecks == true)
        #expect(provider?.capabilities.canOpenReviewRequest == true)
    }

    @Test func liveGitLabProviderStartsReadOnlyUntilActionsAreImplemented() {
        let provider = CodeHostProviderRegistry.live().provider(for: .gitlab)

        #expect(provider?.capabilities.canCreateReviewRequest == false)
        #expect(provider?.capabilities.canRerunFailedChecks == false)
        #expect(provider?.capabilities.canOpenReviewRequest == true)
    }

    @Test func processRunnerUsesShellResolvedPath() async throws {
        let prior = ShellEnvResolver.shared.resolvedPath
        ShellEnvResolver.shared.resolvedPath = "/custom/provider/bin:/usr/bin:/bin"
        defer { ShellEnvResolver.shared.resolvedPath = prior }

        let result = try await ProcessCodeHostCommandRunner().run(
            "/usr/bin/env",
            args: ["printenv", "PATH"],
            cwd: nil
        )

        #expect(result.exitCode == 0)
        #expect(result.stdout.trimmingCharacters(in: .whitespacesAndNewlines) == "/custom/provider/bin:/usr/bin:/bin")
    }

    private struct FakeCodeHostProvider: CodeHostProvider {
        let kind: CodeHostKind
        let capabilities: CodeHostProviderCapabilities = .readOnly

        func isAvailable() async -> Bool {
            true
        }

        func isAuthenticated(remote: CodeHostRemote, cwd: URL) async -> Bool {
            true
        }

        func currentReviewRequest(
            remote: CodeHostRemote,
            branch: String,
            headOwner: String?,
            baseBranch: String,
            cwd: URL
        ) async throws -> ReviewRequest? {
            nil
        }

        func createReviewRequest(
            remote: CodeHostRemote,
            branch: String,
            headOwner: String?,
            baseBranch: String,
            title: String,
            body: String,
            isDraft: Bool,
            cwd: URL
        ) async throws -> URL {
            remote.webURL
        }

        func checks(remote: CodeHostRemote, request: ReviewRequest, cwd: URL) async throws -> [ReviewCheck] {
            []
        }

        func rerunFailedChecks(
            remote: CodeHostRemote,
            branch: String,
            headSHA: String,
            request: ReviewRequest?,
            cwd: URL
        ) async throws {}
    }
}
