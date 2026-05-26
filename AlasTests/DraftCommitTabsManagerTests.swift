import Testing
import Foundation
@testable import Alas

@MainActor
struct DraftCommitTabsManagerTests {
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

        guard case .commitEditor(let s) = replaced! else {
            Issue.record("expected commitEditor after replace")
            return
        }
        #expect(s.currentSha == "abc1234")
        #expect(s.baseRef == "main")
    }
}
