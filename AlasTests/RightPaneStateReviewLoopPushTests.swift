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

    private static func makeSnapshot(
        remoteName: String = "origin",
        hasUpstream: Bool = true,
        upstreamRemoteName: String? = nil,
        upstreamBranchName: String? = nil,
        headRemoteName: String? = nil
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
            reviewRequest: nil,
            providerAvailable: true,
            providerAuthenticated: true,
            providerCapabilities: .githubCLI,
            errorMessage: nil
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
