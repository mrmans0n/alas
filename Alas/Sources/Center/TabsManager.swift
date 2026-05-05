import Foundation
import Observation

struct TabsFile: Codable {
    var version: Int = 1
    var tabs: [Tab]
    var activeTabId: TabID?
}

@Observable
final class TabsManager {
    private var byWorktree: [String: TabsFile] = [:]
    private let store = PersistenceStore()

    func tabs(forWorktree id: String) -> [Tab] {
        byWorktree[id]?.tabs ?? []
    }

    func activeTabId(forWorktree id: String) -> TabID? {
        byWorktree[id]?.activeTabId
    }

    func loadAll(worktreeIds: [String]) {
        for id in worktreeIds {
            if let file = try? store.readIfExists(TabsFile.self, from: Paths.tabsFile(forWorktreeId: id)) {
                byWorktree[id] = file
            }
        }
    }

    @discardableResult
    func appendTerminal(worktreeId: String, title: String, sessionId: String) -> Tab {
        let state = TerminalTabState(id: UUID().uuidString, title: title, sessionId: sessionId)
        let tab = Tab.terminal(state)
        append(tab, to: worktreeId)
        return tab
    }

    @discardableResult
    func appendEditor(worktreeId: String, title: String, relativePath: String) -> Tab {
        let state = EditorTabState(id: UUID().uuidString, title: title, relativePath: relativePath)
        let tab = Tab.editor(state)
        append(tab, to: worktreeId)
        return tab
    }

    /// Open or focus an editor tab for `relativePath`. If a tab for that
    /// path already exists, its reveal hints are updated and it becomes
    /// active. Otherwise a new tab is appended.
    @discardableResult
    func openEditor(
        worktreeId: String,
        relativePath: String,
        revealLine: Int?,
        revealCharacter: Int?
    ) -> Tab {
        if var file = byWorktree[worktreeId],
           let idx = file.tabs.firstIndex(where: {
               if case .editor(let s) = $0 { return s.relativePath == relativePath }
               return false
           }) {
            if case .editor(var s) = file.tabs[idx] {
                s.revealLine = revealLine
                s.revealCharacter = revealCharacter
                file.tabs[idx] = .editor(s)
                file.activeTabId = s.id
                byWorktree[worktreeId] = file
                persist(worktreeId)
                return .editor(s)
            }
        }
        let title = (relativePath as NSString).lastPathComponent
        let state = EditorTabState(
            id: UUID().uuidString,
            title: title,
            relativePath: relativePath,
            revealLine: revealLine,
            revealCharacter: revealCharacter
        )
        let tab = Tab.editor(state)
        append(tab, to: worktreeId)
        return tab
    }

    @discardableResult
    func appendDiff(worktreeId: String, title: String, relativePath: String) -> Tab {
        let state = DiffTabState(id: UUID().uuidString, title: title, relativePath: relativePath)
        let tab = Tab.diff(state)
        append(tab, to: worktreeId)
        return tab
    }

    func activate(worktreeId: String, tabId: TabID) {
        var file = byWorktree[worktreeId] ?? TabsFile(tabs: [], activeTabId: nil)
        file.activeTabId = tabId
        byWorktree[worktreeId] = file
        persist(worktreeId)
    }

    func close(worktreeId: String, tabId: TabID) {
        guard var file = byWorktree[worktreeId] else { return }
        guard let idx = file.tabs.firstIndex(where: { $0.id == tabId }) else { return }
        let wasActive = file.activeTabId == tabId
        file.tabs.remove(at: idx)
        if wasActive {
            if file.tabs.isEmpty {
                file.activeTabId = nil
            } else {
                let neighbourIdx = max(0, idx - 1)
                file.activeTabId = file.tabs[neighbourIdx].id
            }
        }
        byWorktree[worktreeId] = file
        persist(worktreeId)
    }

    private func append(_ tab: Tab, to worktreeId: String) {
        var file = byWorktree[worktreeId] ?? TabsFile(tabs: [], activeTabId: nil)
        file.tabs.append(tab)
        file.activeTabId = tab.id
        byWorktree[worktreeId] = file
        persist(worktreeId)
    }

    private func persist(_ worktreeId: String) {
        guard let file = byWorktree[worktreeId] else { return }
        try? store.write(file, to: Paths.tabsFile(forWorktreeId: worktreeId))
    }
}
