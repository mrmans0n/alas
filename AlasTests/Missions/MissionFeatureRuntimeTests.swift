import Combine
import Foundation
import Testing
@testable import Alas

@Suite("Mission feature runtime", .serialized)
@MainActor
struct MissionFeatureRuntimeTests {
    @Test("AppState observes Mission feature flag updates without Settings pane")
    func appStateObservesFeatureFlagUpdatesWithoutSettingsPane() async {
        let updates = PassthroughSubject<Bool, Never>()
        let state = AppState(
            store: MemoryStore(),
            missionPersistence: MissionPersistence(path: "/tmp/unused-missions.sqlite"),
            missionsEnabled: true,
            missionsFeatureUpdates: updates.eraseToAnyPublisher()
        )
        defer { state.setMissionsEnabled(false) }

        updates.send(false)
        for _ in 0..<20 where state.missionsEnabled {
            await Task.yield()
        }

        #expect(!state.missionsEnabled)
    }

    @Test("disabled tab reload preserves legacy Mission tabs without migration writes")
    func disabledTabReloadPreservesLegacyMissionTabs() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("disabled-mission-tab-reload-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let tabsDirectory = root.appendingPathComponent("tabs", isDirectory: true)
        let worktreeID = "worktree-1"
        let tabsFile = tabsDirectory.appendingPathComponent("\(worktreeID).json")
        let globalTabsFile = root.appendingPathComponent("global-tabs.json")
        let mission = MissionTabState(
            missionID: MissionID(rawValue: "mission-1"),
            title: "Fix issue 42"
        )
        try PersistenceStore().write(
            TabsFile(tabs: [.mission(mission)], activeTabId: mission.id),
            to: tabsFile
        )
        let persistedBeforeReload = try Data(contentsOf: tabsFile)
        let project = ProjectConfig(
            id: "project-1",
            name: "Alas",
            path: "/tmp/alas",
            color: "#5fb7c4",
            addedAt: Date(timeIntervalSince1970: 0)
        )
        let worktree = Worktree(
            id: worktreeID,
            projectId: project.id,
            name: "fix-42",
            branch: "fix-42",
            path: URL(fileURLWithPath: "/tmp/alas-fix-42"),
            status: .clean,
            lastActivity: Date(timeIntervalSince1970: 0)
        )
        let worktreeTabs = TabsManager(tabsDirectory: tabsDirectory)
        let globalTabs = GlobalTabsManager(fileURL: globalTabsFile)
        let state = AppState(
            store: ProjectStore(project: project),
            missionsEnabled: false,
            globalTabs: globalTabs,
            tabsManager: worktreeTabs
        )
        state.projectsManager.insertOptimisticWorktree(worktree)

        state.reloadTabs()

        #expect(worktreeTabs.tabs(forWorktree: worktreeID) == [.mission(mission)])
        #expect(worktreeTabs.activeTabId(forWorktree: worktreeID) == mission.id)
        #expect(try Data(contentsOf: tabsFile) == persistedBeforeReload)
        #expect(!FileManager.default.fileExists(atPath: globalTabsFile.path))
        #expect(globalTabs.tabs.isEmpty)
    }

    @Test("enabled tab reload restores persisted global Mission tabs before migration")
    func enabledTabReloadRestoresPersistedGlobalTabsBeforeMigration() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("enabled-global-mission-reload-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let tabsDirectory = root.appendingPathComponent("tabs", isDirectory: true)
        let globalTabsFile = root.appendingPathComponent("global-tabs.json")
        let mission = MissionTabState(
            missionID: MissionID(rawValue: "persisted-mission"),
            title: "Persisted mission"
        )
        try PersistenceStore().write(
            GlobalTabsFile(
                migrationVersion: 1,
                tabs: [.mission(mission)],
                activeTabId: mission.id
            ),
            to: globalTabsFile
        )
        let project = ProjectConfig(
            id: "project-1",
            name: "Alas",
            path: "/tmp/alas",
            color: "#5fb7c4",
            addedAt: Date(timeIntervalSince1970: 0)
        )
        let worktree = Worktree(
            id: "worktree-1",
            projectId: project.id,
            name: "main",
            branch: "main",
            path: URL(fileURLWithPath: "/tmp/alas"),
            status: .clean,
            lastActivity: Date(timeIntervalSince1970: 0)
        )
        let globalTabs = GlobalTabsManager(fileURL: globalTabsFile)
        let state = AppState(
            store: ProjectStore(project: project),
            missionsEnabled: true,
            globalTabs: globalTabs,
            tabsManager: TabsManager(tabsDirectory: tabsDirectory)
        )
        state.projectsManager.insertOptimisticWorktree(worktree)

        state.reloadTabs()

        #expect(globalTabs.tabs == [.mission(mission)])
        #expect(globalTabs.activeTabId == mission.id)
    }

    @Test("enabling at runtime migrates legacy worktree Mission tabs")
    func enablingAtRuntimeMigratesLegacyWorktreeMissionTabs() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("enable-runtime-mission-migration-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let tabsDirectory = root.appendingPathComponent("tabs", isDirectory: true)
        let worktreeID = "worktree-1"
        let tabsFile = tabsDirectory.appendingPathComponent("\(worktreeID).json")
        let globalTabsFile = root.appendingPathComponent("global-tabs.json")
        let mission = MissionTabState(
            missionID: MissionID(rawValue: "runtime-mission"),
            title: "Runtime mission"
        )
        try PersistenceStore().write(
            TabsFile(tabs: [.mission(mission)], activeTabId: mission.id),
            to: tabsFile
        )
        let project = ProjectConfig(
            id: "project-1",
            name: "Alas",
            path: "/tmp/alas",
            color: "#5fb7c4",
            addedAt: Date(timeIntervalSince1970: 0)
        )
        let worktree = Worktree(
            id: worktreeID,
            projectId: project.id,
            name: "main",
            branch: "main",
            path: URL(fileURLWithPath: "/tmp/alas"),
            status: .clean,
            lastActivity: Date(timeIntervalSince1970: 0)
        )
        let worktreeTabs = TabsManager(tabsDirectory: tabsDirectory)
        let globalTabs = GlobalTabsManager(fileURL: globalTabsFile)
        let state = AppState(
            store: ProjectStore(project: project),
            missionPersistence: MissionPersistence(path: root.appendingPathComponent("missions.sqlite").path),
            missionsEnabled: false,
            globalTabs: globalTabs,
            tabsManager: worktreeTabs
        )
        state.projectsManager.insertOptimisticWorktree(worktree)
        state.selectedWorktreeId = worktreeID
        state.reloadTabs()

        state.setMissionsEnabled(true)
        await state.waitForMissionFeatureTransitionForTesting()
        defer { state.setMissionsEnabled(false) }

        #expect(globalTabs.tabs == [.mission(mission)])
        #expect(globalTabs.activeTabId == mission.id)
        #expect(worktreeTabs.tabs(forWorktree: worktreeID).isEmpty)
    }

    @Test("disabled startup does not open Mission persistence")
    func disabledStartupDoesNotOpenPersistence() async {
        let databaseURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("disabled-missions-\(UUID().uuidString).sqlite")
        let state = AppState(
            store: MemoryStore(),
            missionPersistence: MissionPersistence(path: databaseURL.path),
            missionsEnabled: false,
            globalTabs: GlobalTabsManager(
                store: MemoryStore(),
                fileURL: databaseURL.deletingPathExtension().appendingPathExtension("tabs.json")
            )
        )

        await state.loadMissionsIfEnabledForStartup()

        #expect(!FileManager.default.fileExists(atPath: databaseURL.path))
    }

    @Test("enabling loads once without replacing worktree selection")
    func enablingLoadsWithoutReplacingSelection() async {
        let databaseURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("enabled-missions-\(UUID().uuidString).sqlite")
        let tabsStore = RecordingStore()
        let state = AppState(
            store: MemoryStore(),
            missionPersistence: MissionPersistence(path: databaseURL.path),
            missionsEnabled: false,
            globalTabs: GlobalTabsManager(
                store: tabsStore,
                fileURL: databaseURL.deletingPathExtension().appendingPathExtension("tabs.json")
            )
        )
        defer { state.setMissionsEnabled(false) }
        state.selectedWorktreeId = "selected-before-enable"

        state.setMissionsEnabled(true)
        state.setMissionsEnabled(true)
        await state.waitForMissionFeatureTransitionForTesting()

        #expect(FileManager.default.fileExists(atPath: databaseURL.path))
        #expect(tabsStore.readIfExistsCalls == 1)
        #expect(state.missions.loadState == .loaded)
        #expect(state.selectedWorktreeId == "selected-before-enable")
    }

    @Test("disabling clears Mission focus without deleting persisted tabs")
    func disablingPreservesMissionTabs() {
        let tabs = GlobalTabsManager(store: MemoryStore(), fileURL: URL(fileURLWithPath: "/tmp/unused-tabs.json"))
        let missionID = MissionID(rawValue: "mission-1")
        tabs.openOrFocusMission(missionID: missionID, title: "Fix issue 42")
        let state = AppState(
            store: MemoryStore(),
            missionPersistence: MissionPersistence(path: "/tmp/unused-missions.sqlite"),
            missionsEnabled: true,
            globalTabs: tabs
        )

        state.setMissionsEnabled(false)

        #expect(tabs.activeTabId == nil)
        #expect(tabs.tabs == [.mission(MissionTabState(missionID: missionID, title: "Fix issue 42"))])
    }

    @Test("disabling reselects a visible worktree when the selected worktree is hidden")
    func disablingSelectsVisibleWorktreeWhenCurrentSelectionIsHidden() {
        let project = ProjectConfig(
            id: "project-1",
            name: "Alas",
            path: "/tmp/alas",
            color: "#5fb7c4",
            addedAt: Date(timeIntervalSince1970: 0)
        )
        let visible = Worktree(
            id: "visible-worktree",
            projectId: project.id,
            name: "main",
            branch: "main",
            path: URL(fileURLWithPath: "/tmp/alas"),
            status: .clean,
            lastActivity: Date(timeIntervalSince1970: 0)
        )
        let hidden = Worktree(
            id: "hidden-worktree",
            projectId: project.id,
            name: "mission",
            branch: "mission",
            path: URL(fileURLWithPath: "/tmp/alas-mission"),
            status: .clean,
            lastActivity: Date(timeIntervalSince1970: 1)
        )
        let state = AppState(
            store: ProjectStore(project: project),
            missionPersistence: MissionPersistence(path: "/tmp/unused-missions.sqlite"),
            missionsEnabled: true
        )
        state.spacesManager.addProject(project.id, toSpace: state.spacesManager.activeSpaceId)
        state.projectsManager.insertOptimisticWorktree(visible)
        state.projectsManager.insertOptimisticWorktree(hidden)
        state.projectsManager.setWorktreeHidden(projectId: project.id, path: hidden.path, hidden: true)
        state.selectWorktree(id: hidden.id)

        state.setMissionsEnabled(false)

        #expect(state.selectedWorktreeId == visible.id)
    }

    @Test("disabled center fallback synchronizes the active worktree tab")
    func disabledCenterFallbackSynchronizesActiveWorktreeTab() {
        let worktreeID = "worktree-center-fallback"
        let tabsManager = TabsManager()
        let mission = tabsManager.openOrFocusMission(
            worktreeId: worktreeID,
            missionID: MissionID(rawValue: "mission-center-fallback"),
            title: "Hidden Mission"
        )
        let terminal = tabsManager.appendTerminal(
            worktreeId: worktreeID,
            title: "Terminal",
            sessionId: "session-center-fallback"
        )
        tabsManager.activate(worktreeId: worktreeID, tabId: mission.id)
        let state = AppState(
            store: MemoryStore(),
            missionPersistence: MissionPersistence(path: "/tmp/unused-missions.sqlite"),
            missionsEnabled: false,
            tabsManager: tabsManager
        )

        state.synchronizeVisibleWorktreeCenterTabIfNeeded(
            worktreeId: worktreeID,
            activeTabId: terminal.id,
            missionsEnabled: false
        )

        #expect(state.tabs.activeTabId(forWorktree: worktreeID) == terminal.id)
    }

    @Test("disabled center fallback clears hidden active Mission when no visible tab remains")
    func disabledCenterFallbackClearsHiddenMissionWhenNoVisibleTabRemains() {
        let worktreeID = "worktree-center-empty"
        let tabsManager = TabsManager()
        let mission = tabsManager.openOrFocusMission(
            worktreeId: worktreeID,
            missionID: MissionID(rawValue: "mission-center-empty"),
            title: "Hidden Mission"
        )
        tabsManager.activate(worktreeId: worktreeID, tabId: mission.id)
        let state = AppState(
            store: MemoryStore(),
            missionPersistence: MissionPersistence(path: "/tmp/unused-missions.sqlite"),
            missionsEnabled: false,
            tabsManager: tabsManager
        )

        state.synchronizeVisibleWorktreeCenterTabIfNeeded(
            worktreeId: worktreeID,
            activeTabId: nil,
            missionsEnabled: false
        )

        let persistedTabs = state.tabs.tabs(forWorktree: worktreeID)
        #expect(persistedTabs.count == 1)
        if case .mission(let missionState)? = persistedTabs.first {
            #expect(missionState.id == mission.id)
        } else {
            Issue.record("Expected Mission tab to remain persisted")
        }
        #expect(state.tabs.activeTabId(forWorktree: worktreeID) == nil)
    }

    @Test("suspending during Git prevents the next durable checkpoint")
    func suspendingDuringGitPreventsNextCheckpoint() async throws {
        let databaseURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("suspended-missions-\(UUID().uuidString).sqlite")
        let persistence = MissionPersistence(path: databaseURL.path)
        let gate = WorktreeGate()
        var startACPCalls = 0
        let worktree = Worktree(
            id: "worktree-1",
            projectId: "project-1",
            name: "fix-42",
            branch: "fix-42",
            path: URL(fileURLWithPath: "/tmp/fix-42"),
            status: .clean,
            lastActivity: .now,
            lineageID: "lineage-1"
        )
        var ids = ["mission-1", "leg-1", "created-event"]
        let coordinator = MissionCoordinator(environment: .init(
            persistence: persistence,
            now: Date.init,
            makeID: { ids.removeFirst() },
            worktreeAtDestination: { _, _ in nil },
            createWorktree: { _ in await gate.wait() },
            startACP: { leg, _ in
                startACPCalls += 1
                return .success(leg.acpSessionId ?? "session-1")
            },
            notifyChanged: { _ in }
        ))
        let draft = MissionDraft(
            source: MissionSourceSnapshot(issue: MissionFixtures.issue()),
            projectId: "project-1",
            baseRef: "origin/main",
            baseRemoteName: "origin",
            branch: "fix-42",
            destinationPath: "/tmp/fix-42",
            agentId: "codex",
            initialPromptId: UUID(),
            initialPrompt: "Fix issue 42."
        )

        let missionID = try await coordinator.create(draft)
        await gate.waitUntilStarted()
        coordinator.suspend()
        gate.resume(with: .success(worktree))
        for _ in 0..<20 { await Task.yield() }

        let aggregate = try #require(try await persistence.aggregate(id: missionID))
        #expect(aggregate.primaryLeg?.setupCheckpoint == .creatingWorktree)
        #expect(!aggregate.events.contains { $0.kind == .worktreeCreated })
        #expect(startACPCalls == 0)
    }
}

@MainActor
private final class WorktreeGate {
    private var continuation: CheckedContinuation<Result<Worktree, WorktreeCreationFailure>, Never>?
    private var started = false

    func wait() async -> Result<Worktree, WorktreeCreationFailure> {
        started = true
        return await withCheckedContinuation { continuation = $0 }
    }

    func waitUntilStarted() async {
        while !started { await Task.yield() }
    }

    func resume(with result: Result<Worktree, WorktreeCreationFailure>) {
        continuation?.resume(returning: result)
        continuation = nil
    }
}

private struct MemoryStore: PersistenceStoreProtocol {
    func read<T: Decodable>(_: T.Type, from _: URL) throws -> T { throw CocoaError(.fileNoSuchFile) }
    func readIfExists<T: Decodable>(_: T.Type, from _: URL) throws -> T? { nil }
    func write<T: Encodable>(_: T, to _: URL) throws {}
}

private struct ProjectStore: PersistenceStoreProtocol {
    let project: ProjectConfig

    func read<T: Decodable>(_: T.Type, from _: URL) throws -> T { throw CocoaError(.fileNoSuchFile) }

    func readIfExists<T: Decodable>(_ type: T.Type, from _: URL) throws -> T? {
        type == ProjectsFile.self ? ProjectsFile(projects: [project]) as? T : nil
    }

    func write<T: Encodable>(_: T, to _: URL) throws {}
}

private final class RecordingStore: PersistenceStoreProtocol, @unchecked Sendable {
    private(set) var readIfExistsCalls = 0

    func read<T: Decodable>(_: T.Type, from _: URL) throws -> T { throw CocoaError(.fileNoSuchFile) }

    func readIfExists<T: Decodable>(_: T.Type, from _: URL) throws -> T? {
        readIfExistsCalls += 1
        return nil
    }

    func write<T: Encodable>(_: T, to _: URL) throws {}
}
