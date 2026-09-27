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

    @Test func localBranchRenameKeepsPendingCreatedReviewDraft() {
        let worktreeId = "review-request-draft-renamed-local-branch"
        defer { try? FileManager.default.removeItem(at: Paths.tabsFile(forWorktreeId: worktreeId)) }
        let manager = TabsManager()
        let first = manager.openOrFocusDraftReviewRequest(
            worktreeId: worktreeId, snapshot: Self.snapshot(branchName: "local-feature")
        )
        let createdURL = URL(string: "https://github.com/mrmans0n/alas/pull/42")!
        _ = manager.updateDraftReviewRequest(worktreeId: worktreeId, tabId: first.id) {
            $0.createdURL = createdURL
        }

        let second = manager.openOrFocusDraftReviewRequest(
            worktreeId: worktreeId, snapshot: Self.snapshot(branchName: "renamed-feature")
        )

        #expect(second.id == first.id)
        guard case .draftReviewRequest(let state) = second else {
            Issue.record("Expected draft review request tab")
            return
        }
        #expect(state.createdURL == createdURL)
        #expect(manager.tabs(forWorktree: worktreeId).count == 1)
    }

    @Test func persistedPendingDraftWithoutUpstreamMetadataSurvivesLocalRename() throws {
        let worktreeId = "review-request-draft-legacy-upstream"
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let store = PersistenceStore()
        let snapshot = Self.snapshot(branchName: "local-feature")
        var legacy = DraftReviewRequestTabState(worktreeId: worktreeId, snapshot: snapshot)
        legacy.upstreamBranchName = nil
        legacy.title = "Saved title"
        legacy.body = "Saved body"
        legacy.createdURL = URL(string: "https://github.com/mrmans0n/alas/pull/42")!
        try store.write(TabsFile(tabs: [.draftReviewRequest(legacy)], activeTabId: legacy.id),
            to: directory.appendingPathComponent("\(worktreeId).json"))
        let manager = TabsManager(store: store, tabsDirectory: directory)
        manager.loadAll(worktreeIds: [worktreeId])

        let reopened = manager.openOrFocusDraftReviewRequest(
            worktreeId: worktreeId, snapshot: Self.snapshot(branchName: "renamed-feature"),
            existingLocalBranches: ["renamed-feature"]
        )

        #expect(reopened.id == legacy.id)
        #expect(manager.tabs(forWorktree: worktreeId).count == 1)
        guard case .draftReviewRequest(let state) = reopened else {
            Issue.record("Expected draft review request tab")
            return
        }
        #expect(state.title == "Saved title")
        #expect(state.body == "Saved body")
        #expect(state.createdURL == legacy.createdURL)
        #expect(state.reviewBranchName == "feature/pr-drafts")
    }

    @Test func legacyPendingDraftDoesNotFollowAnotherBranchAtSameCommit() {
        let worktreeId = "review-request-draft-legacy-distinct-branch"
        defer { try? FileManager.default.removeItem(at: Paths.tabsFile(forWorktreeId: worktreeId)) }
        let manager = TabsManager()
        let first = manager.openOrFocusDraftReviewRequest(
            worktreeId: worktreeId, snapshot: Self.snapshot(branchName: "branch-a")
        )
        _ = manager.updateDraftReviewRequest(worktreeId: worktreeId, tabId: first.id) { state in
            state.upstreamBranchName = nil
            state.createdURL = URL(string: "https://github.com/mrmans0n/alas/pull/42")!
        }

        let second = manager.openOrFocusDraftReviewRequest(
            worktreeId: worktreeId, snapshot: Self.snapshot(branchName: "branch-b"),
            existingLocalBranches: ["branch-a", "branch-b"]
        )

        #expect(second.id != first.id)
        #expect(manager.tabs(forWorktree: worktreeId).count == 2)
        guard case .draftReviewRequest(let state) = second else {
            Issue.record("Expected draft review request tab")
            return
        }
        #expect(state.createdURL == nil)
    }

    @Test func createdReviewSurvivesHeadAdvanceAndRefocusUntilDiscovered() throws {
        let worktreeId = "review-request-draft-pending-created-url"
        defer { try? FileManager.default.removeItem(at: Paths.tabsFile(forWorktreeId: worktreeId)) }
        let manager = TabsManager()
        let first = manager.openOrFocusDraftReviewRequest(
            worktreeId: worktreeId,
            snapshot: Self.snapshot(headSHA: "abc123")
        )

        _ = manager.updateDraftReviewRequest(worktreeId: worktreeId, tabId: first.id) { state in
            state.createdURL = URL(string: "https://github.com/mrmans0n/alas/pull/42")!
        }

        let second = manager.openOrFocusDraftReviewRequest(
            worktreeId: worktreeId,
            snapshot: Self.snapshot(headSHA: "def456")
        )

        guard case .draftReviewRequest(let state) = second else {
            Issue.record("Expected draft review request tab")
            return
        }
        #expect(state.headSHA == "def456")
        #expect(state.createdURL == URL(string: "https://github.com/mrmans0n/alas/pull/42"))
        let refreshed = Self.snapshot(headSHA: "def456")
        let found = ReviewLoopSnapshot(
            local: refreshed.local, remote: refreshed.remote,
            reviewRequest: .placeholder(remote: try #require(refreshed.remote), number: 42),
            providerAvailable: true, providerAuthenticated: true,
            providerCapabilities: .githubCLI, errorMessage: nil
        )
        let review = try #require(manager.transitionPendingCreatedReview(worktreeId: worktreeId, snapshot: found))
        #expect(manager.activeTabId(forWorktree: worktreeId) == review.id)
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

    @Test func draftReviewRequestTargetFollowsUpstreamAcrossLocalRename() {
        let state = DraftReviewRequestTabState(worktreeId: "wt-1", snapshot: Self.snapshot())

        #expect(state.matchesTarget(Self.snapshot()))
        #expect(state.matchesTarget(Self.snapshot(branchName: "feature/other")))
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
