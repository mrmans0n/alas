import Foundation
import Testing
@testable import Alas

@MainActor
struct GGSplitTabsManagerTests {
    @Test func openingSplitTargetCreatesAndFocusesStableTab() {
        let worktreeID = "gg-split-tabs-open"
        defer { try? FileManager.default.removeItem(at: Paths.tabsFile(forWorktreeId: worktreeID)) }
        let tabs = TabsManager()

        let id = tabs.openGGSplitCommit(
            worktreeId: worktreeID,
            targetGGID: "change-2",
            targetSHA: "abc"
        )

        #expect(id == "gg-split:\(worktreeID):change-2")
        #expect(tabs.activeTabId(forWorktree: worktreeID) == id)
        #expect(tabs.tabs(forWorktree: worktreeID).map(\.id) == [id])
    }

    @Test func openingSameSplitTargetFocusesExistingTab() {
        let worktreeID = "gg-split-tabs-dedupe"
        defer { try? FileManager.default.removeItem(at: Paths.tabsFile(forWorktreeId: worktreeID)) }
        let tabs = TabsManager()
        let first = tabs.openGGSplitCommit(
            worktreeId: worktreeID,
            targetGGID: "change-2",
            targetSHA: "abc"
        )
        _ = tabs.appendTerminal(worktreeId: worktreeID, title: "Terminal", sessionId: "session")

        let second = tabs.openGGSplitCommit(
            worktreeId: worktreeID,
            targetGGID: "change-2",
            targetSHA: "rewritten-sha"
        )

        #expect(first == second)
        #expect(tabs.tabs(forWorktree: worktreeID).filter { $0.id == first }.count == 1)
        #expect(tabs.activeTabId(forWorktree: worktreeID) == first)
    }

    @Test func openingDistinctTargetsCreatesDistinctTabs() {
        let worktreeID = "gg-split-tabs-distinct"
        defer { try? FileManager.default.removeItem(at: Paths.tabsFile(forWorktreeId: worktreeID)) }
        let tabs = TabsManager()

        let first = tabs.openGGSplitCommit(worktreeId: worktreeID, targetGGID: "change-1", targetSHA: "abc")
        let second = tabs.openGGSplitCommit(worktreeId: worktreeID, targetGGID: "change-2", targetSHA: "def")

        #expect(first != second)
        #expect(tabs.tabs(forWorktree: worktreeID).count == 2)
    }

    @Test func splitTabCodableRoundTripCarriesOnlyStableIdentity() throws {
        let state = GGSplitCommitTabState(
            worktreeId: "wt",
            targetGGID: "change-2",
            targetSHA: "abc"
        )

        let data = try JSONEncoder().encode(Tab.ggSplitCommit(state))
        let decoded = try JSONDecoder().decode(Tab.self, from: data)

        guard case .ggSplitCommit(let restored) = decoded else {
            Issue.record("Expected restored gg Split tab")
            return
        }
        #expect(restored == state)
        #expect(restored.id == "gg-split:wt:change-2")
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(!String(describing: object).contains("selectedHunk"))
        #expect(!String(describing: object).contains("firstMessage"))
        #expect(!String(describing: object).contains("planToken"))
    }

    @Test func restoredSplitTabRemainsVisibleWhenStructuredSplitIsUnavailable() {
        let state = GGSplitCommitTabState(worktreeId: "wt", targetGGID: nil, targetSHA: "abc")

        let presentation = state.presentation(
            capabilities: GGCapabilities(structuredSplit: false, keepCurrentUnstack: true),
            workflowAvailable: true
        )

        #expect(presentation == .unavailable(reason: "Update GG to use native Split Commit"))
        #expect(state.id == "gg-split:wt:abc")
    }

    @Test func restoredSplitTabRemainsVisibleWhenGGWorkflowIsUnavailable() {
        let state = GGSplitCommitTabState(worktreeId: "wt", targetGGID: "change-2", targetSHA: "abc")

        let presentation = state.presentation(
            capabilities: GGCapabilities(structuredSplit: true, keepCurrentUnstack: true),
            workflowAvailable: false
        )

        #expect(presentation == .unavailable(reason: "Native Split Commit is unavailable."))
    }

    @Test func restoredSplitTabIsUnavailableDuringGenericGitOperation() {
        let state = GGSplitCommitTabState(worktreeId: "wt", targetGGID: "change-2", targetSHA: "abc")

        let presentation = state.presentation(
            capabilities: GGCapabilities(structuredSplit: true, keepCurrentUnstack: true),
            workflowAvailable: true,
            hasBlockingGitOperation: true
        )

        #expect(presentation == .unavailable(reason: "Finish the current Git operation before splitting a commit."))
    }

    @Test func splitDraftSurvivesSwitchingAwayAndBack() {
        let worktreeID = "gg-split-tabs-draft"
        defer { try? FileManager.default.removeItem(at: Paths.tabsFile(forWorktreeId: worktreeID)) }
        let tabs = TabsManager()
        let id = tabs.openGGSplitCommit(worktreeId: worktreeID, targetGGID: "change-2", targetSHA: "abc")
        let draft = GGSplitCommitDraft(
            selectedHunkIDs: ["h-1"],
            firstMessage: "Extract parser",
            remainderMessage: "Keep renderer"
        )

        tabs.updateGGSplitCommitDraft(worktreeId: worktreeID, tabId: id, draft: draft)
        _ = tabs.appendTerminal(worktreeId: worktreeID, title: "Terminal", sessionId: "session")
        tabs.activate(worktreeId: worktreeID, tabId: id)

        #expect(tabs.ggSplitCommitDraft(worktreeId: worktreeID, tabId: id) == draft)
    }

    @Test func restoredSplitTabMatchesStableGGIDAfterTargetSHAIsRewritten() {
        let state = GGSplitCommitTabState(
            worktreeId: "wt",
            targetGGID: "change-2",
            targetSHA: "abc123"
        )
        let matchingStack = GGStack(
            name: "matching",
            base: "main",
            totalCommits: 1,
            syncedCommits: 0,
            currentPosition: 1,
            behindBase: 0,
            entries: [GGStackEntry(position: 1, sha: "rewritten456", title: "target", ggId: "change-2")]
        )
        let otherStack = GGStack(
            name: "other",
            base: "main",
            totalCommits: 1,
            syncedCommits: 0,
            currentPosition: 1,
            behindBase: 0,
            entries: [GGStackEntry(position: 1, sha: "def456", title: "other")]
        )

        #expect(state.belongs(to: matchingStack))
        #expect(!state.belongs(to: otherStack))
        #expect(!state.belongs(to: nil))
    }

    @Test func restoredSplitTabWithGGIDRejectsMatchingSHAWithoutThatID() {
        let state = GGSplitCommitTabState(
            worktreeId: "wt",
            targetGGID: "change-2",
            targetSHA: "abc123"
        )
        let stack = GGStack(
            name: "matching-sha-only",
            base: "main",
            totalCommits: 1,
            syncedCommits: 0,
            currentPosition: 1,
            behindBase: 0,
            entries: [GGStackEntry(position: 1, sha: "abc123def", title: "target")]
        )

        #expect(!state.belongs(to: stack))
    }

    @Test func restoredSplitTabWithoutGGIDFallsBackToTargetSHA() {
        let state = GGSplitCommitTabState(worktreeId: "wt", targetGGID: nil, targetSHA: "abc123")
        let stack = GGStack(
            name: "matching-sha",
            base: "main",
            totalCommits: 1,
            syncedCommits: 0,
            currentPosition: 1,
            behindBase: 0,
            entries: [GGStackEntry(position: 1, sha: "abc123def", title: "target")]
        )

        #expect(state.belongs(to: stack))
    }

    @Test func targetEntryResolvesMergedStateForRestoredTab() {
        let state = GGSplitCommitTabState(worktreeId: "wt", targetGGID: "change-2", targetSHA: "abc")
        let stack = GGStack(
            name: "merged-target",
            base: "main",
            totalCommits: 1,
            syncedCommits: 1,
            currentPosition: 1,
            behindBase: 0,
            entries: [GGStackEntry(position: 1, sha: "rewritten456", title: "target", ggId: "change-2", prState: .merged)]
        )

        #expect(state.targetEntry(in: stack)?.prState == .merged)
        #expect(state.targetEntry(in: nil) == nil)
    }

    @Test func matchesSplitTargetByGGIDThenSHA() {
        let state = GGSplitCommitTabState(worktreeId: "wt", targetGGID: "change-2", targetSHA: "abc")

        // Same GG-ID matches even if the SHA was rewritten.
        #expect(state.matches(splitTarget: GGSplitTargetIdentity(ggID: "change-2", sha: "rewritten", tree: "t")))
        // Different GG-ID is another tab's target.
        #expect(!state.matches(splitTarget: GGSplitTargetIdentity(ggID: "change-9", sha: "abc", tree: "t")))

        // Without a GG-ID on either side, fall back to the SHA.
        let shaOnly = GGSplitCommitTabState(worktreeId: "wt", targetGGID: nil, targetSHA: "abc")
        #expect(shaOnly.matches(splitTarget: GGSplitTargetIdentity(ggID: nil, sha: "abc", tree: "t")))
        #expect(!shaOnly.matches(splitTarget: GGSplitTargetIdentity(ggID: nil, sha: "def", tree: "t")))
    }
}
