import Testing
import Foundation
@testable import Alas

struct CodeHostModelsTests {
    @Test func checkBucketSeverityOrdersFailuresBeforePendingBeforePass() {
        #expect(ReviewCheckBucket.fail.severity > ReviewCheckBucket.pending.severity)
        #expect(ReviewCheckBucket.pending.severity > ReviewCheckBucket.pass.severity)
        #expect(ReviewCheckBucket.pass.severity > ReviewCheckBucket.skipping.severity)
    }

    @Test func reviewRequestDisplayIdentityUsesProviderAndNumber() {
        let request = makeReviewRequest(reviewDecision: .reviewRequired)

        #expect(request.displayIdentity == "GitHub #428")
    }

    @Test func codeHostKindUsesProviderNativeReviewRequestLabels() {
        #expect(CodeHostKind.github.reviewRequestLabel == "PR")
        #expect(CodeHostKind.github.reviewRequestNumberPrefix == "#")
        #expect(CodeHostKind.github.createReviewRequestTitle == "Create PR")
        #expect(CodeHostKind.github.openReviewRequestTitle == "Open PR")

        #expect(CodeHostKind.gitlab.reviewRequestLabel == "MR")
        #expect(CodeHostKind.gitlab.reviewRequestNumberPrefix == "!")
        #expect(CodeHostKind.gitlab.createReviewRequestTitle == "Create MR")
        #expect(CodeHostKind.gitlab.openReviewRequestTitle == "Open MR")
    }

    @Test func reviewRequestDisplayIdentityUsesProviderNativeNumberPrefix() {
        let gitlabRemote = CodeHostRemote(
            kind: .gitlab,
            host: "gitlab.com",
            owner: "mrmans0n",
            repository: "alas",
            remoteName: "origin",
            webURL: URL(string: "https://gitlab.com/mrmans0n/alas")!
        )
        let request = makeReviewRequest(remote: gitlabRemote)

        #expect(request.displayIdentity == "GitLab !428")
    }

    @Test func providerCapabilitiesDefaultToSafeReadOnlyValues() {
        let capabilities = CodeHostProviderCapabilities.readOnly

        #expect(capabilities.canCreateReviewRequest == false)
        #expect(capabilities.canRerunFailedChecks == false)
        #expect(capabilities.canOpenReviewRequest == true)
    }

    @Test func remoteAheadOnlyBranchIsStale() {
        let local = ReviewLoopLocalState(
            branchName: "feature/review-loop",
            headSHA: "abc123",
            baseBranch: "main",
            hasWorkingTreeChanges: false,
            hasStagedChanges: false,
            aheadCommitCount: 0,
            hasUpstream: true,
            upstreamAheadCommitCount: 2,
            needsPush: false
        )

        #expect(local.pushState == .stale)
    }

    @Test func reviewRequiredWithoutActionableThreadsHasNoActionableFeedback() {
        let request = makeReviewRequest(reviewDecision: .reviewRequired)

        #expect(request.hasActionableFeedback == false)
    }

    @Test func changesRequestedHasActionableFeedback() {
        let request = makeReviewRequest(reviewDecision: .changesRequested)

        #expect(request.hasActionableFeedback)
    }

    @Test func actionableThreadHasActionableFeedback() {
        let thread = makeThread(isResolved: false, isActionable: true)
        let request = makeReviewRequest(reviewDecision: .reviewRequired, threads: [thread])

        #expect(request.hasActionableFeedback)
    }

    @Test func resolvedActionableThreadHasNoActionableFeedback() {
        let thread = makeThread(isResolved: true, isActionable: true)
        let request = makeReviewRequest(reviewDecision: .reviewRequired, threads: [thread])

        #expect(request.hasActionableFeedback == false)
    }

    @Test func reviewRequestIDIncludesRemoteIdentity() {
        let githubRequest = makeReviewRequest()
        let gitlabRequest = makeReviewRequest(
            remote: CodeHostRemote(
                kind: .gitlab,
                host: "gitlab.com",
                owner: "mrmans0n",
                repository: "alas",
                remoteName: "gitlab",
                webURL: URL(string: "https://gitlab.com/mrmans0n/alas")!
            )
        )

        #expect(githubRequest.id == "github-github.com-mrmans0n/alas-428")
        #expect(githubRequest.id != gitlabRequest.id)
        #expect(gitlabRequest.provider == .gitlab)
    }

    @Test func worstCheckBucketReturnsNilForEmptyChecks() {
        let request = makeReviewRequest(checks: [])

        #expect(request.worstCheckBucket == nil)
    }

    @Test func worstCheckBucketReturnsHighestSeverityBucket() {
        let request = makeReviewRequest(checks: [
            makeCheck(id: "unit-1", name: "unit", bucket: .pass),
            makeCheck(id: "integration-1", name: "integration", bucket: .pending),
            makeCheck(id: "lint-1", name: "lint", bucket: .fail),
        ])

        #expect(request.worstCheckBucket == .fail)
    }

    @Test func reviewChecksUseProviderSuppliedIDs() {
        let first = makeCheck(id: "provider-check-1", name: "build", workflow: "ci", bucket: .pass)
        let second = makeCheck(id: "provider-check-2", name: "build", workflow: "ci", bucket: .fail)

        #expect(first.name == second.name)
        #expect(first.workflow == second.workflow)
        #expect(first.id == "provider-check-1")
        #expect(second.id == "provider-check-2")
        #expect(first.id != second.id)
    }

    @Test func reviewThreadSummaryCarriesProviderThreadIdentity() {
        let thread = ReviewThreadSummary(
            id: "thread-1",
            author: "reviewer",
            body: "Please fix this.",
            url: URL(string: "https://provider/thread"),
            isResolved: false,
            isActionable: true,
            location: ReviewThreadLocation(
                path: "Sources/App.swift",
                originalPath: nil,
                line: 42,
                side: .new,
                providerPosition: "42"
            ),
            providerThreadID: "thread-provider-id",
            providerCommentID: "comment-provider-id"
        )

        #expect(thread.providerThreadID == "thread-provider-id")
        #expect(thread.providerCommentID == "comment-provider-id")
    }

    private func makeReviewRequest(
        remote: CodeHostRemote = CodeHostRemote(
            kind: .github,
            host: "github.com",
            owner: "mrmans0n",
            repository: "alas",
            remoteName: "origin",
            webURL: URL(string: "https://github.com/mrmans0n/alas")!
        ),
        reviewDecision: ReviewDecision = .reviewRequired,
        checks: [ReviewCheck] = [],
        threads: [ReviewThreadSummary] = []
    ) -> ReviewRequest {
        ReviewRequest(
            remote: remote,
            number: 428,
            title: "Review loop",
            url: URL(string: "https://github.com/mrmans0n/alas/pull/428")!,
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

    private func makeThread(isResolved: Bool, isActionable: Bool) -> ReviewThreadSummary {
        ReviewThreadSummary(
            id: "thread-1",
            author: "reviewer",
            body: "Please adjust this",
            url: URL(string: "https://github.com/mrmans0n/alas/pull/428#discussion_r1"),
            isResolved: isResolved,
            isActionable: isActionable
        )
    }

    private func makeCheck(
        id: String,
        name: String,
        workflow: String? = "ci",
        bucket: ReviewCheckBucket
    ) -> ReviewCheck {
        ReviewCheck(
            id: id,
            name: name,
            workflow: workflow,
            bucket: bucket,
            detailURL: nil,
            completedAt: nil
        )
    }
}
