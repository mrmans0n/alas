import Foundation
import Testing
@testable import Alas

struct ReviewRequestDraftTests {
    @Test func parsesSelectedFileDiffPreviewIntoHunks() {
        let raw = """
        diff --git a/Sources/A.swift b/Sources/A.swift
        index 1111111..2222222 100644
        --- a/Sources/A.swift
        +++ b/Sources/A.swift
        @@ -1,1 +1,1 @@
        -let value = 1
        +let value = 2
        """

        let preview = DraftReviewRequestDiffPreview(
            path: "Sources/A.swift",
            file: CommitChangedFile(path: "Sources/A.swift", originalPath: nil, status: "M", add: 1, del: 1),
            rawDiff: raw
        )

        #expect(preview.parsedDiff.hunks.count == 1)
        #expect(preview.fileExtension == "swift")
        #expect(preview.title == "A.swift")
        #expect(preview.directory == "Sources")
    }

    @Test func parsesGeneratedTitleAndBody() throws {
        let parsed = try ReviewRequestDraft.parseGeneratedMessage("""
        Add review request drafts

        ## Summary
        - Adds a draft PR tab.

        ## Testing
        - xcodebuild test
        """)

        #expect(parsed.title == "Add review request drafts")
        #expect(parsed.body.contains("## Summary"))
        #expect(parsed.body.contains("## Testing"))
    }

    @Test func validationRequiresTitleBodyAndReadySnapshot() {
        let ready = ReviewRequestDraft.ValidationInput(
            title: "Add review request drafts",
            body: "## Summary\n- Adds a tab\n\n## Testing\n- Not run",
            snapshot: Self.snapshot(needsPush: false, aheadCommitCount: 2)
        )
        #expect(ReviewRequestDraft.validationMessage(for: ready) == nil)

        let missingTitle = ReviewRequestDraft.ValidationInput(title: "", body: ready.body, snapshot: ready.snapshot)
        #expect(ReviewRequestDraft.validationMessage(for: missingTitle) == "Title is required.")

        let needsPush = ReviewRequestDraft.ValidationInput(
            title: ready.title,
            body: ready.body,
            snapshot: Self.snapshot(needsPush: true, aheadCommitCount: 2)
        )
        #expect(ReviewRequestDraft.validationMessage(for: needsPush) == "Push this branch before creating a PR.")

        let stale = ReviewRequestDraft.ValidationInput(
            title: ready.title,
            body: ready.body,
            snapshot: Self.snapshot(needsPush: false, aheadCommitCount: 2, upstreamAheadCommitCount: 1)
        )
        #expect(ReviewRequestDraft.validationMessage(for: stale) == "Remote has commits not in this branch. Pull or rebase before creating a PR.")

        let diverged = ReviewRequestDraft.ValidationInput(
            title: ready.title,
            body: ready.body,
            snapshot: Self.snapshot(needsPush: true, aheadCommitCount: 2, upstreamAheadCommitCount: 1)
        )
        #expect(ReviewRequestDraft.validationMessage(for: diverged) == "Remote has commits not in this branch. Pull, rebase, or force push before creating a PR.")
    }

    @Test func validationBlocksExistingReviewRequest() {
        let snapshot = Self.snapshot(
            needsPush: false,
            aheadCommitCount: 2,
            reviewRequest: Self.reviewRequest()
        )
        let input = ReviewRequestDraft.ValidationInput(
            title: "Add review request drafts",
            body: "## Summary\n- Adds a tab",
            snapshot: snapshot
        )

        #expect(ReviewRequestDraft.validationMessage(for: input) == "A PR already exists for this branch.")
    }

    @Test func validationBlocksLocalBranchMatchingSelectedBase() {
        let snapshot = Self.snapshot(
            branchName: "main",
            baseBranch: "origin/main",
            needsPush: false,
            aheadCommitCount: 2
        )
        let input = ReviewRequestDraft.ValidationInput(
            title: "Add review request drafts",
            body: "## Summary\n- Adds a tab",
            snapshot: snapshot
        )

        #expect(ReviewRequestDraft.validationMessage(for: input) == "Switch to a feature branch before creating a PR.")
    }

    private static func snapshot(
        needsPush: Bool,
        aheadCommitCount: Int,
        upstreamAheadCommitCount: Int = 0
    ) -> ReviewLoopSnapshot {
        snapshot(
            branchName: "feature/pr-drafts",
            baseBranch: "origin/main",
            needsPush: needsPush,
            aheadCommitCount: aheadCommitCount,
            upstreamAheadCommitCount: upstreamAheadCommitCount
        )
    }

    private static func snapshot(
        branchName: String = "feature/pr-drafts",
        baseBranch: String = "origin/main",
        needsPush: Bool,
        aheadCommitCount: Int,
        upstreamAheadCommitCount: Int = 0,
        reviewRequest: ReviewRequest? = nil
    ) -> ReviewLoopSnapshot {
        ReviewLoopSnapshot(
            local: ReviewLoopLocalState(
                branchName: branchName,
                headSHA: "abc123",
                baseBranch: baseBranch,
                hasWorkingTreeChanges: false,
                hasStagedChanges: false,
                aheadCommitCount: aheadCommitCount,
                hasUpstream: true,
                upstreamRemoteName: "origin",
                upstreamBranchName: "feature/pr-drafts",
                upstreamAheadCommitCount: upstreamAheadCommitCount,
                needsPush: needsPush
            ),
            remote: CodeHostRemote(
                kind: .github,
                host: "github.com",
                owner: "mrmans0n",
                repository: "alas",
                remoteName: "origin",
                webURL: URL(string: "https://github.com/mrmans0n/alas")!
            ),
            reviewRequest: reviewRequest,
            providerAvailable: true,
            providerAuthenticated: true,
            providerCapabilities: .githubCLI,
            errorMessage: nil
        )
    }

    private static func reviewRequest() -> ReviewRequest {
        ReviewRequest(
            remote: CodeHostRemote(
                kind: .github,
                host: "github.com",
                owner: "mrmans0n",
                repository: "alas",
                remoteName: "origin",
                webURL: URL(string: "https://github.com/mrmans0n/alas")!
            ),
            number: 42,
            title: "Add review request drafts",
            url: URL(string: "https://github.com/mrmans0n/alas/pull/42")!,
            state: .open,
            isDraft: true,
            headRefName: "feature/pr-drafts",
            baseRefName: "main",
            reviewDecision: .reviewRequired,
            mergeState: .unknown,
            checks: [],
            threads: []
        )
    }
}
