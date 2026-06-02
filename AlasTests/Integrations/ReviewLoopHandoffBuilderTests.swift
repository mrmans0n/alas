import Foundation
import Testing
@testable import Alas

struct ReviewLoopHandoffBuilderTests {
    @Test func failingCheckPromptIncludesBoundedProviderContext() {
        let request = Self.makeReviewRequest(
            checks: [
                ReviewCheck(
                    id: "ci-tests",
                    name: "Tests",
                    workflow: "CI",
                    bucket: .fail,
                    detailURL: URL(string: "https://github.com/run")!,
                    completedAt: nil
                ),
            ]
        )
        let snapshot = Self.makeSnapshot(request: request)
        let prompt = ReviewLoopHandoffBuilder.build(
            snapshot: snapshot,
            action: ReviewLoopAction(
                kind: .prepareCheckFailureHandoff,
                title: "Ask agent",
                detail: "CI failed"
            )
        )

        #expect(prompt.contains("GitHub PR: https://github.com/mrmans0n/alas/pull/428"))
        #expect(prompt.contains("Failing check: Tests"))
        #expect(prompt.contains("Workflow: CI"))
        #expect(prompt.contains("Branch: feature/review-loop"))
        #expect(prompt.count < 5_000)
    }

    @Test func failedChecksWinOverReviewFeedbackWhenChoosingHandoffPromptKind() {
        let request = Self.makeReviewRequest(
            reviewDecision: .changesRequested,
            checks: [
                ReviewCheck(
                    id: "ci-tests",
                    name: "Tests",
                    workflow: "CI",
                    bucket: .fail,
                    detailURL: nil,
                    completedAt: nil
                ),
            ]
        )

        #expect(AppState.reviewLoopHandoffActionKind(for: request) == .prepareCheckFailureHandoff)
    }

    @Test func gitlabPromptUsesMRLabel() {
        let remote = Self.makeRemote(kind: .gitlab)
        let request = Self.makeReviewRequest(
            remote: remote,
            url: URL(string: "https://gitlab.com/mrmans0n/alas/merge_requests/428")!
        )
        let prompt = ReviewLoopHandoffBuilder.build(
            snapshot: Self.makeSnapshot(request: request),
            action: ReviewLoopAction(
                kind: .prepareReviewHandoff,
                title: "Ask agent",
                detail: "Review feedback"
            )
        )

        #expect(prompt.contains("GitLab MR: https://gitlab.com/mrmans0n/alas/merge_requests/428"))
        #expect(!prompt.contains("GitLab PR:"))
    }

    @Test func reviewPromptIncludesOnlyActionableThreadSummaries() {
        let request = Self.makeReviewRequest(
            reviewDecision: .changesRequested,
            threads: [
                ReviewThreadSummary(
                    id: "thread-2",
                    author: "reviewer",
                    body: "Resolved already.",
                    url: nil,
                    isResolved: true,
                    isActionable: true
                ),
                ReviewThreadSummary(
                    id: "thread-3",
                    author: nil,
                    body: "FYI only.",
                    url: nil,
                    isResolved: false,
                    isActionable: false
                ),
                ReviewThreadSummary(
                    id: "thread-4",
                    author: "reviewer",
                    body: "Also FYI only.",
                    url: nil,
                    isResolved: false,
                    isActionable: false
                ),
                ReviewThreadSummary(
                    id: "thread-1",
                    author: "reviewer",
                    body: "Please simplify this.",
                    url: nil,
                    isResolved: false,
                    isActionable: true
                ),
            ]
        )
        let prompt = ReviewLoopHandoffBuilder.build(
            snapshot: Self.makeSnapshot(request: request),
            action: ReviewLoopAction(
                kind: .prepareReviewHandoff,
                title: "Ask agent",
                detail: "Review feedback"
            )
        )

        #expect(prompt.contains("Review decision: changesRequested"))
        #expect(prompt.contains("- reviewer: Please simplify this."))
        #expect(!prompt.contains("Resolved already."))
        #expect(!prompt.contains("FYI only."))
        #expect(!prompt.contains("Also FYI only."))
    }

    @Test func promptWithoutRequestFallsBackToLocalContext() {
        let prompt = ReviewLoopHandoffBuilder.build(
            snapshot: Self.makeSnapshot(request: nil),
            action: ReviewLoopAction(
                kind: .blocked,
                title: "Blocked",
                detail: "Provider unavailable"
            )
        )

        #expect(prompt.contains("Branch: feature/review-loop"))
        #expect(prompt.contains("Base: main"))
        #expect(prompt.contains("State: Provider unavailable"))
    }

    @Test func longReviewPromptIsTruncated() {
        let title = String(repeating: "Review note ", count: 1_000)
        let request = Self.makeReviewRequest(
            title: title,
            reviewDecision: .changesRequested,
            threads: [
                ReviewThreadSummary(
                    id: "thread-1",
                    author: "reviewer",
                    body: "Please update this.",
                    url: nil,
                    isResolved: false,
                    isActionable: true
                ),
            ]
        )

        let prompt = ReviewLoopHandoffBuilder.build(
            snapshot: Self.makeSnapshot(request: request),
            action: ReviewLoopAction(
                kind: .prepareReviewHandoff,
                title: "Ask agent",
                detail: "Review feedback"
            )
        )

        #expect(prompt.count <= 4_540)
        #expect(prompt.contains("[Context truncated by Alas.]"))
    }

    private static func makeSnapshot(request: ReviewRequest?) -> ReviewLoopSnapshot {
        ReviewLoopSnapshot(
            local: ReviewLoopLocalState(
                branchName: "feature/review-loop",
                headSHA: "abc",
                baseBranch: "main",
                hasWorkingTreeChanges: false,
                hasStagedChanges: false,
                aheadCommitCount: 2,
                hasUpstream: true,
                needsPush: false
            ),
            remote: request?.remote ?? Self.makeRemote(),
            reviewRequest: request,
            providerAvailable: true,
            providerAuthenticated: true,
            providerCapabilities: .githubCLI,
            errorMessage: nil
        )
    }

    private static func makeReviewRequest(
        remote: CodeHostRemote = makeRemote(),
        title: String = "Review loop",
        url: URL? = nil,
        reviewDecision: ReviewDecision = .reviewRequired,
        checks: [ReviewCheck] = [],
        threads: [ReviewThreadSummary] = []
    ) -> ReviewRequest {
        return ReviewRequest(
            remote: remote,
            number: 428,
            title: title,
            url: url ?? URL(string: "https://github.com/mrmans0n/alas/pull/428")!,
            state: .open,
            isDraft: false,
            headRefName: "feature/review-loop",
            baseRefName: "main",
            reviewDecision: reviewDecision,
            mergeState: .blocked,
            checks: checks,
            threads: threads
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
}
