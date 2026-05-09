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
    private struct BufferKey: Hashable {
        var worktreeId: String
        var relativePath: String
    }

    private var byWorktree: [String: TabsFile] = [:]
    private let store = PersistenceStore()
    private let bufferStore: EditorBufferStore
    private var buffers: [BufferKey: EditorBuffer] = [:]
    private var bufferKeys: [TabID: BufferKey] = [:]
    /// Tracks the absolute URL for external (out-of-worktree) tabs so that
    /// `discardBuffer(worktreeId:tabId:)` can tear them down too.
    private var externalTabURLs: [TabID: (worktreeId: String, url: URL)] = [:]
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

    /// Open or focus an editor tab for an absolute URL outside the
    /// worktree (SDK headers, dependencies). Reuse-or-create keyed by
    /// absolute path. The tab is "owned" by `worktreeId` so closing the
    /// worktree cascades.
    @discardableResult
    func openExternalEditor(
        worktreeId: String,
        absoluteURL: URL,
        revealLine: Int?,
        revealCharacter: Int?
    ) -> Tab {
        let absPath = absoluteURL.path
        if var file = byWorktree[worktreeId],
           let idx = file.tabs.firstIndex(where: {
               if case .editor(let s) = $0 { return s.externalAbsolutePath == absPath }
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
        let title = absoluteURL.lastPathComponent
        let state = EditorTabState(
            id: UUID().uuidString,
            title: title,
            relativePath: "",
            revealLine: revealLine,
            revealCharacter: revealCharacter,
            externalAbsolutePath: absPath
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
        if let key = bufferKeys[tabId], let existing = buffers[key] { return existing }
        let key = BufferKey(worktreeId: worktreeId, relativePath: relativePath)
        if let existing = buffers[key] {
            bufferKeys[tabId] = key
            return existing
        }
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
        buffer.shouldFollowPathChange = { [weak self] oldPath, newPath in
            self?.canFollowBufferPathChange(worktreeId: worktreeId, oldPath: oldPath, newPath: newPath) ?? false
        }
        buffer.onPathChanged = { [weak self] oldPath, newPath in
            self?.handleBufferPathChanged(worktreeId: worktreeId, oldPath: oldPath, newPath: newPath)
        }
        buffer.onSnapshotRequested = { [weak self, weak buffer] in
            guard let buffer else { return }
            self?.snapshotBufferForAllTabs(buffer)
        }
        buffer.onDiscardSnapshotsRequested = { [weak self, weak buffer] in
            guard let buffer else { return }
            self?.discardSnapshotsForAllTabs(buffer)
        }
        buffers[key] = buffer
        bufferKeys[tabId] = key
        return buffer
    }

    /// Returns (or creates) a read-only external buffer keyed by absolute URL.
    /// Registering `tabId` in `externalTabURLs` ensures that the normal
    /// `discardBuffer(worktreeId:tabId:)` close-tab path tears the buffer
    /// down and stops its file watcher.
    func externalBuffer(worktreeId: String, tabId: TabID, absoluteURL: URL) -> EditorBuffer {
        externalTabURLs[tabId] = (worktreeId: worktreeId, url: absoluteURL)
        let buffer = bufferStore.externalBuffer(worktreeId: worktreeId, absoluteURL: absoluteURL)
        buffer.startWatching()
        return buffer
    }

    /// Inspect (do not create) the buffer for `tabId`. Used by tests and by
    /// dirty-tab queries.
    func peekBuffer(tabId: TabID) -> EditorBuffer? {
        guard let key = bufferKeys[tabId] else { return nil }
        return buffers[key]
    }

    func activeEditorContext(worktreeId: String) -> (tab: EditorTabState, buffer: EditorBuffer)? {
        guard let activeId = activeTabId(forWorktree: worktreeId),
              let tab = tabs(forWorktree: worktreeId).first(where: { $0.id == activeId }),
              case .editor(let state) = tab,
              let buffer = peekBuffer(tabId: activeId) else { return nil }
        return (state, buffer)
    }

    /// Tear down the buffer for `tabId`, close its watcher, and drop it from
    /// cache. Explicit tab removal discards hot-exit snapshots; app quit paths
    /// snapshot dirty buffers before teardown. `worktreeId` is asserted in
    /// debug builds against the recorded owner so a tab discarded from the
    /// wrong worktree context surfaces immediately rather than silently
    /// mis-routing the snapshot.
    func discardBuffer(worktreeId: String, tabId: TabID) {
        // Handle external (out-of-worktree) tabs whose buffers live in the
        // externalBuffers cache rather than the in-worktree `buffers` dict.
        if let ext = externalTabURLs.removeValue(forKey: tabId) {
            assert(ext.worktreeId == worktreeId, "discardBuffer called with worktreeId=\(worktreeId) but external buffer is owned by \(ext.worktreeId)")
            bufferStore.discardExternalBuffer(worktreeId: ext.worktreeId, absoluteURL: ext.url)
            return
        }
        guard let key = bufferKeys.removeValue(forKey: tabId) else { return }
        assert(key.worktreeId == worktreeId, "discardBuffer called with worktreeId=\(worktreeId) but buffer is owned by \(key.worktreeId)")
        bufferStore.discard(worktreeId: worktreeId, tabId: tabId)
        guard let buffer = buffers[key] else { return }
        if let nextTabId = bufferKeys.first(where: { $0.value == key })?.key {
            if buffer.persistenceTabId == tabId {
                buffer.adoptPersistenceTabId(nextTabId)
            }
            return
        }
        buffers.removeValue(forKey: key)
        buffer.close(persistDirtySnapshot: false)
    }

    /// Tab IDs whose buffers are currently dirty. Order is unspecified.
    func dirtyTabIds() -> [TabID] {
        bufferKeys.compactMap { tabId, key in
            buffers[key]?.dirty == true ? tabId : nil
        }
    }

    @discardableResult
    func updateEditorPath(worktreeId: String, tabId: TabID, relativePath: String) -> Bool {
        guard var file = byWorktree[worktreeId],
              let idx = file.tabs.firstIndex(where: { $0.id == tabId }),
              case .editor(var state) = file.tabs[idx] else { return false }
        state.relativePath = relativePath
        state.title = (relativePath as NSString).lastPathComponent
        state.revealLine = nil
        state.revealCharacter = nil
        file.tabs[idx] = .editor(state)
        byWorktree[worktreeId] = file
        persist(worktreeId)
        if let oldKey = bufferKeys[tabId] {
            let newKey = BufferKey(worktreeId: worktreeId, relativePath: relativePath)
            bufferKeys[tabId] = newKey
            if oldKey != newKey, let buffer = buffers.removeValue(forKey: oldKey) {
                buffers[newKey] = buffer
            }
        }
        return true
    }

    func hasEditor(worktreeId: String, relativePath: String, excluding tabId: TabID? = nil) -> Bool {
        tabs(forWorktree: worktreeId).contains { tab in
            guard case .editor(let state) = tab else { return false }
            return state.id != tabId && state.relativePath == relativePath
        }
    }

    /// Walk all dirty buffers and write a final snapshot. Called by the
    /// quit handler. Errors are swallowed — failing to snapshot one buffer
    /// must not block snapshotting the rest, and quit must not be blocked.
    func snapshotDirtyBuffersForQuit() {
        for (tabId, key) in bufferKeys {
            guard let buffer = buffers[key], buffer.dirty else { continue }
            buffer.snapshotNow(tabId: tabId)
        }
    }

    @discardableResult
    func saveAll(worktreeRoots: [String: URL] = [:]) -> [(tabId: TabID, error: Error)] {
        var errors: [(TabID, Error)] = []
        var saved = Set<ObjectIdentifier>()
        for (tabId, key) in bufferKeys {
            guard let buffer = buffers[key], buffer.dirty else { continue }
            let id = ObjectIdentifier(buffer)
            guard !saved.contains(id) else { continue }
            saved.insert(id)
            do {
                try buffer.saveRecordingError()
            } catch {
                errors.append((tabId, error))
            }
        }
        for (worktreeId, file) in byWorktree {
            guard let root = worktreeRoots[worktreeId] else { continue }
            for tab in file.tabs {
                guard case .editor(let state) = tab,
                      peekBuffer(tabId: state.id) == nil,
                      (try? bufferStore.read(worktreeId: worktreeId, tabId: state.id)) != nil else { continue }
                let buffer: EditorBuffer
                if let lsp {
                    buffer = EditorBuffer(
                        worktreeRoot: root,
                        relativePath: state.relativePath,
                        store: bufferStore,
                        worktreeId: worktreeId,
                        tabId: state.id,
                        lsp: lsp
                    )
                } else {
                    buffer = EditorBuffer(
                        worktreeRoot: root,
                        relativePath: state.relativePath,
                        store: bufferStore,
                        worktreeId: worktreeId,
                        tabId: state.id
                    )
                }
                do {
                    try buffer.saveRecordingError()
                    buffer.close(persistDirtySnapshot: false)
                } catch {
                    errors.append((state.id, error))
                    buffer.close(persistDirtySnapshot: true)
                }
            }
        }
        return errors
    }

    /// Save the active editor tab's buffer for `worktreeId`. No-op if the
    /// active tab is not an editor or has no buffer.
    @discardableResult
    func saveActive(worktreeId: String) -> Bool {
        guard let activeId = activeTabId(forWorktree: worktreeId),
              let buffer = peekBuffer(tabId: activeId) else { return false }
        do {
            try buffer.saveRecordingError()
            return true
        } catch {
            return false
        }
    }

    @discardableResult
    func revertActive(worktreeId: String) -> Bool {
        guard let activeId = activeTabId(forWorktree: worktreeId),
              let buffer = peekBuffer(tabId: activeId) else { return false }
        buffer.revert()
        return true
    }

    private func handleBufferPathChanged(worktreeId: String, oldPath: String, newPath: String) {
        let oldKey = BufferKey(worktreeId: worktreeId, relativePath: oldPath)
        let newKey = BufferKey(worktreeId: worktreeId, relativePath: newPath)
        let affectedTabIds = bufferKeys.compactMap { tabId, key in key == oldKey ? tabId : nil }
        guard !affectedTabIds.isEmpty else { return }

        if let buffer = buffers.removeValue(forKey: oldKey) {
            buffers[newKey] = buffer
        }
        for tabId in affectedTabIds {
            bufferKeys[tabId] = newKey
            _ = updateEditorPath(worktreeId: worktreeId, tabId: tabId, relativePath: newPath)
        }
    }

    private func canFollowBufferPathChange(worktreeId: String, oldPath: String, newPath: String) -> Bool {
        let oldKey = BufferKey(worktreeId: worktreeId, relativePath: oldPath)
        let newKey = BufferKey(worktreeId: worktreeId, relativePath: newPath)
        guard oldKey != newKey else { return true }
        guard buffers[newKey] == nil else { return false }
        guard let file = byWorktree[worktreeId] else { return true }
        return !file.tabs.contains { tab in
            guard case .editor(let state) = tab,
                  state.relativePath == newPath,
                  bufferKeys[state.id] == nil,
                  (try? bufferStore.read(worktreeId: worktreeId, tabId: state.id)) != nil else { return false }
            return true
        }
    }

    private func snapshotBufferForAllTabs(_ buffer: EditorBuffer) {
        for (tabId, _) in tabIdsSharing(buffer: buffer) {
            buffer.snapshotNow(tabId: tabId)
        }
    }

    private func discardSnapshotsForAllTabs(_ buffer: EditorBuffer) {
        for (tabId, key) in tabIdsSharing(buffer: buffer) {
            bufferStore.discard(worktreeId: key.worktreeId, tabId: tabId)
        }
    }

    private func tabIdsSharing(buffer: EditorBuffer) -> [(TabID, BufferKey)] {
        var result: [(TabID, BufferKey)] = []
        var seen = Set<TabID>()
        let liveKeys = Set(bufferKeys.compactMap { _, key in buffers[key] === buffer ? key : nil })

        for (tabId, key) in bufferKeys where liveKeys.contains(key) {
            result.append((tabId, key))
            seen.insert(tabId)
        }

        for key in liveKeys {
            guard let file = byWorktree[key.worktreeId] else { continue }
            for tab in file.tabs {
                guard case .editor(let state) = tab,
                      state.relativePath == key.relativePath,
                      !seen.contains(state.id) else { continue }
                result.append((state.id, key))
                seen.insert(state.id)
            }
        }

        return result
    }
}
