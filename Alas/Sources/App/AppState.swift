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

    /// All worktree IDs currently known to the projects manager (including
    /// hidden/archived ones).
    func allWorktreeIds() -> Set<String> {
        Set(projectsManager.projects.flatMap {
            projectsManager.worktrees(projectId: $0.id).map(\.id)
        })
    }

    /// Tear down tabs, terminals, harness state, and editor buffers for any
    /// worktree IDs that existed in `beforeIds` but are absent after a refresh.
    /// Also re-points selection if the selected worktree was removed.
    func cleanupMissingWorktrees(beforeIds: Set<String>) {
        let afterIds = allWorktreeIds()
        let disappeared = beforeIds.subtracting(afterIds)
        for id in disappeared {
            cleanupWorktreeState(worktreeId: id)
        }
        if let current = selectedWorktreeId, !afterIds.contains(current) {
            selectedWorktreeId = firstVisibleWorktreeId()
        }
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

    func updateProject(id: String, name: String, color: String, startupScripts: ProjectStartupScripts) {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else { return }

        projectsManager.updateProject(
            id: id,
            update: ProjectUpdate(
                name: trimmedName,
                color: color,
                startupScripts: startupScripts
            )
        )
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
        LegacyHookSweep.sweepAll()
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
        terminal.socketPath = harness.socketServer.socketPath
        harness.onClickThrough = { [weak self] projectId, worktreeId, sessionId in
            self?.activateHarnessSession(
                projectId: projectId, worktreeId: worktreeId, sessionId: sessionId
            )
        }
    }

    /// Activate a specific harness session: bring the app to front, select
    /// the worktree, activate the terminal tab hosting `sessionId`, and
    /// focus the pane within that tab that owns the session (so keyboard
    /// input and the tab-bar harness badge follow the user's intent).
    /// If the tab is no longer present (session was closed mid-flight) the
    /// worktree is still selected so the user lands somewhere sensible.
    func activateHarnessSession(projectId _: String, worktreeId: String, sessionId: String) {
        selectedWorktreeId = worktreeId
        var matchedTabId: TabID?
        var matchedLeafId: String?
        for tab in tabs.tabs(forWorktree: worktreeId) {
            guard case .terminal(let s) = tab,
                  let leaf = s.root.leaves().first(where: { $0.sessionId == sessionId }) else { continue }
            matchedTabId = tab.id
            matchedLeafId = leaf.id
            break
        }
        if let tabId = matchedTabId {
            if let leafId = matchedLeafId {
                _ = tabs.setFocusedLeaf(worktreeId: worktreeId, tabId: tabId, leafId: leafId)
            }
            tabs.activate(worktreeId: worktreeId, tabId: tabId)
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

    // MARK: - Pane splits

    /// Per-tab cache of leaf frames, written by `SplitContainer` during layout
    /// and read by `focusPane`. Keyed by tab id; inner dictionary maps leaf id
    /// to its on-screen rect within the tab's coordinate space.
    @ObservationIgnored
    var terminalLeafFrames: [TabID: [String: CGRect]] = [:]

    /// Split the focused pane of the active terminal tab on `worktreeId`. The
    /// new pane gains focus, inherits the focused pane's current OSC-7 cwd
    /// (falling back to its lastCwd, then the worktree root) and runs a plain
    /// shell — harness state is not inherited.
    func splitFocusedPane(worktreeId: String, axis: SplitAxis) {
        guard let activeId = tabs.activeTabId(forWorktree: worktreeId),
              let tab = tabs.tabs(forWorktree: worktreeId).first(where: { $0.id == activeId }),
              case .terminal(let state) = tab,
              let focused = state.root.find(leafId: state.focusedLeafId)?.leaf,
              let worktree = worktree(withId: worktreeId),
              let project = projects.first(where: { $0.id == worktree.projectId }),
              let focusedSession = terminal.registry.session(for: focused.sessionId) else { return }

        let cwd = focusedSession.surface.currentWorkingDirectory
            ?? focused.lastCwd.map { URL(fileURLWithPath: $0) }
            ?? worktree.path

        do {
            let session = try terminal.openSession(
                worktree: worktree, project: project,
                cfg: config.terminal, theme: themeStore.current,
                forcedCwd: cwd
            )
            harness.detector.register(sessionId: session.id) { [weak session] in
                session?.surface.foregroundPid
            }
            _ = tabs.splitFocusedLeaf(
                worktreeId: worktreeId, tabId: activeId, axis: axis,
                newLeafId: UUID().uuidString, newSessionId: session.id
            )
        } catch {
            AlasGhostty.logger.error("splitFocusedPane failed: \(String(describing: error), privacy: .public)")
        }
    }

    /// Close the focused pane. If it was the last leaf, also closes the tab
    /// via the existing close-tab path (preserves today's ⌘W-on-unsplit
    /// behavior).
    func closeFocusedPane(worktreeId: String) {
        guard let activeId = tabs.activeTabId(forWorktree: worktreeId),
              let tab = tabs.tabs(forWorktree: worktreeId).first(where: { $0.id == activeId }),
              case .terminal = tab else { return }
        guard let outcome = tabs.removeFocusedLeaf(worktreeId: worktreeId, tabId: activeId) else { return }
        if case .tabRemoved = outcome {
            closeTab(worktreeId: worktreeId, tabId: activeId)
        } else {
            let closedSessionId = outcome.closedSessionId
            terminal.closeSession(id: closedSessionId)
            harness.detector.unregister(sessionId: closedSessionId)
            harness.forgetSession(closedSessionId)
        }
    }

    /// Move focus to the geometrically nearest leaf in `direction`. No-op when
    /// no candidate exists (no wrap-around).
    func focusPane(worktreeId: String, direction: PaneFocusDirection) {
        guard let activeId = tabs.activeTabId(forWorktree: worktreeId),
              let tab = tabs.tabs(forWorktree: worktreeId).first(where: { $0.id == activeId }),
              case .terminal(let state) = tab,
              let frames = terminalLeafFrames[activeId],
              let next = PaneFocusFinder.nearestLeaf(
                from: state.focusedLeafId, direction: direction, frames: frames
              ) else { return }
        _ = tabs.setFocusedLeaf(worktreeId: worktreeId, tabId: activeId, leafId: next)
    }

    /// Resize the focused leaf's enclosing split by ±0.05 toward `direction`.
    /// Picks the innermost split on the focused-leaf's path whose axis matches
    /// the direction's axis; nudges its fraction (positive when the focused
    /// pane is the first child and direction is right/down).
    func resizePane(worktreeId: String, direction: PaneFocusDirection) {
        guard let activeId = tabs.activeTabId(forWorktree: worktreeId),
              let tab = tabs.tabs(forWorktree: worktreeId).first(where: { $0.id == activeId }),
              case .terminal(let state) = tab,
              let pathLeaf = state.root.find(leafId: state.focusedLeafId) else { return }
        let axis: SplitAxis = (direction == .left || direction == .right) ? .vertical : .horizontal
        guard let target = innermostSplit(matching: axis, path: pathLeaf.path, in: state.root) else { return }
        let isFirstChildOfTarget = isLeafInFirstChild(of: target, leafId: state.focusedLeafId)
        let delta = 0.05
        let signed: Double = {
            switch direction {
            case .right, .down: return isFirstChildOfTarget ? delta : -delta
            case .left, .up:    return isFirstChildOfTarget ? -delta : delta
            }
        }()
        let newFraction = target.fraction + signed
        _ = tabs.setSplitFraction(worktreeId: worktreeId, tabId: activeId, splitId: target.id, fraction: newFraction)
    }

    /// ⌘W router: if the active tab is a multi-pane terminal, close the focused
    /// pane; otherwise fall through to the existing tab-close behavior.
    func handleCloseShortcut(worktreeId: String) {
        if let activeId = tabs.activeTabId(forWorktree: worktreeId),
           let tab = tabs.tabs(forWorktree: worktreeId).first(where: { $0.id == activeId }),
           case .terminal(let state) = tab,
           case .split = state.root {
            closeFocusedPane(worktreeId: worktreeId)
            return
        }
        if let activeId = tabs.activeTabId(forWorktree: worktreeId) {
            closeTab(worktreeId: worktreeId, tabId: activeId)
        }
    }

    /// Walk down `path` collecting splits; return the innermost one whose
    /// axis matches `axis`. `path` is the list of split ids from root to (but
    /// not including) the focused leaf.
    private func innermostSplit(matching axis: SplitAxis, path: [String], in root: PaneNode) -> PaneSplit? {
        var current: PaneNode = root
        var match: PaneSplit? = nil
        for (index, splitId) in path.enumerated() {
            guard case .split(let s) = current, s.id == splitId else { return match }
            if s.axis == axis { match = s }
            let nextId: String? = (index + 1 < path.count) ? path[index + 1] : nil
            if let next = nextId {
                guard let child = s.children.first(where: { containsNode(id: next, in: $0) }) else { return match }
                current = child
            } else {
                return match
            }
        }
        return match
    }

    private func isLeafInFirstChild(of split: PaneSplit, leafId: String) -> Bool {
        split.children.first?.find(leafId: leafId) != nil
    }

    private func containsNode(id: String, in node: PaneNode) -> Bool {
        if node.id == id { return true }
        if case .split(let s) = node {
            return s.children.contains(where: { containsNode(id: id, in: $0) })
        }
        return false
    }

    /// Walk every leaf in the tab's tree and recreate any session whose
    /// `TerminalSession` is no longer alive (e.g., after relaunch).
    ///
    /// **Partial-failure contract:** if `openSession` throws midway through the
    /// walk, leaves processed up to that point have already been persisted with
    /// their new sessionIds. Re-calling this method is safe — already-restored
    /// leaves are skipped, and the failing leaf is retried.
    @discardableResult
    func restoreTerminalTabIfNeeded(worktreeId: String, tabId: TabID) throws -> Tab? {
        guard let tab = tabs.tabs(forWorktree: worktreeId).first(where: { $0.id == tabId }),
              case .terminal(let state) = tab,
              let worktree = worktree(withId: worktreeId),
              let project = projects.first(where: { $0.id == worktree.projectId }) else { return nil }

        for leaf in state.root.leaves() {
            if terminal.registry.session(for: leaf.sessionId) != nil { continue }
            let forcedCwd = leaf.lastCwd.map { URL(fileURLWithPath: $0) }
            let session = try terminal.openSession(
                worktree: worktree, project: project,
                cfg: config.terminal, theme: themeStore.current,
                forcedCwd: forcedCwd
            )
            harness.detector.unregister(sessionId: leaf.sessionId)
            harness.forgetSession(leaf.sessionId)
            harness.detector.register(sessionId: session.id) { [weak session] in
                session?.surface.foregroundPid
            }
            _ = tabs.replaceLeafSession(
                worktreeId: worktreeId, tabId: tabId, leafId: leaf.id, sessionId: session.id
            )
        }
        return tabs.tabs(forWorktree: worktreeId).first(where: { $0.id == tabId })
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
                for leaf in s.root.leaves() {
                    harness.detector.unregister(sessionId: leaf.sessionId)
                    harness.forgetSession(leaf.sessionId)
                    terminal.closeSession(id: leaf.sessionId)
                }
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
                for leaf in s.root.leaves() {
                    harness.detector.unregister(sessionId: leaf.sessionId)
                    harness.forgetSession(leaf.sessionId)
                    terminal.closeSession(id: leaf.sessionId)
                }
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

    var activeTab: Tab? {
        guard let worktreeId = selectedWorktreeId else { return nil }
        return tabs.activeTab(forWorktree: worktreeId)
    }

    var hasActiveEditorTab: Bool {
        guard case .editor = activeTab else { return false }
        return true
    }

    var hasAnyDirtyEditorTab: Bool {
        var result = false
        for project in projects {
            for worktree in projectsManager.worktrees(projectId: project.id) {
                for tab in tabs.tabs(forWorktree: worktree.id) {
                    guard case .editor(let state) = tab else { continue }
                    if let buffer = tabs.peekBuffer(tabId: state.id) {
                        _ = buffer.editGeneration
                        if buffer.dirty { result = true }
                    }
                }
            }
        }
        return result
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

    func firstVisibleWorktreeId() -> String? {
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
