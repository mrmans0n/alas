import Foundation

struct ReviewLoopPlanner: Sendable {
    func nextAction(snapshot: ReviewLoopSnapshot?, sessionApproved: Bool) -> ReviewLoopAction {
        guard let snapshot else {
            return ReviewLoopAction(
                kind: .blocked,
                title: "Checking review state",
                detail: "Review state is still loading."
            )
        }

        if let errorMessage = snapshot.errorMessage {
            return ReviewLoopAction(
                kind: .blocked,
                title: "Review state unavailable",
                detail: "Could not inspect review state: \(errorMessage)"
            )
        }

        guard let remote = snapshot.remote else {
            return ReviewLoopAction(
                kind: .none,
                title: "No supported remote",
                detail: "This branch is not connected to a supported code host remote."
            )
        }

        let providerName = remote.kind.displayName

        guard snapshot.providerAvailable else {
            return ReviewLoopAction(
                kind: .installProviderCLI,
                title: "Install \(providerName) CLI",
                detail: "\(providerName) command line tooling is required before review loop actions can continue."
            )
        }

        guard snapshot.providerAuthenticated else {
            return ReviewLoopAction(
                kind: .authenticateProvider,
                title: "Authenticate \(providerName)",
                detail: "Sign in to \(providerName) before checking or updating review requests."
            )
        }

        let needsRemoteMutation = snapshot.local.needsPush || snapshot.reviewRequest == nil
        if needsRemoteMutation && !sessionApproved {
            return ReviewLoopAction(
                kind: .startSession,
                title: "Start review session",
                detail: "Approve a session before pushing the branch or creating a review request."
            )
        }

        if snapshot.local.needsPush && sessionApproved {
            return ReviewLoopAction(
                kind: .pushBranch,
                title: "Push branch",
                detail: "Push \(snapshot.local.branchName) to \(providerName) before continuing."
            )
        }

        guard let request = snapshot.reviewRequest else {
            return ReviewLoopAction(
                kind: .createReviewRequest,
                title: "Create review request",
                detail: "Open a review request for \(snapshot.local.branchName) on \(providerName)."
            )
        }

        switch request.worstCheckBucket {
        case .fail:
            return ReviewLoopAction(
                kind: .prepareCheckFailureHandoff,
                title: "Fix failed checks",
                detail: "\(request.displayIdentity) has failing checks that need a handoff."
            )
        case .pending:
            return ReviewLoopAction(
                kind: .waitForChecks,
                title: "Wait for checks",
                detail: "\(request.displayIdentity) still has checks in progress."
            )
        case .cancel, .unknown:
            return ReviewLoopAction(
                kind: .blocked,
                title: "Manual attention required",
                detail: "\(request.displayIdentity) has checks in a state that needs manual attention."
            )
        case .pass, .skipping, nil:
            break
        }

        if request.hasActionableFeedback {
            return ReviewLoopAction(
                kind: .prepareReviewHandoff,
                title: "Address review feedback",
                detail: "\(request.displayIdentity) has actionable review feedback."
            )
        }

        if request.reviewDecision == .reviewRequired {
            return ReviewLoopAction(
                kind: .waitForReview,
                title: "Wait for review",
                detail: "\(request.displayIdentity) is waiting for reviewer approval."
            )
        }

        if request.reviewDecision == .approved, request.mergeState == .clean {
            return ReviewLoopAction(
                kind: .readyToMerge,
                title: "Ready to merge",
                detail: "\(request.displayIdentity) is approved and has a clean merge state."
            )
        }

        return ReviewLoopAction(
            kind: .blocked,
            title: "Manual attention required",
            detail: "\(request.displayIdentity) needs manual attention before the review loop can continue."
        )
    }
}
