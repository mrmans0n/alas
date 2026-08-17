import Foundation
import Observation

struct TabsFile: Codable {
    var version: Int = 1
    var tabs: [Tab]
    var activeTabId: TabID?
    /// Draft commit state preserved across tab close/reopen.
    /// Nil when no draft has been started in this worktree, or when the
    /// draft has been committed/discarded. Survives close so the user's
    /// in-progress subject/body isn't lost.
    var stashedDraft: DraftCommitTabState? = nil
}

extension TabsFile {
    // Custom decoder skips unknown/removed Tab cases instead of failing the
    // entire file when users upgrade from an older build that had more cases.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = (try? c.decode(Int.self, forKey: .version)) ?? 1
        activeTabId = try? c.decode(TabID.self, forKey: .activeTabId)
        stashedDraft = try? c.decode(DraftCommitTabState.self, forKey: .stashedDraft)
        tabs = ((try? c.decode([FailableTab].self, forKey: .tabs)) ?? []).compactMap(\.value)
    }

    private struct FailableTab: Decodable {
        let value: Tab?
        init(from decoder: Decoder) throws { value = try? Tab(from: decoder) }
    }
}

@Observable
@MainActor
final class TabsManager {
    private struct BufferKey: Hashable {
        var worktreeId: String
        var relativePath: String
    }

    private var byWorktree: [String: TabsFile] = [:]
    /// `true` once `loadAll` has been called at least once, meaning any
    /// persisted tabs have been read from disk. Views use this to
    /// distinguish "no tabs yet (still loading)" from "genuinely empty".
    private(set) var hasLoaded = false
    private let store: any PersistenceStoreProtocol
    private let tabsDirectory: URL
    private let bufferStore: EditorBufferStore
    private var buffers: [BufferKey: EditorBuffer] = [:]
    private var bufferKeys: [TabID: BufferKey] = [:]
    /// Canonical ownership for every live in-worktree tab. `buffers` is only
    /// the path-sharing index; lifecycle operations must resolve through here.
    private var tabBuffers: [TabID: EditorBuffer] = [:]
    /// Tracks the absolute URL for external (out-of-worktree) tabs so that
    /// `discardBuffer(worktreeId:tabId:)` can tear them down too.
    private var externalTabURLs: [TabID: (worktreeId: String, url: URL)] = [:]
    /// LSP parameters recorded when `externalBuffer` fires `openExternalDocument`
    /// so that `discardBuffer` can issue the matching `closeExternalDocument`.
    private struct ExternalLSPInfo: Equatable {
        var worktreeRoot: URL
        var originatingFileURL: URL?
        var language: String?
    }
    private var externalLSPInfo: [TabID: ExternalLSPInfo] = [:]
    /// Session-only split drafts survive view recreation when the user switches
    /// tabs, but are deliberately not persisted as part of the tab identity.
    private var ggSplitCommitDrafts: [TabID: GGSplitCommitDraft] = [:]
    /// Tracks which tab IDs have already had `openExternalDocument` fired so
    /// that cache-hit calls to `externalBuffer` don't double-count the ref.
    private var openedExternalDocs: Set<TabID> = []
    /// Tracks in-flight `openExternalDocument` Tasks keyed by tabId.
    /// Cancellation on `discardBuffer` prevents a completed-but-unregistered
    /// open from leaking the URI if the tab was closed before the Task landed.
    private var pendingExternalOpenTasks: [TabID: Task<Void, Never>] = [:]
    /// Generation counter per tab for the pending open task. When a rebind
    /// cancels and replaces the task, the generation increments. The task's
    /// completion handler only clears pendingExternalOpenTasks if its
    /// captured generation still matches the current one.
    private var pendingExternalOpenGen: [TabID: Int] = [:]
    /// Runtime-only display titles for terminal pane leaves. Key = leafId.
    var terminalRuntimeTitles: [String: String] = [:]
    private let lsp: WorkspaceLSPManager?

    init(
        bufferStore: EditorBufferStore = EditorBufferStore(),
        lsp: WorkspaceLSPManager? = nil,
        store: any PersistenceStoreProtocol = PersistenceStore(),
        tabsDirectory: URL = Paths.tabsDir
    ) {
        self.bufferStore = bufferStore
        self.lsp = lsp
        self.store = store
        self.tabsDirectory = tabsDirectory
    }

    func tabs(forWorktree id: String) -> [Tab] {
        byWorktree[id]?.tabs ?? []
    }

    func commitEditorTab(worktreeId: String, currentSha: String) -> Tab? {
        tabs(forWorktree: worktreeId).first { tab in
            if case .commitEditor(let state) = tab {
                return state.currentSha == currentSha
            }
            return false
        }
    }

    func activeTabId(forWorktree id: String) -> TabID? {
        byWorktree[id]?.activeTabId
    }

    func activeTab(forWorktree id: String) -> Tab? {
        guard let activeId = activeTabId(forWorktree: id) else { return nil }
        return tabs(forWorktree: id).first(where: { $0.id == activeId })
    }

    func ggSplitCommitDraft(worktreeId: String, tabId: TabID) -> GGSplitCommitDraft? {
        guard tabs(forWorktree: worktreeId).contains(where: { $0.id == tabId }) else { return nil }
        return ggSplitCommitDrafts[tabId]
    }

    func updateGGSplitCommitDraft(
        worktreeId: String,
        tabId: TabID,
        draft: GGSplitCommitDraft
    ) {
        guard tabs(forWorktree: worktreeId).contains(where: { $0.id == tabId }) else { return }
        ggSplitCommitDrafts[tabId] = draft
    }

    func moveTab(worktreeId: String, fromId: TabID, toId: TabID) {
        guard fromId != toId else { return }
        guard var file = byWorktree[worktreeId] else { return }
        guard let fromIndex = file.tabs.firstIndex(where: { $0.id == fromId }) else { return }
        guard let toIndex = file.tabs.firstIndex(where: { $0.id == toId }) else { return }
        let tab = file.tabs.remove(at: fromIndex)
        let insertionIndex = fromIndex < toIndex ? toIndex : toIndex
        file.tabs.insert(tab, at: insertionIndex)
        byWorktree[worktreeId] = file
        persist(worktreeId)
    }

    @discardableResult
    func activateTabNumber(_ number: Int, worktreeId: String) -> TabID? {
        guard number > 0 else { return nil }
        let index = number - 1
        let tabs = tabs(forWorktree: worktreeId)
        guard tabs.indices.contains(index) else { return nil }
        let tabId = tabs[index].id
        activate(worktreeId: worktreeId, tabId: tabId)
        return tabId
    }

    func loadAll(worktreeIds: [String]) {
        for id in worktreeIds {
            if let file = try? store.readIfExists(TabsFile.self, from: tabsFile(forWorktreeId: id)) {
                byWorktree[id] = file
            }
        }
        hasLoaded = true
    }

    /// Loads every persisted tab file, including files whose worktree is not
    /// currently discoverable. Legacy Mission tabs must be migrated before an
    /// orphaned worktree can otherwise make them unreachable.
    func loadAllPersisted() {
        guard let relativeFiles = try? FileManager.default.subpathsOfDirectory(
            atPath: tabsDirectory.path
        ) else { return }
        let worktreeIDs = relativeFiles.compactMap { relativeFile -> String? in
            guard relativeFile.hasSuffix(".json") else { return nil }
            let file = tabsDirectory.appendingPathComponent(relativeFile)
            guard (try? file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
            else { return nil }
            let relativePath = String(relativeFile.dropLast(".json".count))
            guard !relativePath.isEmpty else { return nil }
            return relativePath.contains("/") ? "/\(relativePath)" : relativePath
        }
        loadAll(worktreeIds: worktreeIDs)
    }

    @discardableResult
    func appendTerminal(worktreeId: String, title: String, sessionId: String, runScriptKey: String? = nil) -> Tab {
        let state = TerminalTabState(id: UUID().uuidString, title: title, sessionId: sessionId, runScriptKey: runScriptKey)
        let tab = Tab.terminal(state)
        append(tab, to: worktreeId)
        return tab
    }

    /// The terminal tab launched from the given run script, if one is open
    /// in this worktree. One tab per (script, worktree) is an invariant
    /// maintained by AppState's run/focus logic.
    func terminalTab(withRunScriptKey key: String, worktreeId: String) -> Tab? {
        tabs(forWorktree: worktreeId).first { tab in
            guard case .terminal(let state) = tab else { return false }
            return state.runScriptKey == key
        }
    }

    @discardableResult
    func clearRunScriptMarker(worktreeId: String, tabId: TabID) -> Tab? {
        guard var file = byWorktree[worktreeId],
              let idx = file.tabs.firstIndex(where: { $0.id == tabId }),
              case .terminal(var state) = file.tabs[idx],
              state.runScriptKey != nil || state.runScriptLeafId != nil else { return nil }
        state.runScriptKey = nil
        state.runScriptLeafId = nil
        let tab = Tab.terminal(state)
        file.tabs[idx] = tab
        byWorktree[worktreeId] = file
        persist(worktreeId)
        return tab
    }

    func nextTerminalTitle(worktreeId: String, baseTitle: String) -> String {
        let base = baseTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        let fallback = base.isEmpty ? "Terminal" : base
        let existing = Set(tabs(forWorktree: worktreeId).compactMap { tab -> String? in
            guard case .terminal(let state) = tab else { return nil }
            return state.title
        })
        guard existing.contains(fallback) else { return fallback }

        var suffix = 2
        while existing.contains("\(fallback) \(suffix)") {
            suffix += 1
        }
        return "\(fallback) \(suffix)"
    }

    @discardableResult
    func renameTerminal(worktreeId: String, tabId: TabID, title: String) -> Tab? {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              var file = byWorktree[worktreeId],
              let idx = file.tabs.firstIndex(where: { $0.id == tabId }),
              case .terminal(var state) = file.tabs[idx] else { return nil }
        state.title = trimmed
        let tab = Tab.terminal(state)
        file.tabs[idx] = tab
        byWorktree[worktreeId] = file
        persist(worktreeId)
        return tab
    }

    @discardableResult
    func renameACPSession(worktreeId: String, tabId: TabID, title: String) -> Tab? {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              var file = byWorktree[worktreeId],
              let idx = file.tabs.firstIndex(where: { $0.id == tabId }),
              case .acpSession(var state) = file.tabs[idx] else { return nil }
        state.title = trimmed
        let tab = Tab.acpSession(state)
        file.tabs[idx] = tab
        byWorktree[worktreeId] = file
        persist(worktreeId)
        return tab
    }

    @discardableResult
    func renameACPSessionTabs(worktreeId: String, sessionId: ACPSession.ID, title: String) -> Int {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, var file = byWorktree[worktreeId] else { return 0 }

        var updatedCount = 0
        for idx in file.tabs.indices {
            guard case .acpSession(var state) = file.tabs[idx],
                  state.sessionId == sessionId else { continue }
            guard state.title != trimmed else { continue }
            state.title = trimmed
            file.tabs[idx] = .acpSession(state)
            updatedCount += 1
        }

        guard updatedCount > 0 else { return 0 }
        byWorktree[worktreeId] = file
        persist(worktreeId)
        return updatedCount
    }

    @discardableResult
    func replaceTerminalSession(worktreeId: String, tabId: TabID, sessionId: String) -> Tab? {
        guard var file = byWorktree[worktreeId],
              let idx = file.tabs.firstIndex(where: { $0.id == tabId }),
              case .terminal(var state) = file.tabs[idx] else { return nil }
        state.root = state.root.replacingLeaf(id: state.focusedLeafId, with: .leaf(
            PaneLeaf(id: state.focusedLeafId, sessionId: sessionId, lastCwd: nil)
        ))
        let tab = Tab.terminal(state)
        file.tabs[idx] = tab
        byWorktree[worktreeId] = file
        persist(worktreeId)
        return tab
    }

    /// Replace a specific leaf's `sessionId` (preserving its `lastCwd`).
    /// Used by `AppState.restoreTerminalTabIfNeeded` to patch the tree after
    /// recreating a dropped session.
    @discardableResult
    func replaceLeafSession(worktreeId: String, tabId: TabID, leafId: String, sessionId: String) -> Tab? {
        guard var file = byWorktree[worktreeId],
              let idx = file.tabs.firstIndex(where: { $0.id == tabId }),
              case .terminal(var state) = file.tabs[idx],
              let existing = state.root.find(leafId: leafId)?.leaf else { return nil }
        let replacement: PaneNode = .leaf(PaneLeaf(
            id: leafId, sessionId: sessionId, lastCwd: existing.lastCwd
        ))
        state.root = state.root.replacingLeaf(id: leafId, with: replacement)
        let tab = Tab.terminal(state)
        file.tabs[idx] = tab
        byWorktree[worktreeId] = file
        persist(worktreeId)
        return tab
    }

    // MARK: - Terminal runtime titles

    func setTerminalRuntimeTitle(leafId: String, title: String) {
        guard !title.isEmpty else { return }
        terminalRuntimeTitles[leafId] = title
    }

    func clearTerminalRuntimeTitles(forLeavesInTabId tabId: TabID) {
        guard let file = byWorktree.values.first(where: { $0.tabs.contains(where: { $0.id == tabId }) }) else { return }
        guard let tab = file.tabs.first(where: { $0.id == tabId }),
              case .terminal(let state) = tab else { return }
        for leaf in state.root.leaves() {
            terminalRuntimeTitles.removeValue(forKey: leaf.id)
        }
    }

    /// Returns the runtime display title for a terminal tab's focused leaf, if any.
    func displayTerminalTitle(for tab: Tab) -> String? {
        guard case .terminal(let state) = tab else { return nil }
        guard let leafId = state.root.find(leafId: state.focusedLeafId)?.leaf.id else { return nil }
        return terminalRuntimeTitles[leafId]
    }

    // MARK: - Pane tree mutations
    @discardableResult
    func setFocusedLeaf(worktreeId: String, tabId: TabID, leafId: String) -> Tab? {
        guard var file = byWorktree[worktreeId],
              let idx = file.tabs.firstIndex(where: { $0.id == tabId }),
              case .terminal(var state) = file.tabs[idx],
              state.root.find(leafId: leafId) != nil else { return nil }
        state.focusedLeafId = leafId
        let tab = Tab.terminal(state)
        file.tabs[idx] = tab
        byWorktree[worktreeId] = file
        return tab
    }

    /// Split the focused leaf into a 2-child split. The freshly-spawned session id
    /// is wrapped in a new leaf, which becomes the focused one.
    @discardableResult
    func splitFocusedLeaf(
        worktreeId: String, tabId: TabID, axis: SplitAxis,
        newLeafId: String, newSessionId: String
    ) -> Tab? {
        guard var file = byWorktree[worktreeId],
              let idx = file.tabs.firstIndex(where: { $0.id == tabId }),
              case .terminal(var state) = file.tabs[idx],
              let existing = state.root.find(leafId: state.focusedLeafId)?.leaf else { return nil }
        let newLeaf = PaneLeaf(id: newLeafId, sessionId: newSessionId, lastCwd: nil)
        let replacement: PaneNode = .split(PaneSplit(
            id: UUID().uuidString,
            axis: axis,
            fraction: 0.5,
            children: [.leaf(existing), .leaf(newLeaf)]
        ))
        state.root = state.root.replacingLeaf(id: existing.id, with: replacement)
        state.focusedLeafId = newLeafId
        let tab = Tab.terminal(state)
        file.tabs[idx] = tab
        byWorktree[worktreeId] = file
        persist(worktreeId)
        return tab
    }

    enum RemoveLeafOutcome {
        /// A sibling collapsed up; the tab persists.
        case leafRemoved(tab: Tab, closedLeafId: String)
        /// The removed leaf was the last leaf; caller must run the regular close-tab path.
        case tabRemoved(closedLeafId: String)

        var closedLeafId: String {
            switch self {
            case .leafRemoved(_, let id), .tabRemoved(let id): return id
            }
        }
    }

    /// Remove the leaf identified by `leafId` from `tabId` in `worktreeId`. If the
    /// leaf is part of a split, the sibling collapses up; focus only moves when
    /// the removed leaf was itself focused (then to the first leaf in the
    /// remaining tree). Returns `.tabRemoved` when the leaf was the last in the
    /// tab — the tab stays in the list so callers can run the regular close-tab
    /// path. Returns `nil` when the worktree, tab, or leaf is missing, so the
    /// process-exit handler can race manual close as a quiet no-op.
    @discardableResult
    func removeLeaf(worktreeId: String, tabId: TabID, leafId: String) -> RemoveLeafOutcome? {
        guard var file = byWorktree[worktreeId],
              let idx = file.tabs.firstIndex(where: { $0.id == tabId }),
              case .terminal(var state) = file.tabs[idx],
              state.root.find(leafId: leafId) != nil else { return nil }
        let closedLeafId = leafId
        if let newRoot = state.root.removingLeaf(id: leafId) {
            state.root = newRoot
            if state.root.find(leafId: state.focusedLeafId) == nil {
                state.focusedLeafId = newRoot.firstLeaf().id
            }
            // The script's own pane is gone but a sibling pane keeps the tab
            // alive — that no longer means the script is running. Leave the
            // marker alone if a DIFFERENT (non-script) pane was the one
            // closed; the script's leaf, and thus its "running" status, is
            // unaffected.
            if state.runScriptLeafId == closedLeafId {
                state.runScriptKey = nil
                state.runScriptLeafId = nil
            }
            let tab = Tab.terminal(state)
            file.tabs[idx] = tab
            byWorktree[worktreeId] = file
            persist(worktreeId)
            return .leafRemoved(tab: tab, closedLeafId: closedLeafId)
        } else {
            return .tabRemoved(closedLeafId: closedLeafId)
        }
    }

    /// Remove the focused leaf. Thin wrapper around `removeLeaf(worktreeId:tabId:leafId:)`.
    @discardableResult
    func removeFocusedLeaf(worktreeId: String, tabId: TabID) -> RemoveLeafOutcome? {
        guard let file = byWorktree[worktreeId],
              let idx = file.tabs.firstIndex(where: { $0.id == tabId }),
              case .terminal(let state) = file.tabs[idx] else { return nil }
        return removeLeaf(worktreeId: worktreeId, tabId: tabId, leafId: state.focusedLeafId)
    }

    @discardableResult
    func setSplitFraction(worktreeId: String, tabId: TabID, splitId: String, fraction: Double) -> Tab? {
        guard var file = byWorktree[worktreeId],
              let idx = file.tabs.firstIndex(where: { $0.id == tabId }),
              case .terminal(var state) = file.tabs[idx] else { return nil }
        state.root = updatingSplit(state.root, splitId: splitId) { s in
            var copy = s
            copy.fraction = max(0.1, min(0.9, fraction))
            return copy
        }
        let tab = Tab.terminal(state)
        file.tabs[idx] = tab
        byWorktree[worktreeId] = file
        persist(worktreeId)
        return tab
    }

    @discardableResult
    func setLeafCwd(worktreeId: String, tabId: TabID, leafId: String, cwd: String) -> Tab? {
        guard var file = byWorktree[worktreeId],
              let idx = file.tabs.firstIndex(where: { $0.id == tabId }),
              case .terminal(var state) = file.tabs[idx],
              let existing = state.root.find(leafId: leafId)?.leaf else { return nil }
        guard existing.lastCwd != cwd else { return nil }
        state.root = updatingLeaf(state.root, leafId: leafId) { l in
            var copy = l
            copy.lastCwd = cwd
            return copy
        }
        let tab = Tab.terminal(state)
        file.tabs[idx] = tab
        byWorktree[worktreeId] = file
        return tab
    }

    /// Walks the tree and applies `transform` to the split with `splitId`.
    private func updatingSplit(_ node: PaneNode, splitId: String,
                               transform: (PaneSplit) -> PaneSplit) -> PaneNode {
        switch node {
        case .leaf: return node
        case .split(var s):
            if s.id == splitId { return .split(transform(s)) }
            s.children = s.children.map { updatingSplit($0, splitId: splitId, transform: transform) }
            return .split(s)
        }
    }

    private func updatingLeaf(_ node: PaneNode, leafId: String,
                              transform: (PaneLeaf) -> PaneLeaf) -> PaneNode {
        switch node {
        case .leaf(let l):
            return l.id == leafId ? .leaf(transform(l)) : node
        case .split(var s):
            s.children = s.children.map { updatingLeaf($0, leafId: leafId, transform: transform) }
            return .split(s)
        }
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
        revealCharacter: Int?,
        revealEndLine: Int? = nil
    ) -> Tab {
        let shouldRevealInMarkdownEditor = (revealLine != nil || revealCharacter != nil)
            && MarkdownFileType.supportsRichPreview(relativePath: relativePath)
        if var file = byWorktree[worktreeId],
           let idx = file.tabs.firstIndex(where: {
               if case .editor(let s) = $0 { return s.relativePath == relativePath }
               return false
           }) {
            if case .editor(var s) = file.tabs[idx] {
                s.revealLine = revealLine
                s.revealEndLine = revealEndLine
                s.revealCharacter = revealCharacter
                if revealLine != nil || revealCharacter != nil {
                    s.revealRevision = (s.revealRevision ?? 0) &+ 1
                }
                if shouldRevealInMarkdownEditor {
                    s.markdownViewMode = .editor
                }
                file.tabs[idx] = .editor(s)
                file.activeTabId = s.id
                byWorktree[worktreeId] = file
                persist(worktreeId)
                return .editor(s)
            }
        }
        let title = (relativePath as NSString).lastPathComponent
        var state = EditorTabState(
            id: UUID().uuidString,
            title: title,
            relativePath: relativePath,
            revealLine: revealLine,
            revealEndLine: revealEndLine,
            revealCharacter: revealCharacter
        )
        if shouldRevealInMarkdownEditor {
            state.markdownViewMode = .editor
        }
        let tab = Tab.editor(state)
        append(tab, to: worktreeId)
        return tab
    }

    /// Open or focus an editor tab for an absolute URL outside the
    /// worktree (SDK headers, dependencies). Reuse-or-create keyed by
    /// absolute path. The tab is "owned" by `worktreeId` so closing the
    /// worktree cascades.
    ///
    /// `originatingRelativePath` is the worktree-relative path of the
    /// in-worktree file from which the user navigated here (e.g. via
    /// ⌘-click). Stored on the tab so that LSP traffic for this external
    /// file is routed to the correct holder in nested-package layouts.
    ///
    /// `originatingWorktreeRoot` and `language` are used to rebind the
    /// external LSP holder when reusing an existing tab from a different
    /// origin package, even while the tab is inactive.
    @discardableResult
    func openExternalEditor(
        worktreeId: String,
        absoluteURL: URL,
        revealLine: Int?,
        revealCharacter: Int?,
        revealEndLine: Int? = nil,
        originatingRelativePath: String? = nil,
        originatingWorktreeRoot: URL? = nil,
        language: String? = nil,
        editable: Bool = false
    ) -> Tab {
        let absPath = absoluteURL.path
        let shouldRevealInMarkdownEditor = (revealLine != nil || revealCharacter != nil)
            && MarkdownFileType.supportsRichPreview(relativePath: absPath)
        if var file = byWorktree[worktreeId],
           let idx = file.tabs.firstIndex(where: {
               if case .editor(let s) = $0 { return s.externalAbsolutePath == absPath }
               return false
           }) {
            if case .editor(var s) = file.tabs[idx] {
                let originChanged = (s.originatingRelativePath != originatingRelativePath)
                s.revealLine = revealLine
                s.revealEndLine = revealEndLine
                s.revealCharacter = revealCharacter
                if revealLine != nil || revealCharacter != nil {
                    s.revealRevision = (s.revealRevision ?? 0) &+ 1
                }
                if shouldRevealInMarkdownEditor {
                    s.markdownViewMode = .editor
                }
                s.originatingRelativePath = originatingRelativePath   // refresh the origin
                // Upgrade an existing tab to editable if a more-editable open
                // is requested; never downgrade an already-editable tab.
                if editable { s.externalEditable = true }
                file.tabs[idx] = .editor(s)
                file.activeTabId = s.id
                byWorktree[worktreeId] = file
                persist(worktreeId)
                if originChanged, let originatingWorktreeRoot {
                    let originatingFileURL = originatingRelativePath.flatMap {
                        originatingWorktreeRoot.appendingPathComponent($0)
                    }
                    if let language {
                        rebindExternalLSPHolder(
                            tabId: s.id,
                            absoluteURL: absoluteURL,
                            worktreeRoot: originatingWorktreeRoot,
                            originatingFileURL: originatingFileURL,
                            language: language
                        )
                    } else if externalLSPInfo[s.id]?.language == nil {
                        externalLSPInfo[s.id] = ExternalLSPInfo(
                            worktreeRoot: originatingWorktreeRoot,
                            originatingFileURL: originatingFileURL,
                            language: nil
                        )
                    }
                }
                return .editor(s)
            }
        }
        let title = absoluteURL.lastPathComponent
        var state = EditorTabState(
            id: UUID().uuidString,
            title: title,
            relativePath: "",
            revealLine: revealLine,
            revealEndLine: revealEndLine,
            revealCharacter: revealCharacter,
            externalAbsolutePath: absPath,
            originatingRelativePath: originatingRelativePath,
            externalEditable: editable ? true : nil
        )
        if shouldRevealInMarkdownEditor {
            state.markdownViewMode = .editor
        }
        let tab = Tab.editor(state)
        append(tab, to: worktreeId)
        return tab
    }

    /// Rebind an external tab's LSP holder when the originating in-worktree
    /// file changes (e.g. the user ⌘-clicked the same SDK file from a
    /// different package while the external tab was inactive). Operates
    /// regardless of whether the tab is currently active, so the fix applies
    /// even when the coordinator's `updateIfNeeded` path is never reached.
    private func rebindExternalLSPHolder(
        tabId: TabID,
        absoluteURL: URL,
        worktreeRoot: URL,
        originatingFileURL: URL?,
        language: String
    ) {
        let oldInfo = externalLSPInfo[tabId]
        let newInfo = ExternalLSPInfo(
            worktreeRoot: worktreeRoot,
            originatingFileURL: originatingFileURL,
            language: language
        )
        externalLSPInfo[tabId] = newInfo

        // Cancel any in-flight open targeting the old holder so its completion
        // handler can no longer record openedExternalDocs for a stale holder.
        pendingExternalOpenTasks[tabId]?.cancel()
        pendingExternalOpenTasks[tabId] = nil
        pendingExternalOpenGen[tabId] = nil

        // If we already opened against the OLD holder, close that ref now.
        if openedExternalDocs.contains(tabId), let old = oldInfo, let oldLanguage = old.language {
            let lsp = self.lsp
            Task { [lsp, old] in
                await lsp?.closeExternalDocument(
                    absoluteURL: absoluteURL,
                    originatingWorktreeRoot: old.worktreeRoot,
                    originatingFileURL: old.originatingFileURL,
                    language: oldLanguage
                )
            }
        }

        // Clear the opened flag so ensureExternalLSPOpen retries against the
        // new holder even if the tab was already open against the old one.
        openedExternalDocs.remove(tabId)
        ensureExternalLSPOpen(tabId: tabId)
    }

    @discardableResult
    func append(acpSession state: ACPSessionTabState, to worktreeId: String) -> Tab {
        let tab = Tab.acpSession(state)
        append(tab, to: worktreeId)
        return tab
    }

    @discardableResult
    func appendDiff(
        worktreeId: String,
        title: String,
        relativePath: String,
        staged: Bool = false,
        originalPath: String? = nil,
        compareWithHEAD: Bool = false
    ) -> Tab {
        let state = DiffTabState(
            id: UUID().uuidString,
            title: title,
            relativePath: relativePath,
            staged: staged,
            originalPath: originalPath,
            compareWithHEAD: compareWithHEAD
        )
        let tab = Tab.diff(state)
        append(tab, to: worktreeId)
        return tab
    }

    @discardableResult
    func appendStashDiff(worktreeId: String, stash: GitStash, file: GitStashFile) -> Tab {
        let state = StashDiffTabState(worktreeId: worktreeId, stash: stash, file: file)
        let tab = Tab.stashDiff(state)
        append(tab, to: worktreeId)
        return tab
    }

    @discardableResult
    func appendCommit(worktreeId: String, sha: String, title: String) -> Tab {
        let state = CommitTabState(worktreeId: worktreeId, sha: sha, title: title)
        let tab = Tab.commit(state)
        append(tab, to: worktreeId)
        return tab
    }

    @discardableResult
    func updateCommit(
        worktreeId: String,
        tabId: TabID,
        mutate: (inout CommitTabState) -> Void
    ) -> Tab? {
        guard var file = byWorktree[worktreeId],
              let idx = file.tabs.firstIndex(where: { $0.id == tabId }),
              case .commit(var state) = file.tabs[idx]
        else { return nil }
        mutate(&state)
        let tab = Tab.commit(state)
        if tab.id != tabId,
           let existingIdx = file.tabs.firstIndex(where: { $0.id == tab.id && $0.id != tabId }) {
            let existing = file.tabs[existingIdx]
            file.tabs.remove(at: idx)
            file.activeTabId = existing.id
            byWorktree[worktreeId] = file
            persist(worktreeId)
            return existing
        }
        file.tabs[idx] = tab
        if file.activeTabId == tabId {
            file.activeTabId = tab.id
        }
        byWorktree[worktreeId] = file
        persist(worktreeId)
        return tab
    }

    @discardableResult
    func openCommitEditor(
        worktreeId: String,
        baseRef: String,
        originalSha: String,
        currentSha: String,
        title: String
    ) -> Tab {
        let state = CommitEditorTabState(
            worktreeId: worktreeId,
            baseRef: baseRef,
            originalSha: originalSha,
            currentSha: currentSha,
            title: title
        )
        if var file = byWorktree[worktreeId],
           let idx = file.tabs.firstIndex(where: { $0.id == state.id }),
           case .commitEditor(var existing) = file.tabs[idx] {
            if existing.currentSha == currentSha {
                existing.title = title
            }
            let tab = Tab.commitEditor(existing)
            file.tabs[idx] = tab
            file.activeTabId = tab.id
            byWorktree[worktreeId] = file
            persist(worktreeId)
            return tab
        }
        let tab = Tab.commitEditor(state)
        append(tab, to: worktreeId)
        return tab
    }

    /// Returns the stashed draft commit state for `worktreeId`, if one exists.
    /// A stash is created when a non-empty draft tab is closed; it's cleared
    /// when the user explicitly discards or when a commit consumes the draft.
    func stashedDraft(worktreeId: String) -> DraftCommitTabState? {
        byWorktree[worktreeId]?.stashedDraft
    }

    @discardableResult
    func openOrFocusReviewChanges(worktreeId: String) -> Tab {
        if var file = byWorktree[worktreeId],
           let idx = file.tabs.firstIndex(where: {
               if case .reviewChanges(let state) = $0 {
                   return state.worktreeId == worktreeId
               }
               return false
           }) {
            let tab = file.tabs[idx]
            file.activeTabId = tab.id
            byWorktree[worktreeId] = file
            persist(worktreeId)
            return tab
        }

        let tab = Tab.reviewChanges(ReviewChangesTabState(worktreeId: worktreeId))
        append(tab, to: worktreeId)
        return tab
    }

    @discardableResult
    func openOrFocusFileSnapshot(worktreeId: String, relativePath: String, ref: String = "HEAD") -> Tab {
        let state = FileSnapshotTabState(worktreeId: worktreeId, relativePath: relativePath, ref: ref)
        if tabs(forWorktree: worktreeId).contains(where: { $0.id == state.id }) {
            activate(worktreeId: worktreeId, tabId: state.id)
            return tabs(forWorktree: worktreeId).first(where: { $0.id == state.id }) ?? .fileSnapshot(state)
        }
        let tab = Tab.fileSnapshot(state)
        append(tab, to: worktreeId)
        return tab
    }

    @discardableResult
    func openOrFocusFileHistory(worktreeId: String, relativePath: String) -> Tab {
        let state = FileHistoryTabState(worktreeId: worktreeId, relativePath: relativePath)
        if tabs(forWorktree: worktreeId).contains(where: { $0.id == state.id }) {
            activate(worktreeId: worktreeId, tabId: state.id)
            return tabs(forWorktree: worktreeId).first(where: { $0.id == state.id }) ?? .fileHistory(state)
        }
        let tab = Tab.fileHistory(state)
        append(tab, to: worktreeId)
        return tab
    }

    @discardableResult
    func openOrFocusGGInbox(worktreeId: String, projectId: String, projectName: String) -> Tab {
        let state = GGInboxTabState(projectId: projectId, projectName: projectName)
        if tabs(forWorktree: worktreeId).contains(where: { $0.id == state.id }) {
            activate(worktreeId: worktreeId, tabId: state.id)
            return tabs(forWorktree: worktreeId).first(where: { $0.id == state.id }) ?? .ggInbox(state)
        }
        let tab = Tab.ggInbox(state)
        append(tab, to: worktreeId)
        return tab
    }

    @discardableResult
    func openGGSplitCommit(
        worktreeId: String,
        targetGGID: String?,
        targetSHA: String
    ) -> TabID {
        let state = GGSplitCommitTabState(
            worktreeId: worktreeId,
            targetGGID: targetGGID,
            targetSHA: targetSHA
        )
        if tabs(forWorktree: worktreeId).contains(where: { $0.id == state.id }) {
            activate(worktreeId: worktreeId, tabId: state.id)
            return state.id
        }
        append(.ggSplitCommit(state), to: worktreeId)
        return state.id
    }

    @discardableResult
    func openOrFocusReviewSession(worktreeId: String, record: ReviewSessionRecord) -> Tab {
        let baseState = ReviewSessionTabState(worktreeId: worktreeId, record: record)
        if var file = byWorktree[worktreeId],
           let idx = file.tabs.firstIndex(where: { $0.id == baseState.id }),
           case .reviewSession(var existing) = file.tabs[idx] {
            existing.title = record.target.title
            existing.selectedFileID = record.selectedFileID
            existing.focusedCommentID = record.focusedCommentID
            let tab = Tab.reviewSession(existing)
            file.tabs[idx] = tab
            file.activeTabId = tab.id
            byWorktree[worktreeId] = file
            persist(worktreeId)
            return tab
        }

        let tab = Tab.reviewSession(baseState)
        append(tab, to: worktreeId)
        return tab
    }

    @discardableResult
    func updateReviewSession(
        worktreeId: String,
        tabId: TabID,
        mutate: (inout ReviewSessionTabState) -> Void
    ) -> Tab? {
        guard var file = byWorktree[worktreeId],
              let idx = file.tabs.firstIndex(where: { $0.id == tabId }),
              case .reviewSession(var state) = file.tabs[idx]
        else { return nil }
        mutate(&state)
        let tab = Tab.reviewSession(state)
        if tab.id != tabId,
           let existingIdx = file.tabs.firstIndex(where: { $0.id == tab.id && $0.id != tabId }) {
            let existing = file.tabs[existingIdx]
            file.tabs.remove(at: idx)
            file.activeTabId = existing.id
            byWorktree[worktreeId] = file
            persist(worktreeId)
            return existing
        }
        file.tabs[idx] = tab
        if file.activeTabId == tabId {
            file.activeTabId = tab.id
        }
        byWorktree[worktreeId] = file
        persist(worktreeId)
        return tab
    }

    @discardableResult
    func openOrFocusReviewPR(worktreeId: String, snapshot: ReviewLoopSnapshot) -> Tab {
        let baseState = ReviewPRTabState(worktreeId: worktreeId, snapshot: snapshot)
        if var file = byWorktree[worktreeId],
           let idx = file.tabs.firstIndex(where: { $0.id == baseState.id }),
           case .reviewPR(var existing) = file.tabs[idx] {
            existing.refreshSnapshotMetadata(from: snapshot)
            let tab = Tab.reviewPR(existing)
            file.tabs[idx] = tab
            file.activeTabId = tab.id
            byWorktree[worktreeId] = file
            persist(worktreeId)
            return tab
        }
        let tab = Tab.reviewPR(baseState)
        append(tab, to: worktreeId)
        return tab
    }

    @discardableResult
    func openOrFocusDraftCommit(worktreeId: String, resetAmend: Bool = false) -> Tab {
        let baseState = DraftCommitTabState(worktreeId: worktreeId)
        if var file = byWorktree[worktreeId],
           let idx = file.tabs.firstIndex(where: { $0.id == baseState.id }),
           case .draftCommit(var existing) = file.tabs[idx] {
            if resetAmend {
                existing.prepareForNewCommit()
                file.tabs[idx] = .draftCommit(existing)
            }
            file.activeTabId = existing.id
            byWorktree[worktreeId] = file
            persist(worktreeId)
            return file.tabs[idx]
        }
        // No live tab — restore from the stash if present, otherwise start fresh.
        var state = byWorktree[worktreeId]?.stashedDraft ?? baseState
        if resetAmend {
            state.prepareForNewCommit()
            if var file = byWorktree[worktreeId], file.stashedDraft != nil {
                file.stashedDraft = state
                byWorktree[worktreeId] = file
                persist(worktreeId)
            }
        }
        let tab = Tab.draftCommit(state)
        append(tab, to: worktreeId)
        return tab
    }

    @discardableResult
    func updateDraftCommit(
        worktreeId: String,
        tabId: TabID,
        mutate: (inout DraftCommitTabState) -> Void
    ) -> Tab? {
        guard var file = byWorktree[worktreeId],
              let idx = file.tabs.firstIndex(where: { $0.id == tabId }),
              case .draftCommit(var state) = file.tabs[idx]
        else { return nil }
        mutate(&state)
        let tab = Tab.draftCommit(state)
        file.tabs[idx] = tab
        byWorktree[worktreeId] = file
        persist(worktreeId)
        return tab
    }

    @discardableResult
    func openOrFocusDraftReviewRequest(worktreeId: String, snapshot: ReviewLoopSnapshot) -> Tab {
        let baseState = DraftReviewRequestTabState(worktreeId: worktreeId, snapshot: snapshot)
        if var file = byWorktree[worktreeId],
           let idx = file.tabs.firstIndex(where: { $0.id == baseState.id }),
           case .draftReviewRequest(var existing) = file.tabs[idx] {
            existing.refreshSnapshotMetadata(from: snapshot)
            let tab = Tab.draftReviewRequest(existing)
            file.tabs[idx] = tab
            file.activeTabId = tab.id
            byWorktree[worktreeId] = file
            persist(worktreeId)
            return tab
        }
        let tab = Tab.draftReviewRequest(baseState)
        append(tab, to: worktreeId)
        return tab
    }

    @discardableResult
    func updateDraftReviewRequest(
        worktreeId: String,
        tabId: TabID,
        mutate: (inout DraftReviewRequestTabState) -> Void
    ) -> Tab? {
        guard var file = byWorktree[worktreeId],
              let idx = file.tabs.firstIndex(where: { $0.id == tabId }),
              case .draftReviewRequest(var state) = file.tabs[idx]
        else { return nil }
        mutate(&state)
        let tab = Tab.draftReviewRequest(state)
        file.tabs[idx] = tab
        byWorktree[worktreeId] = file
        persist(worktreeId)
        return tab
    }

    /// Clear any stashed draft commit state for the given worktree.
    /// Used when the user explicitly discards the draft (via tab context
    /// menu) or after a successful commit consumes the draft.
    func discardStashedDraft(worktreeId: String) {
        guard var file = byWorktree[worktreeId], file.stashedDraft != nil else { return }
        file.stashedDraft = nil
        byWorktree[worktreeId] = file
        persist(worktreeId)
    }

    @discardableResult
    func replaceDraftWithCommitEditor(
        worktreeId: String,
        draftTabId: TabID,
        baseRef: String,
        newSha: String,
        title: String
    ) -> Tab? {
        guard var file = byWorktree[worktreeId],
              let idx = file.tabs.firstIndex(where: { $0.id == draftTabId }),
              case .draftCommit = file.tabs[idx]
        else { return nil }
        let editor = CommitEditorTabState(
            worktreeId: worktreeId,
            baseRef: baseRef,
            originalSha: newSha,
            currentSha: newSha,
            title: title
        )
        let tab = Tab.commitEditor(editor)
        file.tabs[idx] = tab
        if file.activeTabId == draftTabId {
            file.activeTabId = tab.id
        }
        file.stashedDraft = nil
        byWorktree[worktreeId] = file
        persist(worktreeId)
        return tab
    }

    @discardableResult
    func updateCommitEditor(
        worktreeId: String,
        tabId: TabID,
        currentSha: String,
        title: String
    ) -> Tab? {
        guard var file = byWorktree[worktreeId],
              let idx = file.tabs.firstIndex(where: { $0.id == tabId }),
              case .commitEditor(var state) = file.tabs[idx]
        else { return nil }
        state.currentSha = currentSha
        state.title = title
        let tab = Tab.commitEditor(state)
        file.tabs[idx] = tab
        byWorktree[worktreeId] = file
        persist(worktreeId)
        return tab
    }

    func updateCommitEditorShas(worktreeId: String, shaMap: [String: String]) {
        guard !shaMap.isEmpty, var file = byWorktree[worktreeId] else { return }
        var changed = false
        for idx in file.tabs.indices {
            guard case .commitEditor(var state) = file.tabs[idx],
                  let newSha = shaMap[state.currentSha],
                  newSha != state.currentSha else { continue }
            state.currentSha = newSha
            file.tabs[idx] = .commitEditor(state)
            changed = true
        }
        guard changed else { return }
        byWorktree[worktreeId] = file
        persist(worktreeId)
    }

    /// Open a merge-conflict tab for `relativePath`, or activate the existing
    /// one if it's already open. Returns the tab.
    @discardableResult
    func openMergeConflict(worktreeId: String, relativePath: String, title: String) -> Tab {
        if var file = byWorktree[worktreeId],
           let idx = file.tabs.firstIndex(where: {
               if case .mergeConflict(let s) = $0 {
                   return s.relativePath == relativePath
               }
               return false
           }) {
            let existing = file.tabs[idx]
            file.activeTabId = existing.id
            byWorktree[worktreeId] = file
            persist(worktreeId)
            return existing
        }
        let state = MergeConflictTabState(
            worktreeId: worktreeId,
            relativePath: relativePath,
            title: title
        )
        let tab = Tab.mergeConflict(state)
        append(tab, to: worktreeId)
        return tab
    }

    /// Mutate the `MergeConflictTabState` for `tabId` in `worktreeId`'s tab list,
    /// in place. Used by the merge editor view to persist UI state like the
    /// `showBase` toggle. Persists to disk.
    @discardableResult
    func updateMergeConflict(
        worktreeId: String,
        tabId: TabID,
        _ transform: (inout MergeConflictTabState) -> Void
    ) -> Bool {
        guard var file = byWorktree[worktreeId],
              let idx = file.tabs.firstIndex(where: { $0.id == tabId }),
              case .mergeConflict(var state) = file.tabs[idx]
        else { return false }
        transform(&state)
        file.tabs[idx] = .mergeConflict(state)
        byWorktree[worktreeId] = file
        persist(worktreeId)
        return true
    }

    /// Open or focus an image preview tab for `relativePath`.
    @discardableResult
    func openImagePreview(worktreeId: String, relativePath: String) -> Tab {
        if var file = byWorktree[worktreeId],
           let idx = file.tabs.firstIndex(where: {
               if case .imagePreview(let s) = $0 { return s.relativePath == relativePath }
               return false
           }) {
            if case .imagePreview(let s) = file.tabs[idx] {
                file.activeTabId = s.id
                byWorktree[worktreeId] = file
                persist(worktreeId)
                return .imagePreview(s)
            }
        }

        let title = (relativePath as NSString).lastPathComponent
        let state = ImagePreviewTabState(id: UUID().uuidString, title: title, relativePath: relativePath)
        let tab = Tab.imagePreview(state)
        append(tab, to: worktreeId)
        return tab
    }

    /// Open or focus a binary preview tab for `relativePath`.
    /// Used for files whose extension is in `BinaryFileType.knownBinaryExtensions`,
    /// so they skip a wasted text-load attempt in the editor.
    @discardableResult
    func openBinaryPreview(worktreeId: String, relativePath: String) -> Tab {
        if var file = byWorktree[worktreeId],
           let idx = file.tabs.firstIndex(where: {
               if case .binaryPreview(let s) = $0 { return s.relativePath == relativePath }
               return false
           }) {
            if case .binaryPreview(let s) = file.tabs[idx] {
                file.activeTabId = s.id
                byWorktree[worktreeId] = file
                persist(worktreeId)
                return .binaryPreview(s)
            }
        }

        let title = (relativePath as NSString).lastPathComponent
        let state = BinaryPreviewTabState(id: UUID().uuidString, title: title, relativePath: relativePath)
        let tab = Tab.binaryPreview(state)
        append(tab, to: worktreeId)
        return tab
    }

    /// Clears the reveal hints on an editor tab.
    /// Called by the editor coordinator once it has scrolled to the target,
    /// so the hint isn't replayed on the next view re-render or app
    /// relaunch.
    func consumeReveal(worktreeId: String, tabId: TabID) {
        guard var file = byWorktree[worktreeId],
              let idx = file.tabs.firstIndex(where: { $0.id == tabId }),
              case .editor(var s) = file.tabs[idx],
              s.revealLine != nil || s.revealEndLine != nil || s.revealCharacter != nil else { return }
        s.revealLine = nil
        s.revealEndLine = nil
        s.revealCharacter = nil
        file.tabs[idx] = .editor(s)
        byWorktree[worktreeId] = file
        persist(worktreeId)
    }

    // MARK: - Markdown tab helpers

    /// Lookup the editor state for a given tab. Used by markdown tabs to read
    /// persisted view-mode / split-fraction without re-walking the tab list.
    func editorTabState(worktreeId: String, tabId: TabID) -> EditorTabState? {
        guard let file = byWorktree[worktreeId] else { return nil }
        if let tab = file.tabs.first(where: { $0.id == tabId }),
           case .editor(let s) = tab { return s }
        return nil
    }

    /// Update the per-tab markdown view mode and persist.
    func setMarkdownViewMode(worktreeId: String, tabId: TabID, mode: MarkdownViewMode) {
        guard var file = byWorktree[worktreeId],
              let idx = file.tabs.firstIndex(where: { $0.id == tabId }),
              case .editor(var state) = file.tabs[idx] else { return }
        state.markdownViewMode = mode
        file.tabs[idx] = .editor(state)
        byWorktree[worktreeId] = file
        persist(worktreeId)
    }

    /// Update the per-tab markdown split fraction and persist.
    func setMarkdownSplitFraction(worktreeId: String, tabId: TabID, fraction: Double) {
        guard var file = byWorktree[worktreeId],
              let idx = file.tabs.firstIndex(where: { $0.id == tabId }),
              case .editor(var state) = file.tabs[idx] else { return }
        state.markdownSplitFraction = max(0.1, min(0.9, fraction))
        file.tabs[idx] = .editor(state)
        byWorktree[worktreeId] = file
        persist(worktreeId)
    }

    func activate(worktreeId: String, tabId: TabID) {
        var file = byWorktree[worktreeId] ?? TabsFile(tabs: [], activeTabId: nil)
        file.activeTabId = tabId
        byWorktree[worktreeId] = file
        persist(worktreeId)
    }

    func clearActiveTab(worktreeId: String) {
        guard var file = byWorktree[worktreeId],
              file.activeTabId != nil
        else { return }
        file.activeTabId = nil
        byWorktree[worktreeId] = file
        persist(worktreeId)
    }

    @discardableResult
    func restore(tab: Tab, worktreeID: String, placement: ClosedTabPlacement) -> TabID {
        var file = byWorktree[worktreeID] ?? TabsFile(tabs: [], activeTabId: nil)
        if file.tabs.contains(where: { $0.id == tab.id }) {
            file.activeTabId = tab.id
        } else {
            let index = placement.insertionIndex(in: file.tabs.map(\.id))
            file.tabs.insert(tab, at: index)
            file.activeTabId = tab.id
        }
        byWorktree[worktreeID] = file
        persist(worktreeID)
        return tab.id
    }

    /// Capture a draft commit tab's state into `file.stashedDraft` before
    /// removal. Non-empty drafts stash so they survive close/reopen. Empty
    /// drafts CLEAR the stash so a user who opens an old stashed draft,
    /// wipes the text, and closes the tab actually gets rid of it.
    /// Silently does nothing if `removingTabId` is not a draftCommit tab.
    private func captureDraftIfNeeded(_ file: inout TabsFile, removingTabId: TabID) {
        guard let tab = file.tabs.first(where: { $0.id == removingTabId }),
              case .draftCommit(let state) = tab else { return }
        let hasSubject = !state.subject.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let hasBody = !state.bodyText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        file.stashedDraft = (hasSubject || hasBody) ? state : nil
    }

    func close(worktreeId: String, tabId: TabID) {
        guard var file = byWorktree[worktreeId] else { return }
        guard let idx = file.tabs.firstIndex(where: { $0.id == tabId }) else { return }
        let tab = file.tabs[idx]
        // Only stash drafts the user actually authored. Closing an
        // untouched draft tab should NOT plant a sticky "Open draft"
        // affordance for an empty message.
        captureDraftIfNeeded(&file, removingTabId: tabId)
        let wasActive = file.activeTabId == tabId
        file.tabs.remove(at: idx)
        ggSplitCommitDrafts.removeValue(forKey: tabId)
        if case .terminal(let state) = tab {
            for leaf in state.root.leaves() {
                terminalRuntimeTitles.removeValue(forKey: leaf.id)
            }
        }
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

    @discardableResult
    func closeDiffTabs(worktreeId: String, relativePaths: some Sequence<String>) -> [TabID] {
        let pathSet = Set(relativePaths)
        guard !pathSet.isEmpty else { return [] }
        let tabIds = tabs(forWorktree: worktreeId).compactMap { tab -> TabID? in
            guard case .diff(let state) = tab, pathSet.contains(state.relativePath) else { return nil }
            return state.id
        }
        for tabId in tabIds {
            close(worktreeId: worktreeId, tabId: tabId)
        }
        return tabIds
    }

    func closeOthers(worktreeId: String, keeping tabId: TabID) -> [TabID] {
        guard var file = byWorktree[worktreeId] else { return [] }
        let closed = file.tabs.filter { $0.id != tabId }.map(\.id)
        guard let kept = file.tabs.first(where: { $0.id == tabId }) else { return [] }
        for id in closed {
            captureDraftIfNeeded(&file, removingTabId: id)
            ggSplitCommitDrafts.removeValue(forKey: id)
        }
        file.tabs = [kept]
        file.activeTabId = tabId
        byWorktree[worktreeId] = file
        persist(worktreeId)
        return closed
    }

    func closeAll(worktreeId: String) -> [TabID] {
        guard var file = byWorktree[worktreeId] else { return [] }
        let closed = file.tabs.map(\.id)
        for id in closed {
            captureDraftIfNeeded(&file, removingTabId: id)
            ggSplitCommitDrafts.removeValue(forKey: id)
        }
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
        for id in closed {
            captureDraftIfNeeded(&file, removingTabId: id)
            ggSplitCommitDrafts.removeValue(forKey: id)
        }
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
        for id in closed {
            captureDraftIfNeeded(&file, removingTabId: id)
            ggSplitCommitDrafts.removeValue(forKey: id)
        }
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
        try? store.write(file, to: tabsFile(forWorktreeId: worktreeId))
    }

    private func tabsFile(forWorktreeId worktreeId: String) -> URL {
        tabsDirectory.appendingPathComponent("\(worktreeId).json")
    }

    // MARK: - Buffer lifecycle

    /// Returns the buffer for `tabId`, creating it (cold-load from disk or
    /// hot-restore from snapshot) on first access.
    func buffer(worktreeId: String, tabId: TabID, worktreeRoot: URL, relativePath: String) -> EditorBuffer {
        if let existing = tabBuffers[tabId] { return existing }
        let snapshot = (try? bufferStore.read(worktreeId: worktreeId, tabId: tabId)) ?? nil
        var restoresToDifferentPath = snapshot.map { $0.relativePath != relativePath } ?? false
        if restoresToDifferentPath {
            if let snapshot,
               !canFollowBufferPathChange(worktreeId: worktreeId, oldPath: relativePath, newPath: snapshot.relativePath) {
                bufferStore.discard(worktreeId: worktreeId, tabId: tabId)
                restoresToDifferentPath = false
            }
        }
        let key = BufferKey(worktreeId: worktreeId, relativePath: relativePath)
        if !restoresToDifferentPath, let existing = buffers[key] {
            bufferKeys[tabId] = key
            tabBuffers[tabId] = existing
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
                lsp: lsp,
                checkConflictOnRestore: true
            )
        } else {
            buffer = EditorBuffer(
                worktreeRoot: worktreeRoot,
                relativePath: relativePath,
                store: bufferStore,
                worktreeId: worktreeId,
                tabId: tabId,
                checkConflictOnRestore: true
            )
        }
        buffer.startWatching()
        buffer.shouldFollowPathChange = { [weak self] oldPath, newPath in
            self?.canFollowBufferPathChange(worktreeId: worktreeId, oldPath: oldPath, newPath: newPath) ?? false
        }
        buffer.onPathChanged = { [weak self, weak buffer] oldPath, newPath in
            guard let buffer else { return }
            self?.handleBufferPathChanged(
                worktreeId: worktreeId,
                buffer: buffer,
                oldPath: oldPath,
                newPath: newPath
            )
        }
        buffer.onRestoredPathChanged = { [weak self, weak buffer] oldPath, newPath in
            guard let self, let buffer else { return }
            self.resolvePendingRestoredPathChange(
                worktreeId: worktreeId,
                tabId: tabId,
                buffer: buffer,
                oldPath: oldPath,
                newPath: newPath
            )
        }
        buffer.onInitialLoadFinished = { [weak self, weak buffer] in
            guard let self, let buffer else { return }
            self.indexRestoredPathBufferIfAvailable(worktreeId: worktreeId, tabId: tabId, buffer: buffer)
        }
        buffer.onSnapshotRequested = { [weak self, weak buffer] in
            guard let buffer else { return }
            self?.snapshotBufferForAllTabs(buffer)
        }
        buffer.onDiscardSnapshotsRequested = { [weak self, weak buffer] in
            guard let buffer else { return }
            self?.discardSnapshotsForAllTabs(buffer)
        }
        tabBuffers[tabId] = buffer
        if restoresToDifferentPath {
            bufferKeys[tabId] = key
            if buffer.initialLoadFinished {
                indexRestoredPathBufferIfAvailable(worktreeId: worktreeId, tabId: tabId, buffer: buffer)
            }
        } else if let restoredPathChange = buffer.consumeRestoredPathChange() {
            let restoredKey = BufferKey(worktreeId: worktreeId, relativePath: restoredPathChange.newPath)
            buffers[restoredKey] = buffer
            bufferKeys[tabId] = restoredKey
            _ = updateEditorPath(worktreeId: worktreeId, tabId: tabId, relativePath: restoredPathChange.newPath)
        } else {
            buffers[key] = buffer
            bufferKeys[tabId] = key
        }
        return buffer
    }

    /// Returns (or creates) a read-only external buffer keyed by absolute URL.
    /// Registering `tabId` in `externalTabURLs` ensures that the normal
    /// `discardBuffer(worktreeId:tabId:)` close-tab path tears the buffer
    /// down and stops its file watcher.
    ///
    /// Fires `openExternalDocument` via the LSP manager so the holder's
    /// reference count is tied to the buffer's lifetime, not the
    /// `CodeEditorView`'s. The open is retried on every call until a holder
    /// is found — this handles the case where a persisted external tab is
    /// restored before any in-worktree file has started the language server.
    func externalBuffer(
        worktreeId: String,
        tabId: TabID,
        absoluteURL: URL,
        worktreeRoot: URL? = nil,
        originatingFileURL: URL? = nil,
        language: String? = nil,
        editable: Bool = false
    ) -> EditorBuffer {
        let existingEntry = externalTabURLs[tabId]
        if existingEntry?.worktreeId != worktreeId || existingEntry?.url != absoluteURL {
            externalTabURLs[tabId] = (worktreeId: worktreeId, url: absoluteURL)
        }
        let buffer = bufferStore.externalBuffer(
            worktreeId: worktreeId,
            absoluteURL: absoluteURL,
            editable: editable,
            tabId: editable ? tabId : nil
        )
        buffer.startWatchingIfNeeded()

        if let root = worktreeRoot {
            let existing = externalLSPInfo[tabId]
            let shouldRefreshOrigin = language != nil || existing?.language == nil
            let info = ExternalLSPInfo(
                worktreeRoot: shouldRefreshOrigin ? root : existing?.worktreeRoot ?? root,
                originatingFileURL: shouldRefreshOrigin ? originatingFileURL : existing?.originatingFileURL,
                language: language ?? existing?.language
            )
            if info != existing {
                externalLSPInfo[tabId] = info
            }
        }

        ensureExternalLSPOpen(tabId: tabId)

        return buffer
    }

    /// Attempts to open the LSP document for `tabId` if it hasn't been opened
    /// yet. Idempotent: no-ops if already opened or if an open is already in
    /// flight. Retries silently until a holder is available — this covers the
    /// case where a persisted external tab is restored before any in-worktree
    /// file has started the language server.
    func ensureExternalLSPOpen(tabId: TabID) {
        guard !openedExternalDocs.contains(tabId), pendingExternalOpenTasks[tabId] == nil else { return }
        guard let lsp,
              let info = externalLSPInfo[tabId],
              let language = info.language,
              let entry = externalTabURLs[tabId] else { return }
        let absoluteURL = entry.url
        let contents = bufferStore.externalBuffer(worktreeId: entry.worktreeId, absoluteURL: absoluteURL).storage.string
        // Capture the info snapshot this Task is opening against so the completion
        // can detect a mid-flight rebind and undo the open on the old holder.
        let snapshot = info
        let gen = (pendingExternalOpenGen[tabId] ?? 0) + 1
        pendingExternalOpenGen[tabId] = gen
        let task = Task { [weak self] in
            let opened = await lsp.openExternalDocument(
                absoluteURL: absoluteURL,
                originatingWorktreeRoot: snapshot.worktreeRoot,
                originatingFileURL: snapshot.originatingFileURL,
                language: language,
                contents: contents
            )
            await MainActor.run { [weak self] in
                guard let self else { return }
                // Only clear our own entry — a rebind may have installed a successor.
                if self.pendingExternalOpenGen[tabId] == gen {
                    self.pendingExternalOpenTasks[tabId] = nil
                }
                // If the tab was discarded while the open was in flight, undo it
                // against the snapshot we actually opened against, so the URI
                // doesn't leak on the holder until app exit.
                if self.externalTabURLs[tabId] == nil {
                    if opened {
                        Task { [lsp, snapshot] in
                            if let language = snapshot.language {
                                await lsp.closeExternalDocument(
                                    absoluteURL: absoluteURL,
                                    originatingWorktreeRoot: snapshot.worktreeRoot,
                                    originatingFileURL: snapshot.originatingFileURL,
                                    language: language
                                )
                            }
                        }
                    }
                    return
                }
                // Info changed mid-flight (rebind). Undo the open against the
                // snapshot so the old holder's ref is balanced. Don't touch
                // openedExternalDocs — the rebind's ensureExternalLSPOpen call
                // (issued after the rebind) will register the new holder.
                if let current = self.externalLSPInfo[tabId], current != snapshot {
                    if opened {
                        Task { [lsp, snapshot] in
                            if let language = snapshot.language {
                                await lsp.closeExternalDocument(
                                    absoluteURL: absoluteURL,
                                    originatingWorktreeRoot: snapshot.worktreeRoot,
                                    originatingFileURL: snapshot.originatingFileURL,
                                    language: language
                                )
                            }
                        }
                    }
                    return
                }
                if opened { self.openedExternalDocs.insert(tabId) }
            }
        }
        pendingExternalOpenTasks[tabId] = task
    }

    /// Inspect (do not create) the buffer for `tabId`. Used by tests and by
    /// dirty-tab queries.
    func peekBuffer(tabId: TabID) -> EditorBuffer? {
        tabBuffers[tabId] ?? peekExternalBuffer(tabId: tabId)
    }

    /// Non-creating lookup for an external editor buffer. Returns nil if no
    /// external buffer has been registered for this tab (or if the tab isn't
    /// an external editor tab). Used by read-only checks (e.g.
    /// `EditorTabView.isBinary`) to avoid the side-effecting creation in
    /// `externalBuffer(...)` while still detecting the load kind of external
    /// files that went through the editor path (unknown-extension binaries).
    func peekExternalBuffer(tabId: TabID) -> EditorBuffer? {
        guard let entry = externalTabURLs[tabId] else { return nil }
        return bufferStore.peekExternalBuffer(worktreeId: entry.worktreeId, absoluteURL: entry.url)
    }

    private func indexRestoredPathBufferIfAvailable(worktreeId: String, tabId: TabID, buffer: EditorBuffer) {
        guard tabBuffers[tabId] === buffer else { return }
        let key = BufferKey(worktreeId: worktreeId, relativePath: buffer.relativePath)
        if let existing = buffers[key], existing !== buffer { return }
        buffers[key] = buffer
        bufferKeys[tabId] = key
    }

    private func resolvePendingRestoredPathChange(
        worktreeId: String,
        tabId: TabID,
        buffer: EditorBuffer,
        oldPath: String,
        newPath: String
    ) {
        let oldKey = BufferKey(worktreeId: worktreeId, relativePath: oldPath)
        let restoredKey = BufferKey(worktreeId: worktreeId, relativePath: newPath)
        if buffers[oldKey] === buffer {
            buffers.removeValue(forKey: oldKey)
        }
        if let existing = buffers[restoredKey], existing !== buffer {
            tabBuffers[tabId] = existing
            bufferKeys[tabId] = restoredKey
            bufferStore.discard(worktreeId: worktreeId, tabId: tabId)
            _ = updateEditorPath(worktreeId: worktreeId, tabId: tabId, relativePath: newPath)
            buffer.close(persistDirtySnapshot: false)
            return
        }
        buffers[restoredKey] = buffer
        tabBuffers[tabId] = buffer
        bufferKeys[tabId] = restoredKey
        _ = updateEditorPath(worktreeId: worktreeId, tabId: tabId, relativePath: newPath)
        buffer.startWatching()
    }

    /// Excludes external tabs deliberately: `peekBuffer` resolves them via
    /// its external fallback, but callers here (Save As, Rename) assume a
    /// worktree-relative `relativePath` and call `saveAs`/`moveTo`, which
    /// operate against the buffer's own root — the script's parent
    /// directory for an external buffer, not the worktree. Cmd+S and revert
    /// don't go through this path (they use `peekBuffer` directly, which is
    /// exactly where the external fallback is meant to apply).
    func activeEditorContext(worktreeId: String) -> (tab: EditorTabState, buffer: EditorBuffer)? {
        guard let activeId = activeTabId(forWorktree: worktreeId),
              let tab = tabs(forWorktree: worktreeId).first(where: { $0.id == activeId }),
              case .editor(let state) = tab,
              !state.isExternal,
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
            // Cancel any in-flight open Task so it bails out before recording
            // the stale tabId in openedExternalDocs. The Task's completion
            // handler will also re-check externalTabURLs and undo the open if
            // the LSP request had already been sent before cancellation.
            pendingExternalOpenTasks[tabId]?.cancel()
            pendingExternalOpenTasks[tabId] = nil
            pendingExternalOpenGen[tabId] = nil
            // Fire closeExternalDocument to release the LSP ref that was
            // acquired in externalBuffer(...) on cache miss.
            if let info = externalLSPInfo.removeValue(forKey: tabId), let lsp, let language = info.language {
                let url = ext.url
                Task { [lsp, info, language] in
                    await lsp.closeExternalDocument(
                        absoluteURL: url,
                        originatingWorktreeRoot: info.worktreeRoot,
                        originatingFileURL: info.originatingFileURL,
                        language: language
                    )
                }
            }
            openedExternalDocs.remove(tabId)
            bufferStore.discardExternalBuffer(worktreeId: ext.worktreeId, absoluteURL: ext.url)
            return
        }
        // Always discard the persisted snapshot for in-worktree tabs, even
        // when the buffer was never loaded (e.g. snapshot-only state after a
        // relaunch). Otherwise the early-return below would leave snapshot
        // JSON orphaned under App Support after tab teardown.
        bufferStore.discard(worktreeId: worktreeId, tabId: tabId)
        let buffer = tabBuffers.removeValue(forKey: tabId)
        guard let key = bufferKeys.removeValue(forKey: tabId) else { return }
        assert(key.worktreeId == worktreeId, "discardBuffer called with worktreeId=\(worktreeId) but buffer is owned by \(key.worktreeId)")
        guard let buffer else { return }
        if let nextTabId = tabBuffers.first(where: { $0.value === buffer })?.key {
            if buffer.persistenceTabId == tabId {
                buffer.adoptPersistenceTabId(nextTabId)
            }
            return
        }
        if buffers[key] === buffer {
            buffers.removeValue(forKey: key)
        }
        buffer.close(persistDirtySnapshot: false)
    }

    /// Tab IDs whose buffers are currently dirty. Order is unspecified.
    func dirtyTabIds() -> [TabID] {
        bufferKeys.compactMap { tabId, _ in
            peekBuffer(tabId: tabId)?.dirty == true ? tabId : nil
        }
    }

    /// Returns `true` when the in-worktree buffer at `relativePath` (within
    /// `worktreeId`) is currently live **and** dirty. External/uninstantiated
    /// buffers with only a hot-exit snapshot on disk are not considered dirty
    /// here because the agent write replaces on-disk bytes — the snapshot
    /// already diverges from disk, so no additional notice is needed.
    func hasDirtyBuffer(worktreeId: String, relativePath: String) -> Bool {
        let key = BufferKey(worktreeId: worktreeId, relativePath: relativePath)
        return buffers[key]?.dirty == true
    }

    /// Live in-memory contents of the editor buffer at
    /// `relativePath`, when one is open AND dirty. Returns `nil` when
    /// the file isn't open in the editor or has no unsaved changes,
    /// in which case the caller should fall back to disk. Used by the
    /// ACP `fs/read_text_file` handler so agents see what the user
    /// sees, not the last saved bytes.
    func dirtyBufferText(worktreeId: String, relativePath: String) -> String? {
        let key = BufferKey(worktreeId: worktreeId, relativePath: relativePath)
        guard let buffer = buffers[key], buffer.dirty else { return nil }
        return buffer.storage.string
    }

    /// Tab IDs in `worktreeId` that have unsaved changes — either a live dirty
    /// buffer or a persisted hot-exit snapshot for a buffer that hasn't been
    /// instantiated yet. Returns IDs in tab order (declaration order within the
    /// worktree's tab list).
    func tabIdsWithUnsavedChanges(forWorktree worktreeId: String) -> [TabID] {
        guard let file = byWorktree[worktreeId] else { return [] }
        var result: [TabID] = []
        for tab in file.tabs {
            guard case .editor(let state) = tab else { continue }
            let tabId = state.id
            if let buffer = peekBuffer(tabId: tabId) {
                if buffer.saveDisposition != .clean { result.append(tabId) }
            } else if (try? bufferStore.read(worktreeId: worktreeId, tabId: tabId)) != nil {
                result.append(tabId)
            }
        }
        return result
    }

    @discardableResult
    func updateEditorPath(worktreeId: String, tabId: TabID, relativePath: String) -> Bool {
        guard var file = byWorktree[worktreeId],
              let idx = file.tabs.firstIndex(where: { $0.id == tabId }),
              case .editor(var state) = file.tabs[idx] else { return false }
        state.relativePath = relativePath
        state.title = (relativePath as NSString).lastPathComponent
        state.revealLine = nil
        state.revealEndLine = nil
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
        for (tabId, _) in bufferKeys {
            guard let buffer = peekBuffer(tabId: tabId), buffer.dirty else { continue }
            buffer.snapshotNow(tabId: tabId)
        }
        for tabId in externalTabURLs.keys {
            guard let buffer = peekExternalBuffer(tabId: tabId), buffer.dirty else { continue }
            buffer.snapshotNow(tabId: tabId)
        }
    }

    @discardableResult
    func saveAll(worktreeRoots: [String: URL] = [:]) -> [(tabId: TabID, error: Error)] {
        var errors: [(TabID, Error)] = []
        var saved = Set<ObjectIdentifier>()
        for (tabId, _) in bufferKeys {
            guard let buffer = peekBuffer(tabId: tabId), buffer.saveDisposition != .clean else { continue }
            let id = ObjectIdentifier(buffer)
            guard !saved.contains(id) else { continue }
            saved.insert(id)
            do {
                try buffer.saveRecordingError()
            } catch {
                errors.append((tabId, error))
            }
        }
        // Editable external buffers (e.g. global run scripts) are tracked in
        // `externalTabURLs`, not `bufferKeys` — they'd otherwise be silently
        // skipped by every save sweep. Read-only ones are never dirty, so
        // this is a no-op for the common ⌘-click navigation case.
        for tabId in externalTabURLs.keys {
            guard let buffer = peekExternalBuffer(tabId: tabId), buffer.saveDisposition != .clean else { continue }
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
            for tab in file.tabs {
                guard case .editor(let state) = tab,
                      peekBuffer(tabId: state.id) == nil,
                      (try? bufferStore.read(worktreeId: worktreeId, tabId: state.id)) != nil else { continue }
                let root = worktreeRoots[worktreeId]
                guard let buffer = materializeSnapshotBufferForSave(worktreeId: worktreeId, state: state, worktreeRoot: root) else { continue }
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

    @discardableResult
    func saveAllAwaitingRemote(worktreeRoots: [String: URL] = [:]) async -> [(tabId: TabID, error: Error)] {
        var errors: [(TabID, Error)] = []
        var saved = Set<ObjectIdentifier>()
        for (tabId, key) in bufferKeys {
            guard let buffer = buffers[key], buffer.dirty else { continue }
            let id = ObjectIdentifier(buffer)
            guard !saved.contains(id) else { continue }
            saved.insert(id)
            do {
                try await buffer.saveRecordingErrorAwaitingRemote()
            } catch {
                errors.append((tabId, error))
            }
        }
        // See the matching pass in `saveAll(worktreeRoots:)`: editable
        // external buffers (global run scripts) live outside `bufferKeys`.
        for tabId in externalTabURLs.keys {
            guard let buffer = peekExternalBuffer(tabId: tabId), buffer.dirty else { continue }
            let id = ObjectIdentifier(buffer)
            guard !saved.contains(id) else { continue }
            saved.insert(id)
            do {
                try await buffer.saveRecordingErrorAwaitingRemote()
            } catch {
                errors.append((tabId, error))
            }
        }
        for (worktreeId, file) in byWorktree {
            for tab in file.tabs {
                guard case .editor(let state) = tab,
                      peekBuffer(tabId: state.id) == nil,
                      (try? bufferStore.read(worktreeId: worktreeId, tabId: state.id)) != nil else { continue }
                let root = worktreeRoots[worktreeId]
                guard let buffer = materializeSnapshotBufferForSave(worktreeId: worktreeId, state: state, worktreeRoot: root) else { continue }
                do {
                    try await buffer.saveRecordingErrorAwaitingRemote()
                    buffer.close(persistDirtySnapshot: false)
                } catch {
                    errors.append((state.id, error))
                    buffer.close(persistDirtySnapshot: true)
                }
            }
        }
        return errors
    }

    /// Save all unsaved buffers for a single worktree. Mirrors the snapshot-
    /// materialize pattern from `saveAll(worktreeRoots:)` but scoped to one
    /// worktree so archive/delete can save before teardown.
    /// Returns an array of (tabId, error) pairs; empty on full success.
    @discardableResult
    func saveAllUnsaved(forWorktree worktreeId: String, root: URL) -> [(tabId: TabID, error: Error)] {
        var errors: [(TabID, Error)] = []
        var saved = Set<ObjectIdentifier>()
        // Pass 1: live dirty buffers belonging to this worktree.
        for (tabId, key) in bufferKeys {
            guard key.worktreeId == worktreeId,
                  let buffer = peekBuffer(tabId: tabId), buffer.saveDisposition != .clean else { continue }
            let id = ObjectIdentifier(buffer)
            guard !saved.contains(id) else { continue }
            saved.insert(id)
            do {
                try buffer.saveRecordingError()
            } catch {
                errors.append((tabId, error))
            }
        }
        // Pass 1b: editable external buffers (global run scripts) belonging
        // to this worktree — tracked in `externalTabURLs`, not `bufferKeys`.
        for (tabId, entry) in externalTabURLs {
            guard entry.worktreeId == worktreeId,
                  let buffer = peekExternalBuffer(tabId: tabId), buffer.saveDisposition != .clean else { continue }
            let id = ObjectIdentifier(buffer)
            guard !saved.contains(id) else { continue }
            saved.insert(id)
            do {
                try buffer.saveRecordingError()
            } catch {
                errors.append((tabId, error))
            }
        }
        // Pass 2: editor tabs with no live buffer but a persisted snapshot.
        guard let file = byWorktree[worktreeId] else { return errors }
        for tab in file.tabs {
            guard case .editor(let state) = tab,
                  peekBuffer(tabId: state.id) == nil,
                  (try? bufferStore.read(worktreeId: worktreeId, tabId: state.id)) != nil else { continue }
            guard let buffer = materializeSnapshotBufferForSave(worktreeId: worktreeId, state: state, worktreeRoot: root) else { continue }
            do {
                try buffer.saveRecordingError()
                buffer.close(persistDirtySnapshot: false)
            } catch {
                errors.append((state.id, error))
                buffer.close(persistDirtySnapshot: true)
            }
        }
        return errors
    }

    @discardableResult
    func saveAllUnsavedAwaitingRemote(forWorktree worktreeId: String, root: URL) async -> [(tabId: TabID, error: Error)] {
        var errors: [(TabID, Error)] = []
        var saved = Set<ObjectIdentifier>()
        // Pass 1: live dirty buffers belonging to this worktree.
        for (tabId, key) in bufferKeys {
            guard key.worktreeId == worktreeId,
                  let buffer = buffers[key], buffer.dirty else { continue }
            let id = ObjectIdentifier(buffer)
            guard !saved.contains(id) else { continue }
            saved.insert(id)
            do {
                try await buffer.saveRecordingErrorAwaitingRemote()
            } catch {
                errors.append((tabId, error))
            }
        }
        // Pass 1b: editable external buffers (global run scripts) belonging
        // to this worktree — tracked in `externalTabURLs`, not `bufferKeys`.
        for (tabId, entry) in externalTabURLs {
            guard entry.worktreeId == worktreeId,
                  let buffer = peekExternalBuffer(tabId: tabId), buffer.dirty else { continue }
            let id = ObjectIdentifier(buffer)
            guard !saved.contains(id) else { continue }
            saved.insert(id)
            do {
                try await buffer.saveRecordingErrorAwaitingRemote()
            } catch {
                errors.append((tabId, error))
            }
        }
        // Pass 2: editor tabs with no live buffer but a persisted snapshot.
        guard let file = byWorktree[worktreeId] else { return errors }
        for tab in file.tabs {
            guard case .editor(let state) = tab,
                  peekBuffer(tabId: state.id) == nil,
                  (try? bufferStore.read(worktreeId: worktreeId, tabId: state.id)) != nil else { continue }
            guard let buffer = materializeSnapshotBufferForSave(worktreeId: worktreeId, state: state, worktreeRoot: root) else { continue }
            do {
                try await buffer.saveRecordingErrorAwaitingRemote()
                buffer.close(persistDirtySnapshot: false)
            } catch {
                errors.append((state.id, error))
                buffer.close(persistDirtySnapshot: true)
            }
        }
        return errors
    }

    private func materializeSnapshotBufferForSave(worktreeId: String, state: EditorTabState, worktreeRoot: URL?) -> EditorBuffer? {
        let tabId = state.id
        guard let snapshot = (try? bufferStore.read(worktreeId: worktreeId, tabId: tabId)) ?? nil else { return nil }
        if let externalAbsolutePath = state.externalAbsolutePath, state.isExternalEditable {
            return externalBuffer(
                worktreeId: worktreeId,
                tabId: tabId,
                absoluteURL: URL(fileURLWithPath: externalAbsolutePath),
                editable: true
            )
        }
        guard let worktreeRoot else { return nil }
        let relativePath = state.relativePath
        if snapshot.relativePath != relativePath,
           !canFollowBufferPathChange(worktreeId: worktreeId, oldPath: relativePath, newPath: snapshot.relativePath) {
            bufferStore.discard(worktreeId: worktreeId, tabId: tabId)
            return nil
        }
        let buffer: EditorBuffer
        if let lsp {
            buffer = EditorBuffer(
                worktreeRoot: worktreeRoot,
                relativePath: relativePath,
                store: bufferStore,
                worktreeId: worktreeId,
                tabId: tabId,
                lsp: lsp,
                loadSynchronously: true
            )
        } else {
            buffer = EditorBuffer(
                worktreeRoot: worktreeRoot,
                relativePath: relativePath,
                store: bufferStore,
                worktreeId: worktreeId,
                tabId: tabId,
                loadSynchronously: true
            )
        }
        if buffer.relativePath != relativePath {
            _ = updateEditorPath(worktreeId: worktreeId, tabId: tabId, relativePath: buffer.relativePath)
        }
        return buffer
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

    /// Async save that attempts LSP formatting first when enabled.
    @discardableResult
    func saveActiveAsync(worktreeId: String, config: AppConfig.Code) async -> Bool {
        guard let activeId = activeTabId(forWorktree: worktreeId),
              let buffer = peekBuffer(tabId: activeId) else { return false }
        do {
            try await buffer.formatAndSaveRecordingError(config: config, lsp: lsp)
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

    private func handleBufferPathChanged(
        worktreeId: String,
        buffer: EditorBuffer,
        oldPath: String,
        newPath: String
    ) {
        let oldKey = BufferKey(worktreeId: worktreeId, relativePath: oldPath)
        let newKey = BufferKey(worktreeId: worktreeId, relativePath: newPath)
        let affectedTabIds = tabBuffers.compactMap { tabId, liveBuffer in
            liveBuffer === buffer ? tabId : nil
        }
        guard !affectedTabIds.isEmpty else { return }

        if buffers[oldKey] === buffer {
            buffers.removeValue(forKey: oldKey)
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
        for tab in file.tabs {
            guard case .editor(let state) = tab,
                  state.relativePath == newPath,
                  bufferKeys[state.id] == nil else { continue }
            if let snapshot = (try? bufferStore.read(worktreeId: worktreeId, tabId: state.id)) ?? nil,
               snapshot.relativePath != newPath {
                continue
            }
            return false
        }
        return true
    }

    /// Re-fires `didOpen` for every live buffer whose resolved LSP language
    /// matches `language` *or any alias that shares its install recipes*.
    /// Used after the install nudge finishes: the buffers tried to open
    /// their document at construction time, the spawn failed (executable
    /// missing), and `WorkspaceLSPManager` dropped the holder. Without a
    /// re-open they stay LSP-less even after the executable becomes
    /// available.
    ///
    /// Expands the alias group so that installing typescript-language-server
    /// from a `.tsx` banner also revives open `.ts`/`.js`/`.jsx` tabs (all
    /// four languages share the same recipe in the catalog).
    ///
    /// Covers both in-worktree buffers (via `EditorBuffer.reopenLSPDocument`)
    /// and external tabs (via `ensureExternalLSPOpen` — idempotent against
    /// already-opened docs).
    func reopenLSPDocuments(forLanguage language: String) {
        let group = Set(RecommendedLanguageCatalog.aliasGroup(forLanguage: language))
        for buffer in uniqueInWorktreeBuffers()
            where buffer.language.map(group.contains) ?? false {
            buffer.reopenLSPDocument()
        }
        for (tabId, info) in externalLSPInfo where info.language.map(group.contains) ?? false {
            ensureExternalLSPOpen(tabId: tabId)
        }
    }

    func reopenLSPDocuments(forFileExtensions extensions: [String], language: String) {
        let normalized = Set(extensions.map { $0.lowercased() }.filter { !$0.isEmpty })
        guard !normalized.isEmpty else { return }
        for buffer in uniqueInWorktreeBuffers() {
            buffer.reopenLSPDocument(afterRegistering: language, forFileExtensions: normalized)
        }
        guard let lsp else { return }
        for (tabId, entry) in externalTabURLs {
            let ext = LanguageServerRegistry.extensionKey(forPath: entry.url.path)
            guard normalized.contains(ext), lsp.language(forFileExtension: ext) == language else { continue }
            guard var info = externalLSPInfo[tabId] else { continue }
            guard info.language == nil || info.language == language else { continue }
            let isRegisteringLanguage = info.language == nil
            info.language = language
            externalLSPInfo[tabId] = info
            if isRegisteringLanguage {
                openedExternalDocs.remove(tabId)
            }
            ensureExternalLSPOpen(tabId: tabId)
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
        let liveKeys = Set(bufferKeys.compactMap { tabId, key in tabBuffers[tabId] === buffer ? key : nil })

        for (tabId, liveBuffer) in tabBuffers where liveBuffer === buffer {
            guard let key = bufferKeys[tabId], !seen.contains(tabId) else { continue }
            result.append((tabId, key))
            seen.insert(tabId)
        }

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

    private func uniqueInWorktreeBuffers() -> [EditorBuffer] {
        var seen = Set<ObjectIdentifier>()
        return tabBuffers.values.filter { seen.insert(ObjectIdentifier($0)).inserted }
    }
}
