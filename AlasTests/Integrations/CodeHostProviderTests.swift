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

    @Test func issueErrorClassificationRecognizesGitLabForbiddenPhrase() {
        let remote = Self.remote(kind: .gitlab)
        let result = ProcessResult(exitCode: 1, stdout: "", stderr: "glab: 403 Forbidden")

        #expect(CodeHostIssueProviderError.classification(
            provider: .gitlab,
            remote: remote,
            number: 77,
            result: result
        ) == .permissionDenied(host: remote.host))
    }

    @Test func issueErrorClassificationDoesNotTreatIssueNumbersAsStatuses() {
        let remote = Self.remote(kind: .github)
        let result = ProcessResult(
            exitCode: 1,
            stdout: "",
            stderr: "failed while loading /repos/acme/alas/issues/404; see issue #403 for context"
        )

        #expect(CodeHostIssueProviderError.classification(
            provider: .github,
            remote: remote,
            number: 77,
            result: result
        ) == nil)
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

    @Test func commandInvocationRoutesRemoteWorkspaceThroughSSH() throws {
        let cwd = URL(fileURLWithPath: "/srv/alas-code-host-invocation-test")
        RemoteHostRegistry.shared.register(root: cwd.path, host: "code-host-devbox")
        defer { RemoteHostRegistry.shared.unregister(root: cwd.path) }

        let invocation = CodeHostCommandInvocation.build(
            executable: "gh",
            args: ["auth", "status", "--hostname", "github.com"],
            cwd: cwd
        )

        #expect(invocation.executable == SSHCommand.executable)
        #expect(invocation.cwd == nil)
        #expect(invocation.env == nil)
        #expect(invocation.args.contains("code-host-devbox"))
        let script = try #require(invocation.args.last)
        let command = [
            "env", "GIT_OPTIONAL_LOCKS=0", "LC_ALL=C",
            "gh", "auth", "status", "--hostname", "github.com",
        ]
            .map(SSHCommand.shellQuote)
            .joined(separator: " ")
        #expect(script == SSHCommand.remoteScript(cwd: cwd.path, command: command))
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
                makeThread(id: "thread-1", author: "reviewer", body: "Please fix this.",
                           url: URL(string: "https://github.com/thread")!,
                           isResolved: false, isOutdated: false),
                makeThread(id: "thread-resolved", author: "reviewer", body: "Already handled.",
                           url: URL(string: "https://github.com/resolved")!,
                           isResolved: true, isOutdated: false),
                makeThread(id: "thread-non-actionable", author: "reviewer", body: "Looks good.",
                           url: URL(string: "https://github.com/non-actionable")!,
                           isResolved: false, isOutdated: true),
            ]
        )
        let provider = FakeCodeHostProvider(kind: .github)

        let ci = try await provider.failedCheckEvidence(remote: remote, request: request, cwd: URL(fileURLWithPath: "/tmp/alas"))
        let feedback = try await provider.feedbackEvidence(remote: remote, request: request, cwd: URL(fileURLWithPath: "/tmp/alas"))

        #expect(ci.map(\.id) == ["check-passed", "check-1", "check-pending"])
        #expect(ci.map(\.status) == [.passed, .failed, .pending])
        #expect(feedback.map(\.id) == ["thread-1"])
        #expect(feedback.first?.status == .actionable)
    }

    @Test func reviewThreadSummaryPreservesLocation() throws {
        let location = ReviewThreadLocation(
            path: "Sources/App.swift",
            originalPath: nil,
            line: 42,
            side: .new,
            providerPosition: "github-position-1"
        )
        let thread = ReviewThreadSummary(
            id: "thread-located",
            author: "reviewer",
            body: "Inline feedback.",
            url: URL(string: "https://github.com/thread-located")!,
            isResolved: false,
            isActionable: true,
            location: location
        )

        #expect(thread.location?.path == "Sources/App.swift")
        #expect(thread.location?.line == 42)
        #expect(thread.location?.side == .new)
        #expect(thread.location?.providerPosition == "github-position-1")
    }

    @Test func githubCapabilitiesAllowMerge() {
        #expect(CodeHostProviderCapabilities.githubCLI.canMerge)
    }

    @Test func gitlabCapabilitiesAllowMerge() {
        #expect(CodeHostProviderCapabilities.gitlabCLI.canMerge)
    }

    @Test func readOnlyCapabilitiesDisallowMerge() {
        #expect(!CodeHostProviderCapabilities.readOnly.canMerge)
    }

    private static func remote(kind: CodeHostKind) -> CodeHostRemote {
        CodeHostRemote(
            kind: kind,
            host: "\(kind.displayName.lowercased()).example.com",
            owner: "acme",
            repository: "alas",
            remoteName: "origin",
            webURL: URL(string: "https://\(kind.displayName.lowercased()).example.com/acme/alas")!
        )
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

        func isAvailable(cwd: URL) async -> Bool {
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

private func makeThread(
    id: String,
    author: String?,
    body: String,
    url: URL?,
    isResolved: Bool,
    isOutdated: Bool
) -> ReviewThread {
    ReviewThread(
        id: id,
        path: nil,
        line: nil,
        startLine: nil,
        originalLine: nil,
        diffHunk: nil,
        isResolved: isResolved,
        isOutdated: isOutdated,
        isFileLevel: true,
        comments: [
            ReviewComment(
                id: id,
                author: author,
                body: body,
                url: url,
                createdAt: nil,
                viewerCanUpdate: false,
                viewerCanDelete: false,
                isPending: false
            ),
        ],
        viewerCanResolve: false,
        viewerCanReply: false,
        url: url
    )
}
