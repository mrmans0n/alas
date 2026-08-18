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
        let liveMarker = directory.appendingPathComponent("launching-7-live")
        _ = FileManager.default.createFile(atPath: liveMarker.path, contents: Data())

        let recovery = StartupRecovery(
            markerDirectory: directory,
            processID: 42,
            isProcessAlive: { $0 == 7 }
        )

        #expect(recovery.begin() == false)
        #expect(FileManager.default.fileExists(atPath: liveMarker.path))
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
    }

    @Test func reloadTabsMarksStartupRecoveryComplete() {
        let coordinator = AlasTerminationCoordinator.shared
        let originalFinish = coordinator.finish
        defer { coordinator.finish = originalFinish }
        var didFinish = false
        coordinator.finish = { didFinish = true }

        AppState().reloadTabs()

        #expect(didFinish)
    }
}
