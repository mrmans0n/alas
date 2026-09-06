import Testing
import Foundation
@testable import Alas

@MainActor
struct DraftCommitTabsManagerTests {
    @Test func openDraftWithPublishIntentCreatesPublishFirstDraft() {
        let worktreeId = "draft-commit-tabs-mgr-publish-intent-new"
        defer { try? FileManager.default.removeItem(at: Paths.tabsFile(forWorktreeId: worktreeId)) }
        let manager = TabsManager()

        let tab = manager.openOrFocusDraftCommit(worktreeId: worktreeId, preferredAction: .publish)

        guard case .draftCommit(let state) = tab else {
            Issue.record("expected draftCommit tab")
            return
        }
        #expect(state.preferredAction == .publish)
    }

    @Test func changingIntentPreservesLiveDraftContents() {
        let worktreeId = "draft-commit-tabs-mgr-publish-intent-live"
        defer { try? FileManager.default.removeItem(at: Paths.tabsFile(forWorktreeId: worktreeId)) }
        let manager = TabsManager()
        let draft = manager.openOrFocusDraftCommit(worktreeId: worktreeId)
        let checkpoint = makePublishCheckpoint()
        manager.updateDraftCommit(worktreeId: worktreeId, tabId: draft.id) { state in
            state.subject = "feat: publish this"
            state.bodyText = "Preserve this body"
            state.createReviewRequestAsDraft = true
            state.amend = true
            state.selectedPath = "Alas/Sources/Center/TabsManager.swift"
            state.publishCheckpoint = checkpoint
        }
        guard case .draftCommit(let original) = manager.tabs(forWorktree: worktreeId).first(where: { $0.id == draft.id }) else {
            Issue.record("expected live draftCommit tab")
            return
        }
        var expected = original
        expected.preferredAction = .publish

        let reopened = manager.openOrFocusDraftCommit(
            worktreeId: worktreeId,
            resetAmend: false,
            preferredAction: .publish
        )

        guard case .draftCommit(let state) = reopened,
              case .draftCommit(let selectedState) = manager.activeTab(forWorktree: worktreeId) else {
            Issue.record("expected focused draftCommit tab")
            return
        }
        #expect(state == expected)
        #expect(selectedState == expected)
        #expect(reopened.id == draft.id)
        #expect(manager.tabs(forWorktree: worktreeId).count == 1)
    }

    @Test func changingIntentPreservesStashedDraftContents() {
        let worktreeId = "draft-commit-tabs-mgr-publish-intent-stashed"
        defer { try? FileManager.default.removeItem(at: Paths.tabsFile(forWorktreeId: worktreeId)) }
        let manager = TabsManager()
        let draft = manager.openOrFocusDraftCommit(worktreeId: worktreeId)
        let checkpoint = makePublishCheckpoint()
        manager.updateDraftCommit(worktreeId: worktreeId, tabId: draft.id) { state in
            state.subject = "feat: resume publish"
            state.bodyText = "Preserve this stashed body"
            state.createReviewRequestAsDraft = true
            state.amend = true
            state.selectedPath = "Alas/Sources/Center/TabsManager.swift"
            state.publishCheckpoint = checkpoint
        }
        guard case .draftCommit(let original) = manager.tabs(forWorktree: worktreeId).first(where: { $0.id == draft.id }) else {
            Issue.record("expected live draftCommit tab")
            return
        }
        manager.close(worktreeId: worktreeId, tabId: draft.id)
        var expected = original
        expected.preferredAction = .publish

        let reopened = manager.openOrFocusDraftCommit(
            worktreeId: worktreeId,
            resetAmend: false,
            preferredAction: .publish
        )

        guard case .draftCommit(let state) = reopened else {
            Issue.record("expected restored draftCommit tab")
            return
        }
        #expect(state == expected)
        #expect(manager.stashedDraft(worktreeId: worktreeId) == expected)
    }

    @Test func closingCheckpointOnlyDraftRetainsCheckpoint() {
        let worktreeId = "draft-commit-tabs-mgr-checkpoint-stash"
        let tabsDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("alas-draft-checkpoint-stash-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tabsDirectory) }
        let manager = TabsManager(store: PersistenceStore(), tabsDirectory: tabsDirectory)
        let draft = manager.openOrFocusDraftCommit(worktreeId: worktreeId)
        let checkpoint = makePublishCheckpoint()
        manager.updateDraftCommit(worktreeId: worktreeId, tabId: draft.id) { state in
            state.subject = ""
            state.bodyText = ""
            state.publishCheckpoint = checkpoint
        }

        manager.close(worktreeId: worktreeId, tabId: draft.id)

        let reloaded = TabsManager(store: PersistenceStore(), tabsDirectory: tabsDirectory)
        reloaded.loadAll(worktreeIds: [worktreeId])
        let reopened = reloaded.openOrFocusDraftCommit(worktreeId: worktreeId)

        guard case .draftCommit(let state) = reopened else {
            Issue.record("expected restored draftCommit tab")
            return
        }
        #expect(state.publishCheckpoint == checkpoint)
    }

    @Test func openOrFocusDraftCommit_createsTabFirstTime() {
        let worktreeId = "draft-commit-tabs-mgr-create"
        defer { try? FileManager.default.removeItem(at: Paths.tabsFile(forWorktreeId: worktreeId)) }
        let mgr = TabsManager()
        let tab = mgr.openOrFocusDraftCommit(worktreeId: worktreeId)
        #expect(tab.id == "draft-commit:\(worktreeId)")
        guard case .draftCommit(let s) = tab else {
            Issue.record("expected draftCommit tab")
            return
        }
        #expect(s.worktreeId == worktreeId)
        #expect(s.subject == "")
    }

    @Test func openOrFocusDraftCommit_focusesExistingTab() {
        let worktreeId = "draft-commit-tabs-mgr-focus"
        defer { try? FileManager.default.removeItem(at: Paths.tabsFile(forWorktreeId: worktreeId)) }
        let mgr = TabsManager()
        let first = mgr.openOrFocusDraftCommit(worktreeId: worktreeId)
        let again = mgr.openOrFocusDraftCommit(worktreeId: worktreeId)
        #expect(first.id == again.id)
        let drafts = mgr.tabs(forWorktree: worktreeId).filter {
            if case .draftCommit = $0 { return true } else { return false }
        }
        #expect(drafts.count == 1)
        #expect(mgr.activeTabId(forWorktree: worktreeId) == first.id)
    }

    @Test func openOrFocusDraftCommitForNewCommit_resetsLiveAmendBeforeFocusing() {
        let worktreeId = "draft-commit-tabs-mgr-new-live"
        defer { try? FileManager.default.removeItem(at: Paths.tabsFile(forWorktreeId: worktreeId)) }
        let mgr = TabsManager()
        let first = mgr.openOrFocusDraftCommit(worktreeId: worktreeId)
        mgr.updateDraftCommit(worktreeId: worktreeId, tabId: first.id) { state in
            state.subject = "Keep this message"
            state.bodyText = "Keep this body"
            state.amend = true
        }
        guard case .draftCommit(let mountedState) = mgr.tabs(forWorktree: worktreeId).first else {
            Issue.record("expected mounted draftCommit tab")
            return
        }

        let reopened = mgr.openOrFocusDraftCommit(worktreeId: worktreeId, resetAmend: true)

        guard case .draftCommit(let state) = reopened else {
            Issue.record("expected draftCommit tab")
            return
        }
        #expect(state.subject == "Keep this message")
        #expect(state.bodyText == "Keep this body")
        #expect(state.amend == false)
        #expect(state.presentationID != mountedState.presentationID)
        #expect(mgr.activeTabId(forWorktree: worktreeId) == first.id)
    }

    @Test func openOrFocusDraftCommitForGenericDraft_preservesLiveAmend() {
        let worktreeId = "draft-commit-tabs-mgr-generic-live"
        defer { try? FileManager.default.removeItem(at: Paths.tabsFile(forWorktreeId: worktreeId)) }
        let mgr = TabsManager()
        let first = mgr.openOrFocusDraftCommit(worktreeId: worktreeId)
        mgr.updateDraftCommit(worktreeId: worktreeId, tabId: first.id) { state in
            state.amend = true
        }
        guard case .draftCommit(let mountedState) = mgr.tabs(forWorktree: worktreeId).first else {
            Issue.record("expected mounted draftCommit tab")
            return
        }

        let reopened = mgr.openOrFocusDraftCommit(worktreeId: worktreeId)

        guard case .draftCommit(let state) = reopened else {
            Issue.record("expected draftCommit tab")
            return
        }
        #expect(state.amend == true)
        #expect(state.presentationID == mountedState.presentationID)
    }

    @Test func openOrFocusDraftCommitForNewCommit_resetsStashedAmendBeforeOpening() {
        let worktreeId = "draft-commit-tabs-mgr-new-stashed"
        defer { try? FileManager.default.removeItem(at: Paths.tabsFile(forWorktreeId: worktreeId)) }
        let mgr = TabsManager()
        let first = mgr.openOrFocusDraftCommit(worktreeId: worktreeId)
        mgr.updateDraftCommit(worktreeId: worktreeId, tabId: first.id) { state in
            state.subject = "Keep this stashed message"
            state.amend = true
        }
        mgr.close(worktreeId: worktreeId, tabId: first.id)

        let reopened = mgr.openOrFocusDraftCommit(worktreeId: worktreeId, resetAmend: true)

        guard case .draftCommit(let state) = reopened else {
            Issue.record("expected draftCommit tab")
            return
        }
        #expect(state.subject == "Keep this stashed message")
        #expect(state.amend == false)
        #expect(mgr.stashedDraft(worktreeId: worktreeId)?.amend == false)
    }

    @Test func updateDraftCommit_persistsSubjectAndBody() {
        let worktreeId = "draft-commit-tabs-mgr-update"
        defer { try? FileManager.default.removeItem(at: Paths.tabsFile(forWorktreeId: worktreeId)) }
        let mgr = TabsManager()
        let tab = mgr.openOrFocusDraftCommit(worktreeId: worktreeId)
        mgr.updateDraftCommit(worktreeId: worktreeId, tabId: tab.id) { state in
            state.subject = "feat: foo"
            state.bodyText = "Detailed body"
            state.amend = true
            state.selectedPath = "src/foo.swift"
        }
        guard let found = mgr.tabs(forWorktree: worktreeId).first(where: { $0.id == tab.id }),
              case .draftCommit(let s) = found else {
            Issue.record("expected draftCommit tab after update")
            return
        }
        #expect(s.subject == "feat: foo")
        #expect(s.bodyText == "Detailed body")
        #expect(s.amend == true)
        #expect(s.selectedPath == "src/foo.swift")
    }

    @Test func replaceDraftWithCommitEditor_swapsCaseKeepingTabPosition() {
        let worktreeId = "draft-commit-tabs-mgr-replace"
        defer { try? FileManager.default.removeItem(at: Paths.tabsFile(forWorktreeId: worktreeId)) }
        let mgr = TabsManager()
        let draft = mgr.openOrFocusDraftCommit(worktreeId: worktreeId)
        let originalIndex = mgr.tabs(forWorktree: worktreeId).firstIndex { $0.id == draft.id }!

        let replaced = mgr.replaceDraftWithCommitEditor(
            worktreeId: worktreeId,
            draftTabId: draft.id,
            baseRef: "main",
            newSha: "abc1234",
            title: "abc1234 feat: foo"
        )
        #expect(replaced != nil)

        let tabs = mgr.tabs(forWorktree: worktreeId)
        let newIndex = tabs.firstIndex { $0.id == replaced!.id }!
        #expect(newIndex == originalIndex)
        #expect(!tabs.contains { $0.id == draft.id })
        #expect(mgr.activeTabId(forWorktree: worktreeId) == replaced!.id)

        guard case .commitEditor(let s) = replaced! else {
            Issue.record("expected commitEditor after replace")
            return
        }
        #expect(s.currentSha == "abc1234")
        #expect(s.baseRef == "main")
    }

    @Test func closingDraftTab_stashesStateAcrossReopen() {
        let worktreeId = "draft-stash-roundtrip"
        defer { try? FileManager.default.removeItem(at: Paths.tabsFile(forWorktreeId: worktreeId)) }
        let mgr = TabsManager()

        let first = mgr.openOrFocusDraftCommit(worktreeId: worktreeId)
        mgr.updateDraftCommit(worktreeId: worktreeId, tabId: first.id) { state in
            state.subject = "wip: persist me"
            state.bodyText = "Draft body that should survive close"
            state.amend = true
        }

        mgr.close(worktreeId: worktreeId, tabId: first.id)
        #expect(mgr.tabs(forWorktree: worktreeId).isEmpty)

        let reopened = mgr.openOrFocusDraftCommit(worktreeId: worktreeId)
        guard case .draftCommit(let restored) = reopened else {
            Issue.record("expected draftCommit tab after reopen")
            return
        }
        #expect(restored.subject == "wip: persist me")
        #expect(restored.bodyText == "Draft body that should survive close")
        #expect(restored.amend == true)
    }

    @Test func stashedDraft_returnsStateAfterClose() {
        let worktreeId = "draft-stash-accessor"
        let mgr = TabsManager()
        defer { try? FileManager.default.removeItem(at: Paths.tabsFile(forWorktreeId: worktreeId)) }

        let tab = mgr.openOrFocusDraftCommit(worktreeId: worktreeId)
        mgr.updateDraftCommit(worktreeId: worktreeId, tabId: tab.id) { state in
            state.subject = "wip: stashed"
            state.bodyText = "body"
        }
        #expect(mgr.stashedDraft(worktreeId: worktreeId) == nil) // not stashed while live
        mgr.close(worktreeId: worktreeId, tabId: tab.id)

        let stashed = mgr.stashedDraft(worktreeId: worktreeId)
        #expect(stashed?.subject == "wip: stashed")
        #expect(stashed?.bodyText == "body")
    }

    @Test func replaceDraftWithCommitEditor_clearsStash() {
        let worktreeId = "draft-stash-cleared-on-commit"
        defer { try? FileManager.default.removeItem(at: Paths.tabsFile(forWorktreeId: worktreeId)) }
        let mgr = TabsManager()

        let draft = mgr.openOrFocusDraftCommit(worktreeId: worktreeId)
        mgr.updateDraftCommit(worktreeId: worktreeId, tabId: draft.id) { state in
            state.subject = "feat: thing"
        }
        _ = mgr.replaceDraftWithCommitEditor(
            worktreeId: worktreeId,
            draftTabId: draft.id,
            baseRef: "main",
            newSha: "abcdef0",
            title: "abcdef0 feat: thing"
        )

        // Open a new draft — should be empty, not restored from a stale stash.
        let next = mgr.openOrFocusDraftCommit(worktreeId: worktreeId)
        guard case .draftCommit(let fresh) = next else {
            Issue.record("expected draftCommit tab")
            return
        }
        #expect(fresh.subject == "")
        #expect(fresh.bodyText == "")
    }

    @Test func closingEmptyDraftTab_doesNotStash() {
        let worktreeId = "draft-empty-no-stash"
        defer { try? FileManager.default.removeItem(at: Paths.tabsFile(forWorktreeId: worktreeId)) }
        let mgr = TabsManager()

        let tab = mgr.openOrFocusDraftCommit(worktreeId: worktreeId)
        // Don't write subject/body. Close immediately.
        mgr.close(worktreeId: worktreeId, tabId: tab.id)

        #expect(mgr.stashedDraft(worktreeId: worktreeId) == nil)
    }

    @Test func closingWhitespaceOnlyDraftTab_doesNotStash() {
        let worktreeId = "draft-whitespace-no-stash"
        defer { try? FileManager.default.removeItem(at: Paths.tabsFile(forWorktreeId: worktreeId)) }
        let mgr = TabsManager()

        let tab = mgr.openOrFocusDraftCommit(worktreeId: worktreeId)
        mgr.updateDraftCommit(worktreeId: worktreeId, tabId: tab.id) { state in
            state.subject = "   "
            state.bodyText = "\n\n"
        }
        mgr.close(worktreeId: worktreeId, tabId: tab.id)

        #expect(mgr.stashedDraft(worktreeId: worktreeId) == nil)
    }

    @Test func emptyingAndClosingDraftTab_clearsExistingStash() {
        let worktreeId = "draft-empty-clears-stash"
        defer { try? FileManager.default.removeItem(at: Paths.tabsFile(forWorktreeId: worktreeId)) }
        let mgr = TabsManager()

        // Plant a meaningful stash via close-with-content.
        let first = mgr.openOrFocusDraftCommit(worktreeId: worktreeId)
        mgr.updateDraftCommit(worktreeId: worktreeId, tabId: first.id) { state in
            state.subject = "wip: should be removable"
        }
        mgr.close(worktreeId: worktreeId, tabId: first.id)
        #expect(mgr.stashedDraft(worktreeId: worktreeId)?.subject == "wip: should be removable")

        // Reopen, wipe both fields, close → stash should clear.
        let reopened = mgr.openOrFocusDraftCommit(worktreeId: worktreeId)
        mgr.updateDraftCommit(worktreeId: worktreeId, tabId: reopened.id) { state in
            state.subject = ""
            state.bodyText = ""
        }
        mgr.close(worktreeId: worktreeId, tabId: reopened.id)

        #expect(mgr.stashedDraft(worktreeId: worktreeId) == nil)
    }

    @Test func closeOthers_stashesNonEmptyDraft() {
        let worktreeId = "draft-close-others-stash"
        defer { try? FileManager.default.removeItem(at: Paths.tabsFile(forWorktreeId: worktreeId)) }
        let mgr = TabsManager()

        let draft = mgr.openOrFocusDraftCommit(worktreeId: worktreeId)
        mgr.updateDraftCommit(worktreeId: worktreeId, tabId: draft.id) { state in
            state.subject = "wip: bulk-close test"
        }
        // Open a second tab to keep so closeOthers has something to keep.
        let other = mgr.appendCommit(worktreeId: worktreeId, sha: "abc123", title: "abc123 init")
        _ = mgr.closeOthers(worktreeId: worktreeId, keeping: other.id)

        #expect(mgr.stashedDraft(worktreeId: worktreeId)?.subject == "wip: bulk-close test")
    }

    @Test func closeAll_stashesNonEmptyDraft() {
        let worktreeId = "draft-close-all-stash"
        defer { try? FileManager.default.removeItem(at: Paths.tabsFile(forWorktreeId: worktreeId)) }
        let mgr = TabsManager()

        let draft = mgr.openOrFocusDraftCommit(worktreeId: worktreeId)
        mgr.updateDraftCommit(worktreeId: worktreeId, tabId: draft.id) { state in
            state.subject = "wip: close-all test"
        }
        _ = mgr.closeAll(worktreeId: worktreeId)

        #expect(mgr.stashedDraft(worktreeId: worktreeId)?.subject == "wip: close-all test")
    }

    private func makePublishCheckpoint() -> CommitPublishCheckpoint {
        CommitPublishCheckpoint(
            commitSHA: "abc1234",
            baseRef: "main",
            commitTitle: "abc1234 feat: publish",
            subject: "feat: publish",
            body: "Publish body",
            destination: .gg,
            nextPhase: .push
        )
    }
}
