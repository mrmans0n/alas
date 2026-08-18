import Foundation
import Testing
@testable import Alas

@Suite(.serialized)
@MainActor
struct StartupRecoveryTests {
    @Test func detectsAnUnfinishedPreviousLaunch() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("alas-startup-recovery-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }

        let recovery = StartupRecovery(
            markerDirectory: directory,
            processID: 42,
            isProcessAlive: { _ in false }
        )

        #expect(recovery.begin() == false)
        #expect(recovery.begin() == true)

        recovery.finish()

        #expect(recovery.begin() == false)
    }

    @Test func ignoresMarkersOwnedByLiveInstances() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("alas-startup-recovery-live-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let liveMarker = directory.appendingPathComponent("launching-7-7000000-live")
        _ = FileManager.default.createFile(atPath: liveMarker.path, contents: Data())

        let recovery = StartupRecovery(
            markerDirectory: directory,
            processID: 42,
            isProcessAlive: { $0 == 7 },
            processStartTime: { $0 == 7 ? 7 : 42 }
        )

        #expect(recovery.begin() == false)
        #expect(FileManager.default.fileExists(atPath: liveMarker.path))
    }

    @Test func treatsReusedPIDMarkerAsAbandoned() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("alas-startup-recovery-reused-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let staleMarker = directory.appendingPathComponent("launching-7-7000000-stale")
        _ = FileManager.default.createFile(atPath: staleMarker.path, contents: Data())

        let recovery = StartupRecovery(
            markerDirectory: directory,
            processID: 42,
            isProcessAlive: { $0 == 7 },
            processStartTime: { $0 == 7 ? 8 : 42 }
        )

        #expect(recovery.begin())
        #expect(!FileManager.default.fileExists(atPath: staleMarker.path))
    }

    @Test func recoveryLoadKeepsTabsWithoutActivatingOne() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("alas-tabs-recovery-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let worktreeID = "worktree"
        let original = TabsManager(store: PersistenceStore(), tabsDirectory: directory)
        let first = original.appendTerminal(worktreeId: worktreeID, title: "First", sessionId: "first")
        let second = original.appendTerminal(worktreeId: worktreeID, title: "Second", sessionId: "second")

        let recovered = TabsManager(store: PersistenceStore(), tabsDirectory: directory)
        recovered.loadAll(worktreeIds: [worktreeID], restoringActiveTabs: false)

        #expect(recovered.tabs(forWorktree: worktreeID).map(\.id) == [first.id, second.id])
        #expect(recovered.activeTabId(forWorktree: worktreeID) == nil)

        let reloaded = TabsManager(store: PersistenceStore(), tabsDirectory: directory)
        reloaded.loadAll(worktreeIds: [worktreeID])
        #expect(reloaded.activeTabId(forWorktree: worktreeID) == nil)
    }

    @Test func recoveryLoadAlsoClearsUndiscoveredWorktrees() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("alas-tabs-recovery-all-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let original = TabsManager(store: PersistenceStore(), tabsDirectory: directory)
        _ = original.appendTerminal(worktreeId: "undiscovered", title: "Terminal", sessionId: "terminal")

        let recovered = TabsManager(store: PersistenceStore(), tabsDirectory: directory)
        recovered.loadAllPersisted(restoringActiveTabs: false)

        #expect(recovered.activeTabId(forWorktree: "undiscovered") == nil)
    }

    @Test func recoveryLoadMarksMissingTabsDirectoryAsLoaded() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("alas-tabs-recovery-missing-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }

        let recovered = TabsManager(store: PersistenceStore(), tabsDirectory: directory)
        recovered.loadAllPersisted(restoringActiveTabs: false)

        #expect(recovered.hasLoaded)
    }

    @Test func missingSelectionDoesNotFallBackToRenderingTheFirstTab() {
        let tab = Tab.terminal(.init(id: "first", title: "First", sessionId: "first"))

        let composition = CenterTabComposition(
            worktreeTabs: [tab],
            activeWorktreeTabId: nil
        )

        #expect(composition.activeId == nil)
    }

    @Test func staleSelectionFallsBackToTheFirstAvailableTab() {
        let tab = Tab.terminal(.init(id: "first", title: "First", sessionId: "first"))

        let composition = CenterTabComposition(
            worktreeTabs: [tab],
            activeWorktreeTabId: "removed-tab"
        )

        #expect(composition.activeId == tab.id)
        #expect(composition.activeTab == tab)
    }

    @Test func recoveryCompletesOnlyAfterTheCenterPaneAppears() {
        let coordinator = AlasTerminationCoordinator.shared
        let originalFinish = coordinator.finish
        defer { coordinator.finish = originalFinish }
        var didFinish = false
        coordinator.finish = { didFinish = true }

        AppState().reloadTabs()

        #expect(!didFinish)

        AppState().completeStartupRecovery()

        #expect(didFinish)
    }

    @Test func recoveryCompletesWhenStartupHasNoCenterPane() {
        let coordinator = AlasTerminationCoordinator.shared
        let originalFinish = coordinator.finish
        defer { coordinator.finish = originalFinish }
        var didFinish = false
        coordinator.finish = { didFinish = true }

        AppState().completeStartupRecoveryIfCenterPaneWillNotAppear()

        #expect(didFinish)
    }

    @Test func recoverySuppressesRestoredRightPaneForTheLaunch() {
        let state = AppState(restoreActiveTabsOnStartup: false)

        #expect(state.suppressesRestoredRightPaneAfterAbandonedStartup)

        state.completeStartupRecovery()

        #expect(state.suppressesRestoredRightPaneAfterAbandonedStartup)
    }

    @Test func asyncRestoredTabsDoNotCompleteRecoveryFromCenterPane() {
        let terminal = Tab.terminal(.init(id: "terminal", title: "Terminal", sessionId: "terminal"))
        let acp = Tab.acpSession(.init(sessionId: "acp", title: "ACP"))
        let history = Tab.fileHistory(.init(worktreeId: "wt", relativePath: "README.md"))
        let editor = Tab.editor(.init(id: "editor", title: "README.md", relativePath: "README.md"))
        let ggInbox = Tab.ggInbox(.init(projectId: "project", projectName: "Project"))

        #expect(!StartupRecoveryPaneCompletionPolicy.shouldComplete(activeTab: terminal))
        #expect(!StartupRecoveryPaneCompletionPolicy.shouldComplete(activeTab: acp))
        #expect(!StartupRecoveryPaneCompletionPolicy.shouldComplete(activeTab: history))
        #expect(!StartupRecoveryPaneCompletionPolicy.shouldComplete(activeTab: editor))
        #expect(!StartupRecoveryPaneCompletionPolicy.shouldComplete(activeTab: ggInbox))
        #expect(StartupRecoveryPaneCompletionPolicy.shouldComplete(activeTab: nil))
    }

    @Test func ggSplitUnavailableRecoveryWaitsForAvailabilityProbe() {
        #expect(!CenterPaneView.shouldCompleteGGSplitStartupRecoveryWhenUnavailable(
            hasLoadedSnapshot: true,
            ggStackLoadState: .inactive,
            ggAvailabilityHasProbed: false
        ))
        #expect(CenterPaneView.shouldCompleteGGSplitStartupRecoveryWhenUnavailable(
            hasLoadedSnapshot: true,
            ggStackLoadState: .inactive,
            ggAvailabilityHasProbed: true
        ))
        #expect(!CenterPaneView.shouldCompleteGGSplitStartupRecoveryWhenUnavailable(
            hasLoadedSnapshot: true,
            ggStackLoadState: .loading,
            ggAvailabilityHasProbed: true
        ))
    }

    @Test func startupRecoveryWaitsForVisibleRightPaneSnapshot() {
        #expect(CenterPaneView.shouldCompleteStartupRecoveryForRightPane(
            isRightPaneVisible: false,
            hasLoadedSnapshot: false,
            isLoading: true,
            ggStackLoadState: .loading
        ))
        #expect(!CenterPaneView.shouldCompleteStartupRecoveryForRightPane(
            isRightPaneVisible: true,
            hasLoadedSnapshot: false,
            isLoading: false,
            ggStackLoadState: .inactive
        ))
        #expect(!CenterPaneView.shouldCompleteStartupRecoveryForRightPane(
            isRightPaneVisible: true,
            hasLoadedSnapshot: true,
            isLoading: true,
            ggStackLoadState: .inactive
        ))
        #expect(!CenterPaneView.shouldCompleteStartupRecoveryForRightPane(
            isRightPaneVisible: true,
            hasLoadedSnapshot: true,
            isLoading: false,
            ggStackLoadState: .loading
        ))
        #expect(CenterPaneView.shouldCompleteStartupRecoveryForRightPane(
            isRightPaneVisible: true,
            hasLoadedSnapshot: true,
            isLoading: false,
            ggStackLoadState: .loaded
        ))
    }

    @Test func asyncTabReadinessCanCompleteAfterRightPaneSettles() {
        let terminal = Tab.terminal(.init(id: "terminal", title: "Terminal", sessionId: "terminal"))

        #expect(!CenterPaneView.shouldCompleteStartupRecoveryForCenterPane(
            activeTab: terminal,
            readyKey: nil,
            currentKey: "terminal\u{0}snapshot-1"
        ))
        #expect(CenterPaneView.shouldCompleteStartupRecoveryForCenterPane(
            activeTab: terminal,
            readyKey: "terminal\u{0}snapshot-1",
            currentKey: "terminal\u{0}snapshot-1"
        ))
        #expect(!CenterPaneView.shouldCompleteStartupRecoveryForCenterPane(
            activeTab: terminal,
            readyKey: "terminal\u{0}snapshot-1",
            currentKey: "terminal\u{0}snapshot-2"
        ))
    }

    @Test func independentAsyncTabReadinessIgnoresRightPaneFingerprintChanges() {
        let terminal = Tab.terminal(.init(id: "terminal", title: "Terminal", sessionId: "terminal"))

        #expect(CenterPaneView.startupRecoveryActiveKey(activeTab: terminal, rightPaneState: nil) ==
            "terminal\u{0}tab")
    }

    @Test func commitEditorDiffTaskRerunsAfterDetailsSettle() {
        #expect(CommitEditorTabView.diffTaskKey(
            currentSha: "abc",
            selectedPath: "file.swift",
            loadingDetails: true
        ) != CommitEditorTabView.diffTaskKey(
            currentSha: "abc",
            selectedPath: "file.swift",
            loadingDetails: false
        ))
    }

    @Test func commitEditorReportsReadinessOnlyForCurrentDiffTask() {
        #expect(CommitEditorTabView.shouldReportStartupRecoveryReady(
            requestedDiffTaskKey: "sha:file:false",
            currentDiffTaskKey: "sha:file:false",
            isCancelled: false
        ))
        #expect(!CommitEditorTabView.shouldReportStartupRecoveryReady(
            requestedDiffTaskKey: "sha:file:false",
            currentDiffTaskKey: "next:file:false",
            isCancelled: false
        ))
        #expect(!CommitEditorTabView.shouldReportStartupRecoveryReady(
            requestedDiffTaskKey: "sha:file:false",
            currentDiffTaskKey: "sha:file:false",
            isCancelled: true
        ))
    }
}
