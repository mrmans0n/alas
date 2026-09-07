import Foundation
import Testing
@testable import Alas

@MainActor
@Suite(.serialized)
struct ReviewLoopStateTests {
    @Test func explicitTargetLookupAndCreationUseCapturedProviderAndArguments() async throws {
        let remote = CodeHostRemote(
            kind: .gitlab, host: "gitlab.com", owner: "captured", repository: "project",
            remoteName: "publish", webURL: URL(string: "https://gitlab.com/captured/project")!
        )
        let provider = FakeCodeHostProvider(kind: .gitlab)
        let state = ReviewLoopState(
            worktreePath: URL(fileURLWithPath: "/tmp/alas-review-loop"), baseBranch: "main",
            providerRegistry: CodeHostProviderRegistry(providers: [.github: FakeCodeHostProvider(kind: .github), .gitlab: provider])
        )
        await state.refresh(local: Self.makeLocal(branchName: "current"), remotes: [Self.makeGitHubRemote()])
        provider.request = Self.makeReviewRequest(remote: remote, checks: [])
        let request = try await state.currentReviewRequest(remote: remote, branch: "captured", headOwner: "fork", baseBranch: "release")
        #expect(request?.number == 42)
        #expect(provider.lookupTargets.last == .init(remote: remote, branch: "captured", headOwner: "fork", baseBranch: "release"))
        let url = try await state.createReviewRequest(remote: remote, branch: "captured", headOwner: "fork", baseBranch: "release", title: "Title", body: "Body", draft: true)
        #expect(url == remote.webURL)
        #expect(provider.creationRemotes == [remote])
        #expect(provider.createdReviewRequests == [.init(branch: "captured", headOwner: "fork", baseBranch: "release", title: "Title", body: "Body", isDraft: true)])
        let error = CodeHostProviderError.commandFailed(command: "lookup", stderr: "offline")
        provider.requestError = error
        await #expect(throws: error) {
            try await state.currentReviewRequest(remote: remote, branch: "captured", headOwner: "fork", baseBranch: "release")
        }
        provider.createError = error
        await #expect(throws: error) {
            try await state.createReviewRequest(remote: remote, branch: "captured", headOwner: "fork", baseBranch: "release", title: "Title", body: "Body", draft: true)
        }
        let unsupported = ReviewLoopState(worktreePath: URL(fileURLWithPath: "/tmp"), baseBranch: "main", providerRegistry: CodeHostProviderRegistry(providers: [:]))
        await #expect(throws: CodeHostProviderError.unsupportedProvider(.gitlab)) {
            try await unsupported.currentReviewRequest(remote: remote, branch: "captured", headOwner: nil, baseBranch: "main")
        }
        await #expect(throws: CodeHostProviderError.unsupportedProvider(.gitlab)) {
            try await unsupported.createReviewRequest(remote: remote, branch: "captured", headOwner: nil, baseBranch: "main", title: "Title", body: "Body", draft: false)
        }
    }

    @Test func rightPaneStoreForwardsCompletedRemoteReviewSnapshot() {
        let store = RightPaneStore()
        let worktree = Worktree(
            id: "worktree-1",
            projectId: "project-1",
            name: "feature/review",
            branch: "feature/review",
            path: URL(fileURLWithPath: "/tmp/alas-review-loop-callback"),
            status: .clean,
            lastActivity: Date()
        )
        let pane = store.state(for: worktree, baseBranch: "main", comparisonMode: .manual)
        let remote = Self.makeRemote()
        let request = Self.makeReviewRequest(remote: remote, checks: [])
        let snapshot = ReviewLoopSnapshot(
            local: Self.makeLocal(needsPush: false),
            remote: remote,
            reviewRequest: request,
            providerAvailable: true,
            providerAuthenticated: true,
            providerCapabilities: .readOnly,
            errorMessage: nil
        )
        var received: [(String, String, ReviewLoopSnapshot)] = []
        store.reviewSnapshotDidChange = { worktreeID, baseRef, snapshot in
            received.append((worktreeID, baseRef, snapshot))
        }
        pane.reviewLoop.updateBaseBranch("release")

        store.observeCompletedRemoteReviewRefresh(
            worktreeId: "worktree-1",
            snapshot: snapshot
        )

        #expect(received.count == 1)
        #expect(received.first?.0 == "worktree-1")
        #expect(received.first?.1 == "main")
        #expect(received.first?.2 == snapshot)
    }

    @Test func baseChangeInvalidatesAnInFlightRefresh() {
        let state = ReviewLoopState(
            worktreePath: URL(fileURLWithPath: "/tmp/alas-review-loop-base-change"),
            baseBranch: "main"
        )
        let stale = state.beginLocalRefresh(local: Self.makeLocal(baseBranch: "main"))

        state.updateBaseBranch("release")
        state.finishLocalRefresh(
            stale,
            preservingRemoteWith: Self.makeLocal(baseBranch: "main")
        )

        #expect(state.currentBaseBranch == "release")
        #expect(state.snapshot == nil)
        #expect(!state.isRefreshing)
    }

    @Test func inFlightActionRejectsConcurrentReviewActions() {
        let state = ReviewLoopState(
            worktreePath: URL(fileURLWithPath: "/tmp/alas-review-loop"),
            baseBranch: "main"
        )

        #expect(state.beginAction(.pushBranch))
        #expect(state.inFlightAction == .pushBranch)
        #expect(!state.beginAction(.rerunFailedChecks))

        state.endAction(.rerunFailedChecks)
        #expect(state.inFlightAction == .pushBranch)

        state.endAction(.pushBranch)
        #expect(state.inFlightAction == nil)
    }

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

    @Test func gitLabRemoteWithoutRegisteredProviderIsUnsupported() async throws {
        let local = Self.makeLocal(branchName: "feature/gitlab", headSHA: "def456")
        let provider = FakeCodeHostProvider(kind: .github)
        let state = ReviewLoopState(
            worktreePath: URL(fileURLWithPath: "/tmp/alas-review-loop"),
            baseBranch: "main",
            providerRegistry: CodeHostProviderRegistry(providers: [.github: provider])
        )

        await state.refresh(local: local, remotes: [
            GitRemote(name: "origin", url: "https://gitlab.com/platform/mobile/alas.git"),
        ])

        #expect(state.snapshot?.local == local)
        #expect(state.snapshot?.remote == nil)
        #expect(state.snapshot?.providerAvailable == false)
        #expect(state.snapshot?.providerAuthenticated == false)
        #expect(state.snapshot?.providerCapabilities == .readOnly)
    }

    @Test func refreshPrefersBaseRemoteOverOriginFork() async throws {
        let provider = FakeCodeHostProvider(kind: .github)
        let state = ReviewLoopState(
            worktreePath: URL(fileURLWithPath: "/tmp/alas-review-loop"),
            baseBranch: "upstream/main",
            providerRegistry: CodeHostProviderRegistry(providers: [.github: provider])
        )

        await state.refresh(
            local: Self.makeLocal(baseBranch: "upstream/main", needsPush: false),
            remotes: [
                GitRemote(name: "origin", url: "git@github.com:nacho/alas.git"),
                GitRemote(name: "upstream", url: "git@github.com:mrmans0n/alas.git"),
            ]
        )

        let remote = try #require(state.snapshot?.remote)
        #expect(remote.remoteName == "upstream")
        #expect(remote.owner == "mrmans0n")
        #expect(remote.repository == "alas")
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

    @Test func emptyBranchNameBlocksReviewLoopActions() async throws {
        let local = Self.makeLocal(branchName: "", headSHA: "detached123", needsPush: true)
        let provider = FakeCodeHostProvider(kind: .github)
        let state = ReviewLoopState(
            worktreePath: URL(fileURLWithPath: "/tmp/alas-review-loop"),
            baseBranch: "main",
            providerRegistry: CodeHostProviderRegistry(providers: [.github: provider])
        )

        await state.refresh(local: local, remotes: [Self.makeGitHubRemote()])

        #expect(state.snapshot?.local == local)
        #expect(state.snapshot?.remote == nil)
        #expect(state.snapshot?.providerAvailable == false)
        #expect(state.snapshot?.providerAuthenticated == false)
        #expect(state.snapshot?.providerCapabilities == .readOnly)
        #expect(state.snapshot?.errorMessage == "No branch checked out.")
    }

    @Test func emptyHeadSHABlocksReviewLoopActions() async throws {
        let local = Self.makeLocal(branchName: "main", headSHA: "", needsPush: true)
        let provider = FakeCodeHostProvider(kind: .github)
        let state = ReviewLoopState(
            worktreePath: URL(fileURLWithPath: "/tmp/alas-review-loop"),
            baseBranch: "main",
            providerRegistry: CodeHostProviderRegistry(providers: [.github: provider])
        )

        await state.refresh(local: local, remotes: [Self.makeGitHubRemote()])

        #expect(state.snapshot?.local == local)
        #expect(state.snapshot?.remote == nil)
        #expect(state.snapshot?.providerAvailable == false)
        #expect(state.snapshot?.providerAuthenticated == false)
        #expect(state.snapshot?.providerCapabilities == .readOnly)
        #expect(state.snapshot?.errorMessage == "No commits yet.")
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

    @Test func refreshPreservesHeadSHAAndRepositoryOwnerForMerge() async throws {
        let remote = Self.makeRemote()
        let request = Self.makeReviewRequest(
            remote: remote,
            headSHA: "reviewed-head-sha",
            headRepositoryOwner: "mrmans0n",
            checks: []
        )
        let check = ReviewCheck(
            id: "ci-build",
            name: "Build",
            workflow: "CI",
            bucket: .pass,
            detailURL: nil,
            completedAt: nil
        )
        let provider = FakeCodeHostProvider(kind: .github, request: request, checks: [check])
        let state = ReviewLoopState(
            worktreePath: URL(fileURLWithPath: "/tmp/alas-review-loop"),
            baseBranch: "main",
            providerRegistry: CodeHostProviderRegistry(providers: [.github: provider])
        )

        await state.refresh(local: Self.makeLocal(needsPush: false), remotes: [Self.makeGitHubRemote()])

        // The refresh reattaches checks; it must not drop the head metadata the
        // merge path relies on for `--match-head-commit` and branch cleanup.
        #expect(state.snapshot?.reviewRequest?.headSHA == "reviewed-head-sha")
        #expect(state.snapshot?.reviewRequest?.headRepositoryOwner == "mrmans0n")
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
        let snapshot = try #require(state.snapshot)
        let url = try await state.createReviewRequest(
            snapshot: snapshot,
            title: "Review loop title",
            body: "Review loop body",
            isDraft: true
        )

        #expect(url == Self.makeRemote().webURL)
        #expect(provider.createdReviewRequests.count == 1)
        #expect(provider.createdReviewRequests.first?.branch == "feature/review-loop")
        #expect(provider.createdReviewRequests.first?.baseBranch == "main")
        #expect(provider.createdReviewRequests.first?.title == "Review loop title")
        #expect(provider.createdReviewRequests.first?.body == "Review loop body")
        #expect(provider.createdReviewRequests.first?.isDraft == true)
    }

    @Test func createReviewRequestPassesForkHeadOwner() async throws {
        let provider = FakeCodeHostProvider(kind: .github)
        let state = ReviewLoopState(
            worktreePath: URL(fileURLWithPath: "/tmp/alas-review-loop"),
            baseBranch: "main",
            providerRegistry: CodeHostProviderRegistry(providers: [.github: provider])
        )
        let local = ReviewLoopLocalState(
            branchName: "feature/review-loop",
            headSHA: "abc123",
            baseBranch: "main",
            hasWorkingTreeChanges: false,
            hasStagedChanges: false,
            aheadCommitCount: 0,
            hasUpstream: true,
            upstreamRemoteName: "fork",
            needsPush: false
        )

        await state.refresh(local: local, remotes: [
            Self.makeGitHubRemote(),
            GitRemote(name: "fork", url: "git@github.com:nacho/alas.git"),
        ])
        let snapshot = try #require(state.snapshot)
        _ = try await state.createReviewRequest(
            snapshot: snapshot,
            title: "Review loop title",
            body: "Review loop body",
            isDraft: false
        )

        #expect(provider.createdReviewRequests.first?.headOwner == "nacho")
    }

    @Test func createReviewRequestUsesPushURLForSplitFetchPushForkOwner() async throws {
        let provider = FakeCodeHostProvider(kind: .github)
        let state = ReviewLoopState(
            worktreePath: URL(fileURLWithPath: "/tmp/alas-review-loop"),
            baseBranch: "main",
            providerRegistry: CodeHostProviderRegistry(providers: [.github: provider])
        )
        let local = ReviewLoopLocalState(
            branchName: "feature/review-loop",
            headSHA: "abc123",
            baseBranch: "main",
            hasWorkingTreeChanges: false,
            hasStagedChanges: false,
            aheadCommitCount: 0,
            hasUpstream: true,
            upstreamRemoteName: "origin",
            needsPush: false
        )

        await state.refresh(local: local, remotes: [
            GitRemote(name: "origin", url: "git@github.com:mrmans0n/alas.git"),
            GitRemote(name: "origin", url: "git@github.com:nacho/alas.git", direction: .push),
        ])
        let snapshot = try #require(state.snapshot)
        _ = try await state.createReviewRequest(
            snapshot: snapshot,
            title: "Review loop title",
            body: "Review loop body",
            isDraft: false
        )

        #expect(state.snapshot?.remote?.owner == "mrmans0n")
        #expect(provider.createdReviewRequests.first?.headOwner == "nacho")
    }

    @Test func newForkBranchUsesOriginAsHeadRemoteWhenBaseIsUpstream() async throws {
        let provider = FakeCodeHostProvider(kind: .github)
        let state = ReviewLoopState(
            worktreePath: URL(fileURLWithPath: "/tmp/alas-review-loop"),
            baseBranch: "upstream/main",
            providerRegistry: CodeHostProviderRegistry(providers: [.github: provider])
        )

        await state.refresh(local: Self.makeLocal(baseBranch: "upstream/main", needsPush: true), remotes: [
            GitRemote(name: "origin", url: "git@github.com:nacho/alas.git"),
            GitRemote(name: "upstream", url: "git@github.com:mrmans0n/alas.git"),
        ])

        #expect(state.snapshot?.remote?.remoteName == "upstream")
        #expect(state.snapshot?.local.headRemoteName == "origin")
        #expect(state.snapshot?.local.headRemoteOwner == "nacho")
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

        _ = try await state.createReviewRequest(
            snapshot: capturedSnapshot,
            title: "Review loop title",
            body: "Review loop body",
            isDraft: false
        )

        #expect(provider.createdReviewRequests.first?.branch == "feature/captured")
    }

    @Test func createReviewRequestUsesExplicitDraftTarget() async throws {
        let provider = FakeCodeHostProvider(kind: .github)
        let state = ReviewLoopState(
            worktreePath: URL(fileURLWithPath: "/tmp/alas-review-loop"),
            baseBranch: "main",
            providerRegistry: CodeHostProviderRegistry(providers: [.github: provider])
        )

        await state.refresh(
            local: Self.makeLocal(branchName: "feature/current", baseBranch: "main", needsPush: false),
            remotes: [Self.makeGitHubRemote()]
        )
        let snapshot = try #require(state.snapshot)

        _ = try await state.createReviewRequest(
            snapshot: snapshot,
            branch: "feature/captured",
            headOwner: "nacho",
            baseBranch: "release",
            title: "Review loop title",
            body: "Review loop body",
            isDraft: true
        )

        #expect(provider.createdReviewRequests.first?.branch == "feature/captured")
        #expect(provider.createdReviewRequests.first?.headOwner == "nacho")
        #expect(provider.createdReviewRequests.first?.baseBranch == "release")
        #expect(provider.createdReviewRequests.first?.isDraft == true)
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
        let snapshot = try #require(state.snapshot)

        await #expect(throws: CodeHostProviderError.commandFailed(
            command: "gh pr create",
            stderr: "GraphQL: Head sha can't be blank"
        )) {
            _ = try await state.createReviewRequest(
                snapshot: snapshot,
                title: "Review loop title",
                body: "Review loop body",
                isDraft: false
            )
        }
    }

    @Test func rerunFailedChecksUsesProviderWithoutSessionApproval() async throws {
        let remote = Self.makeRemote()
        let provider = FakeCodeHostProvider(
            kind: .github,
            capabilities: .githubCLI,
            request: Self.makeMergeableReviewRequest(remote: remote)
        )
        let state = ReviewLoopState(
            worktreePath: URL(fileURLWithPath: "/tmp/alas-review-loop"),
            baseBranch: "main",
            providerRegistry: CodeHostProviderRegistry(providers: [.github: provider])
        )

        await state.refresh(local: Self.makeLocal(needsPush: false), remotes: [Self.makeGitHubRemote()])
        let didRun = await state.rerunFailedChecks()

        #expect(didRun)
        #expect(provider.rerunFailedChecksRequests == [
            FakeCodeHostProvider.RerunFailedChecksRequest(
                branch: "feature/review-loop",
                headSHA: "abc123",
                requestNumber: 42
            ),
        ])
    }

    @Test func rerunFailedChecksUsesCapturedSnapshotInsteadOfCurrentSnapshot() async throws {
        let remote = Self.makeRemote()
        let provider = FakeCodeHostProvider(
            kind: .github,
            requestForBranch: [
                "feature/captured": Self.makeReviewRequest(remote: remote, number: 42, checks: []),
                "feature/current": Self.makeReviewRequest(remote: remote, number: 43, checks: []),
            ]
        )
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
        #expect(provider.rerunFailedChecksRequests == [
            FakeCodeHostProvider.RerunFailedChecksRequest(
                branch: "feature/captured",
                headSHA: "abc123",
                requestNumber: 42
            ),
        ])
    }

    // A fully-mergeable request whose head matches `makeLocal`'s default SHA.
    private static func makeMergeableReviewRequest(remote: CodeHostRemote) -> ReviewRequest {
        makeReviewRequest(
            remote: remote,
            headSHA: "abc123",
            headRepositoryOwner: "mrmans0n",
            reviewDecision: .approved,
            includeActionableThread: false,
            checks: []
        )
    }

    @Test func mergeInvokesProviderWithSquashAndDeleteBranch() async throws {
        let remote = Self.makeRemote()
        let provider = FakeCodeHostProvider(
            kind: .github,
            capabilities: .githubCLI,
            request: Self.makeMergeableReviewRequest(remote: remote)
        )
        let state = ReviewLoopState(
            worktreePath: URL(fileURLWithPath: "/tmp/alas-review-loop"),
            baseBranch: "main",
            providerRegistry: CodeHostProviderRegistry(providers: [.github: provider])
        )

        await state.refresh(local: Self.makeLocal(needsPush: false), remotes: [Self.makeGitHubRemote()])
        let snapshot = try #require(state.snapshot)

        let ok = await state.merge(snapshot: snapshot)

        #expect(ok == .merged)
        #expect(provider.mergeRequestCalls == [
            FakeCodeHostProvider.MergeRequestCall(number: 42, method: .squash, deleteBranch: true),
        ])
    }

    @Test func mergeReportsQueuedOutcomeForQueueRequest() async throws {
        let remote = Self.makeRemote()
        let provider = FakeCodeHostProvider(
            kind: .github,
            capabilities: .githubCLI,
            request: Self.makeMergeableReviewRequest(remote: remote).withMergeQueue(isEnabled: true, isInQueue: false)
        )
        let state = ReviewLoopState(
            worktreePath: URL(fileURLWithPath: "/tmp/alas-review-loop"),
            baseBranch: "main",
            providerRegistry: CodeHostProviderRegistry(providers: [.github: provider])
        )

        await state.refresh(local: Self.makeLocal(needsPush: false), remotes: [Self.makeGitHubRemote()])
        let snapshot = try #require(state.snapshot)

        let outcome = await state.merge(snapshot: snapshot)

        #expect(outcome == .queued)
        #expect(provider.mergeRequestCalls == [
            FakeCodeHostProvider.MergeRequestCall(number: 42, method: .squash, deleteBranch: true),
        ])
    }

    @Test func mergeReturnsFalseAndRecordsErrorOnFailure() async throws {
        let remote = Self.makeRemote()
        let provider = FakeCodeHostProvider(
            kind: .github,
            capabilities: .githubCLI,
            request: Self.makeMergeableReviewRequest(remote: remote)
        )
        provider.mergeError = CodeHostProviderError.commandFailed(command: "gh pr merge", stderr: "boom")
        let state = ReviewLoopState(
            worktreePath: URL(fileURLWithPath: "/tmp/alas-review-loop"),
            baseBranch: "main",
            providerRegistry: CodeHostProviderRegistry(providers: [.github: provider])
        )

        await state.refresh(local: Self.makeLocal(needsPush: false), remotes: [Self.makeGitHubRemote()])
        let snapshot = try #require(state.snapshot)

        let ok = await state.merge(snapshot: snapshot)

        #expect(ok == nil)
        #expect(state.lastError != nil)
    }

    @Test func mergeReValidatesFreshProviderStateAndAbortsWhenNoLongerMergeable() async throws {
        // Refresh sees a mergeable request; then the fresh re-query at merge
        // time returns a non-mergeable one (review now required + actionable
        // feedback). The merge must abort without invoking the provider merge.
        let remote = Self.makeRemote()
        let provider = FakeCodeHostProvider(
            kind: .github,
            capabilities: .githubCLI,
            request: Self.makeMergeableReviewRequest(remote: remote)
        )
        let state = ReviewLoopState(
            worktreePath: URL(fileURLWithPath: "/tmp/alas-review-loop"),
            baseBranch: "main",
            providerRegistry: CodeHostProviderRegistry(providers: [.github: provider])
        )
        await state.refresh(local: Self.makeLocal(needsPush: false), remotes: [Self.makeGitHubRemote()])
        let snapshot = try #require(state.snapshot)

        // Remote state changed since the (still green) snapshot.
        provider.request = Self.makeReviewRequest(
            remote: remote,
            headSHA: "abc123",
            headRepositoryOwner: "mrmans0n",
            reviewDecision: .reviewRequired,
            includeActionableThread: true,
            checks: []
        )

        let ok = await state.merge(snapshot: snapshot)

        #expect(ok == nil)
        #expect(provider.mergeRequestCalls.isEmpty)
        #expect(state.lastError != nil)
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

    @Test func cachedLocalRefreshPreservesEnrichedHeadRemoteMetadata() async throws {
        let state = ReviewLoopState(
            worktreePath: URL(fileURLWithPath: "/tmp/alas-review-loop"),
            baseBranch: "upstream/main",
            providerRegistry: CodeHostProviderRegistry(providers: [.github: FakeCodeHostProvider(kind: .github)])
        )
        await state.refresh(local: Self.makeLocal(baseBranch: "upstream/main", needsPush: true), remotes: [
            GitRemote(name: "origin", url: "git@github.com:nacho/alas.git"),
            GitRemote(name: "upstream", url: "git@github.com:mrmans0n/alas.git"),
        ])
        let enrichedLocal = try #require(state.snapshot?.local)
        #expect(enrichedLocal.headRemoteName == "origin")
        #expect(enrichedLocal.headRemoteOwner == "nacho")

        let rawLocal = ReviewLoopLocalState(
            branchName: enrichedLocal.branchName,
            headSHA: enrichedLocal.headSHA,
            baseBranch: enrichedLocal.baseBranch,
            hasWorkingTreeChanges: enrichedLocal.hasWorkingTreeChanges,
            hasStagedChanges: enrichedLocal.hasStagedChanges,
            aheadCommitCount: enrichedLocal.aheadCommitCount,
            hasUpstream: enrichedLocal.hasUpstream,
            upstreamRemoteName: enrichedLocal.upstreamRemoteName,
            upstreamBranchName: enrichedLocal.upstreamBranchName,
            upstreamAheadCommitCount: enrichedLocal.upstreamAheadCommitCount,
            needsPush: enrichedLocal.needsPush
        )
        let attempt = state.beginLocalRefresh(local: rawLocal)

        state.finishLocalRefresh(attempt, preservingRemoteWith: rawLocal)

        #expect(state.snapshot?.local.headRemoteName == "origin")
        #expect(state.snapshot?.local.headRemoteOwner == "nacho")
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

    @Test func staleLocalInspectionCannotPromoteRefreshAfterNewerAttemptStarts() async throws {
        let local = Self.makeLocal(branchName: "feature/stale", headSHA: "old123", needsPush: false)
        let newerLocal = Self.makeLocal(branchName: "feature/newer", headSHA: "new456", needsPush: false)
        let state = ReviewLoopState(
            worktreePath: URL(fileURLWithPath: "/tmp/alas-review-loop"),
            baseBranch: "main",
            providerRegistry: CodeHostProviderRegistry(providers: [.github: FakeCodeHostProvider(kind: .github)])
        )

        let staleInspection = state.beginLocalInspection()
        let newerAttempt = state.beginLocalRefresh(local: newerLocal)
        let staleAttempt = state.beginLocalRefresh(from: staleInspection, local: local)

        #expect(staleAttempt == nil)
        await state.refresh(newerAttempt, remotes: [Self.makeGitHubRemote()])
        #expect(state.snapshot?.local == newerLocal)
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

        #expect(remotes == [
            GitRemote(name: "origin", url: "git@github.com:mrmans0n/alas.git"),
            GitRemote(name: "origin", url: "git@github.com:mrmans0n/alas.git", direction: .push),
        ])
    }

    @Test func parseRemotesPreservesPushURLsWithDirection() {
        let remotes = GitService.parseRemotes("""
        origin  git@github.com:mrmans0n/alas.git (fetch)
        origin  git@github.com:nacho/alas.git (push)
        fork    git@github.com:nacho/alas.git (fetch)
        fork    git@github.com:nacho/alas.git (push)
        """)

        #expect(remotes == [
            GitRemote(name: "origin", url: "git@github.com:mrmans0n/alas.git"),
            GitRemote(name: "origin", url: "git@github.com:nacho/alas.git", direction: .push),
            GitRemote(name: "fork", url: "git@github.com:nacho/alas.git"),
            GitRemote(name: "fork", url: "git@github.com:nacho/alas.git", direction: .push),
        ])
    }

    @Test func needsPushReturnsTrueWhenUpstreamIsMissing() async throws {
        let repo = try await Self.makeRepo()
        defer { try? FileManager.default.removeItem(at: repo) }
        _ = try await Process.git(["commit", "-q", "--allow-empty", "-m", "initial"], cwd: repo)

        let needsPush = try await GitService().needsPush(worktreePath: repo)

        #expect(needsPush)
    }

    @Test func upstreamAheadCommitCountUsesLocalTrackingRefWithoutFetching() async throws {
        let repo = try await Self.makeRepo()
        let remote = FileManager.default.temporaryDirectory
            .appendingPathComponent("alas-review-loop-remote-\(UUID().uuidString)")
        let remoteClone = FileManager.default.temporaryDirectory
            .appendingPathComponent("alas-review-loop-remote-clone-\(UUID().uuidString)")
        defer {
            try? FileManager.default.removeItem(at: repo)
            try? FileManager.default.removeItem(at: remote)
            try? FileManager.default.removeItem(at: remoteClone)
        }

        _ = try await Process.git(["commit", "-q", "--allow-empty", "-m", "initial"], cwd: repo)
        _ = try await Process.git(["init", "--bare", "-q", remote.path], cwd: nil)
        _ = try await Process.git(["symbolic-ref", "HEAD", "refs/heads/main"], cwd: remote)
        _ = try await Process.git(["remote", "add", "origin", remote.path], cwd: repo)
        _ = try await Process.git(["push", "-q", "-u", "origin", "main"], cwd: repo)

        _ = try await Process.git(["clone", "-q", remote.path, remoteClone.path], cwd: nil)
        _ = try await Process.git(["config", "user.email", "t@e"], cwd: remoteClone)
        _ = try await Process.git(["config", "user.name", "t"], cwd: remoteClone)
        _ = try await Process.git(["commit", "-q", "--allow-empty", "-m", "remote update"], cwd: remoteClone)
        _ = try await Process.git(["push", "-q", "origin", "main"], cwd: remoteClone)
        _ = try await Process.git(["commit", "-q", "--allow-empty", "-m", "local update"], cwd: repo)

        let staleTrackingCount = try await GitService().upstreamAheadCommitCount(worktreePath: repo)
        _ = try await Process.git(["fetch", "origin", "main"], cwd: repo)
        let fetchedTrackingCount = try await GitService().upstreamAheadCommitCount(worktreePath: repo)

        #expect(staleTrackingCount == 0)
        #expect(fetchedTrackingCount == 1)
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
        baseBranch: String = "main",
        needsPush: Bool = true
    ) -> ReviewLoopLocalState {
        ReviewLoopLocalState(
            branchName: branchName,
            headSHA: headSHA,
            baseBranch: baseBranch,
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
        number: Int = 42,
        headRefName: String = "feature/review-loop",
        headSHA: String? = nil,
        headRepositoryOwner: String? = nil,
        reviewDecision: ReviewDecision = .reviewRequired,
        includeActionableThread: Bool = true,
        checks: [ReviewCheck]
    ) -> ReviewRequest {
        ReviewRequest(
            remote: remote,
            number: number,
            title: "Review loop",
            url: URL(string: "https://github.com/mrmans0n/alas/pull/42")!,
            state: .open,
            isDraft: false,
            headRefName: headRefName,
            baseRefName: "main",
            headSHA: headSHA,
            headRepositoryOwner: headRepositoryOwner,
            reviewDecision: reviewDecision,
            mergeState: .clean,
            checks: checks,
            threads: includeActionableThread ? [
                ReviewThread(
                    id: "thread-1",
                    path: nil,
                    line: nil,
                    startLine: nil,
                    originalLine: nil,
                    diffHunk: nil,
                    isResolved: false,
                    isOutdated: false,
                    isFileLevel: true,
                    comments: [
                        ReviewComment(
                            id: "thread-1",
                            author: "reviewer",
                            body: "Please update this.",
                            url: nil,
                            createdAt: nil,
                            viewerCanUpdate: false,
                            viewerCanDelete: false,
                            isPending: false
                        ),
                    ],
                    viewerCanResolve: false,
                    viewerCanReply: false,
                    url: nil
                ),
            ] : []
        )
    }
}

private struct StubError: LocalizedError {
    let message: String

    var errorDescription: String? { message }
}

private final class FakeCodeHostProvider: CodeHostProvider, @unchecked Sendable {
    struct LookupTarget: Equatable {
        let remote: CodeHostRemote
        let branch: String
        let headOwner: String?
        let baseBranch: String
    }
    var lookupTargets: [LookupTarget] = []
    var creationRemotes: [CodeHostRemote] = []
    struct CreatedReviewRequest: Equatable {
        let branch: String
        let headOwner: String?
        let baseBranch: String
        let title: String
        let body: String
        let isDraft: Bool
    }

    struct RerunFailedChecksRequest: Equatable {
        let branch: String
        let headSHA: String
        let requestNumber: Int?
    }

    struct MergeRequestCall: Equatable {
        let number: Int
        let method: ReviewMergeMethod
        let deleteBranch: Bool
    }

    let kind: CodeHostKind
    let capabilities: CodeHostProviderCapabilities
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
    var mergeError: Error?
    var createdReviewRequests: [CreatedReviewRequest] = []
    var rerunFailedChecksRequests: [RerunFailedChecksRequest] = []
    var mergeRequestCalls: [MergeRequestCall] = []

    init(
        kind: CodeHostKind,
        capabilities: CodeHostProviderCapabilities = .readOnly,
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
        self.capabilities = capabilities
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

    func isAvailable(cwd: URL) async -> Bool {
        available
    }

    func isAuthenticated(remote: CodeHostRemote, cwd: URL) async -> Bool {
        authenticated
    }

    func currentReviewRequest(
        remote: CodeHostRemote,
        branch: String,
        headOwner: String?,
        baseBranch: String,
        cwd: URL
    ) async throws -> ReviewRequest? {
        lookupTargets.append(.init(remote: remote, branch: branch, headOwner: headOwner, baseBranch: baseBranch))
        if let requestError { throw requestError }
        if let delay = delayForBranch[branch] {
            try? await Task.sleep(nanoseconds: delay)
        }
        return requestForBranch[branch] ?? request
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
        if let createError { throw createError }
        creationRemotes.append(remote)
        createdReviewRequests.append(CreatedReviewRequest(
            branch: branch,
            headOwner: headOwner,
            baseBranch: baseBranch,
            title: title,
            body: body,
            isDraft: isDraft
        ))
        return remote.webURL
    }

    func checks(remote: CodeHostRemote, request: ReviewRequest, cwd: URL) async throws -> [ReviewCheck] {
        if let checksError { throw checksError }
        return checks
    }

    func rerunFailedChecks(
        remote: CodeHostRemote,
        branch: String,
        headSHA: String,
        request: ReviewRequest?,
        cwd: URL
    ) async throws {
        if let rerunError { throw rerunError }
        rerunFailedChecksRequests.append(RerunFailedChecksRequest(
            branch: branch,
            headSHA: headSHA,
            requestNumber: request?.number
        ))
    }

    func mergeReviewRequest(
        _ request: ReviewRequest,
        method: ReviewMergeMethod,
        deleteBranch: Bool,
        cwd: URL
    ) async throws {
        if let mergeError { throw mergeError }
        mergeRequestCalls.append(MergeRequestCall(
            number: request.number,
            method: method,
            deleteBranch: deleteBranch
        ))
    }
}
