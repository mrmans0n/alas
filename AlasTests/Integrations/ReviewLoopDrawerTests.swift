import Foundation
import Testing
@testable import Alas

struct ReviewLoopDrawerTests {
    @Test func readinessIdentityUsesGitHubRequestWhenPresent() {
        let request = Self.makeReviewRequest()
        let model = ReviewReadinessModel(
            snapshot: Self.makeSnapshot(reviewRequest: request),
            lastError: nil,
            canOpenAgentHandoff: true
        )

        #expect(model.identity == "GitHub #42")
    }

    @Test func githubSnapshotWithoutRequestExposesCreatePR() {
        let model = ReviewReadinessModel(
            snapshot: Self.makeSnapshot(reviewRequest: nil),
            lastError: nil,
            canOpenAgentHandoff: false
        )

        #expect(model.actions.contains(Action(kind: .createReviewRequest, title: "Create PR", isEnabled: true)))
    }

    @Test func gitlabSnapshotWithoutRequestExposesCreateMR() {
        let remote = Self.makeRemote(kind: .gitlab)
        let capabilities = CodeHostProviderCapabilities(
            canCreateReviewRequest: true,
            canRerunFailedChecks: false,
            canOpenReviewRequest: true
        )
        let model = ReviewReadinessModel(
            snapshot: Self.makeSnapshot(remote: remote, reviewRequest: nil, providerCapabilities: capabilities),
            lastError: nil,
            canOpenAgentHandoff: false
        )

        #expect(model.actions.contains(Action(kind: .createReviewRequest, title: "Create MR", isEnabled: true)))
    }

    @Test func agentHandoffActionIsHiddenWhenUnavailable() {
        let request = Self.makeReviewRequest(checks: [Self.makeCheck(bucket: .fail)])
        let model = ReviewReadinessModel(
            snapshot: Self.makeSnapshot(reviewRequest: request),
            lastError: nil,
            canOpenAgentHandoff: false
        )

        #expect(!model.actions.map(\.kind).contains(.openAgentHandoff))
    }

    @Test func readinessActionsDoNotExposeStartNarrative() {
        let model = ReviewReadinessModel(
            snapshot: Self.makeSnapshot(reviewRequest: nil),
            lastError: nil,
            canOpenAgentHandoff: false
        )

        #expect(model.title != "Start " + "review session")
        #expect(!model.actions.map(\.title).contains("Start"))
    }

    private typealias Action = ReviewReadinessModel.Action

    private static func makeLocal(needsPush: Bool = false) -> ReviewLoopLocalState {
        ReviewLoopLocalState(
            branchName: "feature/review-readiness",
            headSHA: "abc123",
            baseBranch: "main",
            hasWorkingTreeChanges: false,
            hasStagedChanges: false,
            aheadCommitCount: needsPush ? 1 : 0,
            hasUpstream: true,
            needsPush: needsPush
        )
    }

    private static func makeSnapshot(
        local: ReviewLoopLocalState = makeLocal(),
        remote: CodeHostRemote? = makeRemote(),
        reviewRequest: ReviewRequest? = makeReviewRequest(),
        providerCapabilities: CodeHostProviderCapabilities = .githubCLI
    ) -> ReviewLoopSnapshot {
        ReviewLoopSnapshot(
            local: local,
            remote: remote,
            reviewRequest: reviewRequest,
            providerAvailable: true,
            providerAuthenticated: true,
            providerCapabilities: providerCapabilities,
            errorMessage: nil
        )
    }

    private static func makeRemote(kind: CodeHostKind = .github) -> CodeHostRemote {
        CodeHostRemote(
            kind: kind,
            host: "\(kind.rawValue).com",
            owner: "mrmans0n",
            repository: "alas",
            remoteName: "origin",
            webURL: URL(string: "https://\(kind.rawValue).com/mrmans0n/alas")!
        )
    }

    private static func makeReviewRequest(
        remote: CodeHostRemote = makeRemote(),
        checks: [ReviewCheck] = []
    ) -> ReviewRequest {
        ReviewRequest(
            remote: remote,
            number: 42,
            title: "Review readiness",
            url: remote.webURL.appending(path: remote.kind == .github ? "pull/42" : "merge_requests/42"),
            state: .open,
            isDraft: false,
            headRefName: "feature/review-readiness",
            baseRefName: "main",
            reviewDecision: .reviewRequired,
            mergeState: .blocked,
            checks: checks,
            threads: []
        )
    }

    private static func makeCheck(bucket: ReviewCheckBucket) -> ReviewCheck {
        ReviewCheck(
            id: "ci-tests",
            name: "Tests",
            workflow: "CI",
            bucket: bucket,
            detailURL: nil,
            completedAt: nil
        )
    }
}
