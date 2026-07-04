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
        #expect(model.chips.map(\ReviewReadinessModel.Chip.tone) == [.muted])
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
        #expect(model.chips.map(\ReviewReadinessModel.Chip.tone) == [.accent])
        #expect(model.actions.contains(Action(kind: .pushBranch, title: "Push", isEnabled: true)))
        #expect(!model.actions.map(\.kind).contains(.createReviewRequest))
    }

    @Test func inFlightActionDisablesReadinessActionsAndMarksRunningAction() throws {
        let model = ReviewReadinessModel(
            snapshot: Self.makeSnapshot(local: Self.makeLocal(needsPush: true), reviewRequest: nil),
            lastError: nil,
            canOpenAgentHandoff: false,
            inFlightAction: .pushBranch
        )

        let push = try #require(model.actions.first { $0.kind == .pushBranch })
        #expect(push.isInFlight)
        #expect(!push.isEnabled)
        #expect(model.actions.allSatisfy { !$0.isEnabled })
    }

    @Test func divergedBranchExposesForcePushInsteadOfNormalPush() {
        let model = ReviewReadinessModel(
            snapshot: Self.makeSnapshot(local: Self.makeLocal(needsPush: true, upstreamAheadCommitCount: 3), reviewRequest: nil),
            lastError: nil,
            canOpenAgentHandoff: false
        )

        #expect(model.chips.map(\ReviewReadinessModel.Chip.title) == ["Remote diverged"])
        #expect(model.chips.map(\ReviewReadinessModel.Chip.tone) == [.warning])
        #expect(model.blockingText == "Remote has commits not in this branch. Pull, rebase, or force push from the terminal if intentional.")
        #expect(!model.actions.map(\.kind).contains(.forcePushBranch))
        #expect(!model.actions.map(\.kind).contains(.pushBranch))
        #expect(!model.actions.map(\.kind).contains(.createReviewRequest))
    }

    @Test func staleBranchBlocksReviewActions() {
        let model = ReviewReadinessModel(
            snapshot: Self.makeSnapshot(local: Self.makeLocal(needsPush: false, upstreamAheadCommitCount: 2), reviewRequest: nil),
            lastError: nil,
            canOpenAgentHandoff: false
        )

        #expect(model.chips.map(\ReviewReadinessModel.Chip.title) == ["Remote ahead"])
        #expect(model.chips.map(\ReviewReadinessModel.Chip.tone) == [.warning])
        #expect(model.blockingText == "Remote has commits not in this branch. Pull or rebase before using review actions.")
        #expect(model.actions.map(\.kind) == [ReviewReadinessActionKind.refresh])
    }

    @Test func noGitHubRequestExposesCreatePR() {
        let model = ReviewReadinessModel(
            snapshot: Self.makeSnapshot(reviewRequest: nil),
            lastError: nil,
            canOpenAgentHandoff: false
        )

        #expect(model.chips.map(\ReviewReadinessModel.Chip.title) == ["No PR"])
        #expect(model.chips.map(\ReviewReadinessModel.Chip.tone) == [.muted])
        #expect(model.actions == [Action(kind: .createReviewRequest, title: "Create PR", isEnabled: true)])
    }

    @Test func noRequestOnBaseBranchSuppressesCreatePR() {
        let model = ReviewReadinessModel(
            snapshot: Self.makeSnapshot(
                local: Self.makeLocal(branchName: "main", baseBranch: "main", aheadCommitCount: 1),
                reviewRequest: nil
            ),
            lastError: nil,
            canOpenAgentHandoff: false
        )

        #expect(model.chips.map(\ReviewReadinessModel.Chip.title) == ["No PR"])
        #expect(model.actions.map(\.kind) == [ReviewReadinessActionKind.refresh])
    }

    @Test func remoteQualifiedBaseBranchSuppressesCreatePROnMatchingBranch() {
        let model = ReviewReadinessModel(
            snapshot: Self.makeSnapshot(
                local: Self.makeLocal(branchName: "main", baseBranch: "origin/main", aheadCommitCount: 1),
                reviewRequest: nil
            ),
            lastError: nil,
            canOpenAgentHandoff: false
        )

        #expect(model.actions.map(\.kind) == [ReviewReadinessActionKind.refresh])
    }

    @Test func noAheadCommitsSuppressesCreatePR() {
        let model = ReviewReadinessModel(
            snapshot: Self.makeSnapshot(
                local: Self.makeLocal(aheadCommitCount: 0),
                reviewRequest: nil
            ),
            lastError: nil,
            canOpenAgentHandoff: false
        )

        #expect(model.chips.map(\ReviewReadinessModel.Chip.title) == ["No PR"])
        #expect(model.actions.map(\.kind) == [ReviewReadinessActionKind.refresh])
    }

    @Test func noGitLabRequestExposesMRLabelsWhenCreateIsSupported() {
        let remote = Self.makeRemote(kind: .gitlab)
        let capabilities = CodeHostProviderCapabilities(
            canCreateReviewRequest: true,
            canRerunFailedChecks: false,
            canOpenReviewRequest: true,
            canReply: true,
            canResolve: true,
            canComment: true,
            canSubmitReview: true,
            canFetchAnnotations: false,
            canEditComment: true,
            canDeleteComment: true,
            canMerge: true
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

    @Test func failedChecksExposeRerunAndInspectWhenSupported() {
        let request = Self.makeReviewRequest(checks: [Self.makeCheck(bucket: .fail)])
        let model = ReviewReadinessModel(
            snapshot: Self.makeSnapshot(reviewRequest: request),
            lastError: nil,
            canOpenAgentHandoff: true
        )

        #expect(model.chips.map(\ReviewReadinessModel.Chip.title) == ["CI failed"])
        #expect(model.chips.map(\ReviewReadinessModel.Chip.tone) == [.danger])
        #expect(model.actions.contains(Action(kind: .rerunFailedChecks, title: "Rerun", isEnabled: true)))
        #expect(model.actions.contains(Action(kind: .inspectReviewEvidence, title: "Inspect", isEnabled: true)))
        #expect(!model.actions.map(\.kind).contains(.openAgentHandoff))
    }

    @Test func failedChecksHideRerunForReadOnlyProviderButKeepInspect() {
        let request = Self.makeReviewRequest(checks: [Self.makeCheck(bucket: .fail)])
        let model = ReviewReadinessModel(
            snapshot: Self.makeSnapshot(reviewRequest: request, providerCapabilities: .readOnly),
            lastError: nil,
            canOpenAgentHandoff: true
        )

        #expect(model.chips.map(\ReviewReadinessModel.Chip.title) == ["CI failed"])
        #expect(!model.actions.map(\ReviewReadinessModel.Action.kind).contains(.rerunFailedChecks))
        #expect(model.actions.contains(Action(kind: .inspectReviewEvidence, title: "Inspect", isEnabled: true)))
        #expect(!model.actions.map(\.kind).contains(.openAgentHandoff))
    }

    @Test func externalFailedChecksHideRerunButKeepInspect() {
        let externalCheck = ReviewCheck(
            id: "buildkite",
            name: "Buildkite",
            workflow: nil,
            bucket: .fail,
            detailURL: URL(string: "https://buildkite.com/mrmans0n/alas/builds/42"),
            completedAt: nil
        )
        let request = Self.makeReviewRequest(checks: [externalCheck])
        let model = ReviewReadinessModel(
            snapshot: Self.makeSnapshot(reviewRequest: request),
            lastError: nil,
            canOpenAgentHandoff: true
        )

        #expect(model.chips.map(\ReviewReadinessModel.Chip.title) == ["CI failed"])
        #expect(!model.actions.map(\ReviewReadinessModel.Action.kind).contains(.rerunFailedChecks))
        #expect(model.actions.contains(Action(kind: .inspectReviewEvidence, title: "Inspect", isEnabled: true)))
        #expect(!model.actions.map(\.kind).contains(.openAgentHandoff))
    }

    @Test func changesRequestedExposesReviewFeedbackAndInspect() {
        let request = Self.makeReviewRequest(reviewDecision: .changesRequested)
        let model = ReviewReadinessModel(
            snapshot: Self.makeSnapshot(reviewRequest: request),
            lastError: nil,
            canOpenAgentHandoff: true
        )

        #expect(model.chips.map(\ReviewReadinessModel.Chip.title) == ["Review feedback"])
        #expect(model.chips.map(\ReviewReadinessModel.Chip.tone) == [.warning])
        #expect(model.actions.contains(Action(kind: .inspectReviewEvidence, title: "Inspect", isEnabled: true)))
        #expect(!model.actions.map(\.kind).contains(.openAgentHandoff))
    }

    @Test func actionableReviewThreadExposesInspect() {
        let thread = ReviewThread(
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
                    body: "Please adjust this",
                    url: URL(string: "https://github.com/mrmans0n/alas/pull/428#discussion_r1"),
                    createdAt: nil,
                    viewerCanUpdate: false,
                    viewerCanDelete: false,
                    isPending: false
                ),
            ],
            viewerCanResolve: false,
            viewerCanReply: false,
            url: URL(string: "https://github.com/mrmans0n/alas/pull/428#discussion_r1")
        )
        let request = Self.makeReviewRequest(threads: [thread])
        let model = ReviewReadinessModel(
            snapshot: Self.makeSnapshot(reviewRequest: request),
            lastError: nil,
            canOpenAgentHandoff: false
        )

        #expect(model.chips.map(\ReviewReadinessModel.Chip.title) == ["Review feedback"])
        #expect(model.actions.contains(Action(kind: .inspectReviewEvidence, title: "Inspect", isEnabled: true)))
        #expect(!model.actions.map(\.kind).contains(.openAgentHandoff))
    }

    @Test func approvedCleanRequestExposesMergeAction() {
        let request = Self.makeReviewRequest(reviewDecision: .approved, mergeState: .clean)
        let model = ReviewReadinessModel(
            snapshot: Self.makeSnapshot(reviewRequest: request),
            lastError: nil,
            canOpenAgentHandoff: true
        )

        #expect(model.chips.map(\ReviewReadinessModel.Chip.title) == ["Ready"])
        #expect(model.chips.map(\ReviewReadinessModel.Chip.tone) == [.success])
        #expect(model.actions.map(\ReviewReadinessModel.Action.kind).contains(.merge))
        #expect(!model.actions.map(\ReviewReadinessModel.Action.kind).contains(.refresh))
    }

    @Test func greenMergeableRequestExposesMergeAndReviewDiff() {
        let request = Self.makeReviewRequest(
            reviewDecision: .approved,
            mergeState: .clean,
            checks: [Self.makeCheck(bucket: .pass)]
        )
        let model = ReviewReadinessModel(
            snapshot: Self.makeSnapshot(reviewRequest: request),
            lastError: nil,
            canOpenAgentHandoff: false
        )

        let merge = model.actions.first { $0.kind == .merge }
        #expect(merge?.title == "Merge PR")
        #expect(merge?.emphasis == .primary)
        #expect(merge?.isEnabled == true)

        let review = model.actions.first { $0.kind == .inspectReviewEvidence }
        #expect(review?.title == "Review diff")
        #expect(review?.emphasis == .normal)
    }

    @Test func blockedRequestDoesNotExposeMerge() {
        let request = Self.makeReviewRequest(
            mergeState: .blocked,
            checks: [Self.makeCheck(bucket: .pass)]
        )
        let model = ReviewReadinessModel(
            snapshot: Self.makeSnapshot(reviewRequest: request),
            lastError: nil,
            canOpenAgentHandoff: false
        )
        #expect(!model.actions.map(\.kind).contains(.merge))
    }

    @Test func actionableFeedbackSuppressesMergeOnGreenPR() {
        // Green + mergeable, but a reviewer has requested changes. Even in a
        // repo that doesn't enforce reviews as a merge block (mergeState stays
        // clean), in-app merge must not bypass the open feedback.
        let request = Self.makeReviewRequest(
            reviewDecision: .changesRequested,
            mergeState: .clean,
            checks: [Self.makeCheck(bucket: .pass)]
        )
        let snapshot = Self.makeSnapshot(reviewRequest: request)
        let model = ReviewReadinessModel(
            snapshot: snapshot,
            lastError: nil,
            canOpenAgentHandoff: false
        )
        #expect(!model.actions.map(\.kind).contains(.merge))
        #expect(!ReviewReadinessModel.canMergeReviewRequest(snapshot: snapshot))
        // Falls through to the feedback-inspection affordance instead.
        #expect(model.actions.contains(Action(kind: .inspectReviewEvidence, title: "Inspect", isEnabled: true)))
    }

    @Test func unpushedLocalCommitsSuppressMergeEvenWhenPRIsGreen() {
        let request = Self.makeReviewRequest(
            reviewDecision: .approved,
            mergeState: .clean,
            checks: [Self.makeCheck(bucket: .pass)]
        )
        let snapshot = Self.makeSnapshot(
            local: Self.makeLocal(needsPush: true),
            reviewRequest: request
        )
        let model = ReviewReadinessModel(
            snapshot: snapshot,
            lastError: nil,
            canOpenAgentHandoff: false
        )
        // Local head is ahead of what the green PR reviewed — merging now
        // would ship the old head and delete the branch, dropping the
        // unpushed commits. The gate (shared with the Inspect-tab button and
        // the merge handler) must suppress merge here.
        #expect(!model.actions.map(\.kind).contains(.merge))
        #expect(!ReviewReadinessModel.canMergeReviewRequest(snapshot: snapshot))
    }

    @Test func pendingChecksDoNotExposeMerge() {
        let request = Self.makeReviewRequest(
            mergeState: .clean,
            checks: [Self.makeCheck(bucket: .pending)]
        )
        let model = ReviewReadinessModel(
            snapshot: Self.makeSnapshot(reviewRequest: request),
            lastError: nil,
            canOpenAgentHandoff: false
        )
        #expect(!model.actions.map(\.kind).contains(.merge))
    }

    @Test func mergeHiddenWhenCapabilityMissing() {
        let request = Self.makeReviewRequest(mergeState: .clean, checks: [Self.makeCheck(bucket: .pass)])
        let model = ReviewReadinessModel(
            snapshot: Self.makeSnapshot(reviewRequest: request, providerCapabilities: .readOnly),
            lastError: nil,
            canOpenAgentHandoff: false
        )
        #expect(!model.actions.map(\.kind).contains(.merge))
    }

    @Test func pendingChecksKeepRefreshAsFallback() {
        let request = Self.makeReviewRequest(checks: [Self.makeCheck(bucket: .pending)])
        let model = ReviewReadinessModel(
            snapshot: Self.makeSnapshot(reviewRequest: request),
            lastError: nil,
            canOpenAgentHandoff: false
        )

        #expect(model.chips.map(\ReviewReadinessModel.Chip.title) == ["Checks running"])
        #expect(model.actions.map(\ReviewReadinessModel.Action.kind).contains(.refresh))
    }

    @Test func actionsExposeCompactPresentationForDrawerButtons() {
        let unpushed = ReviewReadinessModel(
            snapshot: Self.makeSnapshot(local: Self.makeLocal(needsPush: true), reviewRequest: nil),
            lastError: nil,
            canOpenAgentHandoff: false
        )
        let push = unpushed.actions.first { $0.kind == .pushBranch }
        #expect(push?.iconName == "arrow.up")
        #expect(push?.emphasis == .primary)

        let noRequest = ReviewReadinessModel(
            snapshot: Self.makeSnapshot(reviewRequest: nil),
            lastError: nil,
            canOpenAgentHandoff: false
        )
        let create = noRequest.actions.first { $0.kind == .createReviewRequest }
        #expect(create?.iconName == "plus")
        #expect(create?.emphasis == .primary)

        let failedChecks = ReviewReadinessModel(
            snapshot: Self.makeSnapshot(reviewRequest: Self.makeReviewRequest(checks: [Self.makeCheck(bucket: .fail)])),
            lastError: nil,
            canOpenAgentHandoff: true
        )
        let actions = Dictionary(uniqueKeysWithValues: failedChecks.actions.map { ($0.kind, $0) })
        #expect(actions[.openReviewRequest]?.iconName == "arrow.up.right.square")
        #expect(actions[.openReviewRequest]?.emphasis == .normal)
        #expect(actions[.rerunFailedChecks]?.iconName == "arrow.clockwise")
        #expect(actions[.rerunFailedChecks]?.emphasis == .normal)
        #expect(actions[.inspectReviewEvidence]?.iconName == "doc.text.magnifyingglass")
        #expect(actions[.inspectReviewEvidence]?.emphasis == .primary)
        #expect(actions[.openAgentHandoff] == nil)
    }

    @Test func lastErrorBecomesBlockingTextWhileFactsStillIncludeBranch() {
        let model = ReviewReadinessModel(
            snapshot: Self.makeSnapshot(errorMessage: "provider failed"),
            lastError: "refresh failed",
            canOpenAgentHandoff: false
        )

        #expect(model.blockingText == "refresh failed")
        #expect(model.chips.map(\ReviewReadinessModel.Chip.title) == ["Needs attention"])
        #expect(model.chips.map(\ReviewReadinessModel.Chip.tone) == [.warning])
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

    private static func makeLocal(
        branchName: String = "feature/review-loop",
        baseBranch: String = "main",
        needsPush: Bool = false,
        upstreamAheadCommitCount: Int = 0,
        aheadCommitCount: Int = 1
    ) -> ReviewLoopLocalState {
        ReviewLoopLocalState(
            branchName: branchName,
            headSHA: "abc123",
            baseBranch: baseBranch,
            hasWorkingTreeChanges: false,
            hasStagedChanges: false,
            aheadCommitCount: aheadCommitCount,
            hasUpstream: true,
            upstreamAheadCommitCount: upstreamAheadCommitCount,
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
        threads: [ReviewThread] = []
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
