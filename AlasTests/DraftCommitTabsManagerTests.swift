import Testing
import Foundation
@testable import Alas

@MainActor
struct DraftCommitTabsManagerTests {
    private struct ProjectMemoryStore: PersistenceStoreProtocol {
        var projectsFile: ProjectsFile

        func write<T: Encodable>(_: T, to _: URL) throws {}

        func readIfExists<T: Decodable>(_ type: T.Type, from _: URL) throws -> T? {
            if type == ProjectsFile.self { return projectsFile as? T }
            if type == AppConfig.self { return AppConfig.defaults as? T }
            return nil
        }
    }

    @Test func projectScopedGitClientsUseTheSelectedProjectHost() throws {
        let root = URL(fileURLWithPath: "/draft-commit-project-host-\(UUID().uuidString)")
        defer { RemoteHostRegistry.shared.unregister(root: root.path) }
        let projectA = ProjectConfig(
            id: "project-a", name: "A", path: root.path, color: "blue", addedAt: .distantPast, host: "host-a"
        )
        let projectB = ProjectConfig(
            id: "project-b", name: "B", path: root.path, color: "green", addedAt: .distantPast
        )
        let appState = AppState(
            store: ProjectMemoryStore(projectsFile: ProjectsFile(projects: [projectA, projectB])),
            runHistoryStore: nil,
            restoreActiveTabsOnStartup: false
        )
        RemoteHostRegistry.shared.register(root: root.path, host: "host-a")

        let worktree = Worktree(
            id: "shared-worktree-id",
            projectId: projectB.id,
            name: "main",
            branch: "main",
            path: root,
            status: .clean,
            lastActivity: .distantPast
        )
        let view = DraftCommitTabView(
            worktreePath: root,
            worktreeId: "shared-worktree-id",
            projectId: projectB.id,
            projectHost: appState.remoteHost(for: worktree),
            tabState: DraftCommitTabState(worktreeId: "shared-worktree-id", projectId: projectB.id),
            executionTarget: .local,
            appState: appState
        )

        #expect(RemoteHostRegistry.shared.host(forPath: root.path) == "host-a")
        #expect(appState.remoteHost(for: worktree) == nil)
        #expect(view.git.remoteHost(forWorktreePath: root) == nil)

        let commitView = CommitTabView(
            worktreePath: root,
            tabState: CommitTabState(worktreeId: worktree.id, projectId: projectB.id, sha: "abc", title: "abc"),
            worktreeId: worktree.id,
            projectId: projectB.id,
            projectHost: appState.remoteHost(for: worktree),
            appState: appState
        )
        let commitGit = commitView.git
        let snapshotView = FileSnapshotTabView(
            worktreePath: root,
            state: FileSnapshotTabState(worktreeId: worktree.id, projectId: projectB.id, relativePath: "README.md"),
            projectHost: appState.remoteHost(for: worktree)
        )
        let snapshotGit = snapshotView.git
        let historyView = FileHistoryTabView(
            worktreePath: root,
            state: FileHistoryTabState(worktreeId: worktree.id, projectId: projectB.id, relativePath: "README.md"),
            projectHost: appState.remoteHost(for: worktree),
            onSelectCommit: { _ in },
            onCopySHA: { _ in }
        )
        let historyGit = historyView.git
        let mergeConflictView = MergeConflictTabView(
            state: appState,
            worktree: worktree,
            tabState: MergeConflictTabState(
                worktreeId: worktree.id,
                projectId: projectB.id,
                relativePath: "README.md",
                title: "README.md"
            ),
            projectHost: appState.remoteHost(for: worktree)
        )

        #expect(commitGit.remoteHost(forWorktreePath: root) == nil)
        #expect(snapshotGit.remoteHost(forWorktreePath: root) == nil)
        #expect(historyGit.remoteHost(forWorktreePath: root) == nil)
        #expect(mergeConflictView.gitService.remoteHost(forWorktreePath: root) == nil)
    }

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

    @Test func failedCheckpointClearPreservesRetryStateForLaterClose() {
        let worktreeId = "draft-commit-tabs-mgr-checkpoint-clear-fails"
        let store = FlakyTabsStore()
        let manager = TabsManager(store: store)
        let draft = manager.openOrFocusDraftCommit(worktreeId: worktreeId)
        let checkpoint = makePublishCheckpoint()
        manager.updateDraftCommit(worktreeId: worktreeId, tabId: draft.id) { state in
            state.publishCheckpoint = checkpoint
        }

        store.failWrites = true
        #expect(!manager.abandonCommitPublishCheckpoint(worktreeId: worktreeId, tabId: draft.id))

        guard case .draftCommit(let liveState) = manager.tabs(forWorktree: worktreeId).first(where: { $0.id == draft.id }) else {
            Issue.record("expected live draftCommit tab")
            return
        }
        #expect(liveState.publishCheckpoint == checkpoint)

        store.failWrites = false
        manager.close(worktreeId: worktreeId, tabId: draft.id)

        let persisted = store.files[Paths.tabsFile(forWorktreeId: worktreeId)]
        #expect(manager.stashedDraft(worktreeId: worktreeId)?.publishCheckpoint == checkpoint)
        #expect(persisted?.stashedDraft?.publishCheckpoint == checkpoint)
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

    @Test func samePathProjectsKeepDraftCommitTabsAndStashesIsolated() {
        let worktreeId = "draft-commit-tabs-mgr-shared-path-\(UUID().uuidString)"
        let tabsDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("alas-draft-project-scope-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tabsDirectory) }
        let manager = TabsManager(store: PersistenceStore(), tabsDirectory: tabsDirectory)

        let projectADraft = manager.openOrFocusDraftCommit(worktreeId: worktreeId, projectId: "project-a")
        manager.updateDraftCommit(worktreeId: worktreeId, tabId: projectADraft.id) { state in
            state.subject = "A's draft"
            state.bodyText = "Only project A"
            state.amend = true
            state.publishCheckpoint = makePublishCheckpoint()
        }
        let projectBDraft = manager.openOrFocusDraftCommit(worktreeId: worktreeId, projectId: "project-b")
        manager.updateDraftCommit(worktreeId: worktreeId, tabId: projectBDraft.id) { state in
            state.subject = "B's draft"
            state.bodyText = "Only project B"
        }

        #expect(projectADraft.id != projectBDraft.id)
        #expect(manager.tabs(forWorktree: worktreeId, projectId: "project-a").compactMap(\.draftCommitState).map(\.subject) == ["A's draft"])
        #expect(manager.tabs(forWorktree: worktreeId, projectId: "project-b").compactMap(\.draftCommitState).map(\.subject) == ["B's draft"])
        #expect(manager.activeTabId(forWorktree: worktreeId, projectId: "project-a") == projectADraft.id)
        #expect(manager.activeTabId(forWorktree: worktreeId, projectId: "project-b") == projectBDraft.id)

        manager.close(worktreeId: worktreeId, tabId: projectADraft.id)
        manager.close(worktreeId: worktreeId, tabId: projectBDraft.id)

        #expect(manager.stashedDraft(worktreeId: worktreeId, projectId: "project-a")?.subject == "A's draft")
        #expect(manager.stashedDraft(worktreeId: worktreeId, projectId: "project-a")?.publishCheckpoint == makePublishCheckpoint())
        #expect(manager.stashedDraft(worktreeId: worktreeId, projectId: "project-b")?.subject == "B's draft")
        #expect(manager.stashedDraft(worktreeId: worktreeId, projectId: "project-b")?.publishCheckpoint == nil)

        let reloaded = TabsManager(store: PersistenceStore(), tabsDirectory: tabsDirectory)
        reloaded.loadAll(worktreeIds: [worktreeId])
        let reopenedB = reloaded.openOrFocusDraftCommit(worktreeId: worktreeId, projectId: "project-b")
        let reopenedA = reloaded.openOrFocusDraftCommit(worktreeId: worktreeId, projectId: "project-a")

        #expect(reopenedA.id == projectADraft.id)
        #expect(reopenedB.id == projectBDraft.id)
        #expect(reopenedA.draftCommitState?.subject == "A's draft")
        #expect(reopenedA.draftCommitState?.amend == true)
        #expect(reopenedA.draftCommitState?.publishCheckpoint == makePublishCheckpoint())
        #expect(reopenedB.draftCommitState?.subject == "B's draft")
        #expect(reloaded.tabs(forWorktree: worktreeId, projectId: "project-a").compactMap(\.draftCommitState).map(\.subject) == ["A's draft"])
        #expect(reloaded.tabs(forWorktree: worktreeId, projectId: "project-b").compactMap(\.draftCommitState).map(\.subject) == ["B's draft"])

        #expect(reloaded.replaceDraftWithCommitEditor(
            worktreeId: worktreeId,
            draftTabId: projectADraft.id,
            baseRef: "main",
            newSha: "a-commit",
            title: "A's commit"
        ) != nil)
        #expect(reloaded.stashedDraft(worktreeId: worktreeId, projectId: "project-a") == nil)
        #expect(reloaded.stashedDraft(worktreeId: worktreeId, projectId: "project-b")?.subject == "B's draft")
    }

    @Test func projectOwnerAdoptsOnlyItsLegacyStashedDraft() {
        let worktreeId = "draft-commit-tabs-mgr-legacy-shared-path-\(UUID().uuidString)"
        let tabsDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("alas-draft-legacy-project-scope-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tabsDirectory) }
        let manager = TabsManager(store: PersistenceStore(), tabsDirectory: tabsDirectory)
        let legacyDraft = manager.openOrFocusDraftCommit(worktreeId: worktreeId)
        manager.updateDraftCommit(worktreeId: worktreeId, tabId: legacyDraft.id) { state in
            state.subject = "Legacy draft"
        }
        manager.close(worktreeId: worktreeId, tabId: legacyDraft.id)

        #expect(manager.stashedDraft(
            worktreeId: worktreeId,
            projectId: "project-a",
            includesLegacyUnownedDraftCommit: true
        )?.subject == "Legacy draft")
        #expect(manager.stashedDraft(worktreeId: worktreeId, projectId: "project-b") == nil)

        let adopted = manager.openOrFocusDraftCommit(
            worktreeId: worktreeId,
            projectId: "project-a",
            includesLegacyUnownedDraftCommit: true
        )
        let sibling = manager.openOrFocusDraftCommit(worktreeId: worktreeId, projectId: "project-b")

        #expect(adopted.id == legacyDraft.id)
        #expect(adopted.draftCommitState?.projectId == "project-a")
        #expect(adopted.draftCommitState?.subject == "Legacy draft")
        #expect(sibling.draftCommitState?.subject == "")
        #expect(manager.tabs(forWorktree: worktreeId, projectId: "project-a").compactMap(\.draftCommitState).map(\.subject) == ["Legacy draft"])
        #expect(manager.tabs(forWorktree: worktreeId, projectId: "project-b").compactMap(\.draftCommitState).map(\.subject) == [""])
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

    @Test func replaceDraftWithCommitEditor_reusesExistingEditorForPublishedCommit() {
        let worktreeId = "draft-commit-tabs-mgr-replace-reuse"
        defer { try? FileManager.default.removeItem(at: Paths.tabsFile(forWorktreeId: worktreeId)) }
        let mgr = TabsManager()
        let draft = mgr.openOrFocusDraftCommit(worktreeId: worktreeId)
        let existing = mgr.openCommitEditor(
            worktreeId: worktreeId,
            baseRef: "main",
            originalSha: "abc1234",
            currentSha: "abc1234",
            title: "abc1234 existing"
        )

        let replaced = mgr.replaceDraftWithCommitEditor(
            worktreeId: worktreeId,
            draftTabId: draft.id,
            baseRef: "main",
            newSha: "abc1234",
            title: "abc1234 feat: foo"
        )

        #expect(replaced?.id == existing.id)
        #expect(mgr.tabs(forWorktree: worktreeId).count == 1)
        #expect(!mgr.tabs(forWorktree: worktreeId).contains { $0.id == draft.id })
        #expect(mgr.activeTabId(forWorktree: worktreeId) == existing.id)
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
            destination: .gg(),
            nextPhase: .push
        )
    }
}

private extension Tab {
    var draftCommitState: DraftCommitTabState? {
        guard case .draftCommit(let state) = self else { return nil }
        return state
    }
}

private final class FlakyTabsStore: PersistenceStoreProtocol, @unchecked Sendable {
    var failWrites = false
    var files: [URL: TabsFile] = [:]

    func write<T: Encodable>(_ value: T, to url: URL) throws {
        if failWrites {
            throw NSError(domain: "DraftCommitTabsManagerTests", code: 1,
                userInfo: [NSLocalizedDescriptionKey: "write rejected"])
        }
        if let file = value as? TabsFile {
            files[url] = file
        }
    }

    func readIfExists<T: Decodable>(_: T.Type, from url: URL) throws -> T? {
        files[url] as? T
    }
}
