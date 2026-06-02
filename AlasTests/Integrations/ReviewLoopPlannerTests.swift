import Foundation
import Testing
@testable import Alas

struct ReviewLoopPlannerTests {
    @Test func missingProviderCLIInstallsCLI() {
        let action = ReviewLoopPlanner().nextAction(
            snapshot: makeSnapshot(providerAvailable: false),
            sessionApproved: false
        )

        #expect(action.kind == .installProviderCLI)
    }

    @Test func unauthenticatedProviderAuthenticatesCLI() {
        let action = ReviewLoopPlanner().nextAction(
            snapshot: makeSnapshot(providerAuthenticated: false),
            sessionApproved: false
        )

        #expect(action.kind == .authenticateProvider)
    }

    @Test func unapprovedSessionStartsBeforePushOrCreateMutation() {
        let action = ReviewLoopPlanner().nextAction(
            snapshot: makeSnapshot(local: Self.makeLocal(needsPush: true), reviewRequest: nil),
            sessionApproved: false
        )

        #expect(action.kind == .startSession)
    }

    @Test func unapprovedSessionStartsBeforePushEvenWhenRequestExists() {
        let action = ReviewLoopPlanner().nextAction(
            snapshot: makeSnapshot(local: Self.makeLocal(needsPush: true), reviewRequest: Self.makeReviewRequest()),
            sessionApproved: false
        )

        #expect(action.kind == .startSession)
    }

    @Test func unapprovedSessionStartsBeforeCreateWhenBranchIsPushed() {
        let action = ReviewLoopPlanner().nextAction(
            snapshot: makeSnapshot(local: Self.makeLocal(needsPush: false), reviewRequest: nil),
            sessionApproved: false
        )

        #expect(action.kind == .startSession)
    }

    @Test func approvedSessionPushesBranchWhenNeeded() {
        let action = ReviewLoopPlanner().nextAction(
            snapshot: makeSnapshot(local: Self.makeLocal(needsPush: true), reviewRequest: nil),
            sessionApproved: true
        )

        #expect(action.kind == .pushBranch)
    }

    @Test func approvedSessionCreatesReviewRequestWhenBranchIsPushed() {
        let action = ReviewLoopPlanner().nextAction(
            snapshot: makeSnapshot(local: Self.makeLocal(needsPush: false), reviewRequest: nil),
            sessionApproved: true
        )

        #expect(action.kind == .createReviewRequest)
    }

    @Test func failedChecksPrepareCheckFailureHandoff() {
        let request = Self.makeReviewRequest(checks: [
            Self.makeCheck(id: "build-1", name: "Build", bucket: .fail),
        ])

        let action = ReviewLoopPlanner().nextAction(
            snapshot: makeSnapshot(reviewRequest: request),
            sessionApproved: true
        )

        #expect(action.kind == .prepareCheckFailureHandoff)
    }

    @Test func pendingChecksWaitForChecks() {
        let request = Self.makeReviewRequest(checks: [
            Self.makeCheck(id: "build-1", name: "Build", bucket: .pending),
        ])

        let action = ReviewLoopPlanner().nextAction(
            snapshot: makeSnapshot(reviewRequest: request),
            sessionApproved: true
        )

        #expect(action.kind == .waitForChecks)
    }

    @Test func cancelledChecksBlockManualAttention() {
        let request = Self.makeReviewRequest(checks: [
            Self.makeCheck(id: "build-1", name: "Build", bucket: .cancel),
        ])

        let action = ReviewLoopPlanner().nextAction(
            snapshot: makeSnapshot(reviewRequest: request),
            sessionApproved: true
        )

        #expect(action.kind == .blocked)
    }

    @Test func unknownChecksBlockManualAttention() {
        let request = Self.makeReviewRequest(checks: [
            Self.makeCheck(id: "build-1", name: "Build", bucket: .unknown),
        ])

        let action = ReviewLoopPlanner().nextAction(
            snapshot: makeSnapshot(reviewRequest: request),
            sessionApproved: true
        )

        #expect(action.kind == .blocked)
    }

    @Test func changesRequestedPreparesReviewHandoff() {
        let request = Self.makeReviewRequest(reviewDecision: .changesRequested)

        let action = ReviewLoopPlanner().nextAction(
            snapshot: makeSnapshot(reviewRequest: request),
            sessionApproved: true
        )

        #expect(action.kind == .prepareReviewHandoff)
    }

    @Test func reviewRequiredWaitsForReview() {
        let request = Self.makeReviewRequest(reviewDecision: .reviewRequired)

        let action = ReviewLoopPlanner().nextAction(
            snapshot: makeSnapshot(reviewRequest: request),
            sessionApproved: true
        )

        #expect(action.kind == .waitForReview)
    }

    @Test func approvedCleanRequestIsReadyToMerge() {
        let request = Self.makeReviewRequest(reviewDecision: .approved, mergeState: .clean)

        let action = ReviewLoopPlanner().nextAction(
            snapshot: makeSnapshot(reviewRequest: request),
            sessionApproved: true
        )

        #expect(action.kind == .readyToMerge)
    }

    @Test func nonCleanRequestBlocksForManualAttention() {
        let request = Self.makeReviewRequest(reviewDecision: .approved, mergeState: .blocked)

        let action = ReviewLoopPlanner().nextAction(
            snapshot: makeSnapshot(reviewRequest: request),
            sessionApproved: true
        )

        #expect(action.kind == .blocked)
    }

    @Test func nilSnapshotBlocksWhileCheckingReviewState() {
        let action = ReviewLoopPlanner().nextAction(snapshot: nil, sessionApproved: false)

        #expect(action.kind == .blocked)
        #expect(action.title.contains("Checking review state"))
    }

    @Test func errorSnapshotBlocksWithErrorDetail() {
        let action = ReviewLoopPlanner().nextAction(
            snapshot: makeSnapshot(errorMessage: "provider output was malformed"),
            sessionApproved: false
        )

        #expect(action.kind == .blocked)
        #expect(action.detail.contains("provider output was malformed"))
    }

    @Test func missingRemoteReturnsNoAction() {
        let action = ReviewLoopPlanner().nextAction(
            snapshot: makeSnapshot(remote: nil),
            sessionApproved: false
        )

        #expect(action.kind == .none)
    }

    private func makeSnapshot(
        local: ReviewLoopLocalState = makeLocal(),
        remote: CodeHostRemote? = makeRemote(),
        reviewRequest: ReviewRequest? = makeReviewRequest(),
        providerAvailable: Bool = true,
        providerAuthenticated: Bool = true,
        errorMessage: String? = nil
    ) -> ReviewLoopSnapshot {
        ReviewLoopSnapshot(
            local: local,
            remote: remote,
            reviewRequest: reviewRequest,
            providerAvailable: providerAvailable,
            providerAuthenticated: providerAuthenticated,
            providerCapabilities: remote == nil ? .readOnly : .githubCLI,
            errorMessage: errorMessage
        )
    }

    private static func makeLocal(needsPush: Bool = false) -> ReviewLoopLocalState {
        ReviewLoopLocalState(
            branchName: "feature/review-loop",
            headSHA: "abc123",
            baseBranch: "main",
            hasWorkingTreeChanges: false,
            hasStagedChanges: false,
            aheadCommitCount: needsPush ? 1 : 0,
            hasUpstream: true,
            needsPush: needsPush
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
        reviewDecision: ReviewDecision = .approved,
        mergeState: ReviewMergeState = .clean,
        checks: [ReviewCheck] = []
    ) -> ReviewRequest {
        ReviewRequest(
            remote: makeRemote(),
            number: 428,
            title: "Review loop",
            url: URL(string: "https://github.com/mrmans0n/alas/pull/428")!,
            state: .open,
            isDraft: false,
            headRefName: "feature/review-loop",
            baseRefName: "main",
            reviewDecision: reviewDecision,
            mergeState: mergeState,
            checks: checks,
            threads: []
        )
    }

    private static func makeCheck(id: String, name: String, bucket: ReviewCheckBucket) -> ReviewCheck {
        ReviewCheck(
            id: id,
            name: name,
            workflow: "ci",
            bucket: bucket,
            detailURL: nil,
            completedAt: nil
        )
    }
}
