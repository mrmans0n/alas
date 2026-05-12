import Foundation
import AppKit
import Observation

@Observable
@MainActor
final class AppState {
    var config: AppConfig
    var themeStore: ThemeStore
    var projectsManager: ProjectsManager
    var selectedWorktreeId: String?
    @ObservationIgnored
    private var _tabs: TabsManager?
    var tabs: TabsManager {
        if let _tabs { return _tabs }
        let manager = TabsManager(lsp: lsp)
        _tabs = manager
        return manager
    }
    let terminal = TerminalService()
    let rightPaneStore = RightPaneStore()
    let harness = HarnessService()
    @ObservationIgnored
    private var lspManager: WorkspaceLSPManager?

    var isSearchOpen: Bool = false
    @ObservationIgnored
    lazy var search: SearchModel = SearchModel(environment: makeSearchEnvironment())
    @ObservationIgnored
    private let fileIndex = FileIndex()
    @ObservationIgnored
    private let statusCache = GitStatusCache()

    var lsp: WorkspaceLSPManager {
        if let lspManager { return lspManager }
        let manager = WorkspaceLSPManager(registry: LanguageServerRegistry(userDefined: config.code.languageServers))
        lspManager = manager
        return manager
    }

    private let store = PersistenceStore()

    init() {
        let config = (try? store.readIfExists(AppConfig.self, from: Paths.appConfigFile)) ?? AppConfig.defaults
        let projectsFile = (try? store.readIfExists(ProjectsFile.self, from: Paths.projectsFile)) ?? ProjectsFile(projects: [])
        self.config = config
        self.projectsManager = ProjectsManager(persistedProjects: projectsFile.projects)
        let themeStore = (try? ThemeStore(initialId: config.themeId)) ?? (try! ThemeStore())
        // Apply the persisted accent override so the picker's selection
        // survives relaunches; otherwise launches always show the theme's
        // built-in accent until the user re-clicks the picker.
        themeStore.setAccent(config.accent)
        // Same for "Match system" — the toggle's state needs to drive the
        // current theme on launch, not just on subsequent toggle events.
        if config.matchSystemTheme {
            themeStore.setMatchSystem(true)
        }
        self.themeStore = themeStore
        WindowAppearance.apply(darkMode: themeStore.current.darkMode)
        // Tabs can't be loaded here: worktrees haven't been refreshed yet (that
        // happens async in RootView.task), so worktreesByProject is empty and
        // we'd resolve to a 0-element id list. RootView calls reloadTabs() after
        // refreshAll() returns.
    }

    /// Re-scan persisted tab JSONs for every currently-known worktree id. Call
    /// after `projectsManager.refreshAll()` so worktrees actually exist.
    func reloadTabs() {
        let allWorktreeIds = projectsManager.projects.flatMap {
            projectsManager.worktrees(projectId: $0.id).map(\.id)
        }
        tabs.loadAll(worktreeIds: allWorktreeIds)
    }

    var projects: [ProjectConfig] { projectsManager.projects }

    func saveConfig() {
        try? store.write(config, to: Paths.appConfigFile)
        lspManager?.updateRegistry(LanguageServerRegistry(userDefined: config.code.languageServers))
    }

    func saveProjects() {
        try? store.write(ProjectsFile(projects: projectsManager.projects), to: Paths.projectsFile)
    }

    func addProject(path: URL, displayName: String, color: String) async throws {
        _ = try await projectsManager.addProject(path: path, displayName: displayName, color: color)
        saveProjects()
        if await projectsManager.refreshAll() {
            saveProjects()
        }
    }

    func removeProject(id: String) {
        projectsManager.removeProject(id: id)
        saveProjects()
    }

    func updateProject(id: String, name: String, color: String) {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else { return }

        projectsManager.updateProject(id: id, update: ProjectUpdate(name: trimmedName, color: color))
        saveProjects()
    }

    /// Archive (hide) a worktree. Closes all tabs/terminals/harness state for
    /// it, marks the path hidden in `ProjectConfig`, and re-points selection if
    /// the archived worktree was selected. Does NOT touch git or disk.
    func archiveWorktree(_ worktree: Worktree) {
        let dirty = dirtyEditorTabIds(worktreeId: worktree.id)
        if !dirty.isEmpty {
            switch promptForDirtyBuffers(
                action: "Archive",
                branch: worktree.branch,
                dirtyCount: dirty.count,
                onDiskDestructive: false
            ) {
            case .save:
                guard saveDirtyBuffers(in: worktree) else { return }
            case .discard:
                break
            case .cancel:
                return
            }
        }

        // Snapshot index in the visible list BEFORE we mutate anything, so we
        // can pick a sensible follow-up selection.
        let siblingsBefore = projectsManager.visibleWorktrees(projectId: worktree.projectId)
        let removedIndex = siblingsBefore.firstIndex(where: { $0.id == worktree.id }) ?? 0
        let wasSelected = selectedWorktreeId == worktree.id

        cleanupWorktreeState(worktreeId: worktree.id)
        projectsManager.setWorktreeHidden(
            projectId: worktree.projectId,
            path: worktree.path,
            hidden: true
        )
        saveProjects()

        if wasSelected {
            selectedWorktreeId = selectionAfterRemoval(
                removedFromProjectId: worktree.projectId,
                removedAtIndex: removedIndex
            )
        }
    }

    /// Restore an archived worktree. Tabs/terminals are NOT recreated — they
    /// were torn down at archive time and the user re-opens what they need.
    func unarchiveWorktree(projectId: String, path: URL) {
        projectsManager.setWorktreeHidden(projectId: projectId, path: path, hidden: false)
        saveProjects()
    }

    func startHarness() {
        // Sync the persisted preference into NotificationService BEFORE start —
        // otherwise the service defaults to enabled and users who turned
        // notifications off in a previous session get them again until they
        // re-toggle.
        harness.notifications.setEnabled(config.harness.notifyOnFinish)
        harness.start(
            stateLookup: { [weak self] sessionId in
                guard let self else { return nil }
                for s in self.terminal.registry.all where s.id == sessionId {
                    return (projectId: s.projectId, worktreeId: s.worktreeId)
                }
                return nil
            },
            shouldNotifyOnAwaiting: { [weak self] in
                self?.config.harness.notifyOnAwaiting ?? true
            }
        )
        harness.onClickThrough = { [weak self] projectId, worktreeId, sessionId in
            self?.activateHarnessSession(
                projectId: projectId, worktreeId: worktreeId, sessionId: sessionId
            )
        }
    }

    /// Activate a specific harness session: bring the app to front, select
    /// the worktree, and activate the terminal tab hosting `sessionId`.
    /// If the tab is no longer present (session was closed mid-flight) the
    /// worktree is still selected so the user lands somewhere sensible.
    func activateHarnessSession(projectId _: String, worktreeId: String, sessionId: String) {
        selectedWorktreeId = worktreeId
        if let tab = tabs.tabs(forWorktree: worktreeId).first(where: {
            if case .terminal(let s) = $0 { return s.sessionId == sessionId }
            return false
        }) {
            tabs.activate(worktreeId: worktreeId, tabId: tab.id)
        }
        NSApp.activate(ignoringOtherApps: true)
    }

    @discardableResult
    func openTerminalTab(for worktree: Worktree) throws -> Tab {
        guard let project = projects.first(where: { $0.id == worktree.projectId }) else {
            throw NSError(domain: "AppState", code: 2)
        }
        let session = try terminal.openSession(
            worktree: worktree, project: project,
            cfg: config.terminal, theme: themeStore.current
        )
        harness.detector.register(sessionId: session.id) { [weak session] in
            session?.surface.foregroundPid
        }
        let title = tabs.nextTerminalTitle(
            worktreeId: worktree.id,
            baseTitle: defaultTerminalTitle(for: worktree)
        )
        return tabs.appendTerminal(worktreeId: worktree.id, title: title, sessionId: session.id)
    }

    @discardableResult
    func restoreTerminalTabIfNeeded(worktreeId: String, tabId: TabID, sessionId: String) throws -> Tab? {
        guard let tab = tabs.tabs(forWorktree: worktreeId).first(where: { $0.id == tabId }),
              case .terminal(let state) = tab,
              state.sessionId == sessionId else { return nil }
        if terminal.registry.session(for: sessionId) != nil { return tab }
        return try replaceMissingTerminalSession(worktreeId: worktreeId, tab: state)
    }

    func saveActiveTab(worktreeId: String) {
        _ = tabs.saveActive(worktreeId: worktreeId)
    }

    func saveAllTabs() {
        var roots: [String: URL] = [:]
        for project in projects {
            for worktree in projectsManager.worktrees(projectId: project.id) {
                roots[worktree.id] = roots[worktree.id] ?? worktree.path
            }
        }
        let errors = tabs.saveAll(worktreeRoots: roots)
        guard !errors.isEmpty else { return }
        showFileActionError(
            title: "Save All Failed",
            message: "\(errors.count) file\(errors.count == 1 ? "" : "s") could not be saved."
        )
    }

    func revertActiveTab(worktreeId: String) {
        _ = tabs.revertActive(worktreeId: worktreeId)
    }

    func newFile(in worktreeId: String) {
        guard let worktree = worktree(withId: worktreeId) else { return }
        let panel = NSSavePanel()
        panel.title = "New File"
        panel.message = "Choose where to create the new file."
        panel.directoryURL = worktree.path
        panel.nameFieldStringValue = "untitled.txt"
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }

        do {
            let relativePath = try relativePath(for: url, in: worktree.path)
            if FileManager.default.fileExists(atPath: url.path) {
                throw CocoaError(.fileWriteFileExists)
            }
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data().write(to: url, options: .withoutOverwriting)
            openFile(relativePath: relativePath, worktreeId: worktreeId)
        } catch {
            showFileActionError(title: "New File Failed", message: error.localizedDescription)
        }
    }

    func saveActiveTabAs(worktreeId: String) {
        guard let worktree = worktree(withId: worktreeId),
              let context = tabs.activeEditorContext(worktreeId: worktreeId) else { return }
        let currentURL = worktree.path.appendingPathComponent(context.tab.relativePath)
        let panel = NSSavePanel()
        panel.title = "Save As"
        panel.message = "Choose the new path for this editor buffer."
        panel.directoryURL = currentURL.deletingLastPathComponent()
        panel.nameFieldStringValue = currentURL.lastPathComponent
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }

        do {
            let relativePath = try relativePath(for: url, in: worktree.path)
            guard !tabs.hasEditor(worktreeId: worktreeId, relativePath: relativePath, excluding: context.tab.id) else {
                showFileActionError(title: "Save As Failed", message: "That file is already open in another editor tab.")
                return
            }
            try context.buffer.saveAs(relativePath: relativePath)
            _ = tabs.updateEditorPath(worktreeId: worktreeId, tabId: context.tab.id, relativePath: relativePath)
        } catch {
            showFileActionError(title: "Save As Failed", message: error.localizedDescription)
        }
    }

    func renameActiveFile(worktreeId: String) {
        guard let worktree = worktree(withId: worktreeId),
              let context = tabs.activeEditorContext(worktreeId: worktreeId) else { return }
        let currentURL = worktree.path.appendingPathComponent(context.tab.relativePath)
        let panel = NSSavePanel()
        panel.title = "Rename File"
        panel.message = "Choose the new path for this file."
        panel.directoryURL = currentURL.deletingLastPathComponent()
        panel.nameFieldStringValue = currentURL.lastPathComponent
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }

        do {
            let relativePath = try relativePath(for: url, in: worktree.path)
            guard relativePath != context.tab.relativePath else { return }
            try context.buffer.moveTo(relativePath: relativePath)
            _ = tabs.updateEditorPath(worktreeId: worktreeId, tabId: context.tab.id, relativePath: relativePath)
        } catch {
            showFileActionError(title: "Rename File Failed", message: error.localizedDescription)
        }
    }

    func renameTerminalTab(worktreeId: String, tabId: TabID) {
        guard let tab = tabs.tabs(forWorktree: worktreeId).first(where: { $0.id == tabId }),
              case .terminal(let state) = tab else { return }

        let alert = NSAlert()
        alert.messageText = "Rename Terminal"
        alert.informativeText = "Choose a stable name for this terminal tab."
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Rename")
        alert.addButton(withTitle: "Cancel")

        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 280, height: 24))
        field.stringValue = state.title
        field.lineBreakMode = .byTruncatingTail
        alert.accessoryView = field

        guard alert.runModal() == .alertFirstButtonReturn else { return }
        _ = tabs.renameTerminal(worktreeId: worktreeId, tabId: tabId, title: field.stringValue)
    }

    func closeTab(worktreeId: String, tabId: TabID) {
        let allTabs = tabs.tabs(forWorktree: worktreeId)
        if let tab = allTabs.first(where: { $0.id == tabId }) {
            if case .terminal(let s) = tab {
                harness.detector.unregister(sessionId: s.sessionId)
                harness.forgetSession(s.sessionId)
                terminal.closeSession(id: s.sessionId)
            }
            if case .editor = tab {
                tabs.discardBuffer(worktreeId: worktreeId, tabId: tabId)
            }
        }
        tabs.close(worktreeId: worktreeId, tabId: tabId)
    }

    private func cleanupTerminals(allTabs: [Tab], tabIds: [TabID]) {
        for id in tabIds {
            if let tab = allTabs.first(where: { $0.id == id }),
               case .terminal(let s) = tab {
                harness.detector.unregister(sessionId: s.sessionId)
                harness.forgetSession(s.sessionId)
                terminal.closeSession(id: s.sessionId)
            }
        }
    }

    private func cleanupClosedEditorBuffers(worktreeId: String, allTabs: [Tab], closedIds: [TabID]) {
        for id in closedIds {
            if let tab = allTabs.first(where: { $0.id == id }), case .editor = tab {
                tabs.discardBuffer(worktreeId: worktreeId, tabId: id)
            }
        }
    }

    func closeOtherTabs(worktreeId: String, keeping tabId: TabID) {
        let allTabs = tabs.tabs(forWorktree: worktreeId)
        let closed = tabs.closeOthers(worktreeId: worktreeId, keeping: tabId)
        cleanupTerminals(allTabs: allTabs, tabIds: closed)
        cleanupClosedEditorBuffers(worktreeId: worktreeId, allTabs: allTabs, closedIds: closed)
    }

    /// Tear down every tab/terminal/harness reference for a worktree id without
    /// touching git or persistence. Shared between Close-All, archive, and
    /// delete so the bookkeeping stays in one place.
    private func cleanupWorktreeState(worktreeId: String) {
        let allTabs = tabs.tabs(forWorktree: worktreeId)
        let closed = tabs.closeAll(worktreeId: worktreeId)
        cleanupTerminals(allTabs: allTabs, tabIds: closed)
        cleanupClosedEditorBuffers(worktreeId: worktreeId, allTabs: allTabs, closedIds: closed)
    }

    func closeAllTabs(worktreeId: String) {
        cleanupWorktreeState(worktreeId: worktreeId)
    }

    func closeTabsToLeft(worktreeId: String, of tabId: TabID) {
        let allTabs = tabs.tabs(forWorktree: worktreeId)
        let closed = tabs.closeToLeft(worktreeId: worktreeId, of: tabId)
        cleanupTerminals(allTabs: allTabs, tabIds: closed)
        cleanupClosedEditorBuffers(worktreeId: worktreeId, allTabs: allTabs, closedIds: closed)
    }

    func closeTabsToRight(worktreeId: String, of tabId: TabID) {
        let allTabs = tabs.tabs(forWorktree: worktreeId)
        let closed = tabs.closeToRight(worktreeId: worktreeId, of: tabId)
        cleanupTerminals(allTabs: allTabs, tabIds: closed)
        cleanupClosedEditorBuffers(worktreeId: worktreeId, allTabs: allTabs, closedIds: closed)
    }

    @discardableResult
    private func replaceMissingTerminalSession(worktreeId: String, tab: TerminalTabState) throws -> Tab {
        guard let worktree = worktree(withId: worktreeId),
              let project = projects.first(where: { $0.id == worktree.projectId }) else {
            throw NSError(domain: "AppState", code: 2)
        }

        let oldSessionId = tab.sessionId
        let session = try terminal.openSession(
            worktree: worktree, project: project,
            cfg: config.terminal, theme: themeStore.current
        )
        harness.detector.unregister(sessionId: oldSessionId)
        harness.forgetSession(oldSessionId)
        harness.detector.register(sessionId: session.id) { [weak session] in
            session?.surface.foregroundPid
        }
        guard let replacement = tabs.replaceTerminalSession(
            worktreeId: worktreeId,
            tabId: tab.id,
            sessionId: session.id
        ) else {
            terminal.closeSession(id: session.id)
            throw NSError(domain: "AppState", code: 3)
        }
        return replacement
    }

    private func defaultTerminalTitle(for worktree: Worktree) -> String {
        let folder = worktree.path.lastPathComponent.trimmingCharacters(in: .whitespacesAndNewlines)
        if !folder.isEmpty { return folder }
        let name = worktree.name.trimmingCharacters(in: .whitespacesAndNewlines)
        if !name.isEmpty { return name }
        let branch = worktree.branch.trimmingCharacters(in: .whitespacesAndNewlines)
        return branch.isEmpty ? "Terminal" : branch
    }

    private func worktree(withId id: String) -> Worktree? {
        for project in projects {
            if let worktree = projectsManager.worktrees(projectId: project.id).first(where: { $0.id == id }) {
                return worktree
            }
        }
        return nil
    }

    /// Pick a sensible new selection after a worktree was removed (archived or
    /// deleted) from the given project at the given index in its visible list.
    /// Prefers the entry now occupying that index in the same project (i.e.
    /// what was the next sibling). Falls back to the new last entry if the
    /// removed worktree was the last one. If the project has no remaining
    /// visible worktrees, picks the first visible worktree across all projects
    /// in declaration order. Returns `nil` if nothing is left.
    private func selectionAfterRemoval(removedFromProjectId: String, removedAtIndex: Int) -> String? {
        let siblings = projectsManager.visibleWorktrees(projectId: removedFromProjectId)
        if !siblings.isEmpty {
            let i = min(removedAtIndex, siblings.count - 1)
            return siblings[i].id
        }
        for project in projects {
            if let first = projectsManager.visibleWorktrees(projectId: project.id).first {
                return first.id
            }
        }
        return nil
    }

    private func makeSearchEnvironment() -> SearchEnvironment {
        // Invariant: the two synchronous closures below are only invoked
        // from `SearchModel`, which is `@MainActor` — so `assumeIsolated`
        // is sound. If a future caller invokes them off-main this will
        // trap; keep them on main or convert to async.
        SearchEnvironment(
            currentWorktreeId: { [weak self] in
                MainActor.assumeIsolated { self?.selectedWorktreeId }
            },
            allWorktrees: { [weak self] in
                MainActor.assumeIsolated {
                    guard let self else { return [] }
                    var out: [SearchWorktree] = []
                    for project in self.projects {
                        for wt in self.projectsManager.visibleWorktrees(projectId: project.id) {
                            out.append(SearchWorktree(
                                id: wt.id,
                                projectId: project.id,
                                displayName: wt.branch,
                                absolutePath: wt.path
                            ))
                        }
                    }
                    return out
                }
            },
            entries: { [fileIndex] wt in
                try await fileIndex.entries(forWorktreePath: wt.absolutePath)
            },
            statuses: { [statusCache] wt in
                try await statusCache.statuses(forWorktreePath: wt.absolutePath)
            },
            contentSearch: { [contentSearcher = ContentSearcher()] query, options, targets in
                contentSearcher.search(query: query, options: options, worktrees: targets)
            }
        )
    }

    /// Open a file in the right-pane code editor by routing through the
    /// existing tabs system. Switches `selectedWorktreeId` if the file is
    /// in a different worktree.
    func openFile(relativePath: String, worktreeId: String) {
        guard let worktree = worktree(withId: worktreeId) else { return }
        // Reject archived worktrees: their ids may still appear in some legacy
        // call sites (e.g. older persisted tabs). Selecting one would set
        // `selectedWorktreeId` to a hidden id that `RootView.selectedWorktree()`
        // (now visibility-aware) would reject anyway, leaving an empty pane.
        guard !projectsManager.isWorktreeHidden(projectId: worktree.projectId, path: worktree.path) else { return }
        if selectedWorktreeId != worktree.id { selectedWorktreeId = worktree.id }

        if ImageFileType.isSupported(relativePath: relativePath) {
            _ = tabs.openImagePreview(worktreeId: worktree.id, relativePath: relativePath)
            return
        }

        let existing = tabs.tabs(forWorktree: worktree.id).first { tab in
            if case .editor(let s) = tab { return s.relativePath == relativePath } else { return false }
        }
        if let existing {
            tabs.activate(worktreeId: worktree.id, tabId: existing.id)
        } else {
            let tab = tabs.appendEditor(
                worktreeId: worktree.id,
                title: (relativePath as NSString).lastPathComponent,
                relativePath: relativePath
            )
            tabs.activate(worktreeId: worktree.id, tabId: tab.id)
        }
    }

    /// Open a markdown relative-link target as a new editor tab in the same worktree.
    /// Delegates to `openFile` which handles find-or-create, activate, and
    /// worktree-switch if necessary.
    func openMarkdownLink(worktreeId: String, worktreeRoot: URL, relativePath: String) {
        openFile(relativePath: relativePath, worktreeId: worktreeId)
    }

    private func relativePath(for url: URL, in worktreeRoot: URL) throws -> String {
        let root = worktreeRoot.standardizedFileURL.path
        let target = url.standardizedFileURL.path
        let rootWithSlash = root.hasSuffix("/") ? root : root + "/"
        guard target.hasPrefix(rootWithSlash) else {
            throw NSError(
                domain: "AppState",
                code: 4,
                userInfo: [NSLocalizedDescriptionKey: "File must be inside the selected worktree."]
            )
        }
        let rel = String(target.dropFirst(rootWithSlash.count))
        guard !rel.isEmpty, !rel.split(separator: "/").contains("..") else {
            throw NSError(
                domain: "AppState",
                code: 5,
                userInfo: [NSLocalizedDescriptionKey: "Invalid file path."]
            )
        }
        return rel
    }

    private func showFileActionError(title: String, message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    /// Delete a worktree from disk. Shows a confirm dialog; on dirty-tree
    /// failure offers a force retry. Cleans up in-app state on success.
    func deleteWorktree(_ worktree: Worktree) {
        let dirty = dirtyEditorTabIds(worktreeId: worktree.id)
        let saveBuffersFirst: Bool
        if dirty.isEmpty {
            guard confirmDeleteWorktree(branch: worktree.branch) else { return }
            saveBuffersFirst = false
        } else {
            switch promptForDirtyBuffers(
                action: "Delete",
                branch: worktree.branch,
                dirtyCount: dirty.count,
                onDiskDestructive: true
            ) {
            case .save: saveBuffersFirst = true
            case .discard: saveBuffersFirst = false
            case .cancel: return
            }
        }
        if saveBuffersFirst {
            guard saveDirtyBuffers(in: worktree) else { return }
        }
        guard let project = projects.first(where: { $0.id == worktree.projectId }) else {
            showFileActionError(title: "Delete Failed", message: "Could not find the project for this worktree.")
            return
        }
        let repoPath = URL(fileURLWithPath: project.path)
        let deleteBranch = config.worktrees.deleteBranchOnRemove

        // Snapshot for selection follow-up. The index must be captured BEFORE
        // the await because the worktree won't be in `visibleWorktrees` after
        // `refreshWorktrees`. We re-check selection (live) post-await so a
        // selection change during the dialog/await flow isn't clobbered.
        let siblingsBefore = projectsManager.visibleWorktrees(projectId: worktree.projectId)
        let removedIndex = siblingsBefore.firstIndex(where: { $0.id == worktree.id }) ?? 0

        Task { @MainActor in
            let svc = WorktreeService()
            do {
                try await svc.remove(
                    repoPath: repoPath,
                    worktree: worktree,
                    deleteBranchIfMerged: deleteBranch,
                    force: false
                )
            } catch let WorktreeService.WorktreeError.gitFailed(stderr) {
                if Self.looksLikeDirtyWorktreeError(stderr) {
                    guard confirmForceDeleteWorktree(branch: worktree.branch) else { return }
                    do {
                        try await svc.remove(
                            repoPath: repoPath,
                            worktree: worktree,
                            deleteBranchIfMerged: deleteBranch,
                            force: true
                        )
                    } catch let WorktreeService.WorktreeError.gitFailed(stderr) {
                        showFileActionError(title: "Delete Failed", message: stderr)
                        return
                    } catch {
                        showFileActionError(title: "Delete Failed", message: "\(error)")
                        return
                    }
                } else {
                    showFileActionError(title: "Delete Failed", message: stderr)
                    return
                }
            } catch {
                showFileActionError(title: "Delete Failed", message: "\(error)")
                return
            }

            cleanupWorktreeState(worktreeId: worktree.id)
            if (try? await projectsManager.refreshWorktrees(projectId: worktree.projectId)) == true {
                saveProjects()
            }
            if selectedWorktreeId == worktree.id {
                selectedWorktreeId = selectionAfterRemoval(
                    removedFromProjectId: worktree.projectId,
                    removedAtIndex: removedIndex
                )
            }
        }
    }

    /// Permissive substring check: git's exact wording around dirty/locked
    /// worktrees varies by version. If the match misses, the caller surfaces
    /// the raw stderr instead, which is acceptable degradation.
    private static func looksLikeDirtyWorktreeError(_ stderr: String) -> Bool {
        let s = stderr.lowercased()
        return s.contains("is dirty")
            || s.contains("contains modified or untracked files")
            || s.contains("modified or untracked")
    }

    private func confirmDeleteWorktree(branch: String) -> Bool {
        let alert = NSAlert()
        alert.messageText = "Delete worktree '\(branch)'?"
        alert.informativeText = "This removes its files from disk. The local branch will be deleted if merged."
        alert.alertStyle = .warning
        let deleteButton = alert.addButton(withTitle: "Delete")
        alert.addButton(withTitle: "Cancel")
        deleteButton.hasDestructiveAction = true
        return alert.runModal() == .alertFirstButtonReturn
    }

    private func confirmForceDeleteWorktree(branch: String) -> Bool {
        let alert = NSAlert()
        alert.messageText = "'\(branch)' has uncommitted changes."
        alert.informativeText = "Force delete? Any uncommitted work in this worktree will be lost."
        alert.alertStyle = .warning
        let forceButton = alert.addButton(withTitle: "Force Delete")
        alert.addButton(withTitle: "Cancel")
        forceButton.hasDestructiveAction = true
        return alert.runModal() == .alertFirstButtonReturn
    }

    private enum DirtyBufferChoice {
        case save
        case discard
        case cancel
    }

    /// Returns the editor tabs in this worktree whose buffers have unsaved
    /// changes — including tabs whose buffers are not yet instantiated but
    /// have a persisted hot-exit snapshot on disk.
    private func dirtyEditorTabIds(worktreeId: String) -> [TabID] {
        tabs.tabIdsWithUnsavedChanges(forWorktree: worktreeId)
    }

    /// Three-way prompt for actions (archive, delete) that would otherwise
    /// silently discard unsaved editor buffers. The default button (Enter)
    /// is "Save & <action>"; the destructive button is "Discard & <action>".
    /// `onDiskDestructive` true means `<action>` will also remove files from
    /// disk; the message text adjusts accordingly.
    private func promptForDirtyBuffers(
        action: String,
        branch: String,
        dirtyCount: Int,
        onDiskDestructive: Bool
    ) -> DirtyBufferChoice {
        let alert = NSAlert()
        alert.messageText = "\(action) worktree '\(branch)'?"
        let countSentence = dirtyCount == 1
            ? "1 file has unsaved changes."
            : "\(dirtyCount) files have unsaved changes."
        let actionSentence = onDiskDestructive
            ? "This removes its files from disk. The local branch will be deleted if merged."
            : "The worktree itself stays on disk."
        alert.informativeText = "\(countSentence) Saving will write them to disk; discarding will lose them. \(actionSentence)"
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Save & \(action)")
        let discardButton = alert.addButton(withTitle: "Discard & \(action)")
        alert.addButton(withTitle: "Cancel")
        discardButton.hasDestructiveAction = true
        switch alert.runModal() {
        case .alertFirstButtonReturn: return .save
        case .alertSecondButtonReturn: return .discard
        default: return .cancel
        }
    }

    /// Save every dirty editor buffer in the given worktree — including tabs
    /// whose buffers are not yet instantiated but have a persisted hot-exit
    /// snapshot on disk. Returns true on full success; on partial failure
    /// surfaces an aggregate error and returns false so the caller can bail
    /// before the destructive cleanup.
    private func saveDirtyBuffers(in worktree: Worktree) -> Bool {
        let errors = tabs.saveAllUnsaved(forWorktree: worktree.id, root: worktree.path)
        if !errors.isEmpty {
            let count = errors.count
            showFileActionError(
                title: "Save Failed",
                message: "\(count) file\(count == 1 ? "" : "s") could not be saved. The worktree was not archived or deleted."
            )
            return false
        }
        return true
    }
}
