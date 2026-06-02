import Foundation
import Testing
@testable import Alas

struct ReviewReadinessModelTests {
    @Test func unsupportedRemoteShowsReadOnlyBlockingState() {
        let model = ReviewReadinessModel(
            snapshot: Self.makeSnapshot(remote: nil, reviewRequest: nil, providerCapabilities: .readOnly),
            lastError: nil,
            canOpenAgentHandoff: false
        )

        #expect(model.identity == "Review readiness")
        #expect(model.chips.map(\ReviewReadinessModel.Chip.title) == ["No supported review host"])
        #expect(model.actions.map(\ReviewReadinessModel.Action.kind) == [ReviewReadinessActionKind.refresh])
        #expect(model.blockingText == "No supported review host")
    }

    @Test func unpushedBranchExposesPushActionWithoutSessionApproval() {
        let model = ReviewReadinessModel(
            snapshot: Self.makeSnapshot(local: Self.makeLocal(needsPush: true), reviewRequest: nil),
            lastError: nil,
            canOpenAgentHandoff: false
        )

        #expect(model.chips.map(\ReviewReadinessModel.Chip.title) == ["Unpushed"])
        #expect(model.actions.contains(Action(kind: .pushBranch, title: "Push", isEnabled: true)))
    }

    @Test func noGitHubRequestExposesCreatePR() {
        let model = ReviewReadinessModel(
            snapshot: Self.makeSnapshot(reviewRequest: nil),
            lastError: nil,
            canOpenAgentHandoff: false
        )

        #expect(model.chips.map(\ReviewReadinessModel.Chip.title) == ["No PR"])
        #expect(model.actions.contains(Action(kind: .createReviewRequest, title: "Create PR", isEnabled: true)))
    }

    @Test func noGitLabRequestExposesMRLabelsWhenCreateIsSupported() {
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

        #expect(model.identity == "GitLab")
        #expect(model.chips.map(\ReviewReadinessModel.Chip.title) == ["No MR"])
        #expect(model.actions.contains(Action(kind: .createReviewRequest, title: "Create MR", isEnabled: true)))
    }

    @Test func failedChecksExposeRerunAndAgentHandoffWhenSupported() {
        let request = Self.makeReviewRequest(checks: [Self.makeCheck(bucket: .fail)])
        let model = ReviewReadinessModel(
            snapshot: Self.makeSnapshot(reviewRequest: request),
            lastError: nil,
            canOpenAgentHandoff: true
        )

        #expect(model.chips.map(\ReviewReadinessModel.Chip.title) == ["CI failed"])
        #expect(model.actions.contains(Action(kind: .rerunFailedChecks, title: "Rerun", isEnabled: true)))
        #expect(model.actions.contains(Action(kind: .openAgentHandoff, title: "Open in Agent", isEnabled: true)))
    }

    @Test func failedChecksHideRerunForReadOnlyProviderButKeepAgentHandoff() {
        let request = Self.makeReviewRequest(checks: [Self.makeCheck(bucket: .fail)])
        let model = ReviewReadinessModel(
            snapshot: Self.makeSnapshot(reviewRequest: request, providerCapabilities: .readOnly),
            lastError: nil,
            canOpenAgentHandoff: true
        )

        #expect(model.chips.map(\ReviewReadinessModel.Chip.title) == ["CI failed"])
        #expect(!model.actions.map(\ReviewReadinessModel.Action.kind).contains(.rerunFailedChecks))
        #expect(model.actions.contains(Action(kind: .openAgentHandoff, title: "Open in Agent", isEnabled: true)))
    }

    @Test func changesRequestedExposesReviewFeedbackAndAgentHandoff() {
        let request = Self.makeReviewRequest(reviewDecision: .changesRequested)
        let model = ReviewReadinessModel(
            snapshot: Self.makeSnapshot(reviewRequest: request),
            lastError: nil,
            canOpenAgentHandoff: true
        )

        #expect(model.chips.map(\ReviewReadinessModel.Chip.title) == ["Review feedback"])
        #expect(model.actions.contains(Action(kind: .openAgentHandoff, title: "Open in Agent", isEnabled: true)))
    }

    @Test func approvedCleanRequestIsReadyWithoutMergeAction() {
        let request = Self.makeReviewRequest(reviewDecision: .approved, mergeState: .clean)
        let model = ReviewReadinessModel(
            snapshot: Self.makeSnapshot(reviewRequest: request),
            lastError: nil,
            canOpenAgentHandoff: true
        )

        #expect(model.chips.map(\ReviewReadinessModel.Chip.title) == ["Ready"])
        #expect(!model.actions.map(\ReviewReadinessModel.Action.kind).contains(.merge))
    }

    @Test func lastErrorBecomesBlockingTextWhileFactsStillIncludeBranch() {
        let model = ReviewReadinessModel(
            snapshot: Self.makeSnapshot(errorMessage: "provider failed"),
            lastError: "refresh failed",
            canOpenAgentHandoff: false
        )

        #expect(model.blockingText == "refresh failed")
        #expect(model.chips.map(\ReviewReadinessModel.Chip.title) == ["Needs attention"])
        #expect(model.actions.map(\ReviewReadinessModel.Action.kind) == [ReviewReadinessActionKind.refresh])
        #expect(model.facts.contains(Fact(id: "branch", label: "Branch", value: "feature/review-loop")))
    }

    private typealias Action = ReviewReadinessModel.Action
    private typealias Fact = ReviewReadinessModel.Fact

    private static func makeSnapshot(
        local: ReviewLoopLocalState = makeLocal(),
        remote: CodeHostRemote? = makeRemote(),
        reviewRequest: ReviewRequest? = makeReviewRequest(),
        providerAvailable: Bool = true,
        providerAuthenticated: Bool = true,
        providerCapabilities: CodeHostProviderCapabilities = .githubCLI,
        errorMessage: String? = nil
    ) -> ReviewLoopSnapshot {
        ReviewLoopSnapshot(
            local: local,
            remote: remote,
            reviewRequest: reviewRequest,
            providerAvailable: providerAvailable,
            providerAuthenticated: providerAuthenticated,
            providerCapabilities: providerCapabilities,
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
        remote: CodeHostRemote = makeRemote(),
        reviewDecision: ReviewDecision = .reviewRequired,
        mergeState: ReviewMergeState = .blocked,
        checks: [ReviewCheck] = [],
        threads: [ReviewThreadSummary] = []
    ) -> ReviewRequest {
        ReviewRequest(
            remote: remote,
            number: 428,
            title: "Review loop",
            url: remote.webURL.appending(path: remote.kind == .github ? "pull/428" : "merge_requests/428"),
            state: .open,
            isDraft: false,
            headRefName: "feature/review-loop",
            baseRefName: "main",
            reviewDecision: reviewDecision,
            mergeState: mergeState,
            checks: checks,
            threads: threads
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
