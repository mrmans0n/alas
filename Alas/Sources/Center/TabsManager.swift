import Foundation
import Observation

struct TabsFile: Codable {
    var version: Int = 1
    var tabs: [Tab]
    var activeTabId: TabID?
}

@Observable
@MainActor
final class TabsManager {
    private var byWorktree: [String: TabsFile] = [:]
    private let store = PersistenceStore()
    private let bufferStore: EditorBufferStore
    private var buffers: [TabID: EditorBuffer] = [:]
    // Map tabId → worktreeId so `discardBuffer` and `snapshotDirtyBuffersForQuit`
    // know which subtree to write to without forcing callers to pass it.
    private var bufferOwners: [TabID: String] = [:]
    private let lsp: WorkspaceLSPManager?

    init(bufferStore: EditorBufferStore = EditorBufferStore(), lsp: WorkspaceLSPManager? = nil) {
        self.bufferStore = bufferStore
        self.lsp = lsp
    }

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
    func replaceTerminalSession(worktreeId: String, tabId: TabID, sessionId: String) -> Tab? {
        guard var file = byWorktree[worktreeId],
              let idx = file.tabs.firstIndex(where: { $0.id == tabId }),
              case .terminal(var state) = file.tabs[idx] else { return nil }
        state.sessionId = sessionId
        let tab = Tab.terminal(state)
        file.tabs[idx] = tab
        byWorktree[worktreeId] = file
        persist(worktreeId)
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

    /// Clears the `revealLine`/`revealCharacter` hints on an editor tab.
    /// Called by the editor coordinator once it has scrolled to the target,
    /// so the hint isn't replayed on the next view re-render or app
    /// relaunch.
    func consumeReveal(worktreeId: String, tabId: TabID) {
        guard var file = byWorktree[worktreeId],
              let idx = file.tabs.firstIndex(where: { $0.id == tabId }),
              case .editor(var s) = file.tabs[idx],
              s.revealLine != nil || s.revealCharacter != nil else { return }
        s.revealLine = nil
        s.revealCharacter = nil
        file.tabs[idx] = .editor(s)
        byWorktree[worktreeId] = file
        persist(worktreeId)
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

    func closeOthers(worktreeId: String, keeping tabId: TabID) -> [TabID] {
        guard var file = byWorktree[worktreeId] else { return [] }
        let closed = file.tabs.filter { $0.id != tabId }.map(\.id)
        guard let kept = file.tabs.first(where: { $0.id == tabId }) else { return [] }
        file.tabs = [kept]
        file.activeTabId = tabId
        byWorktree[worktreeId] = file
        persist(worktreeId)
        return closed
    }

    func closeAll(worktreeId: String) -> [TabID] {
        guard var file = byWorktree[worktreeId] else { return [] }
        let closed = file.tabs.map(\.id)
        file.tabs = []
        file.activeTabId = nil
        byWorktree[worktreeId] = file
        persist(worktreeId)
        return closed
    }

    func closeToLeft(worktreeId: String, of tabId: TabID) -> [TabID] {
        guard var file = byWorktree[worktreeId],
              let idx = file.tabs.firstIndex(where: { $0.id == tabId }) else { return [] }
        let closed = file.tabs[0..<idx].map(\.id)
        if let active = file.activeTabId, closed.contains(active) {
            file.activeTabId = tabId
        }
        file.tabs.removeSubrange(0..<idx)
        byWorktree[worktreeId] = file
        persist(worktreeId)
        return closed
    }

    func closeToRight(worktreeId: String, of tabId: TabID) -> [TabID] {
        guard var file = byWorktree[worktreeId],
              let idx = file.tabs.firstIndex(where: { $0.id == tabId }) else { return [] }
        let closed = file.tabs[(idx + 1)...].map(\.id)
        if let active = file.activeTabId, closed.contains(active) {
            file.activeTabId = tabId
        }
        file.tabs.removeSubrange((idx + 1)...)
        byWorktree[worktreeId] = file
        persist(worktreeId)
        return closed
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

    // MARK: - Buffer lifecycle

    /// Returns the buffer for `tabId`, creating it (cold-load from disk or
    /// hot-restore from snapshot) on first access.
    func buffer(worktreeId: String, tabId: TabID, worktreeRoot: URL, relativePath: String) -> EditorBuffer {
        if let existing = buffers[tabId] { return existing }
        let buffer: EditorBuffer
        if let lsp {
            buffer = EditorBuffer(
                worktreeRoot: worktreeRoot,
                relativePath: relativePath,
                store: bufferStore,
                worktreeId: worktreeId,
                tabId: tabId,
                lsp: lsp
            )
        } else {
            buffer = EditorBuffer(
                worktreeRoot: worktreeRoot,
                relativePath: relativePath,
                store: bufferStore,
                worktreeId: worktreeId,
                tabId: tabId
            )
        }
        buffer.startWatching()
        buffer.checkForConflictOnRestore()
        buffers[tabId] = buffer
        bufferOwners[tabId] = worktreeId
        return buffer
    }

    /// Inspect (do not create) the buffer for `tabId`. Used by tests and by
    /// dirty-tab queries.
    func peekBuffer(tabId: TabID) -> EditorBuffer? {
        buffers[tabId]
    }

    /// Tear down the buffer for `tabId`, close its watcher, and drop it from
    /// cache. Explicit tab removal discards hot-exit snapshots; app quit paths
    /// snapshot dirty buffers before teardown. `worktreeId` is asserted in
    /// debug builds against the recorded owner so a tab discarded from the
    /// wrong worktree context surfaces immediately rather than silently
    /// mis-routing the snapshot.
    func discardBuffer(worktreeId: String, tabId: TabID) {
        if let owner = bufferOwners[tabId] {
            assert(owner == worktreeId, "discardBuffer called with worktreeId=\(worktreeId) but buffer is owned by \(owner)")
        }
        guard let buffer = buffers.removeValue(forKey: tabId) else { return }
        bufferOwners.removeValue(forKey: tabId)
        buffer.close(persistDirtySnapshot: false)
    }

    /// Tab IDs whose buffers are currently dirty. Order is unspecified.
    func dirtyTabIds() -> [TabID] {
        buffers.compactMap { $0.value.dirty ? $0.key : nil }
    }

    /// Walk all dirty buffers and write a final snapshot. Called by the
    /// quit handler. Errors are swallowed — failing to snapshot one buffer
    /// must not block snapshotting the rest, and quit must not be blocked.
    func snapshotDirtyBuffersForQuit() {
        for buffer in buffers.values where buffer.dirty {
            buffer.snapshotNow()
        }
    }

    /// Save the active editor tab's buffer for `worktreeId`. No-op if the
    /// active tab is not an editor or has no buffer.
    @discardableResult
    func saveActive(worktreeId: String) -> Bool {
        guard let activeId = activeTabId(forWorktree: worktreeId),
              let buffer = buffers[activeId] else { return false }
        do {
            try buffer.save()
            return true
        } catch {
            buffer.lastSaveError = (error as NSError).localizedDescription
            return false
        }
    }
}
