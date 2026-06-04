import Foundation
import Testing
@testable import Alas

@MainActor
struct TabsManagerReviewEvidenceTests {
    @Test func opensOrFocusesReviewEvidenceTabForSameRequest() {
        let worktreeId = "review-evidence-open"
        defer { try? FileManager.default.removeItem(at: Paths.tabsFile(forWorktreeId: worktreeId)) }
        let manager = TabsManager()
        let snapshot = Self.snapshot()

        let first = manager.openOrFocusReviewEvidence(
            worktreeId: worktreeId,
            snapshot: snapshot,
            initialSection: nil
        )
        let second = manager.openOrFocusReviewEvidence(
            worktreeId: worktreeId,
            snapshot: snapshot,
            initialSection: .feedback
        )

        #expect(first.id == second.id)
        #expect(manager.tabs(forWorktree: worktreeId).count == 1)
        #expect(manager.activeTabId(forWorktree: worktreeId) == first.id)
    }

    @Test func focusingExistingReviewEvidenceTabRefreshesSectionAndMetadata() {
        let worktreeId = "review-evidence-refresh"
        defer { try? FileManager.default.removeItem(at: Paths.tabsFile(forWorktreeId: worktreeId)) }
        let manager = TabsManager()
        let first = manager.openOrFocusReviewEvidence(
            worktreeId: worktreeId,
            snapshot: Self.snapshot(title: "Old title", url: URL(string: "https://github.com/mrmans0n/alas/pull/42")!),
            initialSection: .ci
        )

        let second = manager.openOrFocusReviewEvidence(
            worktreeId: worktreeId,
            snapshot: Self.snapshot(title: "New title", url: URL(string: "https://github.com/mrmans0n/alas/pull/42/files")!),
            initialSection: .feedback
        )

        #expect(second.id == first.id)
        guard case .reviewEvidence(let state) = second else {
            Issue.record("Expected review evidence tab")
            return
        }
        #expect(state.selectedSection == .feedback)
        #expect(state.title == "New title")
        #expect(state.url == URL(string: "https://github.com/mrmans0n/alas/pull/42/files"))
    }

    @Test func persistedLocalSelectionDoesNotBlockLaterInspectRetargeting() {
        let worktreeId = "review-evidence-retarget"
        defer { try? FileManager.default.removeItem(at: Paths.tabsFile(forWorktreeId: worktreeId)) }
        let manager = TabsManager()
        let snapshot = Self.snapshot()

        let opened = manager.openOrFocusReviewEvidence(
            worktreeId: worktreeId,
            snapshot: snapshot,
            initialSection: .ci
        )
        _ = manager.updateReviewEvidenceSelection(
            worktreeId: worktreeId,
            tabId: opened.id,
            selectedSection: .feedback,
            selectedItemID: "thread-1"
        )

        let retargeted = manager.openOrFocusReviewEvidence(
            worktreeId: worktreeId,
            snapshot: snapshot,
            initialSection: .ci
        )

        guard case .reviewEvidence(let state) = retargeted else {
            Issue.record("Expected review evidence tab")
            return
        }
        #expect(state.selectedSection == .ci)
        #expect(state.selectedItemID == nil)
        #expect(manager.tabs(forWorktree: worktreeId).count == 1)
    }

    @Test func differentReviewRequestOpensSeparateEvidenceTab() {
        let worktreeId = "review-evidence-separate-request"
        defer { try? FileManager.default.removeItem(at: Paths.tabsFile(forWorktreeId: worktreeId)) }
        let manager = TabsManager()

        let first = manager.openOrFocusReviewEvidence(
            worktreeId: worktreeId,
            snapshot: Self.snapshot(number: 42),
            initialSection: nil
        )
        let second = manager.openOrFocusReviewEvidence(
            worktreeId: worktreeId,
            snapshot: Self.snapshot(number: 43),
            initialSection: nil
        )

        #expect(first.id != second.id)
        #expect(manager.tabs(forWorktree: worktreeId).count == 2)
        #expect(manager.activeTabId(forWorktree: worktreeId) == second.id)
    }

    @Test func reviewEvidenceTabStateMatchesOnlyItsRequest() {
        let state = ReviewEvidenceTabState(
            worktreeId: "review-evidence-match",
            snapshot: Self.snapshot(number: 42),
            initialSection: nil
        )

        #expect(state.matches(Self.snapshot(number: 42)))
        #expect(!state.matches(Self.snapshot(number: 43)))
    }

    @Test func reviewEvidenceTabStateCodableRoundTrips() throws {
        let state = ReviewEvidenceTabState(
            worktreeId: "wt-1",
            snapshot: Self.snapshot(),
            initialSection: .feedback
        )

        let data = try JSONEncoder().encode(state)
        let decoded = try JSONDecoder().decode(ReviewEvidenceTabState.self, from: data)

        #expect(decoded == state)
        #expect(decoded.selectedSection == .feedback)
        #expect(decoded.provider == .github)
        #expect(decoded.number == 42)
    }

    private static func snapshot(
        number: Int = 42,
        title: String = "Review evidence",
        url: URL = URL(string: "https://github.com/mrmans0n/alas/pull/42")!
    ) -> ReviewLoopSnapshot {
        let remote = CodeHostRemote(
            kind: .github,
            host: "github.com",
            owner: "mrmans0n",
            repository: "alas",
            remoteName: "origin",
            webURL: URL(string: "https://github.com/mrmans0n/alas")!
        )
        let request = ReviewRequest(
            remote: remote,
            number: number,
            title: title,
            url: url,
            state: .open,
            isDraft: false,
            headRefName: "feature/review-evidence",
            baseRefName: "main",
            reviewDecision: .changesRequested,
            mergeState: .blocked,
            checks: [],
            threads: []
        )
        return ReviewLoopSnapshot(
            local: ReviewLoopLocalState(
                branchName: "feature/review-evidence",
                headSHA: "abc123",
                baseBranch: "main",
                hasWorkingTreeChanges: false,
                hasStagedChanges: false,
                aheadCommitCount: 1,
                hasUpstream: true,
                upstreamRemoteName: "origin",
                upstreamBranchName: "feature/review-evidence",
                needsPush: false
            ),
            remote: remote,
            reviewRequest: request,
            providerAvailable: true,
            providerAuthenticated: true,
            providerCapabilities: .githubCLI,
            errorMessage: nil
        )
    }
}
