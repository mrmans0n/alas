import Foundation
import Testing
@testable import Alas

@MainActor
struct RightPaneStateReviewLoopPushTests {
    private struct MemoryStore: PersistenceStoreProtocol {
        func write<T: Encodable>(_: T, to _: URL) throws {}
        func readIfExists<T: Decodable>(_: T.Type, from _: URL) throws -> T? { nil }
    }

    @Test func createReviewRequestActionOpensDraftTab() {
        let worktreeId = "wt-review-request-draft-action"
        defer { try? FileManager.default.removeItem(at: Paths.tabsFile(forWorktreeId: worktreeId)) }
        let appState = AppState(store: MemoryStore())
        let worktree = Worktree(
            id: worktreeId,
            projectId: "p1",
            name: "feature/pr-drafts",
            branch: "feature/pr-drafts",
            path: URL(fileURLWithPath: "/tmp/repo"),
            status: .clean,
            lastActivity: Date(timeIntervalSince1970: 0)
        )
        let state = RightPaneState(worktree: worktree, baseBranch: "main")
        state.reviewLoop.setSnapshotForTests(Self.makeSnapshot())

        state.handleReviewReadinessAction(.createReviewRequest, appState: appState)

        let tabs = appState.tabs.tabs(forWorktree: worktreeId)
        #expect(tabs.contains {
            if case .draftReviewRequest = $0 { return true }
            return false
        })
    }

    @Test func createReviewRequestActionNoopsWhileReviewActionIsInFlight() {
        let worktreeId = "wt-review-request-draft-action-in-flight"
        defer { try? FileManager.default.removeItem(at: Paths.tabsFile(forWorktreeId: worktreeId)) }
        let appState = AppState(store: MemoryStore())
        let worktree = Worktree(
            id: worktreeId,
            projectId: "p1",
            name: "feature/pr-drafts",
            branch: "feature/pr-drafts",
            path: URL(fileURLWithPath: "/tmp/repo"),
            status: .clean,
            lastActivity: Date(timeIntervalSince1970: 0)
        )
        let state = RightPaneState(worktree: worktree, baseBranch: "main")
        state.reviewLoop.setSnapshotForTests(Self.makeSnapshot())
        #expect(state.reviewLoop.beginAction(.pushBranch))

        state.handleReviewReadinessAction(.createReviewRequest, appState: appState)

        #expect(appState.tabs.tabs(forWorktree: worktreeId).isEmpty)
        #expect(state.reviewLoop.inFlightAction == .pushBranch)
    }

    @Test func inspectReviewEvidenceActionNoopsWithoutReviewRequest() {
        let worktreeId = "wt-review-evidence-no-request"
        defer { try? FileManager.default.removeItem(at: Paths.tabsFile(forWorktreeId: worktreeId)) }
        let appState = AppState(store: MemoryStore())
        let worktree = Worktree(
            id: worktreeId,
            projectId: "p1",
            name: "feature/review-loop",
            branch: "feature/review-loop",
            path: URL(fileURLWithPath: "/tmp/repo"),
            status: .clean,
            lastActivity: Date(timeIntervalSince1970: 0)
        )
        let state = RightPaneState(worktree: worktree, baseBranch: "main")
        state.reviewLoop.setSnapshotForTests(Self.makeSnapshot())

        state.handleReviewReadinessAction(.inspectReviewEvidence, appState: appState)

        #expect(appState.tabs.tabs(forWorktree: worktreeId).isEmpty)
    }

    @Test func mergeActionNoopsWithoutReviewRequest() {
        let worktreeId = "wt-merge-no-request"
        defer { try? FileManager.default.removeItem(at: Paths.tabsFile(forWorktreeId: worktreeId)) }
        let appState = AppState(store: MemoryStore())
        let worktree = Worktree(
            id: worktreeId,
            projectId: "p1",
            name: "feature/review-loop",
            branch: "feature/review-loop",
            path: URL(fileURLWithPath: "/tmp/repo"),
            status: .clean,
            lastActivity: Date(timeIntervalSince1970: 0)
        )
        let state = RightPaneState(worktree: worktree, baseBranch: "main")
        state.reviewLoop.setSnapshotForTests(Self.makeSnapshot())

        state.handleReviewReadinessAction(.merge, appState: appState)

        #expect(state.pendingMerge == nil)
    }

    @Test func performMergeRevalidatesAgainstCurrentSnapshot() {
        let worktreeId = "wt-merge-revalidate"
        defer { try? FileManager.default.removeItem(at: Paths.tabsFile(forWorktreeId: worktreeId)) }
        let worktree = Worktree(
            id: worktreeId,
            projectId: "p1",
            name: "feature/review-loop",
            branch: "feature/review-loop",
            path: URL(fileURLWithPath: "/tmp/repo"),
            status: .clean,
            lastActivity: Date(timeIntervalSince1970: 0)
        )
        let state = RightPaneState(worktree: worktree, baseBranch: "main")
        // A merge was queued via the dialog, but the current snapshot no longer
        // qualifies (default snapshot is unpushed / has no mergeable request).
        state.pendingMerge = Self.makeSnapshot()
        state.reviewLoop.setSnapshotForTests(Self.makeSnapshot())

        state.performMerge()

        #expect(state.pendingMerge == nil)
        #expect(state.mergeError != nil)
    }

    @Test func mergeConfirmationMessageReflectsQueueOperation() {
        let snapshot = Self.makeSnapshot(reviewRequest: Self.makeReviewRequest(isMergeQueueEnabled: true))

        #expect(
            RightPaneState.mergeConfirmationMessage(for: snapshot.reviewRequest)
                == "Add GitHub #428 to the merge queue for main."
        )
    }

    @Test func mergeConfirmationMessageReflectsSquashOperation() {
        let snapshot = Self.makeSnapshot(reviewRequest: Self.makeReviewRequest())

        #expect(
            RightPaneState.mergeConfirmationMessage(for: snapshot.reviewRequest)
                == "Squash-merge GitHub #428 into main and delete the branch."
        )
    }

    @Test func clearMergeQueuedMessageClearsQueuedSuccess() {
        let worktree = Worktree(
            id: "wt-merge-queued-message",
            projectId: "p1",
            name: "feature/review-loop",
            branch: "feature/review-loop",
            path: URL(fileURLWithPath: "/tmp/repo"),
            status: .clean,
            lastActivity: Date(timeIntervalSince1970: 0)
        )
        let state = RightPaneState(worktree: worktree, baseBranch: "main")
        state.mergeQueuedMessage = "Added to merge queue."

        state.clearMergeQueuedMessage()

        #expect(state.mergeQueuedMessage == nil)
    }

    @Test func normalPushArgumentsDoNotForce() {
        let snapshot = Self.makeSnapshot()

        let args = RightPaneState.reviewLoopPushArguments(snapshot: snapshot, forceWithLease: false)

        #expect(args == ["push", "-u", "origin", "feature/review-loop"])
    }

    @Test func pushArgumentsPreferUpstreamRemote() {
        let snapshot = Self.makeSnapshot(upstreamRemoteName: "fork")

        let args = RightPaneState.reviewLoopPushArguments(snapshot: snapshot, forceWithLease: false)

        #expect(args == ["push", "-u", "fork", "feature/review-loop"])
    }

    @Test func pushArgumentsUseTrackedUpstreamBranchName() {
        let snapshot = Self.makeSnapshot(
            upstreamRemoteName: "fork",
            upstreamBranchName: "review/foo"
        )

        let args = RightPaneState.reviewLoopPushArguments(snapshot: snapshot, forceWithLease: false)

        #expect(args == ["push", "-u", "fork", "HEAD:review/foo"])
    }

    @Test func pushArgumentsPreferHeadRemoteWhenBranchHasNoUpstream() {
        let snapshot = Self.makeSnapshot(
            remoteName: "upstream",
            hasUpstream: false,
            headRemoteName: "origin"
        )

        let args = RightPaneState.reviewLoopPushArguments(snapshot: snapshot, forceWithLease: false)

        #expect(args == ["push", "-u", "origin", "feature/review-loop"])
    }

    @Test func reviewLoopAheadCommitCountPrefersBaseRelativeCount() {
        let displayCommits: [CommitInfo] = []
        let baseCommits = [
            Self.makeCommit(sha: "abc1234"),
            Self.makeCommit(sha: "def5678"),
        ]

        let count = RightPaneState.reviewLoopAheadCommitCount(
            displayCommits: displayCommits,
            baseCommits: baseCommits
        )

        #expect(count == 2)
    }

    @Test func reviewLoopRemoteRefreshSkipsSameFingerprintInsideInterval() {
        let fingerprint = Self.makeRemoteFingerprint(headSHA: "abc")
        let now = Date(timeIntervalSince1970: 100)

        #expect(!RightPaneState.shouldRefreshReviewLoopRemote(
            now: now,
            lastRefreshAt: now.addingTimeInterval(-10),
            lastFingerprint: fingerprint,
            fingerprint: fingerprint,
            minimumInterval: 45
        ))
    }

    @Test func reviewLoopRemoteRefreshRunsWhenFingerprintChanges() {
        let now = Date(timeIntervalSince1970: 100)

        #expect(RightPaneState.shouldRefreshReviewLoopRemote(
            now: now,
            lastRefreshAt: now.addingTimeInterval(-10),
            lastFingerprint: Self.makeRemoteFingerprint(headSHA: "abc"),
            fingerprint: Self.makeRemoteFingerprint(headSHA: "def"),
            minimumInterval: 45
        ))
    }

    @Test func reviewLoopRemoteRefreshRunsAfterInterval() {
        let fingerprint = Self.makeRemoteFingerprint(headSHA: "abc")
        let now = Date(timeIntervalSince1970: 100)

        #expect(RightPaneState.shouldRefreshReviewLoopRemote(
            now: now,
            lastRefreshAt: now.addingTimeInterval(-60),
            lastFingerprint: fingerprint,
            fingerprint: fingerprint,
            minimumInterval: 45
        ))
    }

    @Test func reviewLoopRemoteFingerprintRemotesAreStable() {
        let remotes = [
            GitRemote(name: "upstream", url: "git@github.com:mrmans0n/alas.git"),
            GitRemote(name: "origin", url: "git@github.com:fork/alas.git", direction: .push)
        ]

        let signature = RightPaneState.reviewLoopRemoteFingerprintRemotes(remotes)

        #expect(signature == [
            "origin\u{1F}push\u{1F}git@github.com:fork/alas.git",
            "upstream\u{1F}fetch\u{1F}git@github.com:mrmans0n/alas.git"
        ])
    }

    @Test func forcePushArgumentsUseForceWithLease() {
        let snapshot = Self.makeSnapshot()

        let args = RightPaneState.reviewLoopPushArguments(snapshot: snapshot, forceWithLease: true)

        #expect(args == ["push", "--force-with-lease", "-u", "origin", "feature/review-loop"])
    }

    @Test func pushFailureMessagePrefersStderr() {
        let result = ProcessResult(
            exitCode: 128,
            stdout: "stdout fallback",
            stderr: " fatal: no upstream \n"
        )

        #expect(RightPaneState.reviewLoopPushFailureMessage(result) == "fatal: no upstream")
    }

    @Test func pushFailureMessageUsesStdoutWhenStderrIsEmpty() {
        let result = ProcessResult(
            exitCode: 1,
            stdout: " rejected by remote \n",
            stderr: ""
        )

        #expect(RightPaneState.reviewLoopPushFailureMessage(result) == "rejected by remote")
    }

    @Test func pushFailureMessageFallsBackToExitCode() {
        let result = ProcessResult(exitCode: 1, stdout: "", stderr: "")

        #expect(RightPaneState.reviewLoopPushFailureMessage(result) == "git push failed with exit code 1.")
    }

    private static func makeRemoteFingerprint(headSHA: String) -> ReviewLoopRemoteFingerprint {
        ReviewLoopRemoteFingerprint(
            branchName: "feature/review-loop",
            headSHA: headSHA,
            baseBranch: "main",
            hasWorkingTreeChanges: false,
            hasStagedChanges: false,
            aheadCommitCount: 1,
            hasUpstream: true,
            upstreamRemoteName: "origin",
            upstreamBranchName: "feature/review-loop",
            upstreamAheadCommitCount: 0,
            needsPush: false,
            remotes: ["origin\u{1F}fetch\u{1F}git@github.com:mrmans0n/alas.git"]
        )
    }

    private static func makeSnapshot(
        remoteName: String = "origin",
        hasUpstream: Bool = true,
        upstreamRemoteName: String? = nil,
        upstreamBranchName: String? = nil,
        headRemoteName: String? = nil,
        reviewRequest: ReviewRequest? = nil
    ) -> ReviewLoopSnapshot {
        let remote = CodeHostRemote(
            kind: .github,
            host: "github.com",
            owner: "mrmans0n",
            repository: "alas",
            remoteName: remoteName,
            webURL: URL(string: "https://github.com/mrmans0n/alas")!
        )
        return ReviewLoopSnapshot(
            local: ReviewLoopLocalState(
                branchName: "feature/review-loop",
                headSHA: "abc123",
                baseBranch: "main",
                hasWorkingTreeChanges: false,
                hasStagedChanges: false,
                aheadCommitCount: 1,
                hasUpstream: hasUpstream,
                upstreamRemoteName: upstreamRemoteName,
                upstreamBranchName: upstreamBranchName,
                headRemoteName: headRemoteName,
                upstreamAheadCommitCount: 0,
                needsPush: true
            ),
            remote: remote,
            reviewRequest: reviewRequest,
            providerAvailable: true,
            providerAuthenticated: true,
            providerCapabilities: .githubCLI,
            errorMessage: nil
        )
    }

    private static func makeReviewRequest(isMergeQueueEnabled: Bool = false) -> ReviewRequest {
        let remote = CodeHostRemote(
            kind: .github,
            host: "github.com",
            owner: "mrmans0n",
            repository: "alas",
            remoteName: "origin",
            webURL: URL(string: "https://github.com/mrmans0n/alas")!
        )
        return ReviewRequest(
            remote: remote,
            number: 428,
            title: "Review loop",
            url: URL(string: "https://github.com/mrmans0n/alas/pull/428")!,
            state: .open,
            isDraft: false,
            headRefName: "feature/review-loop",
            baseRefName: "main",
            headSHA: "abc123",
            reviewDecision: .approved,
            mergeState: .clean,
            checks: [],
            threads: [],
            isMergeQueueEnabled: isMergeQueueEnabled,
            isInMergeQueue: false
        )
    }

    private static func makeCommit(sha: String) -> CommitInfo {
        CommitInfo(
            sha: sha,
            shortSha: String(sha.prefix(7)),
            author: "Test",
            authorInitials: "T",
            date: Date(timeIntervalSince1970: 0),
            subject: "Change",
            conventionalTag: nil,
            filesChanged: 0,
            insertions: 0,
            deletions: 0
        )
    }
}
