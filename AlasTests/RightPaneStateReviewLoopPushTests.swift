import Foundation
import Testing
@testable import Alas

struct RightPaneStateReviewLoopPushTests {
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
}
