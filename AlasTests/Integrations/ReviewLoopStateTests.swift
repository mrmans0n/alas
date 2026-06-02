import Foundation
import Testing
@testable import Alas

@MainActor
@Suite(.serialized)
struct ReviewLoopStateTests {
    @Test func refreshBuildsInstallProviderActionWhenProviderIsMissing() async throws {
        let local = Self.makeLocal()
        let state = ReviewLoopState(
            worktreePath: URL(fileURLWithPath: "/tmp/alas-review-loop"),
            baseBranch: "main",
            providerRegistry: CodeHostProviderRegistry(providers: [:])
        )

        await state.refresh(local: local, remotes: [Self.makeGitHubRemote()])

        #expect(state.snapshot?.remote?.repositorySlug == "mrmans0n/alas")
        #expect(state.snapshot?.providerAvailable == false)
        #expect(state.snapshot?.providerAuthenticated == false)
        #expect(state.snapshot?.providerCapabilities == .readOnly)
    }

    @Test func refreshBuildsInstallProviderActionWhenProviderIsUnavailable() async throws {
        let local = Self.makeLocal()
        let provider = FakeCodeHostProvider(kind: .github, available: false)
        let state = ReviewLoopState(
            worktreePath: URL(fileURLWithPath: "/tmp/alas-review-loop"),
            baseBranch: "main",
            providerRegistry: CodeHostProviderRegistry(providers: [.github: provider])
        )

        await state.refresh(local: local, remotes: [Self.makeGitHubRemote()])

        #expect(state.snapshot?.remote?.repositorySlug == "mrmans0n/alas")
        #expect(state.snapshot?.providerAvailable == false)
        #expect(state.snapshot?.providerAuthenticated == false)
        #expect(state.snapshot?.providerCapabilities == .readOnly)
    }

    @Test func unsupportedRemoteReturnsNoneAndPreservesLocalSnapshot() async throws {
        let local = Self.makeLocal(branchName: "feature/no-remote", headSHA: "def456")
        let provider = FakeCodeHostProvider(kind: .github)
        let state = ReviewLoopState(
            worktreePath: URL(fileURLWithPath: "/tmp/alas-review-loop"),
            baseBranch: "main",
            providerRegistry: CodeHostProviderRegistry(providers: [.github: provider])
        )

        await state.refresh(local: local, remotes: [GitRemote(name: "origin", url: "https://example.com/mrmans0n/alas.git")])

        #expect(state.snapshot?.local == local)
        #expect(state.snapshot?.remote == nil)
        #expect(state.snapshot?.providerAvailable == false)
        #expect(state.snapshot?.providerAuthenticated == false)
        #expect(state.snapshot?.providerCapabilities == .readOnly)
    }

    @Test func emptyRemotesReturnNoneAndPreserveLocalSnapshot() async throws {
        let local = Self.makeLocal(branchName: "feature/no-remote", headSHA: "def456")
        let provider = FakeCodeHostProvider(kind: .github)
        let state = ReviewLoopState(
            worktreePath: URL(fileURLWithPath: "/tmp/alas-review-loop"),
            baseBranch: "main",
            providerRegistry: CodeHostProviderRegistry(providers: [.github: provider])
        )

        await state.refresh(local: local, remotes: [])

        #expect(state.snapshot?.local == local)
        #expect(state.snapshot?.remote == nil)
        #expect(state.snapshot?.providerAvailable == false)
        #expect(state.snapshot?.providerAuthenticated == false)
        #expect(state.snapshot?.providerCapabilities == .readOnly)
    }

    @Test func refreshStoresProviderCapabilitiesOnSnapshot() async throws {
        let provider = FakeCodeHostProvider(kind: .github)
        let state = ReviewLoopState(
            worktreePath: URL(fileURLWithPath: "/tmp/alas-review-loop"),
            baseBranch: "main",
            providerRegistry: CodeHostProviderRegistry(providers: [.github: provider])
        )

        await state.refresh(local: Self.makeLocal(needsPush: false), remotes: [Self.makeGitHubRemote()])

        #expect(state.snapshot?.providerCapabilities == provider.capabilities)
    }

    @Test func providerRequestGetsChecksAttachedToSnapshotRequest() async throws {
        let remote = Self.makeRemote()
        let request = Self.makeReviewRequest(remote: remote, checks: [])
        let check = ReviewCheck(
            id: "ci-build",
            name: "Build",
            workflow: "CI",
            bucket: .pass,
            detailURL: nil,
            completedAt: nil
        )
        let provider = FakeCodeHostProvider(
            kind: .github,
            request: request,
            checks: [check]
        )
        let state = ReviewLoopState(
            worktreePath: URL(fileURLWithPath: "/tmp/alas-review-loop"),
            baseBranch: "main",
            providerRegistry: CodeHostProviderRegistry(providers: [.github: provider])
        )

        await state.refresh(local: Self.makeLocal(needsPush: false), remotes: [Self.makeGitHubRemote()])

        #expect(state.snapshot?.reviewRequest?.number == request.number)
        #expect(state.snapshot?.reviewRequest?.threads == request.threads)
        #expect(state.snapshot?.reviewRequest?.checks == [check])
    }

    @Test func providerErrorPreservesPreviousRequestFactsForSameBranchAndRemote() async throws {
        let remote = Self.makeRemote()
        let request = Self.makeReviewRequest(remote: remote, checks: [])
        let check = ReviewCheck(
            id: "ci-build",
            name: "Build",
            workflow: "CI",
            bucket: .pass,
            detailURL: nil,
            completedAt: nil
        )
        let provider = FakeCodeHostProvider(
            kind: .github,
            request: request,
            checks: [check]
        )
        let state = ReviewLoopState(
            worktreePath: URL(fileURLWithPath: "/tmp/alas-review-loop"),
            baseBranch: "main",
            providerRegistry: CodeHostProviderRegistry(providers: [.github: provider])
        )
        let local = Self.makeLocal(needsPush: false)

        await state.refresh(local: local, remotes: [Self.makeGitHubRemote()])
        provider.checksError = StubError(message: "checks failed")
        await state.refresh(local: local, remotes: [Self.makeGitHubRemote()])

        #expect(state.lastError?.contains("checks failed") == true)
        #expect(state.snapshot?.errorMessage?.contains("checks failed") == true)
        #expect(state.snapshot?.reviewRequest?.number == request.number)
        #expect(state.snapshot?.reviewRequest?.title == request.title)
        #expect(state.snapshot?.reviewRequest?.checks == [check])
    }

    @Test func providerErrorSetsBlockedActionAndErrorDetail() async throws {
        let provider = FakeCodeHostProvider(
            kind: .github,
            requestError: StubError(message: "review request failed")
        )
        let state = ReviewLoopState(
            worktreePath: URL(fileURLWithPath: "/tmp/alas-review-loop"),
            baseBranch: "main",
            providerRegistry: CodeHostProviderRegistry(providers: [.github: provider])
        )

        await state.refresh(local: Self.makeLocal(), remotes: [Self.makeGitHubRemote()])

        #expect(state.lastError?.contains("review request failed") == true)
        #expect(state.snapshot?.errorMessage?.contains("review request failed") == true)
    }

    @Test func createReviewRequestUsesProviderWithoutSessionApproval() async throws {
        let provider = FakeCodeHostProvider(kind: .github)
        let state = ReviewLoopState(
            worktreePath: URL(fileURLWithPath: "/tmp/alas-review-loop"),
            baseBranch: "main",
            providerRegistry: CodeHostProviderRegistry(providers: [.github: provider])
        )

        await state.refresh(local: Self.makeLocal(needsPush: false), remotes: [Self.makeGitHubRemote()])
        let didRun = await state.createReviewRequest()

        #expect(didRun)
        #expect(provider.createdReviewRequests.count == 1)
        #expect(provider.createdReviewRequests.first?.branch == "feature/review-loop")
        #expect(provider.createdReviewRequests.first?.baseBranch == "main")
        #expect(provider.createdReviewRequests.first?.title == "feature/review-loop")
    }

    @Test func createReviewRequestUsesCapturedSnapshotInsteadOfCurrentSnapshot() async throws {
        let provider = FakeCodeHostProvider(kind: .github)
        let state = ReviewLoopState(
            worktreePath: URL(fileURLWithPath: "/tmp/alas-review-loop"),
            baseBranch: "main",
            providerRegistry: CodeHostProviderRegistry(providers: [.github: provider])
        )

        await state.refresh(
            local: Self.makeLocal(branchName: "feature/captured", needsPush: false),
            remotes: [Self.makeGitHubRemote()]
        )
        let capturedSnapshot = try #require(state.snapshot)
        await state.refresh(
            local: Self.makeLocal(branchName: "feature/current", needsPush: false),
            remotes: [Self.makeGitHubRemote()]
        )

        let didRun = await state.createReviewRequest(snapshot: capturedSnapshot)

        #expect(didRun)
        #expect(provider.createdReviewRequests.first?.branch == "feature/captured")
    }

    @Test func createReviewRequestRecordsProviderError() async throws {
        let provider = FakeCodeHostProvider(
            kind: .github,
            createError: CodeHostProviderError.commandFailed(
                command: "gh pr create",
                stderr: "GraphQL: Head sha can't be blank"
            )
        )
        let state = ReviewLoopState(
            worktreePath: URL(fileURLWithPath: "/tmp/alas-review-loop"),
            baseBranch: "main",
            providerRegistry: CodeHostProviderRegistry(providers: [.github: provider])
        )

        await state.refresh(local: Self.makeLocal(needsPush: false), remotes: [Self.makeGitHubRemote()])
        let didRun = await state.createReviewRequest()

        #expect(!didRun)
        #expect(state.lastError == "gh pr create failed: GraphQL: Head sha can't be blank")
    }

    @Test func rerunFailedChecksUsesProviderWithoutSessionApproval() async throws {
        let provider = FakeCodeHostProvider(kind: .github)
        let state = ReviewLoopState(
            worktreePath: URL(fileURLWithPath: "/tmp/alas-review-loop"),
            baseBranch: "main",
            providerRegistry: CodeHostProviderRegistry(providers: [.github: provider])
        )

        await state.refresh(local: Self.makeLocal(needsPush: false), remotes: [Self.makeGitHubRemote()])
        let didRun = await state.rerunFailedChecks()

        #expect(didRun)
        #expect(provider.rerunFailedChecksBranches == ["feature/review-loop"])
    }

    @Test func rerunFailedChecksUsesCapturedSnapshotInsteadOfCurrentSnapshot() async throws {
        let provider = FakeCodeHostProvider(kind: .github)
        let state = ReviewLoopState(
            worktreePath: URL(fileURLWithPath: "/tmp/alas-review-loop"),
            baseBranch: "main",
            providerRegistry: CodeHostProviderRegistry(providers: [.github: provider])
        )

        await state.refresh(
            local: Self.makeLocal(branchName: "feature/captured", needsPush: false),
            remotes: [Self.makeGitHubRemote()]
        )
        let capturedSnapshot = try #require(state.snapshot)
        await state.refresh(
            local: Self.makeLocal(branchName: "feature/current", needsPush: false),
            remotes: [Self.makeGitHubRemote()]
        )

        let didRun = await state.rerunFailedChecks(snapshot: capturedSnapshot)

        #expect(didRun)
        #expect(provider.rerunFailedChecksBranches == ["feature/captured"])
    }

    @Test func overlappingRefreshIgnoresOlderResult() async throws {
        let remote = Self.makeRemote()
        let slowRequest = Self.makeReviewRequest(
            remote: remote,
            headRefName: "feature/slow",
            checks: []
        )
        let fastRequest = Self.makeReviewRequest(
            remote: remote,
            headRefName: "feature/fast",
            checks: []
        )
        let provider = FakeCodeHostProvider(
            kind: .github,
            requestForBranch: [
                "feature/slow": slowRequest,
                "feature/fast": fastRequest,
            ],
            delayForBranch: [
                "feature/slow": 50_000_000,
            ]
        )
        let state = ReviewLoopState(
            worktreePath: URL(fileURLWithPath: "/tmp/alas-review-loop"),
            baseBranch: "main",
            providerRegistry: CodeHostProviderRegistry(providers: [.github: provider])
        )

        let slow = Task {
            await state.refresh(
                local: Self.makeLocal(branchName: "feature/slow", needsPush: false),
                remotes: [Self.makeGitHubRemote()]
            )
        }
        try await Task.sleep(nanoseconds: 5_000_000)
        await state.refresh(
            local: Self.makeLocal(branchName: "feature/fast", needsPush: false),
            remotes: [Self.makeGitHubRemote()]
        )
        await slow.value

        #expect(state.snapshot?.local.branchName == "feature/fast")
        #expect(state.snapshot?.reviewRequest?.headRefName == "feature/fast")
    }

    @Test func olderOverlappingRefreshDoesNotClearNewerRefreshingFlag() async throws {
        let remote = Self.makeRemote()
        let slowRequest = Self.makeReviewRequest(
            remote: remote,
            headRefName: "feature/slow",
            checks: []
        )
        let slowerRequest = Self.makeReviewRequest(
            remote: remote,
            headRefName: "feature/slower",
            checks: []
        )
        let provider = FakeCodeHostProvider(
            kind: .github,
            requestForBranch: [
                "feature/slow": slowRequest,
                "feature/slower": slowerRequest,
            ],
            delayForBranch: [
                "feature/slow": 20_000_000,
                "feature/slower": 80_000_000,
            ]
        )
        let state = ReviewLoopState(
            worktreePath: URL(fileURLWithPath: "/tmp/alas-review-loop"),
            baseBranch: "main",
            providerRegistry: CodeHostProviderRegistry(providers: [.github: provider])
        )

        let older = Task {
            await state.refresh(
                local: Self.makeLocal(branchName: "feature/slow", needsPush: false),
                remotes: [Self.makeGitHubRemote()]
            )
        }
        try await Task.sleep(nanoseconds: 5_000_000)
        let newer = Task {
            await state.refresh(
                local: Self.makeLocal(branchName: "feature/slower", needsPush: false),
                remotes: [Self.makeGitHubRemote()]
            )
        }
        try await Task.sleep(nanoseconds: 50_000_000)

        #expect(state.isRefreshing)

        await older.value
        await newer.value
        #expect(state.isRefreshing == false)
        #expect(state.snapshot?.local.branchName == "feature/slower")
    }

    @Test func localRefreshFailureRecordsErrorOnSnapshot() async throws {
        let state = ReviewLoopState(
            worktreePath: URL(fileURLWithPath: "/tmp/alas-review-loop"),
            baseBranch: "main",
            providerRegistry: CodeHostProviderRegistry(providers: [:])
        )

        let attempt = state.beginLocalRefresh(local: Self.makeLocal())
        state.failLocalRefresh(attempt, error: StubError(message: "git status failed"))

        #expect(state.snapshot?.errorMessage?.contains("git status failed") == true)
        #expect(state.lastError?.contains("git status failed") == true)
    }

    @Test func localInspectionFailureBlocksWithoutLocalSnapshot() async throws {
        let state = ReviewLoopState(
            worktreePath: URL(fileURLWithPath: "/tmp/alas-review-loop"),
            baseBranch: "main",
            providerRegistry: CodeHostProviderRegistry(providers: [:])
        )

        let attempt = state.beginLocalInspection()
        state.failLocalRefresh(attempt, error: StubError(message: "git status failed"))

        #expect(state.isRefreshing == false)
        #expect(state.snapshot == nil)
        #expect(state.lastError?.contains("git status failed") == true)
    }

    @Test func localRefreshFailureClearsInFlightRefreshingFlag() async throws {
        let remote = Self.makeRemote()
        let local = Self.makeLocal(branchName: "feature/slow", needsPush: false)
        let provider = FakeCodeHostProvider(
            kind: .github,
            requestForBranch: [
                "feature/slow": Self.makeReviewRequest(remote: remote, checks: []),
            ],
            delayForBranch: [
                "feature/slow": 60_000_000,
            ]
        )
        let state = ReviewLoopState(
            worktreePath: URL(fileURLWithPath: "/tmp/alas-review-loop"),
            baseBranch: "main",
            providerRegistry: CodeHostProviderRegistry(providers: [.github: provider])
        )

        let attempt = state.beginLocalRefresh(local: local)
        let refresh = Task {
            await state.refresh(attempt, remotes: [Self.makeGitHubRemote()])
        }
        try await Task.sleep(nanoseconds: 5_000_000)
        state.failLocalRefresh(attempt, error: StubError(message: "git remote failed"))

        #expect(state.isRefreshing == false)

        await refresh.value
        #expect(state.isRefreshing == false)
        #expect(state.snapshot?.errorMessage?.contains("git remote failed") == true)
    }

    @Test func staleLocalInspectionFailureDoesNotReplaceNewerRefresh() async throws {
        let remote = Self.makeRemote()
        let local = Self.makeLocal(branchName: "feature/newer", headSHA: "new456", needsPush: false)
        let provider = FakeCodeHostProvider(
            kind: .github,
            requestForBranch: [
                "feature/newer": Self.makeReviewRequest(
                    remote: remote,
                    headRefName: "feature/newer",
                    checks: []
                ),
            ],
            delayForBranch: [
                "feature/newer": 60_000_000,
            ]
        )
        let state = ReviewLoopState(
            worktreePath: URL(fileURLWithPath: "/tmp/alas-review-loop"),
            baseBranch: "main",
            providerRegistry: CodeHostProviderRegistry(providers: [.github: provider])
        )

        let staleInspection = state.beginLocalInspection()
        let newerAttempt = state.beginLocalRefresh(local: local)
        let refresh = Task {
            await state.refresh(newerAttempt, remotes: [Self.makeGitHubRemote()])
        }
        try await Task.sleep(nanoseconds: 5_000_000)
        state.failLocalRefresh(staleInspection, error: StubError(message: "stale git status failed"))

        #expect(state.isRefreshing)
        #expect(state.lastError == nil)
        #expect(state.snapshot == nil)

        await refresh.value
        #expect(state.snapshot?.local == local)
        #expect(state.snapshot?.reviewRequest?.headRefName == "feature/newer")
        #expect(state.snapshot?.errorMessage == nil)
        #expect(state.lastError == nil)
    }

    @Test func staleLocalRefreshFailureDoesNotReplaceNewerRefresh() async throws {
        let remote = Self.makeRemote()
        let newerLocal = Self.makeLocal(branchName: "feature/newer", headSHA: "new456", needsPush: false)
        let provider = FakeCodeHostProvider(
            kind: .github,
            requestForBranch: [
                "feature/newer": Self.makeReviewRequest(
                    remote: remote,
                    headRefName: "feature/newer",
                    checks: []
                ),
            ],
            delayForBranch: [
                "feature/newer": 60_000_000,
            ]
        )
        let state = ReviewLoopState(
            worktreePath: URL(fileURLWithPath: "/tmp/alas-review-loop"),
            baseBranch: "main",
            providerRegistry: CodeHostProviderRegistry(providers: [.github: provider])
        )

        let staleAttempt = state.beginLocalRefresh(local: newerLocal)
        let newerAttempt = state.beginLocalRefresh(local: newerLocal)
        let refresh = Task {
            await state.refresh(newerAttempt, remotes: [Self.makeGitHubRemote()])
        }
        try await Task.sleep(nanoseconds: 5_000_000)
        state.failLocalRefresh(staleAttempt, error: StubError(message: "stale git remote failed"))

        #expect(state.isRefreshing)
        #expect(state.lastError == nil)
        #expect(state.snapshot == nil)

        await refresh.value
        #expect(state.snapshot?.local == newerLocal)
        #expect(state.snapshot?.reviewRequest?.headRefName == "feature/newer")
        #expect(state.snapshot?.errorMessage == nil)
        #expect(state.lastError == nil)
    }

    @Test func remotesParsesFetchPushDuplicatesUniquely() async throws {
        let repo = try await Self.makeRepo()
        defer { try? FileManager.default.removeItem(at: repo) }
        _ = try await Process.git(["remote", "add", "origin", "git@github.com:mrmans0n/alas.git"], cwd: repo)

        let remotes = try await GitService().remotes(worktreePath: repo)

        #expect(remotes == [GitRemote(name: "origin", url: "git@github.com:mrmans0n/alas.git")])
    }

    @Test func needsPushReturnsTrueWhenUpstreamIsMissing() async throws {
        let repo = try await Self.makeRepo()
        defer { try? FileManager.default.removeItem(at: repo) }
        _ = try await Process.git(["commit", "-q", "--allow-empty", "-m", "initial"], cwd: repo)

        let needsPush = try await GitService().needsPush(worktreePath: repo)

        #expect(needsPush)
    }

    private static func makeRepo() async throws -> URL {
        let repo = FileManager.default.temporaryDirectory
            .appendingPathComponent("alas-review-loop-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        _ = try await Process.git(["init", "-q", "-b", "main"], cwd: repo)
        _ = try await Process.git(["config", "user.email", "t@e"], cwd: repo)
        _ = try await Process.git(["config", "user.name", "t"], cwd: repo)
        return repo
    }

    private static func makeLocal(
        branchName: String = "feature/review-loop",
        headSHA: String = "abc123",
        needsPush: Bool = true
    ) -> ReviewLoopLocalState {
        ReviewLoopLocalState(
            branchName: branchName,
            headSHA: headSHA,
            baseBranch: "main",
            hasWorkingTreeChanges: false,
            hasStagedChanges: false,
            aheadCommitCount: needsPush ? 1 : 0,
            hasUpstream: !needsPush,
            needsPush: needsPush
        )
    }

    private static func makeGitHubRemote() -> GitRemote {
        GitRemote(name: "origin", url: "git@github.com:mrmans0n/alas.git")
    }

    private static func makeRemote() -> CodeHostRemote {
        CodeHostRemote(
            kind: .github,
            host: "github.com",
            owner: "mrmans0n",
            repository: "alas",
            remoteName: "origin",
            webURL: URL(string: "https://github.com/mrmans0n/alas")!
        )
    }

    private static func makeReviewRequest(
        remote: CodeHostRemote,
        headRefName: String = "feature/review-loop",
        checks: [ReviewCheck]
    ) -> ReviewRequest {
        ReviewRequest(
            remote: remote,
            number: 42,
            title: "Review loop",
            url: URL(string: "https://github.com/mrmans0n/alas/pull/42")!,
            state: .open,
            isDraft: false,
            headRefName: headRefName,
            baseRefName: "main",
            reviewDecision: .reviewRequired,
            mergeState: .clean,
            checks: checks,
            threads: [
                ReviewThreadSummary(
                    id: "thread-1",
                    author: "reviewer",
                    body: "Please update this.",
                    url: nil,
                    isResolved: false,
                    isActionable: true
                ),
            ]
        )
    }
}

private struct StubError: LocalizedError {
    let message: String

    var errorDescription: String? { message }
}

private final class FakeCodeHostProvider: CodeHostProvider, @unchecked Sendable {
    struct CreatedReviewRequest: Equatable {
        let branch: String
        let baseBranch: String
        let title: String
        let body: String
    }

    let kind: CodeHostKind
    var available: Bool
    var authenticated: Bool
    var request: ReviewRequest?
    var requestForBranch: [String: ReviewRequest]
    var delayForBranch: [String: UInt64]
    var checks: [ReviewCheck]
    var requestError: Error?
    var checksError: Error?
    var createError: Error?
    var rerunError: Error?
    var createdReviewRequests: [CreatedReviewRequest] = []
    var rerunFailedChecksBranches: [String] = []

    init(
        kind: CodeHostKind,
        available: Bool = true,
        authenticated: Bool = true,
        request: ReviewRequest? = nil,
        requestForBranch: [String: ReviewRequest] = [:],
        delayForBranch: [String: UInt64] = [:],
        checks: [ReviewCheck] = [],
        requestError: Error? = nil,
        checksError: Error? = nil,
        createError: Error? = nil,
        rerunError: Error? = nil
    ) {
        self.kind = kind
        self.available = available
        self.authenticated = authenticated
        self.request = request
        self.requestForBranch = requestForBranch
        self.delayForBranch = delayForBranch
        self.checks = checks
        self.requestError = requestError
        self.checksError = checksError
        self.createError = createError
        self.rerunError = rerunError
    }

    func isAvailable() async -> Bool {
        available
    }

    func isAuthenticated(remote: CodeHostRemote, cwd: URL) async -> Bool {
        authenticated
    }

    func currentReviewRequest(remote: CodeHostRemote, branch: String, cwd: URL) async throws -> ReviewRequest? {
        if let requestError { throw requestError }
        if let delay = delayForBranch[branch] {
            try? await Task.sleep(nanoseconds: delay)
        }
        return requestForBranch[branch] ?? request
    }

    func createReviewRequest(
        remote: CodeHostRemote,
        branch: String,
        baseBranch: String,
        title: String,
        body: String,
        cwd: URL
    ) async throws -> URL {
        if let createError { throw createError }
        createdReviewRequests.append(CreatedReviewRequest(
            branch: branch,
            baseBranch: baseBranch,
            title: title,
            body: body
        ))
        return remote.webURL
    }

    func checks(remote: CodeHostRemote, request: ReviewRequest, cwd: URL) async throws -> [ReviewCheck] {
        if let checksError { throw checksError }
        return checks
    }

    func rerunFailedChecks(remote: CodeHostRemote, branch: String, cwd: URL) async throws {
        if let rerunError { throw rerunError }
        rerunFailedChecksBranches.append(branch)
    }
}
