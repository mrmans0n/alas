import Foundation
import Testing
@testable import Alas

@MainActor
@Suite(.serialized)
struct GlobalTabsManagerTests {
    @Test("global Mission tabs round trip with their stable Mission ID")
    func roundTripsGlobalMissionTabs() throws {
        let harness = try GlobalTabsHarness()

        let opened = harness.global.openOrFocusMission(
            missionID: MissionID(rawValue: "mission-1"),
            title: "Fix offline sync conflicts"
        )
        let restored = GlobalTabsManager(fileURL: harness.globalTabsFile)

        try restored.loadAndMigrate(worktreeTabs: harness.tabs)

        #expect(opened.id == "mission:mission-1")
        #expect(restored.tabs == [.mission(.fixture)])
        #expect(restored.activeTabId == "mission:mission-1")
    }

    @Test("opening one Mission twice keeps one global tab")
    func openOrFocusKeepsMissionIDsStable() throws {
        let harness = try GlobalTabsHarness()

        let first = harness.global.openOrFocusMission(
            missionID: MissionID(rawValue: "mission-1"),
            title: "Old title"
        )
        let refreshed = harness.global.openOrFocusMission(
            missionID: MissionID(rawValue: "mission-1"),
            title: "New title"
        )

        #expect(first.id == "mission:mission-1")
        #expect(refreshed.id == first.id)
        #expect(harness.global.tabs == [.mission(.init(
            missionID: MissionID(rawValue: "mission-1"),
            title: "New title"
        ))])
    }

    @Test("activate and close persist global active Mission selection")
    func activateAndClosePersistActiveSelection() throws {
        let harness = try GlobalTabsHarness()

        let first = harness.global.openOrFocusMission(
            missionID: MissionID(rawValue: "mission-1"),
            title: "First Mission"
        )
        let second = harness.global.openOrFocusMission(
            missionID: MissionID(rawValue: "mission-2"),
            title: "Second Mission"
        )
        harness.global.activate(tabId: first.id)

        let restored = GlobalTabsManager(fileURL: harness.globalTabsFile)
        try restored.loadAndMigrate(worktreeTabs: harness.tabs)
        #expect(restored.activeTabId == first.id)

        restored.activate(tabId: second.id)
        restored.close(tabId: second.id)

        let closedRestored = GlobalTabsManager(fileURL: harness.globalTabsFile)
        try closedRestored.loadAndMigrate(worktreeTabs: harness.tabs)
        #expect(closedRestored.tabs == [.mission(.init(
            missionID: MissionID(rawValue: "mission-1"),
            title: "First Mission"
        ))])
        #expect(closedRestored.activeTabId == first.id)
    }

    @Test("global tabs skip an unknown future case without dropping Mission tabs")
    func skipsUnknownGlobalTabs() throws {
        let known = GlobalTab.mission(.fixture)
        let encoded = try #require(
            try JSONSerialization.jsonObject(with: JSONEncoder().encode(known)) as? [String: Any]
        )
        let data = try JSONSerialization.data(withJSONObject: [
            "version": 1,
            "migrationVersion": 1,
            "tabs": [encoded, ["futureMission": ["_0": ["id": "future"]]]],
            "activeTabId": known.id,
        ])

        let decoded = try JSONDecoder().decode(GlobalTabsFile.self, from: data)

        #expect(decoded.tabs == [known])
        #expect(decoded.activeTabId == known.id)
    }

    @Test("migration deduplicates Mission tabs across worktrees")
    func migratesWorktreeMissionTabs() throws {
        let harness = try GlobalTabsHarness(
            worktreeTabs: ["app": [.mission(.fixture)], "sdk": [.mission(.fixture)]]
        )

        try harness.global.loadAndMigrate(worktreeTabs: harness.tabs)

        #expect(harness.global.tabs.map(\.id) == ["mission:mission-1"])
        #expect(harness.tabs.tabs(forWorktree: "app").isEmpty)
        #expect(harness.tabs.tabs(forWorktree: "sdk").isEmpty)
    }

    @Test("migration repairs an active worktree Mission tab")
    func migrationRepairsActiveWorktreeTab() throws {
        let terminal = Tab.terminal(.init(id: "terminal-1", title: "Shell", sessionId: "session-1"))
        let harness = try GlobalTabsHarness(
            worktreeTabs: ["app": [.mission(.fixture), terminal]],
            activeTabIDs: ["app": "mission:mission-1"]
        )

        try harness.global.loadAndMigrate(worktreeTabs: harness.tabs)

        #expect(harness.global.activeMissionTab() == .fixture)
        #expect(harness.tabs.tabs(forWorktree: "app") == [terminal])
        #expect(harness.tabs.activeTabId(forWorktree: "app") == terminal.id)
    }

    @Test("migration imports Mission tabs from unavailable worktrees before completing")
    func migrationImportsOrphanedWorktreeTabs() throws {
        let harness = try GlobalTabsHarness(
            worktreeTabs: ["orphaned-sdk": [.mission(.fixture)]],
            worktreeIds: []
        )

        try harness.global.loadAndMigrate(worktreeTabs: harness.tabs)

        #expect(harness.global.tabs == [.mission(.fixture)])
        #expect(harness.tabs.tabs(forWorktree: "orphaned-sdk").isEmpty)
    }

    @Test("migration resumes safely after global tabs were written before completion")
    func migrationResumesAfterPartialWrite() throws {
        let harness = try GlobalTabsHarness(
            worktreeTabs: ["app": [.mission(.fixture)]]
        )
        let store = PersistenceStore()
        try store.write(
            GlobalTabsFile(
                migrationVersion: 0,
                tabs: [.mission(.fixture)],
                activeTabId: "mission:mission-1"
            ),
            to: harness.globalTabsFile
        )

        try harness.global.loadAndMigrate(worktreeTabs: harness.tabs)
        let resumed = GlobalTabsManager(fileURL: harness.globalTabsFile)
        try resumed.loadAndMigrate(worktreeTabs: harness.tabs)

        #expect(resumed.tabs == [.mission(.fixture)])
        #expect(harness.tabs.tabs(forWorktree: "app").isEmpty)
        #expect(try store.read(GlobalTabsFile.self, from: harness.globalTabsFile).migrationVersion == 1)
    }

    @Test("migration preserves worktree Mission tabs when the global import cannot persist")
    func migrationDoesNotExtractWhenGlobalImportFails() throws {
        let harness = try GlobalTabsHarness(
            worktreeTabs: ["app": [.mission(.fixture)]]
        )
        let unwritableGlobalFile = URL(fileURLWithPath: "/dev/null/global-tabs.json")
        let global = GlobalTabsManager(fileURL: unwritableGlobalFile)

        #expect(throws: (any Error).self) {
            try global.loadAndMigrate(worktreeTabs: harness.tabs)
        }
        #expect(harness.tabs.tabs(forWorktree: "app") == [.mission(.fixture)])
    }

    @Test("migration keeps worktree Mission tabs and remains retryable when extraction cannot persist")
    func migrationDoesNotCompleteWhenWorktreeExtractionFails() throws {
        let failingStore = WriteFailingTabsStore(files: [
            "app": TabsFile(tabs: [.mission(.fixture)], activeTabId: "mission:mission-1"),
        ])
        let harness = try GlobalTabsHarness(
            tabsStore: failingStore,
            worktreeIds: ["app"]
        )

        #expect(throws: (any Error).self) {
            try harness.global.loadAndMigrate(worktreeTabs: harness.tabs)
        }

        let persisted = try PersistenceStore().read(GlobalTabsFile.self, from: harness.globalTabsFile)
        #expect(persisted.migrationVersion == 0)
        #expect(persisted.tabs == [.mission(.fixture)])
        #expect(harness.tabs.tabs(forWorktree: "app") == [.mission(.fixture)])
    }
}

@MainActor
private final class GlobalTabsHarness {
    let root: URL
    let tabs: TabsManager
    let global: GlobalTabsManager
    let globalTabsFile: URL

    init(
        worktreeTabs: [String: [Tab]] = [:],
        activeTabIDs: [String: TabID] = [:],
        tabsStore: (any PersistenceStoreProtocol)? = nil,
        worktreeIds: [String]? = nil
    ) throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("alas-global-tabs-\(UUID().uuidString)", isDirectory: true)
        let tabsDirectory = root.appendingPathComponent("tabs", isDirectory: true)
        globalTabsFile = root.appendingPathComponent("global-tabs.json")
        let store = PersistenceStore()
        for (worktreeID, tabs) in worktreeTabs {
            try store.write(
                TabsFile(tabs: tabs, activeTabId: activeTabIDs[worktreeID]),
                to: tabsDirectory.appendingPathComponent("\(worktreeID).json")
            )
        }
        self.tabs = TabsManager(
            store: tabsStore ?? PersistenceStore(),
            tabsDirectory: tabsDirectory
        )
        self.tabs.loadAll(worktreeIds: worktreeIds ?? Array(worktreeTabs.keys))
        global = GlobalTabsManager(fileURL: globalTabsFile)
    }

    deinit {
        try? FileManager.default.removeItem(at: root)
    }
}

private struct WriteFailingTabsStore: PersistenceStoreProtocol {
    let files: [String: TabsFile]
    let error = NSError(
        domain: "GlobalTabsManagerTests",
        code: 1,
        userInfo: [NSLocalizedDescriptionKey: "write rejected"]
    )

    func write<T: Encodable>(_: T, to _: URL) throws {
        throw error
    }

    func readIfExists<T: Decodable>(_: T.Type, from url: URL) throws -> T? {
        files[url.deletingPathExtension().lastPathComponent] as? T
    }
}

private extension MissionTabState {
    static let fixture = MissionTabState(
        missionID: MissionID(rawValue: "mission-1"),
        title: "Fix offline sync conflicts"
    )
}
