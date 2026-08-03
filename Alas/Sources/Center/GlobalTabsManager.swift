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

    init(
        version: Int = 1,
        migrationVersion: Int = 0,
        tabs: [GlobalTab] = [],
        activeTabId: TabID? = nil
    ) {
        self.version = version
        self.migrationVersion = migrationVersion
        self.tabs = tabs
        self.activeTabId = activeTabId
    }
}

extension GlobalTabsFile {
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        version = (try? container.decode(Int.self, forKey: .version)) ?? 1
        migrationVersion = (try? container.decode(Int.self, forKey: .migrationVersion)) ?? 0
        activeTabId = try? container.decode(TabID.self, forKey: .activeTabId)
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
        activeTabId = tab.id
        try? persist()
        return tab
    }

    func close(tabId: TabID) {
        guard let index = tabs.firstIndex(where: { $0.id == tabId }) else { return }
        let wasActive = activeTabId == tabId
        tabs.remove(at: index)
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

    func loadAndMigrate(worktreeTabs: TabsManager) throws {
        let file = try store.readIfExists(GlobalTabsFile.self, from: fileURL) ?? GlobalTabsFile()
        tabs = Self.deduplicated(file.tabs)
        activeTabId = tabs.contains(where: { $0.id == file.activeTabId }) ? file.activeTabId : nil
        migrationVersion = file.migrationVersion

        guard migrationVersion < 1 else { return }

        worktreeTabs.loadAllPersisted()

        merge(worktreeTabs.missionTabs())
        // Persist the imported states before their worktree copies are removed.
        // If the process stops here, the next load repeats safely from this file.
        try persist()
        merge(try worktreeTabs.extractMissionTabs())
        migrationVersion = 1
        try persist()
    }

    private func merge(_ states: [MissionTabState]) {
        for state in states where !tabs.contains(where: { $0.id == state.id }) {
            tabs.append(.mission(state))
        }
    }

    private func persist() throws {
        try store.write(
            GlobalTabsFile(
                migrationVersion: migrationVersion,
                tabs: tabs,
                activeTabId: activeTabId
            ),
            to: fileURL
        )
    }

    private static func deduplicated(_ tabs: [GlobalTab]) -> [GlobalTab] {
        var seen: Set<TabID> = []
        return tabs.filter { seen.insert($0.id).inserted }
    }
}
