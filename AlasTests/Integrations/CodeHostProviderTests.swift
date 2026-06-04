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

    @Test func liveGitLabProviderExposesDirectActionCapabilities() {
        let provider = CodeHostProviderRegistry.live().provider(for: .gitlab)

        #expect(provider?.capabilities.canCreateReviewRequest == true)
        #expect(provider?.capabilities.canRerunFailedChecks == true)
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

    @Test func defaultEvidenceMethodsUseSummaryData() async throws {
        let remote = CodeHostRemote(
            kind: .github,
            host: "github.com",
            owner: "mrmans0n",
            repository: "alas",
            remoteName: "origin",
            webURL: URL(string: "https://github.com/mrmans0n/alas")!
        )
        let request = ReviewRequest(
            remote: remote,
            number: 42,
            title: "Review evidence",
            url: URL(string: "https://github.com/mrmans0n/alas/pull/42")!,
            state: .open,
            isDraft: false,
            headRefName: "feature/evidence",
            baseRefName: "main",
            reviewDecision: .changesRequested,
            mergeState: .blocked,
            checks: [
                ReviewCheck(
                    id: "check-passed",
                    name: "build",
                    workflow: "CI",
                    bucket: .pass,
                    detailURL: URL(string: "https://github.com/build")!,
                    completedAt: nil
                ),
                ReviewCheck(
                    id: "check-1",
                    name: "test",
                    workflow: "CI",
                    bucket: .fail,
                    detailURL: URL(string: "https://github.com/run")!,
                    completedAt: nil
                ),
                ReviewCheck(
                    id: "check-pending",
                    name: "lint",
                    workflow: "CI",
                    bucket: .pending,
                    detailURL: URL(string: "https://github.com/lint")!,
                    completedAt: nil
                ),
            ],
            threads: [
                ReviewThreadSummary(
                    id: "thread-1",
                    author: "reviewer",
                    body: "Please fix this.",
                    url: URL(string: "https://github.com/thread")!,
                    isResolved: false,
                    isActionable: true
                ),
                ReviewThreadSummary(
                    id: "thread-resolved",
                    author: "reviewer",
                    body: "Already handled.",
                    url: URL(string: "https://github.com/resolved")!,
                    isResolved: true,
                    isActionable: true
                ),
                ReviewThreadSummary(
                    id: "thread-non-actionable",
                    author: "reviewer",
                    body: "Looks good.",
                    url: URL(string: "https://github.com/non-actionable")!,
                    isResolved: false,
                    isActionable: false
                ),
            ]
        )
        let provider = FakeCodeHostProvider(kind: .github)

        let ci = try await provider.failedCheckEvidence(remote: remote, request: request, cwd: URL(fileURLWithPath: "/tmp/alas"))
        let feedback = try await provider.feedbackEvidence(remote: remote, request: request, cwd: URL(fileURLWithPath: "/tmp/alas"))

        #expect(ci.map(\.id) == ["check-1"])
        #expect(ci.first?.status == .failed)
        #expect(feedback.map(\.id) == ["thread-1"])
        #expect(feedback.first?.status == .actionable)
    }

    @Test func defaultFeedbackEvidenceSynthesizesChangesRequestedWhenThreadsAreMissing() async throws {
        let remote = CodeHostRemote(
            kind: .github,
            host: "github.com",
            owner: "mrmans0n",
            repository: "alas",
            remoteName: "origin",
            webURL: URL(string: "https://github.com/mrmans0n/alas")!
        )
        let request = ReviewRequest(
            remote: remote,
            number: 42,
            title: "Review evidence",
            url: URL(string: "https://github.com/mrmans0n/alas/pull/42")!,
            state: .open,
            isDraft: false,
            headRefName: "feature/evidence",
            baseRefName: "main",
            reviewDecision: .changesRequested,
            mergeState: .blocked,
            checks: [],
            threads: []
        )
        let provider = FakeCodeHostProvider(kind: .github)

        let feedback = try await provider.feedbackEvidence(remote: remote, request: request, cwd: URL(fileURLWithPath: "/tmp/alas"))
        let detail = try await provider.feedbackEvidenceDetail(
            remote: remote,
            request: request,
            item: #require(feedback.first),
            cwd: URL(fileURLWithPath: "/tmp/alas")
        )

        #expect(feedback.map(\.id) == [ReviewEvidenceFallbacks.changesRequestedID])
        #expect(feedback.first?.status == .actionable)
        #expect(detail.body.contains("review decision is changes requested"))
        #expect(detail.item.providerURL == request.url)
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
