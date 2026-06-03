import Foundation
import Testing
@testable import Alas

@MainActor
struct TabsManagerReviewRequestDraftTests {
    @Test func opensOrFocusesDraftReviewRequestTab() {
        let worktreeId = "review-request-draft-open"
        defer { try? FileManager.default.removeItem(at: Paths.tabsFile(forWorktreeId: worktreeId)) }
        let manager = TabsManager()
        let snapshot = Self.snapshot()

        let first = manager.openOrFocusDraftReviewRequest(worktreeId: worktreeId, snapshot: snapshot)
        let second = manager.openOrFocusDraftReviewRequest(worktreeId: worktreeId, snapshot: snapshot)

        #expect(first.id == second.id)
        #expect(manager.tabs(forWorktree: worktreeId).count == 1)
        #expect(manager.activeTabId(forWorktree: worktreeId) == first.id)
    }

    @Test func focusesSameDraftTargetPreservingEdits() {
        let worktreeId = "review-request-draft-same-target"
        defer { try? FileManager.default.removeItem(at: Paths.tabsFile(forWorktreeId: worktreeId)) }
        let manager = TabsManager()
        let snapshot = Self.snapshot()
        let first = manager.openOrFocusDraftReviewRequest(worktreeId: worktreeId, snapshot: snapshot)

        _ = manager.updateDraftReviewRequest(worktreeId: worktreeId, tabId: first.id) { state in
            state.title = "Add PR draft tab"
            state.body = "## Summary\n- Adds a tab"
            state.createAsDraft = true
        }

        let second = manager.openOrFocusDraftReviewRequest(worktreeId: worktreeId, snapshot: snapshot)

        #expect(second.id == first.id)
        #expect(manager.tabs(forWorktree: worktreeId).count == 1)
        guard case .draftReviewRequest(let state) = second else {
            Issue.record("Expected draft review request tab")
            return
        }
        #expect(state.title == "Add PR draft tab")
        #expect(state.body == "## Summary\n- Adds a tab")
        #expect(state.createAsDraft)
    }

    @Test func differentBaseBranchOpensSeparateDraftTab() {
        let worktreeId = "review-request-draft-different-base"
        defer { try? FileManager.default.removeItem(at: Paths.tabsFile(forWorktreeId: worktreeId)) }
        let manager = TabsManager()

        let first = manager.openOrFocusDraftReviewRequest(
            worktreeId: worktreeId,
            snapshot: Self.snapshot(baseBranch: "origin/main")
        )
        let second = manager.openOrFocusDraftReviewRequest(
            worktreeId: worktreeId,
            snapshot: Self.snapshot(baseBranch: "origin/release")
        )

        #expect(first.id != second.id)
        #expect(manager.tabs(forWorktree: worktreeId).count == 2)
        #expect(manager.activeTabId(forWorktree: worktreeId) == second.id)
    }

    @Test func sameDraftTargetRefreshesHeadSHAPreservingEdits() {
        let worktreeId = "review-request-draft-refresh-head-sha"
        defer { try? FileManager.default.removeItem(at: Paths.tabsFile(forWorktreeId: worktreeId)) }
        let manager = TabsManager()
        let first = manager.openOrFocusDraftReviewRequest(
            worktreeId: worktreeId,
            snapshot: Self.snapshot(headSHA: "abc123", headRemoteOwner: "mrmans0n")
        )

        _ = manager.updateDraftReviewRequest(worktreeId: worktreeId, tabId: first.id) { state in
            state.title = "Add PR draft tab"
            state.body = "## Summary\n- Adds a tab"
        }

        let second = manager.openOrFocusDraftReviewRequest(
            worktreeId: worktreeId,
            snapshot: Self.snapshot(headSHA: "def456", headRemoteOwner: "nacho")
        )

        #expect(second.id == first.id)
        #expect(manager.tabs(forWorktree: worktreeId).count == 1)
        guard case .draftReviewRequest(let state) = second else {
            Issue.record("Expected draft review request tab")
            return
        }
        #expect(state.headSHA == "def456")
        #expect(state.headOwner == "nacho")
        #expect(state.title == "Add PR draft tab")
        #expect(state.body == "## Summary\n- Adds a tab")
    }

    @Test func updatesDraftReviewRequestFields() {
        let worktreeId = "review-request-draft-update"
        defer { try? FileManager.default.removeItem(at: Paths.tabsFile(forWorktreeId: worktreeId)) }
        let manager = TabsManager()
        let tab = manager.openOrFocusDraftReviewRequest(worktreeId: worktreeId, snapshot: Self.snapshot())

        _ = manager.updateDraftReviewRequest(worktreeId: worktreeId, tabId: tab.id) { state in
            state.title = "Add PR draft tab"
            state.body = "## Summary\n- Adds a tab"
            state.createAsDraft = true
        }

        guard case .draftReviewRequest(let state) = manager.tabs(forWorktree: worktreeId).first else {
            Issue.record("Expected draft review request tab")
            return
        }
        #expect(state.title == "Add PR draft tab")
        #expect(state.body.contains("## Summary"))
        #expect(state.createAsDraft)
    }

    @Test func draftReviewRequestTabStateCodableRoundTripsDraftFields() throws {
        var state = DraftReviewRequestTabState(worktreeId: "wt-1", snapshot: Self.snapshot())
        state.title = "Add PR draft tab"
        state.body = "## Summary\n- Adds a tab"
        state.createAsDraft = true
        state.selectedPath = "Alas/Sources/Center/Tab.swift"
        state.createdURL = URL(string: "https://github.com/mrmans0n/alas/pull/42")!

        let data = try JSONEncoder().encode(state)
        let decoded = try JSONDecoder().decode(DraftReviewRequestTabState.self, from: data)

        #expect(decoded == state)
        #expect(decoded.title == "Add PR draft tab")
        #expect(decoded.body.contains("Adds a tab"))
        #expect(decoded.createAsDraft)
        #expect(decoded.selectedPath == "Alas/Sources/Center/Tab.swift")
        #expect(decoded.createdURL == URL(string: "https://github.com/mrmans0n/alas/pull/42")!)
    }

    @Test func draftReviewRequestTargetRequiresSameBranchBaseProviderRepoAndHead() {
        let state = DraftReviewRequestTabState(worktreeId: "wt-1", snapshot: Self.snapshot())

        #expect(state.matchesTarget(Self.snapshot()))
        #expect(!state.matchesTarget(Self.snapshot(branchName: "feature/other")))
        #expect(!state.matchesTarget(Self.snapshot(baseBranch: "origin/release")))
        #expect(!state.matchesTarget(Self.snapshot(provider: .gitlab)))
        #expect(!state.matchesTarget(Self.snapshot(owner: "other")))
        #expect(!state.matchesTarget(Self.snapshot(headSHA: "def456")))
    }

    private static func snapshot(
        provider: CodeHostKind = .github,
        owner: String = "mrmans0n",
        repository: String = "alas",
        branchName: String = "feature/pr-drafts",
        headSHA: String = "abc123",
        baseBranch: String = "origin/main",
        headRemoteOwner: String? = nil
    ) -> ReviewLoopSnapshot {
        ReviewLoopSnapshot(
            local: ReviewLoopLocalState(
                branchName: branchName,
                headSHA: headSHA,
                baseBranch: baseBranch,
                hasWorkingTreeChanges: false,
                hasStagedChanges: false,
                aheadCommitCount: 2,
                hasUpstream: true,
                upstreamRemoteName: "origin",
                upstreamBranchName: "feature/pr-drafts",
                headRemoteOwner: headRemoteOwner,
                needsPush: false
            ),
            remote: CodeHostRemote(
                kind: provider,
                host: provider == .github ? "github.com" : "gitlab.com",
                owner: owner,
                repository: repository,
                remoteName: "origin",
                webURL: URL(string: "https://github.com/mrmans0n/alas")!
            ),
            reviewRequest: nil,
            providerAvailable: true,
            providerAuthenticated: true,
            providerCapabilities: .githubCLI,
            errorMessage: nil
        )
    }
}
