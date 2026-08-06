import Foundation
import Observation

enum GlobalTab: Codable, Equatable, Identifiable {
    case mission(MissionTabState)

    var id: TabID {
        switch self {
        case .mission(let state): state.id
        }
    }
}

struct GlobalTabsFile: Codable {
    var version: Int = 1
    var migrationVersion: Int = 0
    var tabs: [GlobalTab]
    var activeTabId: TabID?
    var suppressedLegacyMissionTabIds: Set<TabID>

    init(
        version: Int = 1,
        migrationVersion: Int = 0,
        tabs: [GlobalTab] = [],
        activeTabId: TabID? = nil,
        suppressedLegacyMissionTabIds: Set<TabID> = []
    ) {
        self.version = version
        self.migrationVersion = migrationVersion
        self.tabs = tabs
        self.activeTabId = activeTabId
        self.suppressedLegacyMissionTabIds = suppressedLegacyMissionTabIds
    }
}

extension GlobalTabsFile {
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        version = (try? container.decode(Int.self, forKey: .version)) ?? 1
        migrationVersion = (try? container.decode(Int.self, forKey: .migrationVersion)) ?? 0
        activeTabId = try? container.decode(TabID.self, forKey: .activeTabId)
        suppressedLegacyMissionTabIds =
            (try? container.decode(Set<TabID>.self, forKey: .suppressedLegacyMissionTabIds)) ?? []
        tabs = ((try? container.decode([FailableGlobalTab].self, forKey: .tabs)) ?? []).compactMap(\.value)
    }

    private struct FailableGlobalTab: Decodable {
        let value: GlobalTab?

        init(from decoder: Decoder) throws {
            value = try? GlobalTab(from: decoder)
        }
    }
}

@Observable
@MainActor
final class GlobalTabsManager {
    private let store: any PersistenceStoreProtocol
    private let fileURL: URL
    private(set) var tabs: [GlobalTab] = []
    private(set) var activeTabId: TabID?
    private var migrationVersion = 0
    private var suppressedLegacyMissionTabIds: Set<TabID> = []

    init(
        store: any PersistenceStoreProtocol = PersistenceStore(),
        fileURL: URL = Paths.globalTabsFile
    ) {
        self.store = store
        self.fileURL = fileURL
    }

    @discardableResult
    func openOrFocusMission(missionID: MissionID, title: String) -> GlobalTab {
        let state = MissionTabState(missionID: missionID, title: title)
        let tab = GlobalTab.mission(state)
        if let index = tabs.firstIndex(where: { $0.id == tab.id }) {
            tabs[index] = tab
        } else {
            tabs.append(tab)
        }
        suppressedLegacyMissionTabIds.remove(tab.id)
        activeTabId = tab.id
        try? persist()
        return tab
    }

    func close(tabId: TabID) {
        guard let index = tabs.firstIndex(where: { $0.id == tabId }) else { return }
        let tab = tabs[index]
        let wasActive = activeTabId == tabId
        tabs.remove(at: index)
        if migrationVersion < 1, case .mission = tab {
            suppressedLegacyMissionTabIds.insert(tabId)
        }
        if wasActive {
            activeTabId = tabs.indices.contains(index) ? tabs[index].id : tabs.last?.id
        }
        try? persist()
    }

    func activate(tabId: TabID) {
        guard tabs.contains(where: { $0.id == tabId }) else { return }
        activeTabId = tabId
        try? persist()
    }

    @discardableResult
    func restore(tab: GlobalTab, placement: ClosedTabPlacement) -> TabID {
        if tabs.contains(where: { $0.id == tab.id }) {
            activeTabId = tab.id
        } else {
            let index = placement.insertionIndex(in: tabs.map(\.id))
            tabs.insert(tab, at: index)
            activeTabId = tab.id
        }
        suppressedLegacyMissionTabIds.remove(tab.id)
        try? persist()
        return tab.id
    }

    func clearActiveTab() {
        guard activeTabId != nil else { return }
        activeTabId = nil
        try? persist()
    }

    func updateMissionTitle(missionID: MissionID, title: String) {
        guard let index = tabs.firstIndex(where: { tab in
            guard case .mission(let state) = tab else { return false }
            return state.missionID == missionID
        }), case .mission(let state) = tabs[index], state.title != title
        else { return }
        tabs[index] = .mission(MissionTabState(missionID: missionID, title: title))
        try? persist()
    }

    func activeMissionTab() -> MissionTabState? {
        guard let activeTabId,
              let tab = tabs.first(where: { $0.id == activeTabId }),
              case .mission(let state) = tab
        else { return nil }
        return state
    }

    func loadPersistedTabs() throws {
        let file = try store.readIfExists(GlobalTabsFile.self, from: fileURL) ?? GlobalTabsFile()
        tabs = Self.deduplicated(file.tabs)
        activeTabId = tabs.contains(where: { $0.id == file.activeTabId }) ? file.activeTabId : nil
        migrationVersion = file.migrationVersion
        suppressedLegacyMissionTabIds = file.suppressedLegacyMissionTabIds
    }

    func migrateLegacyMissionTabs(
        worktreeTabs: TabsManager,
        selectedWorktreeID: String? = nil
    ) throws {
        guard migrationVersion < 1 else { return }

        worktreeTabs.loadAllPersisted()

        let activeLegacyMission = worktreeTabs.activeMissionTab(preferredWorktreeID: selectedWorktreeID)
            .flatMap { suppressedLegacyMissionTabIds.contains($0.id) ? nil : $0 }
        merge(worktreeTabs.missionTabs())
        if activeTabId == nil, let activeLegacyMission {
            activeTabId = activeLegacyMission.id
        }
        // Persist the imported states before their worktree copies are removed.
        // If the process stops here, the next load repeats safely from this file.
        try persist()
        merge(try worktreeTabs.extractMissionTabs())
        migrationVersion = 1
        suppressedLegacyMissionTabIds.removeAll()
        try persist()
    }

    func loadAndMigrate(worktreeTabs: TabsManager, selectedWorktreeID: String? = nil) throws {
        try loadPersistedTabs()
        try migrateLegacyMissionTabs(
            worktreeTabs: worktreeTabs,
            selectedWorktreeID: selectedWorktreeID
        )
    }

    private func merge(_ states: [MissionTabState]) {
        for state in states where !suppressedLegacyMissionTabIds.contains(state.id)
            && !tabs.contains(where: { $0.id == state.id }) {
            tabs.append(.mission(state))
        }
    }

    private func persist() throws {
        try store.write(
            GlobalTabsFile(
                migrationVersion: migrationVersion,
                tabs: tabs,
                activeTabId: activeTabId,
                suppressedLegacyMissionTabIds: suppressedLegacyMissionTabIds
            ),
            to: fileURL
        )
    }

    private static func deduplicated(_ tabs: [GlobalTab]) -> [GlobalTab] {
        var seen: Set<TabID> = []
        return tabs.filter { seen.insert($0.id).inserted }
    }
}
