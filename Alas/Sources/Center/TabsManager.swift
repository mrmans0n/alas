import Foundation
import Observation

struct TabsFile: Codable {
    var version: Int = 1
    var tabs: [Tab]
    var activeTabId: TabID?
    /// Project-local selected tab IDs. The persisted key keeps its historical
    /// name so existing editor selections continue to restore.
    var activeEditorTabIds: [String: TabID] = [:]
    /// Legacy single draft slot for files written before project-scoped drafts.
    /// New project-owned drafts are stored in `stashedDraftsByProject`.
    var stashedDraft: DraftCommitTabState? = nil
    /// Project-owned drafts that were closed while another project shares the
    /// same path-derived worktree ID.
    var stashedDraftsByProject: [String: DraftCommitTabState] = [:]
}

extension TabsFile {
    // Custom decoder skips unknown/removed Tab cases instead of failing the
    // entire file when users upgrade from an older build that had more cases.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = (try? c.decode(Int.self, forKey: .version)) ?? 1
        activeTabId = try? c.decode(TabID.self, forKey: .activeTabId)
        activeEditorTabIds = (try? c.decode([String: TabID].self, forKey: .activeEditorTabIds)) ?? [:]
        stashedDraft = try? c.decode(DraftCommitTabState.self, forKey: .stashedDraft)
        stashedDraftsByProject = (try? c.decode([String: DraftCommitTabState].self, forKey: .stashedDraftsByProject)) ?? [:]
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
        var projectId: String? = nil
        var relativePath: String
    }

    private var byWorktree: [String: TabsFile] = [:]
    /// Runtime navigation state belongs to the worktree rather than an editor
    /// view, so a reference search survives tab switches and view recreation.
    private var navigationStores: [String: EditorNavigationStore] = [:]
    @ObservationIgnored private var workspaceUndoCoordinators: [String: WorkspaceEditUndoCoordinator] = [:]
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
    private var externalTabURLs: [TabID: (worktreeId: String, url: URL, hostResolution: EditorBufferHostResolution)] = [:]
    /// LSP parameters recorded when `externalBuffer` fires `openExternalDocument`
    /// so that `discardBuffer` can issue the matching `closeExternalDocument`.
    private struct ExternalLSPInfo: Equatable {
        var worktreeRoot: URL
        var originatingFileURL: URL?
        var language: String?
        var hostResolution: EditorBufferHostResolution
    }
    private var externalLSPInfo: [TabID: ExternalLSPInfo] = [:]
    /// Session-only split drafts survive view recreation when the user switches
    /// tabs, but are deliberately not persisted as part of the tab identity.
    private var ggSplitCommitDrafts: [TabID: GGSplitCommitDraft] = [:]
    @ObservationIgnored private var webPreviewBrowsers: [String: WebPreviewBrowser] = [:]
    private var commitPublishSessions: [TabID: CommitPublishSession] = [:]
    @ObservationIgnored var onCommitPublishCompletion: ((String, TabID) -> Void)?
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
    private let workspaceEditJournal: WorkspaceEditJournal

    init(
        bufferStore: EditorBufferStore = EditorBufferStore(),
        lsp: WorkspaceLSPManager? = nil,
        store: any PersistenceStoreProtocol = PersistenceStore(),
        tabsDirectory: URL = Paths.tabsDir,
        workspaceEditJournal: WorkspaceEditJournal = WorkspaceEditJournal()
    ) {
        self.bufferStore = bufferStore
        self.lsp = lsp
        self.store = store
        self.tabsDirectory = tabsDirectory
        self.workspaceEditJournal = workspaceEditJournal
    }

    func tabs(forWorktree id: String) -> [Tab] {
        byWorktree[id]?.tabs ?? []
    }

    func tabs(
        forWorktree id: String,
        projectId: String,
        includesLegacyUnownedProjectTabs: Bool = false
    ) -> [Tab] {
        (byWorktree[id]?.tabs ?? []).filter { tab in
            guard let belongsToProject = projectLocalTabBelongs(
                tab,
                projectId: projectId,
                includesLegacyUnownedProjectTabs: includesLegacyUnownedProjectTabs
            ) else { return true }
            return belongsToProject
        }
    }

    private func projectLocalTabBelongs(
        _ tab: Tab,
        projectId: String,
        includesLegacyUnownedProjectTabs: Bool
    ) -> Bool? {
        return switch tab {
        case .editor(let editor):
            editor.projectId == projectId || (includesLegacyUnownedProjectTabs && editor.projectId == nil)
        case .draftCommit(let draft):
            draft.projectId == projectId || (includesLegacyUnownedProjectTabs && draft.projectId == nil)
        case .terminal(let terminal):
            terminal.projectId == projectId || (includesLegacyUnownedProjectTabs && terminal.projectId == nil)
        case .acpSession(let session):
            session.projectId == projectId || (includesLegacyUnownedProjectTabs && session.projectId == nil)
        case .webPreview(let preview):
            preview.projectId == projectId || (includesLegacyUnownedProjectTabs && preview.projectId == nil)
        case .runReport(let report):
            report.projectId == projectId || (includesLegacyUnownedProjectTabs && report.projectId == nil)
        case .imagePreview(let preview):
            preview.projectId == projectId || (includesLegacyUnownedProjectTabs && preview.projectId == nil)
        case .ggInbox(let inbox):
            inbox.projectId == projectId
        case .ggLanding(let landing):
            landing.projectId == projectId
        case .commit(let commit):
            commit.projectId == projectId || (includesLegacyUnownedProjectTabs && commit.projectId == nil)
        case .commitEditor(let editor):
            editor.projectId == projectId || (includesLegacyUnownedProjectTabs && editor.projectId == nil)
        case .draftReviewRequest(let draft):
            draft.projectId == projectId || (includesLegacyUnownedProjectTabs && draft.projectId == nil)
        case .mergeConflict(let conflict):
            conflict.projectId == projectId || (includesLegacyUnownedProjectTabs && conflict.projectId == nil)
        case .fileSnapshot(let snapshot):
            snapshot.projectId == projectId || (includesLegacyUnownedProjectTabs && snapshot.projectId == nil)
        case .fileHistory(let history):
            history.projectId == projectId || (includesLegacyUnownedProjectTabs && history.projectId == nil)
        case .diff(let diff):
            diff.projectId == projectId || (includesLegacyUnownedProjectTabs && diff.projectId == nil)
        case .stashDiff(let diff):
            diff.projectId == projectId || (includesLegacyUnownedProjectTabs && diff.projectId == nil)
        case .checkpointDiff(let diff):
            diff.projectId == projectId || (includesLegacyUnownedProjectTabs && diff.projectId == nil)
        case .reviewPR(let review):
            review.projectId == projectId || (includesLegacyUnownedProjectTabs && review.projectId == nil)
        case .ggSplitCommit(let split):
            split.projectId == projectId || (includesLegacyUnownedProjectTabs && split.projectId == nil)
        case .reviewChanges(let review):
            review.projectId == projectId || (includesLegacyUnownedProjectTabs && review.projectId == nil)
        case .reviewSession(let review):
            review.projectId == projectId || (includesLegacyUnownedProjectTabs && review.projectId == nil)
        default:
            nil
        }
    }

    func navigationStore(forWorktreeId worktreeId: String) -> EditorNavigationStore {
        if let store = navigationStores[worktreeId] { return store }
        let store = EditorNavigationStore(openBuffer: { [weak self] document in self?.workspaceEditBuffer(for: document) })
        navigationStores[worktreeId] = store
        return store
    }

    func workspaceEditUndoCoordinator(forWorktreeId worktreeId: String, worktreeRoot: URL) -> WorkspaceEditUndoCoordinator {
        if let coordinator = workspaceUndoCoordinators[worktreeId] { return coordinator }
        let access = TabsWorkspaceEditUndoAccess(tabs: self, worktreeID: worktreeId, root: worktreeRoot)
        let coordinator = WorkspaceEditUndoCoordinator(access: access, journal: workspaceEditJournal) { [weak self] document in
            self?.workspaceEditBuffer(for: document)
        }
        workspaceUndoCoordinators[worktreeId] = coordinator
        return coordinator
    }

    func disposeWorkspaceEditHistory(worktreeId: String) {
        workspaceUndoCoordinators[worktreeId]?.disposeHistory()
        if workspaceUndoCoordinators[worktreeId]?.retainedJournalIDs.isEmpty == true { workspaceUndoCoordinators.removeValue(forKey: worktreeId) }
        navigationStores.removeValue(forKey: worktreeId)?.close()
    }

    /// Opens an LSP target using the worktree's explicit host context. In
    /// particular, a remote absolute path is only ever handed to the remote
    /// editor-buffer route, never to local `FileManager` APIs.
    @discardableResult
    func openNavigationTarget(
        _ target: EditorNavigationTarget,
        projectId: String? = nil,
        adoptUnownedEditor: Bool = false,
        worktreeRoot: URL,
        originatingRelativePath: String?,
        language: String?,
        hostResolution: EditorBufferHostResolution = .pathRegistry
    ) -> Bool {
        guard target.document.host == hostResolution.remoteHost(forPath: worktreeRoot.path),
              let url = URL(string: target.document.uri)
        else { return false }
        let normalizedURL = url.standardizedFileURL
        let normalizedRoot = worktreeRoot.standardizedFileURL
        let rootComponents = normalizedRoot.pathComponents
        let targetComponents = normalizedURL.pathComponents
        var isContained = targetComponents.count > rootComponents.count
            && targetComponents.starts(with: rootComponents)
        var navigationResolvedRoot: URL?
        if isContained, target.document.host == nil {
            let resolvedRoot = normalizedRoot.resolvingSymlinksInPath().standardizedFileURL
            navigationResolvedRoot = resolvedRoot
            let resolvedRootComponents = resolvedRoot.pathComponents
            let resolvedTargetComponents = normalizedURL.resolvingSymlinksInPath().pathComponents
            // A directory symlink can escape the worktree despite a contained
            // logical path. Missing targets cannot establish resolved identity.
            isContained = FileManager.default.fileExists(atPath: normalizedURL.path)
                && resolvedTargetComponents.count > resolvedRootComponents.count
                && resolvedTargetComponents.starts(with: resolvedRootComponents)
        }
        if isContained {
            _ = openEditor(
                worktreeId: target.document.worktreeID,
                projectId: projectId,
                adoptUnownedEditor: adoptUnownedEditor,
                relativePath: targetComponents.dropFirst(rootComponents.count).joined(separator: "/"),
                revealLine: target.position.line,
                revealCharacter: target.position.character,
                navigationResolvedRoot: navigationResolvedRoot
            )
        } else {
            _ = openExternalEditor(
                worktreeId: target.document.worktreeID,
                projectId: projectId,
                adoptUnownedEditor: adoptUnownedEditor,
                absoluteURL: normalizedURL,
                revealLine: target.position.line,
                revealCharacter: target.position.character,
                originatingRelativePath: originatingRelativePath,
                originatingWorktreeRoot: worktreeRoot,
                language: language,
                hostResolution: hostResolution
            )
        }
        return true
    }

    /// Owner-aware session tab lookup. The worktree overload intentionally
    /// keeps its legacy raw key and storage filename.
    func tabs(for owner: SessionOwnerID) -> [Tab] {
        byWorktree[owner.tabStorageKey]?.tabs ?? []
    }

    func commitEditorTab(
        worktreeId: String,
        currentSha: String,
        projectId: String? = nil,
        includesLegacyUnownedProjectTabs: Bool = false
    ) -> Tab? {
        let candidateTabs = projectId.map {
            tabs(
                forWorktree: worktreeId,
                projectId: $0,
                includesLegacyUnownedProjectTabs: includesLegacyUnownedProjectTabs
            )
        } ?? tabs(forWorktree: worktreeId)
        return candidateTabs.first { tab in
            if case .commitEditor(let state) = tab {
                return state.currentSha == currentSha
            }
            return false
        }
    }

    func activeTabId(forWorktree id: String) -> TabID? {
        byWorktree[id]?.activeTabId
    }

    func activeTabId(
        forWorktree id: String,
        projectId: String,
        includesLegacyUnownedProjectTabs: Bool = false
    ) -> TabID? {
        guard let file = byWorktree[id] else { return nil }
        if let activeTabId = file.activeTabId,
           let activeTab = file.tabs.first(where: { $0.id == activeTabId }) {
            if projectLocalTabBelongs(
                activeTab,
                projectId: projectId,
                includesLegacyUnownedProjectTabs: includesLegacyUnownedProjectTabs
            ) != false {
                return activeTabId
            }
        }
        if let remembered = file.activeEditorTabIds[projectId],
           let rememberedTab = file.tabs.first(where: { $0.id == remembered }),
           projectLocalTabBelongs(
               rememberedTab,
               projectId: projectId,
               includesLegacyUnownedProjectTabs: includesLegacyUnownedProjectTabs
           ) == true {
            return remembered
        }
        if let mostRecentProjectTab = file.tabs.reversed().first(where: { tab in
            projectLocalTabBelongs(
                tab,
                projectId: projectId,
                includesLegacyUnownedProjectTabs: includesLegacyUnownedProjectTabs
            ) == true
        }) {
            return mostRecentProjectTab.id
        }
        return nil
    }

    func activeTabId(for owner: SessionOwnerID) -> TabID? {
        byWorktree[owner.tabStorageKey]?.activeTabId
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

    func moveTab(owner: SessionOwnerID, fromId: TabID, toId: TabID) {
        moveTab(worktreeId: owner.tabStorageKey, fromId: fromId, toId: toId)
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

    func loadAll(worktreeIds: [String], restoringActiveTabs: Bool = true) {
        for id in worktreeIds {
            if var file = try? store.readIfExists(TabsFile.self, from: tabsFile(forWorktreeId: id)) {
                if !restoringActiveTabs {
                    file.activeTabId = nil
                }
                byWorktree[id] = file
                if !restoringActiveTabs {
                    persist(id)
                }
            }
        }
        hasLoaded = true
    }

    func load(owner: SessionOwnerID, restoringActiveTabs: Bool = true) {
        let key = owner.tabStorageKey
        if var file = try? store.readIfExists(TabsFile.self, from: tabsFile(forOwner: owner)) {
            if !restoringActiveTabs {
                file.activeTabId = nil
            }
            byWorktree[key] = file
            if !restoringActiveTabs {
                persist(key)
            }
        }
        hasLoaded = true
    }

    /// Loads every persisted tab file, including files whose worktree is not
    /// currently discoverable. `TabsFile` skips unsupported tab cases.
    func loadAllPersisted(restoringActiveTabs: Bool = true) {
        guard let relativeFiles = try? FileManager.default.subpathsOfDirectory(
            atPath: tabsDirectory.path
        ) else {
            loadAll(worktreeIds: [], restoringActiveTabs: restoringActiveTabs)
            return
        }
        let worktreeIDs = relativeFiles.compactMap { relativeFile -> String? in
            guard relativeFile.hasSuffix(".json") else { return nil }
            let file = tabsDirectory.appendingPathComponent(relativeFile)
            guard (try? file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
            else { return nil }
            let relativePath = String(relativeFile.dropLast(".json".count))
            guard !relativePath.isEmpty else { return nil }
            return relativePath.contains("/") ? "/\(relativePath)" : relativePath
        }
        loadAll(worktreeIds: worktreeIDs, restoringActiveTabs: restoringActiveTabs)
    }

    @discardableResult
    func appendTerminal(
        worktreeId: String,
        projectId: String? = nil,
        title: String,
        sessionId: String,
        runScriptKey: String? = nil
    ) -> Tab {
        let state = TerminalTabState(
            id: UUID().uuidString,
            title: title,
            sessionId: sessionId,
            projectId: projectId,
            runScriptKey: runScriptKey
        )
        let tab = Tab.terminal(state)
        append(tab, to: worktreeId)
        return tab
    }

    @discardableResult
    func appendTerminal(owner: SessionOwnerID, title: String, sessionId: String, runScriptKey: String? = nil) -> Tab {
        let leaf = PaneLeaf(
            id: sessionId,
            sessionId: sessionId,
            lastCwd: nil,
            lastCwdLocation: owner.checkoutExecutionLocation
        )
        let state = TerminalTabState(
            id: UUID().uuidString,
            title: title,
            root: .leaf(leaf),
            focusedLeafId: leaf.id,
            projectId: owner.projectID,
            runScriptKey: runScriptKey,
            runScriptLeafId: runScriptKey != nil ? leaf.id : nil
        )
        let tab = Tab.terminal(state)
        append(tab, to: owner.tabStorageKey)
        return tab
    }

    @discardableResult
    func appendACP(owner: SessionOwnerID, sessionId: ACPSession.ID, title: String) -> Tab {
        let tab = Tab.acpSession(.init(sessionId: sessionId, title: title))
        append(tab, to: owner.tabStorageKey)
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
    func renameTerminal(owner: SessionOwnerID, tabId: TabID, title: String) -> Tab? {
        renameTerminal(worktreeId: owner.tabStorageKey, tabId: tabId, title: title)
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
    func renameACPSession(owner: SessionOwnerID, tabId: TabID, title: String) -> Tab? {
        renameACPSession(worktreeId: owner.tabStorageKey, tabId: tabId, title: title)
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

    @discardableResult
    func setFocusedLeaf(owner: SessionOwnerID, tabId: TabID, leafId: String) -> Tab? {
        setFocusedLeaf(worktreeId: owner.tabStorageKey, tabId: tabId, leafId: leafId)
    }

    /// Split the focused leaf into a 2-child split. The freshly-spawned session id
    /// is wrapped in a new leaf, which becomes the focused one.
    @discardableResult
    func splitFocusedLeaf(
        worktreeId: String, tabId: TabID, axis: SplitAxis,
        newLeafId: String, newSessionId: String,
        newLeafCwdLocation: ExecutionLocation? = nil
    ) -> Tab? {
        guard var file = byWorktree[worktreeId],
              let idx = file.tabs.firstIndex(where: { $0.id == tabId }),
              case .terminal(var state) = file.tabs[idx],
              let existing = state.root.find(leafId: state.focusedLeafId)?.leaf else { return nil }
        let newLeaf = PaneLeaf(id: newLeafId, sessionId: newSessionId, lastCwd: nil, lastCwdLocation: newLeafCwdLocation)
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

    @discardableResult
    func splitFocusedLeaf(
        owner: SessionOwnerID, tabId: TabID, axis: SplitAxis,
        newLeafId: String, newSessionId: String,
        newLeafCwdLocation: ExecutionLocation? = nil
    ) -> Tab? {
        splitFocusedLeaf(worktreeId: owner.tabStorageKey, tabId: tabId, axis: axis, newLeafId: newLeafId, newSessionId: newSessionId, newLeafCwdLocation: newLeafCwdLocation)
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

    func removeLeaf(owner: SessionOwnerID, tabId: TabID, leafId: String) -> RemoveLeafOutcome? {
        removeLeaf(worktreeId: owner.tabStorageKey, tabId: tabId, leafId: leafId)
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
    func setSplitFraction(owner: SessionOwnerID, tabId: TabID, splitId: String, fraction: Double) -> Tab? {
        setSplitFraction(worktreeId: owner.tabStorageKey, tabId: tabId, splitId: splitId, fraction: fraction)
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

    @discardableResult
    func setLeafCwd(owner: SessionOwnerID, tabId: TabID, leafId: String, cwd: String) -> Tab? {
        setLeafCwd(worktreeId: owner.tabStorageKey, tabId: tabId, leafId: leafId, cwd: cwd)
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
    func appendEditor(worktreeId: String, projectId: String? = nil, title: String, relativePath: String) -> Tab {
        let state = EditorTabState(id: UUID().uuidString, title: title, relativePath: relativePath, projectId: projectId)
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
        projectId: String? = nil,
        adoptUnownedEditor: Bool = false,
        relativePath: String,
        revealLine: Int?,
        revealCharacter: Int?,
        revealEndLine: Int? = nil,
        navigationResolvedRoot: URL? = nil
    ) -> Tab {
        let shouldRevealInMarkdownEditor = (revealLine != nil || revealCharacter != nil)
            && MarkdownFileType.supportsRichPreview(relativePath: relativePath)
        if var file = byWorktree[worktreeId],
           let idx = file.tabs.firstIndex(where: {
               if case .editor(let s) = $0 {
                   return s.relativePath == relativePath
                       && (s.projectId == projectId || (adoptUnownedEditor && s.projectId == nil))
               }
               return false
           }) {
            if case .editor(var s) = file.tabs[idx] {
                s.projectId = projectId
                s.navigationResolvedRoot = s.navigationResolvedRoot ?? navigationResolvedRoot
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
                if let projectId { file.activeEditorTabIds[projectId] = s.id }
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
            projectId: projectId,
            revealLine: revealLine,
            revealEndLine: revealEndLine,
            revealCharacter: revealCharacter,
            navigationResolvedRoot: navigationResolvedRoot
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
        projectId: String? = nil,
        adoptUnownedEditor: Bool = false,
        absoluteURL: URL,
        revealLine: Int?,
        revealCharacter: Int?,
        revealEndLine: Int? = nil,
        originatingRelativePath: String? = nil,
        originatingWorktreeRoot: URL? = nil,
        language: String? = nil,
        hostResolution: EditorBufferHostResolution = .pathRegistry,
        editable: Bool = false
    ) -> Tab {
        let absPath = absoluteURL.path
        let shouldRevealInMarkdownEditor = (revealLine != nil || revealCharacter != nil)
            && MarkdownFileType.supportsRichPreview(relativePath: absPath)
        if var file = byWorktree[worktreeId],
           let idx = file.tabs.firstIndex(where: {
               if case .editor(let s) = $0 {
                   return s.externalAbsolutePath == absPath
                       && (s.projectId == projectId || (adoptUnownedEditor && s.projectId == nil))
               }
               return false
           }) {
            if case .editor(var s) = file.tabs[idx] {
                s.projectId = projectId
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
                if let projectId { file.activeEditorTabIds[projectId] = s.id }
                byWorktree[worktreeId] = file
                persist(worktreeId)
                if (originChanged || externalLSPInfo[s.id]?.hostResolution != hostResolution),
                   let originatingWorktreeRoot {
                    let originatingFileURL = originatingRelativePath.flatMap {
                        originatingWorktreeRoot.appendingPathComponent($0)
                    }
                    if let language {
                        rebindExternalLSPHolder(
                            tabId: s.id,
                            absoluteURL: absoluteURL,
                            worktreeRoot: originatingWorktreeRoot,
                            originatingFileURL: originatingFileURL,
                            language: language,
                            hostResolution: hostResolution
                        )
                    } else if externalLSPInfo[s.id]?.language == nil {
                        externalLSPInfo[s.id] = ExternalLSPInfo(
                            worktreeRoot: originatingWorktreeRoot,
                            originatingFileURL: originatingFileURL,
                            language: nil,
                            hostResolution: hostResolution
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
            projectId: projectId,
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
        language: String,
        hostResolution: EditorBufferHostResolution
    ) {
        let oldInfo = externalLSPInfo[tabId]
        let newInfo = ExternalLSPInfo(
            worktreeRoot: worktreeRoot,
            originatingFileURL: originatingFileURL,
            language: language,
            hostResolution: hostResolution
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
                    language: oldLanguage,
                    hostResolution: old.hostResolution
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
    func append(acpSession state: ACPSessionTabState, to owner: SessionOwnerID) -> Tab {
        let tab = Tab.acpSession(state)
        append(tab, to: owner.tabStorageKey)
        return tab
    }

    @discardableResult
    func appendDiff(
        worktreeId: String,
        projectId: String? = nil,
        title: String,
        relativePath: String,
        staged: Bool = false,
        originalPath: String? = nil,
        compareWithHEAD: Bool = false
    ) -> Tab {
        let rawID = UUID().uuidString
        let state = DiffTabState(
            id: projectId.map { "diff-project:\($0):\(rawID)" } ?? rawID,
            title: title,
            relativePath: relativePath,
            staged: staged,
            originalPath: originalPath,
            compareWithHEAD: compareWithHEAD,
            projectId: projectId
        )
        let tab = Tab.diff(state)
        append(tab, to: worktreeId)
        return tab
    }

    @discardableResult
    func appendStashDiff(worktreeId: String, projectId: String? = nil, stash: GitStash, file: GitStashFile) -> Tab {
        let state = StashDiffTabState(worktreeId: worktreeId, projectId: projectId, stash: stash, file: file)
        let tab = Tab.stashDiff(state)
        append(tab, to: worktreeId)
        return tab
    }

    @discardableResult
    func appendCheckpointDiff(
        worktreeID: String,
        projectId: String? = nil,
        checkpointID: CheckpointID,
        groupID: UUID,
        primaryPath: String,
        memberPaths: [String]? = nil,
        checkpointLabel: String
    ) -> Tab {
        let state = CheckpointDiffTabState(
            worktreeID: worktreeID,
            projectId: projectId,
            checkpointID: checkpointID,
            groupID: groupID,
            primaryPath: primaryPath,
            memberPaths: memberPaths,
            checkpointLabel: checkpointLabel
        )
        let tab = Tab.checkpointDiff(state)
        append(tab, to: worktreeID)
        return tab
    }

    @discardableResult
    func appendCommit(worktreeId: String, projectId: String? = nil, sha: String, title: String) -> Tab {
        let state = CommitTabState(worktreeId: worktreeId, projectId: projectId, sha: sha, title: title)
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
        projectId: String? = nil,
        baseRef: String,
        originalSha: String,
        currentSha: String,
        title: String
    ) -> Tab {
        let state = CommitEditorTabState(
            worktreeId: worktreeId,
            projectId: projectId,
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

    func stashedDraft(
        worktreeId: String,
        projectId: String,
        includesLegacyUnownedDraftCommit: Bool = false
    ) -> DraftCommitTabState? {
        guard let file = byWorktree[worktreeId] else { return nil }
        if let draft = file.stashedDraftsByProject[projectId] { return draft }
        guard let legacy = file.stashedDraft,
              legacy.projectId == projectId || (includesLegacyUnownedDraftCommit && legacy.projectId == nil)
        else { return nil }
        return legacy
    }

    @discardableResult
    func openOrFocusReviewChanges(
        worktreeId: String,
        projectId: String? = nil,
        includesLegacyUnownedProjectTabs: Bool = false
    ) -> Tab {
        if var file = byWorktree[worktreeId],
           let idx = file.tabs.firstIndex(where: {
               if case .reviewChanges(let state) = $0 {
                   return state.worktreeId == worktreeId
                       && (state.projectId == projectId
                           || (includesLegacyUnownedProjectTabs && state.projectId == nil))
               }
               return false
           }) {
            if case .reviewChanges(var state) = file.tabs[idx],
               state.projectId == nil, includesLegacyUnownedProjectTabs {
                state.projectId = projectId
                file.tabs[idx] = .reviewChanges(state)
            }
            let tab = file.tabs[idx]
            file.activeTabId = tab.id
            rememberProjectLocalTab(tab, in: &file)
            byWorktree[worktreeId] = file
            persist(worktreeId)
            return tab
        }

        let tab = Tab.reviewChanges(ReviewChangesTabState(worktreeId: worktreeId, projectId: projectId))
        append(tab, to: worktreeId)
        return tab
    }

    @discardableResult
    func webPreviewBrowser(
        ownerKey: String,
        remoteHost: String?,
        projectId: String? = nil,
        sessionOwnerKey: String? = nil
    ) -> WebPreviewBrowser {
        let browserCacheKey = WebPreviewTabState.browserCacheKey(ownerKey: ownerKey, projectId: projectId)
        let resolvedSessionOwnerKey = sessionOwnerKey ?? ownerKey
        if let browser = webPreviewBrowsers[browserCacheKey],
           browser.remoteHost == remoteHost,
           browser.sessionOwnerKey == resolvedSessionOwnerKey {
            return browser
        }
        clearWebPreviewBrowser(ownerKey: ownerKey, projectId: projectId)
        let browser = WebPreviewBrowser(
            ownerKey: ownerKey,
            sessionOwnerKey: resolvedSessionOwnerKey,
            remoteHost: remoteHost
        )
        browser.onNavigate = { [weak self] url in
            self?.updateWebPreviewURL(worktreeId: ownerKey, projectId: projectId, url: url)
        }
        webPreviewBrowsers[browserCacheKey] = browser
        return browser
    }

    @discardableResult
    func openWebPreview(worktreeId: String, url: URL? = nil) -> Tab {
        let existing = tabs(forWorktree: worktreeId).first { tab in
            guard case .webPreview(let state) = tab else { return false }
            return state.ownerKey == worktreeId
        }
        let remoteHost: String?
        let projectId: String?
        if case .webPreview(let state) = existing {
            remoteHost = state.remoteHost
            projectId = state.projectId
        } else {
            remoteHost = nil
            projectId = nil
        }
        return openWebPreview(worktreeId: worktreeId, url: url, remoteHost: remoteHost, projectId: projectId)
    }

    @discardableResult
    func openWebPreview(worktreeId: String, url: URL? = nil, remoteHost: String?, projectId: String? = nil) -> Tab {
        let ownerKey = worktreeId
        if var file = byWorktree[ownerKey],
           let idx = file.tabs.firstIndex(where: {
               if case .webPreview(let state) = $0 {
                   return state.ownerKey == ownerKey && state.projectId == projectId
               }
               return false
           }) {
            if case .webPreview(var state) = file.tabs[idx] {
                if let url {
                    state.url = url
                }
                if state.remoteHost != remoteHost {
                    clearWebPreviewBrowser(ownerKey: ownerKey, projectId: state.projectId)
                }
                state.remoteHost = remoteHost
                if let projectId { state.projectId = projectId }
                let tab = Tab.webPreview(state)
                file.tabs[idx] = tab
                file.activeTabId = tab.id
                byWorktree[ownerKey] = file
                persist(ownerKey)
                return tab
            }
        }
        let tab = Tab.webPreview(WebPreviewTabState(ownerKey: ownerKey, url: url, remoteHost: remoteHost, projectId: projectId))
        append(tab, to: ownerKey)
        return tab
    }

    @discardableResult
    func openWebPreview(owner: SessionOwnerID, url: URL? = nil, remoteHost: String? = nil) -> Tab {
        openWebPreview(
            worktreeId: owner.tabStorageKey, url: url,
            remoteHost: remoteHost ?? Self.remoteHost(for: owner), projectId: owner.projectID
        )
    }

    @discardableResult
    func updateWebPreviewURL(worktreeId: String, projectId: String? = nil, url: URL) -> Tab? {
        let ownerKey = worktreeId
        guard var file = byWorktree[ownerKey],
              let idx = file.tabs.firstIndex(where: {
                  if case .webPreview(let state) = $0 {
                      return state.ownerKey == ownerKey && state.projectId == projectId
                  }
                  return false
              }),
              case .webPreview(var state) = file.tabs[idx]
        else { return nil }
        let activeTabId = file.activeTabId
        state.url = url
        let tab = Tab.webPreview(state)
        file.tabs[idx] = tab
        file.activeTabId = activeTabId
        byWorktree[ownerKey] = file
        persist(ownerKey)
        return tab
    }

    @discardableResult
    func updateWebPreviewURL(owner: SessionOwnerID, url: URL) -> Tab? {
        updateWebPreviewURL(worktreeId: owner.tabStorageKey, projectId: owner.projectID, url: url)
    }

    private static func remoteHost(for owner: SessionOwnerID) -> String? {
        owner.checkoutExecutionLocation?.sshHost
    }

    @discardableResult
    func openOrFocusFileSnapshot(
        worktreeId: String,
        projectId: String? = nil,
        includesLegacyUnownedProjectTabs: Bool = false,
        relativePath: String,
        ref: String = "HEAD"
    ) -> Tab {
        let state = FileSnapshotTabState(worktreeId: worktreeId, projectId: projectId, relativePath: relativePath, ref: ref)
        if var file = byWorktree[worktreeId],
           let idx = file.tabs.firstIndex(where: { tab in
               guard case .fileSnapshot(let existing) = tab,
                     existing.relativePath == relativePath,
                     existing.ref == ref else { return false }
               guard let projectId else { return true }
               return existing.projectId == projectId
                   || (includesLegacyUnownedProjectTabs && existing.projectId == nil)
           }),
           case .fileSnapshot(var existing) = file.tabs[idx] {
            if existing.projectId == nil, includesLegacyUnownedProjectTabs {
                existing.projectId = projectId
                file.tabs[idx] = .fileSnapshot(existing)
            }
            let tab = file.tabs[idx]
            file.activeTabId = tab.id
            rememberProjectLocalTab(tab, in: &file)
            byWorktree[worktreeId] = file
            persist(worktreeId)
            return tab
        }
        let tab = Tab.fileSnapshot(state)
        append(tab, to: worktreeId)
        return tab
    }

    @discardableResult
    func openOrFocusFileHistory(
        worktreeId: String,
        projectId: String? = nil,
        includesLegacyUnownedProjectTabs: Bool = false,
        relativePath: String
    ) -> Tab {
        let state = FileHistoryTabState(worktreeId: worktreeId, projectId: projectId, relativePath: relativePath)
        if var file = byWorktree[worktreeId],
           let idx = file.tabs.firstIndex(where: { tab in
               guard case .fileHistory(let existing) = tab,
                     existing.relativePath == relativePath else { return false }
               guard let projectId else { return true }
               return existing.projectId == projectId
                   || (includesLegacyUnownedProjectTabs && existing.projectId == nil)
           }),
           case .fileHistory(var existing) = file.tabs[idx] {
            if existing.projectId == nil, includesLegacyUnownedProjectTabs {
                existing.projectId = projectId
                file.tabs[idx] = .fileHistory(existing)
            }
            let tab = file.tabs[idx]
            file.activeTabId = tab.id
            rememberProjectLocalTab(tab, in: &file)
            byWorktree[worktreeId] = file
            persist(worktreeId)
            return tab
        }
        let tab = Tab.fileHistory(state)
        append(tab, to: worktreeId)
        return tab
    }

    @discardableResult
    func openOrFocusRunReport(worktreeId: String, projectId: String? = nil, runID: String, isTransient: Bool = false) -> Tab {
        let state = RunReportTabState(worktreeId: worktreeId, projectId: projectId, runID: runID, isTransient: isTransient)
        if tabs(forWorktree: worktreeId).contains(where: { $0.id == state.id }) {
            activate(worktreeId: worktreeId, tabId: state.id)
            return tabs(forWorktree: worktreeId).first(where: { $0.id == state.id }) ?? .runReport(state)
        }
        let tab = Tab.runReport(state)
        append(tab, to: worktreeId)
        return tab
    }

    func closeRunReports(worktreeId: String, projectId: String? = nil) {
        let reportIDs = tabs(forWorktree: worktreeId).compactMap { tab -> TabID? in
            guard case .runReport(let report) = tab,
                  projectId == nil || report.projectId == projectId else { return nil }
            return tab.id
        }
        for tabID in reportIDs {
            close(worktreeId: worktreeId, tabId: tabID)
        }
    }

    @discardableResult
    func openOrFocusGGLanding(worktreeId: String, projectId: String, stackName: String) -> Tab {
        let state = GGLandingTabState(projectId: projectId, stackName: stackName)
        for otherWorktreeId in Array(byWorktree.keys) where otherWorktreeId != worktreeId {
            if tabs(forWorktree: otherWorktreeId).contains(where: { $0.id == state.id }) {
                close(worktreeId: otherWorktreeId, tabId: state.id)
            }
        }
        let tab = Tab.ggLanding(state)
        if let index = byWorktree[worktreeId]?.tabs.firstIndex(where: { $0.id == state.id }) {
            byWorktree[worktreeId]?.tabs[index] = tab
            activate(worktreeId: worktreeId, tabId: state.id)
            return tab
        }
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
        projectId: String? = nil,
        includesLegacyUnownedProjectTabs: Bool = false,
        targetGGID: String?,
        targetSHA: String
    ) -> TabID {
        let state = GGSplitCommitTabState(
            worktreeId: worktreeId,
            projectId: projectId,
            targetGGID: targetGGID,
            targetSHA: targetSHA
        )
        let targetIdentity = targetGGID ?? targetSHA
        if var file = byWorktree[worktreeId],
           let index = file.tabs.firstIndex(where: { tab in
               guard case .ggSplitCommit(let existing) = tab,
                     existing.projectId == projectId
                         || (includesLegacyUnownedProjectTabs && existing.projectId == nil)
               else { return false }
               return (existing.targetGGID ?? existing.targetSHA) == targetIdentity
        }),
           case .ggSplitCommit(var existing) = file.tabs[index] {
            if existing.projectId == nil, let projectId {
                existing.projectId = projectId
                file.tabs[index] = .ggSplitCommit(existing)
            }
            let tab = Tab.ggSplitCommit(existing)
            rememberProjectLocalTab(tab, in: &file)
            file.activeTabId = existing.id
            byWorktree[worktreeId] = file
            persist(worktreeId)
            return existing.id
        }
        append(.ggSplitCommit(state), to: worktreeId)
        return state.id
    }

    @discardableResult
    func openOrFocusReviewSession(
        worktreeId: String,
        projectId: String? = nil,
        includesLegacyUnownedProjectTabs: Bool = false,
        record: ReviewSessionRecord
    ) -> Tab {
        let baseState = ReviewSessionTabState(worktreeId: worktreeId, projectId: projectId, record: record)
        if var file = byWorktree[worktreeId],
           let idx = file.tabs.firstIndex(where: { tab in
               guard case .reviewSession(let state) = tab,
                     state.sessionID == record.id else { return false }
               return state.projectId == projectId
                   || (includesLegacyUnownedProjectTabs && state.projectId == nil)
           }),
           case .reviewSession(var existing) = file.tabs[idx] {
            if existing.projectId == nil, includesLegacyUnownedProjectTabs {
                existing.projectId = projectId
            }
            existing.title = record.target.title
            existing.selectedFileID = record.selectedFileID
            existing.focusedCommentID = record.focusedCommentID
            existing.requestCommentScroll()
            let tab = Tab.reviewSession(existing)
            file.tabs[idx] = tab
            file.activeTabId = tab.id
            rememberProjectLocalTab(tab, in: &file)
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
    func openOrFocusReviewPR(
        worktreeId: String,
        projectId: String? = nil,
        includesLegacyUnownedProjectTabs: Bool = false,
        snapshot: ReviewLoopSnapshot
    ) -> Tab {
        let baseState = ReviewPRTabState(worktreeId: worktreeId, projectId: projectId, snapshot: snapshot)
        if var file = byWorktree[worktreeId],
           let idx = file.tabs.firstIndex(where: { tab in
               guard case .reviewPR(let state) = tab,
                     state.projectId == projectId
                         || (includesLegacyUnownedProjectTabs && state.projectId == nil)
               else { return false }
               return state.id == baseState.id || state.matches(snapshot)
           }),
           case .reviewPR(var existing) = file.tabs[idx] {
            if existing.projectId == nil, let projectId {
                existing.projectId = projectId
            }
            existing.refreshSnapshotMetadata(from: snapshot)
            let tab = Tab.reviewPR(existing)
            file.tabs[idx] = tab
            file.activeTabId = tab.id
            rememberProjectLocalTab(tab, in: &file)
            byWorktree[worktreeId] = file
            persist(worktreeId)
            return tab
        }
        let tab = Tab.reviewPR(baseState)
        append(tab, to: worktreeId)
        return tab
    }

    @discardableResult
    func openOrFocusDraftCommit(
        worktreeId: String,
        projectId: String? = nil,
        includesLegacyUnownedDraftCommit: Bool = false,
        resetAmend: Bool = false,
        preferredAction: DraftCommitPreferredAction? = nil
    ) -> Tab {
        let baseState = DraftCommitTabState(worktreeId: worktreeId, projectId: projectId)
        if var file = byWorktree[worktreeId],
           let idx = file.tabs.firstIndex(where: { tab in
               guard case .draftCommit(let state) = tab else { return false }
               if let projectId {
                   return state.projectId == projectId || (includesLegacyUnownedDraftCommit && state.projectId == nil)
               }
               return state.projectId == nil
           }),
           case .draftCommit(var existing) = file.tabs[idx] {
            let adoptedLegacyDraft = projectId != nil && existing.projectId == nil
                && includesLegacyUnownedDraftCommit
            if adoptedLegacyDraft { existing.projectId = projectId }
            if resetAmend {
                existing.prepareForNewCommit()
            }
            if let preferredAction {
                existing.preferredAction = preferredAction
            }
            let tab = Tab.draftCommit(existing)
            file.tabs[idx] = tab
            file.activeTabId = tab.id
            rememberProjectLocalTab(tab, in: &file)
            if adoptedLegacyDraft, let projectId,
               let legacyStash = file.stashedDraft, legacyStash.projectId == nil {
                var adoptedStash = legacyStash
                adoptedStash.projectId = projectId
                setStashedDraft(adoptedStash, forProjectId: projectId, in: &file)
            }
            byWorktree[worktreeId] = file
            persist(worktreeId)
            return tab
        }
        // No live tab — restore only this project's stash. Old unowned data is
        // adopted by the original project owner and never exposed to siblings.
        var file = byWorktree[worktreeId] ?? TabsFile(tabs: [], activeTabId: nil)
        var stashed: DraftCommitTabState?
        var adoptedLegacyDraft = false
        if let projectId {
            stashed = file.stashedDraftsByProject[projectId]
            if stashed == nil, let legacy = file.stashedDraft,
               legacy.projectId == projectId || (includesLegacyUnownedDraftCommit && legacy.projectId == nil) {
                var adopted = legacy
                adoptedLegacyDraft = adopted.projectId == nil
                if adoptedLegacyDraft { adopted.projectId = projectId }
                stashed = adopted
                if adoptedLegacyDraft {
                    setStashedDraft(adopted, forProjectId: projectId, in: &file)
                }
            }
        } else if let legacy = file.stashedDraft, legacy.projectId == nil {
            stashed = legacy
        }
        var state = stashed ?? baseState
        if resetAmend {
            state.prepareForNewCommit()
        }
        if let preferredAction {
            state.preferredAction = preferredAction
        }
        if adoptedLegacyDraft || (stashed != nil && (resetAmend || preferredAction != nil)) {
            setStashedDraft(state, forProjectId: state.projectId, in: &file)
            byWorktree[worktreeId] = file
            persist(worktreeId)
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

    func commitPublishSession(tabId: TabID) -> CommitPublishSession? {
        commitPublishSessions[tabId]
    }

    func hasRunningCommitPublish(worktreeId: String) -> Bool {
        tabs(forWorktree: worktreeId).contains { tab in
            commitPublishSessions[tab.id]?.isRunning == true
        }
    }

    @discardableResult
    func runCommitPublish(
        worktreeId: String,
        tabId: TabID,
        subject: String,
        body: String,
        amend: Bool,
        operations: CommitPublishOperations,
        prepareDestination: @escaping () async throws -> CommitPublishDestination
    ) -> Task<Void, Never>? {
        guard case .draftCommit(let draft) = tabs(forWorktree: worktreeId).first(where: { $0.id == tabId }) else {
            return nil
        }
        let session: CommitPublishSession
        if let existing = commitPublishSessions[tabId] {
            session = existing
        } else {
            session = CommitPublishSession(checkpoint: draft.publishCheckpoint, onCheckpointChange: { [weak self] checkpoint in
                guard let self else { return }
                try persistCommitPublishCheckpoint(checkpoint, worktreeId: worktreeId, tabId: tabId)
            }, onCompletion: { [weak self] checkpoint in
                guard let self else { return }
                try completeCommitPublish(worktreeId: worktreeId, tabId: tabId, checkpoint: checkpoint)
                onCommitPublishCompletion?(worktreeId, tabId)
            })
            commitPublishSessions[tabId] = session
        }
        return session.run(subject: subject, body: body, amend: amend,
            operations: operations, prepareDestination: prepareDestination)
    }

    @discardableResult
    func abandonCommitPublishCheckpoint(worktreeId: String, tabId: TabID) -> Bool {
        guard commitPublishSessions[tabId]?.isRunning != true else { return false }
        do {
            try persistCommitPublishCheckpoint(nil, worktreeId: worktreeId, tabId: tabId)
            _ = commitPublishSessions[tabId]?.abandonCheckpoint()
            commitPublishSessions[tabId] = nil
            return true
        } catch {
            return false
        }
    }

    @discardableResult
    private func persistCommitPublishCheckpoint(_ checkpoint: CommitPublishCheckpoint?, worktreeId: String, tabId: TabID) throws -> Bool {
        guard var file = byWorktree[worktreeId] else { return false }
        if let idx = file.tabs.firstIndex(where: { $0.id == tabId }),
           case .draftCommit(var state) = file.tabs[idx] {
            state.publishCheckpoint = checkpoint
            file.tabs[idx] = .draftCommit(state)
            try persistThrowing(file, worktreeId: worktreeId)
            byWorktree[worktreeId] = file
            return true
        }
        if file.stashedDraft?.id == tabId {
            file.stashedDraft?.publishCheckpoint = checkpoint
        } else if let projectId = file.stashedDraftsByProject.first(where: { $0.value.id == tabId })?.key {
            file.stashedDraftsByProject[projectId]?.publishCheckpoint = checkpoint
        } else {
            return false
        }
        try persistThrowing(file, worktreeId: worktreeId)
        byWorktree[worktreeId] = file
        return true
    }

    @discardableResult
    func openOrFocusDraftReviewRequest(worktreeId: String, snapshot: ReviewLoopSnapshot) -> Tab {
        openOrFocusDraftReviewRequest(worktreeId: worktreeId, projectId: nil, snapshot: snapshot)
    }

    @discardableResult
    func openOrFocusDraftReviewRequest(
        worktreeId: String,
        projectId: String?,
        snapshot: ReviewLoopSnapshot
    ) -> Tab {
        let baseState = DraftReviewRequestTabState(worktreeId: worktreeId, projectId: projectId, snapshot: snapshot)
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
    func discardStashedDraft(
        worktreeId: String,
        projectId: String? = nil,
        includesLegacyUnownedDraftCommit: Bool = false
    ) {
        guard var file = byWorktree[worktreeId] else { return }
        let draft = projectId.flatMap { file.stashedDraftsByProject[$0] }
            ?? file.stashedDraft.flatMap { legacy in
                guard projectId == nil || legacy.projectId == projectId
                    || (includesLegacyUnownedDraftCommit && legacy.projectId == nil)
                else { return nil }
                return legacy
            }
        guard let draft else { return }
        if commitPublishSessions[draft.id]?.isRunning == false { commitPublishSessions[draft.id] = nil }
        if let projectId {
            if file.stashedDraft?.id == draft.id {
                file.stashedDraft = nil
            } else {
                file.stashedDraftsByProject[projectId] = nil
            }
        } else {
            file.stashedDraft = nil
        }
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
              let tab = replaceDraftWithCommitEditor(
                  in: &file,
                  worktreeId: worktreeId,
                  draftTabId: draftTabId,
                  baseRef: baseRef,
                  newSha: newSha,
                  title: title
              )
        else { return nil }
        do {
            try persistThrowing(file, worktreeId: worktreeId)
            byWorktree[worktreeId] = file
            return tab
        } catch {
            return nil
        }
    }

    @discardableResult
    private func completeCommitPublish(worktreeId: String, tabId: TabID, checkpoint: CommitPublishCheckpoint) throws -> Tab? {
        guard var file = byWorktree[worktreeId] else { return nil }
        if let tab = replaceDraftWithCommitEditor(
            in: &file,
            worktreeId: worktreeId,
            draftTabId: tabId,
            baseRef: checkpoint.baseRef,
            newSha: checkpoint.commitSHA,
            title: checkpoint.commitTitle
        ) {
            try persistThrowing(file, worktreeId: worktreeId)
            byWorktree[worktreeId] = file
            return tab
        }
        guard removeStashedDraft(tabId: tabId, from: &file) else { return nil }
        try persistThrowing(file, worktreeId: worktreeId)
        byWorktree[worktreeId] = file
        return nil
    }

    private func replaceDraftWithCommitEditor(
        in file: inout TabsFile,
        worktreeId: String,
        draftTabId: TabID,
        baseRef: String,
        newSha: String,
        title: String
    ) -> Tab? {
        guard let idx = file.tabs.firstIndex(where: { $0.id == draftTabId }),
              case .draftCommit(let draftState) = file.tabs[idx]
        else { return nil }
        let projectId = draftState.projectId
        for existingIdx in file.tabs.indices {
            guard case .commitEditor(var existing) = file.tabs[existingIdx],
                  existing.projectId == projectId,
                  existing.currentSha == newSha else { continue }
            existing.title = title
            let tab = Tab.commitEditor(existing)
            file.tabs[existingIdx] = tab
            file.tabs.remove(at: idx)
            file.activeTabId = tab.id
            removeStashedDraft(tabId: draftTabId, from: &file)
            return tab
        }
        let editor = CommitEditorTabState(
            worktreeId: worktreeId,
            projectId: projectId,
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
        removeStashedDraft(tabId: draftTabId, from: &file)
        return tab
    }

    @discardableResult
    private func removeStashedDraft(tabId: TabID, from file: inout TabsFile) -> Bool {
        var removed = false
        if file.stashedDraft?.id == tabId {
            file.stashedDraft = nil
            removed = true
        }
        let projectIds = file.stashedDraftsByProject.compactMap { projectId, draft in
            draft.id == tabId ? projectId : nil
        }
        for projectId in projectIds {
            file.stashedDraftsByProject[projectId] = nil
            removed = true
        }
        return removed
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

    func updateCommitEditorShas(
        worktreeId: String,
        shaMap: [String: String],
        projectId: String? = nil,
        includesLegacyUnownedProjectTabs: Bool = false
    ) {
        guard !shaMap.isEmpty, var file = byWorktree[worktreeId] else { return }
        var changed = false
        for idx in file.tabs.indices {
            guard case .commitEditor(var state) = file.tabs[idx],
                  projectId == nil || state.projectId == projectId
                      || (includesLegacyUnownedProjectTabs && state.projectId == nil),
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
    func openMergeConflict(
        worktreeId: String,
        projectId: String? = nil,
        includesLegacyUnownedProjectTabs: Bool = false,
        relativePath: String,
        title: String
    ) -> Tab {
        if var file = byWorktree[worktreeId],
           let idx = file.tabs.firstIndex(where: {
               if case .mergeConflict(let s) = $0 {
                   let belongsToProject = projectId.map {
                       s.projectId == $0 || (includesLegacyUnownedProjectTabs && s.projectId == nil)
                   } ?? true
                   return belongsToProject && s.relativePath == relativePath
               }
               return false
           }) {
            if case .mergeConflict(var state) = file.tabs[idx],
               state.projectId == nil,
               includesLegacyUnownedProjectTabs {
                state.projectId = projectId
                file.tabs[idx] = .mergeConflict(state)
            }
            let existing = file.tabs[idx]
            file.activeTabId = existing.id
            rememberProjectLocalTab(existing, in: &file)
            byWorktree[worktreeId] = file
            persist(worktreeId)
            return existing
        }
        let state = MergeConflictTabState(
            worktreeId: worktreeId,
            projectId: projectId,
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
    func openImagePreview(
        worktreeId: String,
        projectId: String? = nil,
        includesLegacyUnownedProjectTabs: Bool = false,
        relativePath: String
    ) -> Tab {
        if var file = byWorktree[worktreeId],
           let idx = file.tabs.firstIndex(where: {
               if case .imagePreview(let s) = $0 {
                   return s.relativePath == relativePath
                       && (projectId == nil
                           ? s.projectId == nil
                           : s.projectId == projectId || (includesLegacyUnownedProjectTabs && s.projectId == nil))
               }
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
        let state = ImagePreviewTabState(
            id: UUID().uuidString,
            title: title,
            relativePath: relativePath,
            projectId: projectId
        )
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
        if let tab = file.tabs.first(where: { $0.id == tabId }) {
            rememberProjectLocalTab(tab, in: &file)
        }
        byWorktree[worktreeId] = file
        persist(worktreeId)
    }

    func activate(owner: SessionOwnerID, tabId: TabID) {
        activate(worktreeId: owner.tabStorageKey, tabId: tabId)
    }

    func clearActiveTab(owner: SessionOwnerID) {
        clearActiveTab(worktreeId: owner.tabStorageKey)
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
        rememberProjectLocalTab(tab, in: &file)
        byWorktree[worktreeID] = file
        persist(worktreeID)
        return tab.id
    }

    /// Capture a draft commit tab's state into its owner's stash before
    /// removal. Non-empty drafts and recovery checkpoints stash so they survive
    /// close/reopen. Empty drafts without recovery state CLEAR the stash so a
    /// user who opens an old stashed draft, wipes the text, and closes the tab
    /// actually gets rid of it.
    /// Silently does nothing if `removingTabId` is not a draftCommit tab.
    private func captureDraftIfNeeded(_ file: inout TabsFile, removingTabId: TabID) {
        guard let tab = file.tabs.first(where: { $0.id == removingTabId }),
              case .draftCommit(let state) = tab else { return }
        let hasSubject = !state.subject.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let hasBody = !state.bodyText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        setStashedDraft(
            (hasSubject || hasBody || state.publishCheckpoint != nil) ? state : nil,
            forProjectId: state.projectId,
            in: &file
        )
    }

    private func clearWebPreviewBrowsers(for tabs: some Sequence<Tab>) {
        for tab in tabs {
            guard case .webPreview(let state) = tab else { continue }
            clearWebPreviewBrowser(ownerKey: state.ownerKey, projectId: state.projectId)
        }
    }

    private func clearWebPreviewBrowser(ownerKey: String, projectId: String?) {
        let cacheKey = WebPreviewTabState.browserCacheKey(ownerKey: ownerKey, projectId: projectId)
        webPreviewBrowsers.removeValue(forKey: cacheKey)?.close()
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
        clearWebPreviewBrowsers(for: [tab])
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

    /// Discards every project-owned tab in a path-derived bucket while another
    /// project still uses the same path. Unlike `close`, this does not preserve
    /// a live draft in its stash: the caller is completing a destructive
    /// worktree removal.
    func purgeProjectOwnedEditorState(
        worktreeId: String,
        projectId: String,
        includesLegacyUnownedProjectTabs: Bool = false
    ) {
        guard var file = byWorktree[worktreeId] else { return }
        let removedTabs = file.tabs.filter { tab in
            projectLocalTabBelongs(
                tab,
                projectId: projectId,
                includesLegacyUnownedProjectTabs: includesLegacyUnownedProjectTabs
            ) == true
        }
        guard !removedTabs.isEmpty
            || file.stashedDraftsByProject[projectId] != nil
            || file.stashedDraft.map({ $0.projectId == projectId || (includesLegacyUnownedProjectTabs && $0.projectId == nil) }) == true
            || file.activeEditorTabIds[projectId] != nil else { return }

        let removedTabIDs = Set(removedTabs.map(\.id))
        let activeTabIndex = file.tabs.firstIndex(where: { $0.id == file.activeTabId })
        for tab in removedTabs {
            switch tab {
            case .editor:
                discardBuffer(worktreeId: worktreeId, tabId: tab.id)
            case .terminal(let state):
                for leaf in state.root.leaves() {
                    terminalRuntimeTitles.removeValue(forKey: leaf.id)
                }
            default:
                break
            }
            ggSplitCommitDrafts.removeValue(forKey: tab.id)
        }
        clearWebPreviewBrowsers(for: removedTabs)
        file.tabs.removeAll { removedTabIDs.contains($0.id) }
        file.activeEditorTabIds[projectId] = nil
        file.stashedDraftsByProject[projectId] = nil
        if let stashedDraft = file.stashedDraft,
           stashedDraft.projectId == projectId || (includesLegacyUnownedProjectTabs && stashedDraft.projectId == nil) {
            file.stashedDraft = nil
        }
        for tab in removedTabs {
            if case .draftCommit(let state) = tab,
               commitPublishSessions[state.id]?.isRunning != true {
                commitPublishSessions[state.id] = nil
            }
        }
        if let activeTabId = file.activeTabId, removedTabIDs.contains(activeTabId) {
            if file.tabs.isEmpty {
                file.activeTabId = nil
            } else {
                let oldIndex = activeTabIndex ?? 0
                let neighbourIndex = max(0, min(oldIndex - 1, file.tabs.count - 1))
                file.activeTabId = file.tabs[neighbourIndex].id
            }
        }
        byWorktree[worktreeId] = file
        persist(worktreeId)
    }

    func close(owner: SessionOwnerID, tabId: TabID) {
        close(worktreeId: owner.tabStorageKey, tabId: tabId)
    }

    /// Removes visible checkout tabs without changing any focused member's
    /// worktree bucket or deleting the checkout record itself.
    func archive(owner: SessionOwnerID) {
        _ = closeAll(worktreeId: owner.tabStorageKey)
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
        let closedTabs = file.tabs.filter { $0.id != tabId }
        guard let kept = file.tabs.first(where: { $0.id == tabId }) else { return [] }
        for id in closed {
            captureDraftIfNeeded(&file, removingTabId: id)
            ggSplitCommitDrafts.removeValue(forKey: id)
        }
        clearWebPreviewBrowsers(for: closedTabs)
        file.tabs = [kept]
        file.activeTabId = tabId
        byWorktree[worktreeId] = file
        persist(worktreeId)
        return closed
    }

    func closeAll(worktreeId: String) -> [TabID] {
        guard var file = byWorktree[worktreeId] else { return [] }
        let closed = file.tabs.map(\.id)
        let closedTabs = file.tabs
        for id in closed {
            captureDraftIfNeeded(&file, removingTabId: id)
            ggSplitCommitDrafts.removeValue(forKey: id)
        }
        clearWebPreviewBrowsers(for: closedTabs)
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
        let closedTabs = Array(file.tabs[0..<idx])
        for id in closed {
            captureDraftIfNeeded(&file, removingTabId: id)
            ggSplitCommitDrafts.removeValue(forKey: id)
        }
        clearWebPreviewBrowsers(for: closedTabs)
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
        let closedTabs = Array(file.tabs[(idx + 1)...])
        for id in closed {
            captureDraftIfNeeded(&file, removingTabId: id)
            ggSplitCommitDrafts.removeValue(forKey: id)
        }
        clearWebPreviewBrowsers(for: closedTabs)
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
        rememberProjectLocalTab(tab, in: &file)
        byWorktree[worktreeId] = file
        persist(worktreeId)
    }

    private func rememberProjectLocalTab(_ tab: Tab, in file: inout TabsFile) {
        let projectId: String? = switch tab {
        case .editor(let state): state.projectId
        case .draftCommit(let state): state.projectId
        case .terminal(let state): state.projectId
        case .acpSession(let state): state.projectId
        case .webPreview(let state): state.projectId
        case .runReport(let state): state.projectId
        case .imagePreview(let state): state.projectId
        case .ggInbox(let state): state.projectId
        case .ggLanding(let state): state.projectId
        case .commit(let state): state.projectId
        case .commitEditor(let state): state.projectId
        case .draftReviewRequest(let state): state.projectId
        case .mergeConflict(let state): state.projectId
        case .fileSnapshot(let state): state.projectId
        case .fileHistory(let state): state.projectId
        case .diff(let state): state.projectId
        case .stashDiff(let state): state.projectId
        case .checkpointDiff(let state): state.projectId
        case .reviewPR(let state): state.projectId
        case .ggSplitCommit(let state): state.projectId
        case .reviewChanges(let state): state.projectId
        case .reviewSession(let state): state.projectId
        default: nil
        }
        if let projectId { file.activeEditorTabIds[projectId] = tab.id }
    }

    func adoptLegacyProjectOwnedTab(worktreeId: String, tabId: TabID, projectId: String) {
        guard var file = byWorktree[worktreeId],
              let index = file.tabs.firstIndex(where: { $0.id == tabId })
        else { return }

        switch file.tabs[index] {
        case .diff(var state) where state.projectId == nil:
            state.projectId = projectId
            file.tabs[index] = .diff(state)
        case .stashDiff(var state) where state.projectId == nil:
            state.projectId = projectId
            file.tabs[index] = .stashDiff(state)
        case .checkpointDiff(var state) where state.projectId == nil:
            state.projectId = projectId
            file.tabs[index] = .checkpointDiff(state)
        case .reviewPR(var state) where state.projectId == nil:
            state.projectId = projectId
            file.tabs[index] = .reviewPR(state)
        case .ggSplitCommit(var state) where state.projectId == nil:
            state.projectId = projectId
            file.tabs[index] = .ggSplitCommit(state)
        case .reviewChanges(var state) where state.projectId == nil:
            state.projectId = projectId
            file.tabs[index] = .reviewChanges(state)
        case .reviewSession(var state) where state.projectId == nil:
            state.projectId = projectId
            file.tabs[index] = .reviewSession(state)
        default:
            return
        }

        let adoptedTab = file.tabs[index]
        rememberProjectLocalTab(adoptedTab, in: &file)
        byWorktree[worktreeId] = file
        persist(worktreeId)
    }

    private func setStashedDraft(
        _ draft: DraftCommitTabState?,
        forProjectId projectId: String?,
        in file: inout TabsFile
    ) {
        guard let projectId else {
            file.stashedDraft = draft
            return
        }
        file.stashedDraftsByProject[projectId] = draft
        if let legacyDraft = file.stashedDraft,
           legacyDraft.projectId == projectId || legacyDraft.id == draft?.id {
            file.stashedDraft = nil
        }
    }

    private func persist(_ worktreeId: String) {
        try? persistThrowing(worktreeId)
    }

    private func persistThrowing(_ worktreeId: String) throws {
        guard let file = byWorktree[worktreeId] else { return }
        try persistThrowing(file, worktreeId: worktreeId)
    }

    private func persistThrowing(_ file: TabsFile, worktreeId: String) throws {
        var restorable = file
        restorable.tabs = file.tabs.filter(\.isRestorable)
        if let activeId = file.activeTabId,
           !restorable.tabs.contains(where: { $0.id == activeId }) {
            restorable.activeTabId = restorable.tabs.last?.id
        }
        try store.write(restorable, to: tabsFile(forWorktreeId: worktreeId))
    }

    private func tabsFile(forWorktreeId worktreeId: String) -> URL {
        tabsDirectory.appendingPathComponent("\(worktreeId).json")
    }

    private func tabsFile(forOwner owner: SessionOwnerID) -> URL {
        tabsDirectory.appendingPathComponent("\(owner.tabStorageKey).json")
    }

    // MARK: - Buffer lifecycle

    /// Returns the buffer for `tabId`, creating it (cold-load from disk or
    /// hot-restore from snapshot) on first access.
    func buffer(
        worktreeId: String,
        tabId: TabID,
        worktreeRoot: URL,
        relativePath: String,
        projectId: String? = nil,
        projectHost: String? = nil
    ) -> EditorBuffer {
        if let existing = tabBuffers[tabId] { return existing }
        let hostResolution: EditorBufferHostResolution = projectId.map { _ in .project(projectHost) } ?? .pathRegistry
        let editorState = tabs(forWorktree: worktreeId).first(where: { $0.id == tabId }).flatMap { tab -> EditorTabState? in
            guard case .editor(let state) = tab else { return nil }
            return state
        }
        let projectId = editorState?.projectId
        let navigationResolvedRoot = editorState?.navigationResolvedRoot
        let snapshot = (try? bufferStore.read(worktreeId: worktreeId, tabId: tabId)) ?? nil
        var restoresToDifferentPath = snapshot.map { $0.relativePath != relativePath } ?? false
        if restoresToDifferentPath {
            if let snapshot,
               !canFollowBufferPathChange(
                   worktreeId: worktreeId,
                   projectId: projectId,
                   oldPath: relativePath,
                   newPath: snapshot.relativePath
               ) {
                bufferStore.discard(worktreeId: worktreeId, tabId: tabId)
                restoresToDifferentPath = false
            }
        }
        let key = BufferKey(worktreeId: worktreeId, projectId: projectId, relativePath: relativePath)
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
                checkConflictOnRestore: true,
                navigationResolvedRoot: navigationResolvedRoot,
                hostResolution: hostResolution
            )
        } else {
            buffer = EditorBuffer(
                worktreeRoot: worktreeRoot,
                relativePath: relativePath,
                store: bufferStore,
                worktreeId: worktreeId,
                tabId: tabId,
                checkConflictOnRestore: true,
                navigationResolvedRoot: navigationResolvedRoot,
                hostResolution: hostResolution
            )
        }
        buffer.startWatching()
        buffer.shouldFollowPathChange = { [weak self] oldPath, newPath in
            self?.canFollowBufferPathChange(
                worktreeId: worktreeId,
                projectId: projectId,
                oldPath: oldPath,
                newPath: newPath
            ) ?? false
        }
        buffer.onPathChanged = { [weak self, weak buffer] oldPath, newPath in
            guard let buffer else { return }
            self?.handleBufferPathChanged(
                worktreeId: worktreeId,
                projectId: projectId,
                buffer: buffer,
                oldPath: oldPath,
                newPath: newPath
            )
        }
        buffer.onRestoredPathChanged = { [weak self, weak buffer] oldPath, newPath in
            guard let self, let buffer else { return }
            self.resolvePendingRestoredPathChange(
                worktreeId: worktreeId,
                projectId: projectId,
                tabId: tabId,
                buffer: buffer,
                oldPath: oldPath,
                newPath: newPath
            )
        }
        buffer.onInitialLoadFinished = { [weak self, weak buffer] in
            guard let self, let buffer else { return }
            self.indexRestoredPathBufferIfAvailable(
                worktreeId: worktreeId,
                projectId: projectId,
                tabId: tabId,
                buffer: buffer
            )
            self.reattachWorkspaceUndo(buffer, worktreeId: worktreeId)
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
                indexRestoredPathBufferIfAvailable(
                    worktreeId: worktreeId,
                    projectId: projectId,
                    tabId: tabId,
                    buffer: buffer
                )
            }
        } else if let restoredPathChange = buffer.consumeRestoredPathChange() {
            let restoredKey = BufferKey(
                worktreeId: worktreeId,
                projectId: projectId,
                relativePath: restoredPathChange.newPath
            )
            buffers[restoredKey] = buffer
            bufferKeys[tabId] = restoredKey
            _ = updateEditorPath(worktreeId: worktreeId, tabId: tabId, relativePath: restoredPathChange.newPath)
        } else {
            buffers[key] = buffer
            bufferKeys[tabId] = key
        }
        if buffer.initialLoadFinished { reattachWorkspaceUndo(buffer, worktreeId: worktreeId) }
        return buffer
    }

    private func reattachWorkspaceUndo(_ buffer: EditorBuffer, worktreeId: String) {
        let document = EditorDocumentID(host: buffer.workspaceEditHost, worktreeID: worktreeId,
                                        uri: buffer.worktreeRoot.appendingPathComponent(buffer.relativePath).lspURI)
        guard workspaceEditBuffer(for: document) === buffer else { return }
        workspaceUndoCoordinators[worktreeId]?.reattachCleanBuffer(buffer, document: document)
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
        hostResolution: EditorBufferHostResolution = .pathRegistry,
        editable: Bool = false
    ) -> EditorBuffer {
        let existingEntry = externalTabURLs[tabId]
        if existingEntry?.worktreeId != worktreeId || existingEntry?.url != absoluteURL || existingEntry?.hostResolution != hostResolution {
            externalTabURLs[tabId] = (worktreeId: worktreeId, url: absoluteURL, hostResolution: hostResolution)
        }
        let buffer = bufferStore.externalBuffer(
            worktreeId: worktreeId,
            absoluteURL: absoluteURL,
            editable: editable,
            tabId: editable ? tabId : nil,
            hostResolution: hostResolution
        )
        buffer.startWatchingIfNeeded()

        if let root = worktreeRoot {
            let existing = externalLSPInfo[tabId]
            let shouldRefreshOrigin = language != nil || existing?.language == nil
            let info = ExternalLSPInfo(
                worktreeRoot: shouldRefreshOrigin ? root : existing?.worktreeRoot ?? root,
                originatingFileURL: shouldRefreshOrigin ? originatingFileURL : existing?.originatingFileURL,
                language: language ?? existing?.language,
                hostResolution: hostResolution
            )
            if info != existing {
                if let existingLanguage = info.language {
                    rebindExternalLSPHolder(
                        tabId: tabId,
                        absoluteURL: absoluteURL,
                        worktreeRoot: info.worktreeRoot,
                        originatingFileURL: info.originatingFileURL,
                        language: existingLanguage,
                        hostResolution: info.hostResolution
                    )
                } else {
                    externalLSPInfo[tabId] = info
                }
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
        let contents = bufferStore.externalBuffer(
            worktreeId: entry.worktreeId,
            absoluteURL: absoluteURL,
            hostResolution: entry.hostResolution
        ).storage.string
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
                contents: contents,
                hostResolution: snapshot.hostResolution
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
                                    language: language,
                                    hostResolution: snapshot.hostResolution
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
                                    language: language,
                                    hostResolution: snapshot.hostResolution
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

    /// Looks across inactive tabs and external editors without creating a buffer.
    func workspaceEditBuffer(for document: EditorDocumentID) -> EditorBuffer? {
        for (tabID, buffer) in tabBuffers {
            guard bufferKeys[tabID]?.worktreeId == document.worktreeID,
                  buffer.workspaceEditHost == document.host,
                  buffer.worktreeRoot.appendingPathComponent(buffer.relativePath).lspURI == document.uri else { continue }
            return buffer
        }
        for (tabID, entry) in externalTabURLs where entry.worktreeId == document.worktreeID && entry.url.lspURI == document.uri {
            if let buffer = peekExternalBuffer(tabId: tabID), buffer.workspaceEditHost == document.host { return buffer }
        }
        return nil
    }

    /// Capture before sending rename/code-action requests. The receipt path
    /// must reject changed or closed identities, even if text changed back.
    func workspaceEditGenerations(host: String?, worktreeID: String) -> [EditorDocumentID: WorkspaceEditBufferGeneration] {
        var result: [EditorDocumentID: WorkspaceEditBufferGeneration] = [:]
        for (tabID, buffer) in tabBuffers where bufferKeys[tabID]?.worktreeId == worktreeID && buffer.workspaceEditHost == host {
            let document = EditorDocumentID(host: host, worktreeID: worktreeID, uri: buffer.worktreeRoot.appendingPathComponent(buffer.relativePath).lspURI)
            result[document] = WorkspaceEditBufferGeneration(buffer)
        }
        for (tabID, entry) in externalTabURLs where entry.worktreeId == worktreeID {
            if let buffer = peekExternalBuffer(tabId: tabID), buffer.workspaceEditHost == host {
                result[EditorDocumentID(host: host, worktreeID: worktreeID, uri: entry.url.lspURI)] = WorkspaceEditBufferGeneration(buffer)
            }
        }
        return result
    }

    func workspaceEditVersion(for document: EditorDocumentID, buffer: EditorBuffer) -> Int? {
        lsp?.workspaceEditVersion(for: document, worktreeRoot: buffer.worktreeRoot)
    }

    /// Non-creating lookup for an external editor buffer. Returns nil if no
    /// external buffer has been registered for this tab (or if the tab isn't
    /// an external editor tab). Used by read-only checks (e.g.
    /// `EditorTabView.isBinary`) to avoid the side-effecting creation in
    /// `externalBuffer(...)` while still detecting the load kind of external
    /// files that went through the editor path (unknown-extension binaries).
    func peekExternalBuffer(tabId: TabID) -> EditorBuffer? {
        guard let entry = externalTabURLs[tabId] else { return nil }
        return bufferStore.peekExternalBuffer(
            worktreeId: entry.worktreeId,
            absoluteURL: entry.url,
            hostResolution: entry.hostResolution
        )
    }

    private func indexRestoredPathBufferIfAvailable(
        worktreeId: String,
        projectId: String?,
        tabId: TabID,
        buffer: EditorBuffer
    ) {
        guard tabBuffers[tabId] === buffer else { return }
        let key = BufferKey(worktreeId: worktreeId, projectId: projectId, relativePath: buffer.relativePath)
        if let existing = buffers[key], existing !== buffer { return }
        buffers[key] = buffer
        bufferKeys[tabId] = key
    }

    private func resolvePendingRestoredPathChange(
        worktreeId: String,
        projectId: String?,
        tabId: TabID,
        buffer: EditorBuffer,
        oldPath: String,
        newPath: String
    ) {
        let oldKey = BufferKey(worktreeId: worktreeId, projectId: projectId, relativePath: oldPath)
        let restoredKey = BufferKey(worktreeId: worktreeId, projectId: projectId, relativePath: newPath)
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
    func activeEditorContext(worktreeId: String, projectId: String? = nil) -> (tab: EditorTabState, buffer: EditorBuffer)? {
        let activeId = projectId.map { activeTabId(forWorktree: worktreeId, projectId: $0) }
            ?? activeTabId(forWorktree: worktreeId)
        guard let activeId,
              let tab = tabs(forWorktree: worktreeId).first(where: { $0.id == activeId }),
              case .editor(let state) = tab,
              projectId == nil || state.projectId == projectId,
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
                        language: language,
                        hostResolution: info.hostResolution
                    )
                }
            }
            openedExternalDocs.remove(tabId)
            if let buffer = bufferStore.peekExternalBuffer(
                worktreeId: ext.worktreeId,
                absoluteURL: ext.url,
                hostResolution: ext.hostResolution
            ) {
                workspaceUndoCoordinators[ext.worktreeId]?.bufferWillClose(buffer)
            }
            bufferStore.discardExternalBuffer(
                worktreeId: ext.worktreeId,
                absoluteURL: ext.url,
                hostResolution: ext.hostResolution
            )
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
        workspaceUndoCoordinators[worktreeId]?.bufferWillClose(buffer)
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
    func hasDirtyBuffer(worktreeId: String, projectId: String? = nil, relativePath: String) -> Bool {
        if let projectId {
            let key = BufferKey(worktreeId: worktreeId, projectId: projectId, relativePath: relativePath)
            return buffers[key]?.dirty == true
        }
        return buffers.contains { entry in
            entry.key.worktreeId == worktreeId
                && entry.key.relativePath == relativePath
                && entry.value.dirty
        }
    }

    /// Relative paths with unsaved editor state for one worktree. Includes
    /// unloaded hot-exit snapshots because a restore would otherwise replace
    /// the on-disk file behind an unsaved editor draft.
    func unsavedRelativePaths(forWorktree worktreeId: String, projectId: String? = nil) -> Set<String> {
        guard let file = byWorktree[worktreeId] else { return [] }
        return Set(file.tabs.compactMap { tab in
            guard case let .editor(state) = tab,
                  projectId == nil || state.projectId == projectId,
                  !state.isExternal else { return nil }
            if let buffer = peekBuffer(tabId: state.id) {
                return buffer.saveDisposition == .clean ? nil : buffer.relativePath
            }
            guard (try? bufferStore.read(worktreeId: worktreeId, tabId: state.id)) != nil else { return nil }
            return state.relativePath
        })
    }

    /// Live in-memory contents of the editor buffer at
    /// `relativePath`, when one is open AND dirty. Returns `nil` when
    /// the file isn't open in the editor or has no unsaved changes,
    /// in which case the caller should fall back to disk. Used by the
    /// ACP `fs/read_text_file` handler so agents see what the user
    /// sees, not the last saved bytes.
    func dirtyBufferText(worktreeId: String, projectId: String? = nil, relativePath: String) -> String? {
        if let projectId {
            let key = BufferKey(worktreeId: worktreeId, projectId: projectId, relativePath: relativePath)
            guard let buffer = buffers[key], buffer.dirty else { return nil }
            return buffer.storage.string
        }
        let matches = buffers.compactMap { entry -> String? in
            guard entry.key.worktreeId == worktreeId,
                  entry.key.relativePath == relativePath,
                  entry.value.dirty else { return nil }
            return entry.value.storage.string
        }
        return matches.count == 1 ? matches[0] : nil
    }

    /// Tab IDs in `worktreeId` that have unsaved changes — either a live dirty
    /// buffer or a persisted hot-exit snapshot for a buffer that hasn't been
    /// instantiated yet. Returns IDs in tab order (declaration order within the
    /// worktree's tab list).
    func tabIdsWithUnsavedChanges(
        forWorktree worktreeId: String,
        projectId: String? = nil,
        includesLegacyUnownedProjectTabs: Bool = false
    ) -> [TabID] {
        guard let file = byWorktree[worktreeId] else { return [] }
        var result: [TabID] = []
        for tab in file.tabs {
            guard case .editor(let state) = tab,
                  projectId == nil || state.projectId == projectId
                      || (includesLegacyUnownedProjectTabs && state.projectId == nil) else { continue }
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
            let newKey = BufferKey(worktreeId: worktreeId, projectId: oldKey.projectId, relativePath: relativePath)
            bufferKeys[tabId] = newKey
            if oldKey != newKey, let buffer = buffers.removeValue(forKey: oldKey) {
                buffers[newKey] = buffer
            }
        }
        return true
    }

    func hasEditor(worktreeId: String, projectId: String? = nil, relativePath: String, excluding tabId: TabID? = nil) -> Bool {
        tabs(forWorktree: worktreeId).contains { tab in
            guard case .editor(let state) = tab else { return false }
            return state.id != tabId
                && state.relativePath == relativePath
                && (projectId == nil || state.projectId == projectId)
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
    func saveAll(
        worktreeRoots: [String: URL] = [:],
        allowedWorktreeIDs: Set<String>? = nil,
        projectHosts: [String: String] = [:]
    ) -> [(tabId: TabID, error: Error)] {
        var errors: [(TabID, Error)] = []
        var saved = Set<ObjectIdentifier>()
        for (tabId, _) in bufferKeys {
            guard tabIsAllowedForSaveAll(tabId, allowedWorktreeIDs: allowedWorktreeIDs) else { continue }
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
            guard tabIsAllowedForSaveAll(tabId, allowedWorktreeIDs: allowedWorktreeIDs) else { continue }
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
            if let allowedWorktreeIDs, !allowedWorktreeIDs.contains(worktreeId) { continue }
            for tab in file.tabs {
                guard case .editor(let state) = tab,
                      peekBuffer(tabId: state.id) == nil,
                      (try? bufferStore.read(worktreeId: worktreeId, tabId: state.id)) != nil else { continue }
                let root = worktreeRoots[worktreeId]
                guard let buffer = materializeSnapshotBufferForSave(
                    worktreeId: worktreeId,
                    state: state,
                    worktreeRoot: root,
                    projectId: state.projectId,
                    projectHost: state.projectId.flatMap { projectHosts[$0] }
                ) else { continue }
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
    func saveAllAwaitingRemote(
        worktreeRoots: [String: URL] = [:],
        allowedWorktreeIDs: Set<String>? = nil,
        projectHosts: [String: String] = [:]
    ) async -> [(tabId: TabID, error: Error)] {
        var errors: [(TabID, Error)] = []
        var saved = Set<ObjectIdentifier>()
        for (tabId, key) in bufferKeys {
            guard tabIsAllowedForSaveAll(tabId, allowedWorktreeIDs: allowedWorktreeIDs) else { continue }
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
            guard tabIsAllowedForSaveAll(tabId, allowedWorktreeIDs: allowedWorktreeIDs) else { continue }
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
            if let allowedWorktreeIDs, !allowedWorktreeIDs.contains(worktreeId) { continue }
            for tab in file.tabs {
                guard case .editor(let state) = tab,
                      peekBuffer(tabId: state.id) == nil,
                      (try? bufferStore.read(worktreeId: worktreeId, tabId: state.id)) != nil else { continue }
                let root = worktreeRoots[worktreeId]
                guard let buffer = materializeSnapshotBufferForSave(
                    worktreeId: worktreeId,
                    state: state,
                    worktreeRoot: root,
                    projectId: state.projectId,
                    projectHost: state.projectId.flatMap { projectHosts[$0] }
                ) else { continue }
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

    private func tabIsAllowedForSaveAll(_ tabId: TabID, allowedWorktreeIDs: Set<String>?) -> Bool {
        guard let allowedWorktreeIDs else { return true }
        guard let worktreeID = byWorktree.first(where: { _, file in
            file.tabs.contains { $0.id == tabId }
        })?.key else { return true }
        return allowedWorktreeIDs.contains(worktreeID)
    }

    /// Save all unsaved buffers for a single worktree. Mirrors the snapshot-
    /// materialize pattern from `saveAll(worktreeRoots:)` but scoped to one
    /// worktree so archive/delete can save before teardown.
    /// Returns an array of (tabId, error) pairs; empty on full success.
    @discardableResult
    func saveAllUnsaved(
        forWorktree worktreeId: String,
        root: URL,
        projectId: String? = nil,
        includesLegacyUnownedProjectTabs: Bool = false,
        projectHost: String? = nil
    ) -> [(tabId: TabID, error: Error)] {
        var errors: [(TabID, Error)] = []
        var saved = Set<ObjectIdentifier>()
        // Pass 1: live dirty buffers belonging to this worktree.
        for (tabId, key) in bufferKeys {
            guard key.worktreeId == worktreeId,
                  projectId == nil || key.projectId == projectId
                      || (includesLegacyUnownedProjectTabs && key.projectId == nil),
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
                  tabIsInProjectSaveScope(
                      tabId,
                      worktreeId: worktreeId,
                      projectId: projectId,
                      includesLegacyUnownedProjectTabs: includesLegacyUnownedProjectTabs
                  ),
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
                  editorStateBelongsToSaveProject(
                      state,
                      projectId: projectId,
                      includesLegacyUnownedProjectTabs: includesLegacyUnownedProjectTabs
                  ),
                  peekBuffer(tabId: state.id) == nil,
                  (try? bufferStore.read(worktreeId: worktreeId, tabId: state.id)) != nil else { continue }
            guard let buffer = materializeSnapshotBufferForSave(
                worktreeId: worktreeId,
                state: state,
                worktreeRoot: root,
                projectId: projectId,
                projectHost: projectHost
            ) else { continue }
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
    func saveAllUnsavedAwaitingRemote(
        forWorktree worktreeId: String,
        root: URL,
        projectId: String? = nil,
        includesLegacyUnownedProjectTabs: Bool = false,
        projectHost: String? = nil
    ) async -> [(tabId: TabID, error: Error)] {
        var errors: [(TabID, Error)] = []
        var saved = Set<ObjectIdentifier>()
        // Pass 1: live dirty buffers belonging to this worktree.
        for (tabId, key) in bufferKeys {
            guard key.worktreeId == worktreeId,
                  projectId == nil || key.projectId == projectId
                      || (includesLegacyUnownedProjectTabs && key.projectId == nil),
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
                  tabIsInProjectSaveScope(
                      tabId,
                      worktreeId: worktreeId,
                      projectId: projectId,
                      includesLegacyUnownedProjectTabs: includesLegacyUnownedProjectTabs
                  ),
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
                  editorStateBelongsToSaveProject(
                      state,
                      projectId: projectId,
                      includesLegacyUnownedProjectTabs: includesLegacyUnownedProjectTabs
                  ),
                  peekBuffer(tabId: state.id) == nil,
                  (try? bufferStore.read(worktreeId: worktreeId, tabId: state.id)) != nil else { continue }
            guard let buffer = materializeSnapshotBufferForSave(
                worktreeId: worktreeId,
                state: state,
                worktreeRoot: root,
                projectId: projectId,
                projectHost: projectHost
            ) else { continue }
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

    private func editorStateBelongsToSaveProject(
        _ state: EditorTabState,
        projectId: String?,
        includesLegacyUnownedProjectTabs: Bool
    ) -> Bool {
        guard let projectId else { return true }
        return state.projectId == projectId || (includesLegacyUnownedProjectTabs && state.projectId == nil)
    }

    private func tabIsInProjectSaveScope(
        _ tabId: TabID,
        worktreeId: String,
        projectId: String?,
        includesLegacyUnownedProjectTabs: Bool
    ) -> Bool {
        guard let projectId else { return true }
        guard let tab = byWorktree[worktreeId]?.tabs.first(where: { $0.id == tabId }),
              case .editor(let state) = tab
        else { return false }
        return editorStateBelongsToSaveProject(
            state,
            projectId: projectId,
            includesLegacyUnownedProjectTabs: includesLegacyUnownedProjectTabs
        )
    }

    private func materializeSnapshotBufferForSave(
        worktreeId: String,
        state: EditorTabState,
        worktreeRoot: URL?,
        projectId: String? = nil,
        projectHost: String? = nil
    ) -> EditorBuffer? {
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
           !canFollowBufferPathChange(
               worktreeId: worktreeId,
               projectId: state.projectId,
               oldPath: relativePath,
               newPath: snapshot.relativePath
           ) {
            bufferStore.discard(worktreeId: worktreeId, tabId: tabId)
            return nil
        }
        let buffer: EditorBuffer
        let hostResolution: EditorBufferHostResolution = projectId.map { _ in .project(projectHost) } ?? .pathRegistry
        if let lsp {
            buffer = EditorBuffer(
                worktreeRoot: worktreeRoot,
                relativePath: relativePath,
                store: bufferStore,
                worktreeId: worktreeId,
                tabId: tabId,
                lsp: lsp,
                loadSynchronously: true,
                navigationResolvedRoot: state.navigationResolvedRoot,
                hostResolution: hostResolution
            )
        } else {
            buffer = EditorBuffer(
                worktreeRoot: worktreeRoot,
                relativePath: relativePath,
                store: bufferStore,
                worktreeId: worktreeId,
                tabId: tabId,
                loadSynchronously: true,
                navigationResolvedRoot: state.navigationResolvedRoot,
                hostResolution: hostResolution
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
        projectId: String?,
        buffer: EditorBuffer,
        oldPath: String,
        newPath: String
    ) {
        let oldKey = BufferKey(worktreeId: worktreeId, projectId: projectId, relativePath: oldPath)
        let newKey = BufferKey(worktreeId: worktreeId, projectId: projectId, relativePath: newPath)
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

    private func canFollowBufferPathChange(
        worktreeId: String,
        projectId: String? = nil,
        oldPath: String,
        newPath: String
    ) -> Bool {
        let oldKey = BufferKey(worktreeId: worktreeId, projectId: projectId, relativePath: oldPath)
        let newKey = BufferKey(worktreeId: worktreeId, projectId: projectId, relativePath: newPath)
        guard oldKey != newKey else { return true }
        guard buffers[newKey] == nil else { return false }
        guard let file = byWorktree[worktreeId] else { return true }
        for tab in file.tabs {
            guard case .editor(let state) = tab,
                  state.projectId == projectId,
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
