import Foundation
import Testing
@testable import Alas

struct ReviewLoopDrawerTests {
    @Test func statusTextShowsNoPRForCreateAction() {
        let action = ReviewLoopAction(
            kind: .createReviewRequest,
            title: "Create PR",
            detail: "Open a PR"
        )

        let text = ReviewLoopDrawerModel.statusText(request: nil, action: action)

        #expect(text == "No PR")
    }

    @Test func statusTextShowsFailedChecks() {
        let action = ReviewLoopAction(
            kind: .prepareCheckFailureHandoff,
            title: "Ask agent",
            detail: "CI failed"
        )

        let text = ReviewLoopDrawerModel.statusText(request: nil, action: action)

        #expect(text == "CI failed")
    }

    @Test func collapsedIdentityFallsBackToProvider() {
        #expect(ReviewLoopDrawerModel.identityText(request: nil, remoteKind: .github) == "GitHub")
    }

    @Test func collapsedHeaderTextIsUppercase() {
        #expect(ReviewLoopDrawerModel.headerText(request: nil, remoteKind: .github) == "GITHUB")
    }

    @Test func collapsedIdentityUsesReviewRequestWhenPresent() {
        let request = Self.makeReviewRequest()

        #expect(ReviewLoopDrawerModel.identityText(request: request, remoteKind: .gitlab) == "GitHub #42")
    }

    @Test func primaryButtonTitleMatchesActionKind() {
        #expect(ReviewLoopDrawerModel.primaryButtonTitle(for: .startSession) == "Start")
        #expect(ReviewLoopDrawerModel.primaryButtonTitle(for: .prepareReviewHandoff) == "Open in agent")
        #expect(ReviewLoopDrawerModel.primaryButtonTitle(for: .authenticateProvider) == "How to auth")
        #expect(ReviewLoopDrawerModel.primaryButtonTitle(for: .readyToMerge) == "Merge")
    }

    @Test func detailTextPrefersLastError() {
        let action = ReviewLoopAction(
            kind: .createReviewRequest,
            title: "Create review request",
            detail: "Open a review request"
        )

        #expect(ReviewLoopDrawerModel.detailText(action: action, lastError: nil) == "Open a review request")
        #expect(ReviewLoopDrawerModel.detailText(action: action, lastError: "create failed") == "create failed")
    }

    @Test func waitActionsDisablePrimaryButton() {
        #expect(ReviewLoopDrawerModel.isPrimaryActionEnabled(.waitForChecks) == false)
        #expect(ReviewLoopDrawerModel.isPrimaryActionEnabled(.waitForReview) == false)
        #expect(ReviewLoopDrawerModel.isPrimaryActionEnabled(.none) == false)
        #expect(ReviewLoopDrawerModel.isPrimaryActionEnabled(.startSession))
    }

    @Test func approvedRemoteActionsAreEnabled() {
        #expect(ReviewLoopDrawerModel.isPrimaryActionEnabled(.pushBranch))
        #expect(ReviewLoopDrawerModel.isPrimaryActionEnabled(.createReviewRequest))
        #expect(ReviewLoopDrawerModel.isPrimaryActionEnabled(.rerunFailedChecks))
    }

    @Test func handoffPrimaryActionsAreEnabled() {
        #expect(ReviewLoopDrawerModel.isPrimaryActionEnabled(.prepareCheckFailureHandoff))
        #expect(ReviewLoopDrawerModel.isPrimaryActionEnabled(.prepareReviewHandoff))
    }

    @Test func handoffPrimaryActionsRequireAvailableAgent() {
        #expect(ReviewLoopDrawerModel.isPrimaryActionEnabled(
            .prepareCheckFailureHandoff,
            canOpenAgentHandoff: false
        ) == false)
        #expect(ReviewLoopDrawerModel.isPrimaryActionEnabled(
            .prepareReviewHandoff,
            canOpenAgentHandoff: false
        ) == false)
    }

    @Test func unimplementedPrimaryActionsAreDisabled() {
        #expect(ReviewLoopDrawerModel.isPrimaryActionEnabled(.blocked) == false)
        #expect(ReviewLoopDrawerModel.isPrimaryActionEnabled(.readyToMerge) == false)
    }

    private static func makeReviewRequest() -> ReviewRequest {
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
            number: 42,
            title: "Review loop",
            url: URL(string: "https://github.com/mrmans0n/alas/pull/42")!,
            state: .open,
            isDraft: false,
            headRefName: "feature/review-loop",
            baseRefName: "main",
            reviewDecision: .reviewRequired,
            mergeState: .clean,
            checks: [],
            threads: []
        )
    }
}
