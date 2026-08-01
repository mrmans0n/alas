import AppKit
import SwiftUI

struct NewWorktreePresentation: Identifiable, Equatable {
    let id = UUID()
    let projectId: String?
}

private struct CommitReviewSessionLaunchError: Identifiable, Equatable {
    let id = UUID()
    let message: String
}

struct RootView: View {
    @Bindable var state: AppState
    @State private var showNewProject = false
    @State private var editingProject: ProjectConfig?
    @State private var removingProject: ProjectConfig?
    @State private var newWorktreePresentation: NewWorktreePresentation?
    @State private var newMissionPresentation: NewMissionPresentation?
    @State private var commitReviewSessionLaunchError: CommitReviewSessionLaunchError?
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        rootContent
            .environment(\.theme, state.themeStore.current)
            .onChange(of: state.themeStore.current.id, initial: true) { _, _ in
                // `initial: true` is load-bearing: AppState.init() calls
                // WindowAppearance.apply too, but that runs before the SwiftUI
                // Window's NSWindow exists, so the per-window appearance never
                // gets set. Without firing on first appearance, light-mode
                // launches render half-dark until the user toggles the theme.
                WindowAppearance.apply(darkMode: state.themeStore.current.darkMode)
            }
            .onChange(of: state.themeStore.current, initial: true) { _, theme in
                MermaidDiagramViewerController.shared.updateTheme(theme)
            }
            .background(WindowConfigurator(disablesSystemDrag: true))
            .frame(minWidth: 700, minHeight: 600)
            .ignoresSafeArea()
            .modifier(RootCommandHandlers(
                state: state,
                newWorktreePresentation: $newWorktreePresentation,
                showNewProject: $showNewProject,
                selectedWorktree: selectedWorktree,
                openSettings: openSettingsWindow
            ))
            .modifier(RootPresentationHandlers(
                state: state,
                showNewProject: $showNewProject,
                editingProject: $editingProject,
                removingProject: $removingProject,
                newWorktreePresentation: $newWorktreePresentation,
                newMissionPresentation: $newMissionPresentation
            ))
            .alert(
                "Could not open review session",
                isPresented: Binding(
                    get: { commitReviewSessionLaunchError != nil },
                    set: { if !$0 { commitReviewSessionLaunchError = nil } }
                ),
                presenting: commitReviewSessionLaunchError
            ) { _ in
                Button("OK", role: .cancel) {
                    commitReviewSessionLaunchError = nil
                }
            } message: { error in
                Text(error.message)
            }
            .task {
                state.startHarness()
                _ = await state.refreshAllProjectTopologies()
                // Worktrees now exist — load any persisted tab files for them. Init
                // can't do this because refreshAll runs async after init.
                state.reloadTabs()
                await state.reconcileMissionsForStartup()
                if state.selectedWorktreeId == nil {
                    state.selectWorktree(id: state.resolvedSelectionForActiveSpaceForStartup())
                }
                state.startAllProjectGitWatchers()
                state.rescanAgents()
            }
    }

    private var rootContent: some View {
        ZStack {
            mainContent
            FileSearchDialog(appState: state)
            RepoSelectorDialog(appState: state)
            AgentLauncherDialog(appState: state, selectedWorktree: selectedWorktree)
            ReviewTargetDialog(appState: state)
            RunScriptDialog(appState: state, selectedWorktree: selectedWorktree)
        }
    }

    @ViewBuilder
    private var mainContent: some View {
        if state.projects.isEmpty {
            EmptyState(
                canCreateWorktree: false,
                onAddProject: { showNewProject = true },
                onNewWorktree: { newWorktreePresentation = NewWorktreePresentation(projectId: nil) }
            )
        } else {
            ThreePaneLayout(
                sidebarWidth: Binding(
                    get: { state.config.sidebarWidth },
                    set: { state.config.sidebarWidth = $0 }
                ),
                rightWidth: Binding(
                    get: { state.config.rightPaneWidth },
                    set: { state.config.rightPaneWidth = $0 }
                ),
                sidebarVisible: state.config.sidebarVisible,
                rightVisible: state.config.rightPaneVisible,
                onWidthsChanged: { state.saveConfig() },
                sidebar: { sidebarContent },
                center: { centerContent() },
                right: { rightContent }
            )
        }
    }

    private var sidebarContent: some View {
        SidebarView(
            state: state,
            collapsedProjects: Binding(
                get: { Set(state.config.collapsedProjectIds) },
                set: { collapsedProjects in
                    state.config.collapsedProjectIds = collapsedProjects.sorted()
                    state.saveConfig()
                }
            ),
            onSettings: { openSettingsWindow() },
            onAddProject: { showNewProject = true },
            onEditProject: { projectId in
                editingProject = state.projects.first { $0.id == projectId }
            },
            onRemoveProject: { projectId in
                removingProject = state.projects.first { $0.id == projectId }
            },
            onNewWorktree: { projectId in
                newWorktreePresentation = NewWorktreePresentation(projectId: projectId)
            },
            onHideSidebar: {
                state.config.sidebarVisible = false
                state.saveConfig()
            }
        )
    }

    @ViewBuilder
    private var rightContent: some View {
        let resolver = RightPaneSelectionStateResolver(
            selectedWorktreeId: state.selectedWorktreeId,
            projects: state.activeSpaceProjects,
            projectsManager: state.projectsManager
        )
        switch resolver.resolve() {
        case .empty:
            EmptyView()
        case .active(let wt):
            RightPaneView(
                state: state,
                worktree: wt,
                onSelectChangedFile: { file in
                    openOrFocusDiff(
                        worktree: wt,
                        path: file.path,
                        staged: file.stage == .staged,
                        originalPath: file.renameFrom
                    )
                },
                onSelectTreeFile: { node in
                    openOrFocusEditor(worktree: wt, path: node.path)
                },
                onSelectCommit: { commit in
                    openOrFocusCommit(worktree: wt, commit: commit)
                },
                onEditCommit: { commit, baseRef in
                    openOrFocusCommitEditor(worktree: wt, commit: commit, baseRef: baseRef)
                },
                onReviewCommit: { commit in
                    openOrFocusCommitReviewSession(worktree: wt, commit: commit)
                }
            )
        case .creating(let wt):
            RightPaneTransitionalView(state: state, worktree: wt, kind: .creating)
        case .deleting(let wt):
            RightPaneTransitionalView(state: state, worktree: wt, kind: .deleting)
        case .createFailed(let wt):
            RightPaneTransitionalView(state: state, worktree: wt, kind: .createFailed)
        }
    }

    private func openSettingsWindow() {
        openWindow(id: "settings")
    }

    @ViewBuilder
    private func centerContent() -> some View {
        let resolver = CenterSelectionStateResolver(
            selectedWorktreeId: state.selectedWorktreeId,
            projects: state.activeSpaceProjects,
            projectsManager: state.projectsManager,
            allowsHiddenSelectedWorktree: allowsHiddenSelectedWorktreeForMission
        )
        switch resolver.resolve() {
        case .worktree(let wt):
            CenterPaneView(
                state: state,
                worktree: wt,
                allowsPaneFocus: !state.isKeyboardOverlayOpen
            )
        case .deleting(let wt):
            DeletingWorktreeView(worktree: wt)
        case .deleteFailed(let wt, let message):
            DeleteFailedWorktreeView(
                worktree: wt,
                message: message,
                onRetry: { state.deleteWorktree(wt) },
                onArchive: { state.archiveWorktree(wt) },
                onCopyError: {
                    let pb = NSPasteboard.general
                    pb.clearContents()
                    pb.setString(message, forType: .string)
                }
            )
        case .creating(let wt):
            CreatingWorktreeView(worktree: wt)
        case .empty:
            if let tabState = state.missingMissionTab {
                MissionTabView(state: state, worktree: nil, tabState: tabState)
            } else {
                EmptyTabView(
                    onNewTerminal: {},
                    onNewAgentTerminal: {},
                    onNewAgentChat: {},
                    newTerminalShortcut: nil,
                    newAgentTerminalShortcut: nil,
                    newAgentChatShortcut: nil
                )
            }
        }
    }

    private var allowsHiddenSelectedWorktreeForMission: Bool {
        guard let worktreeID = state.selectedWorktreeId,
              let tab = state.tabs.activeTab(forWorktree: worktreeID),
              case .mission = tab
        else { return false }
        return true
    }

    private func selectedWorktree() -> Worktree? {
        let resolver = RightPaneSelectionStateResolver(
            selectedWorktreeId: state.selectedWorktreeId,
            projects: state.activeSpaceProjects,
            projectsManager: state.projectsManager
        )
        if case .active(let wt) = resolver.resolve() { return wt }
        return nil
    }

    private func openOrFocusDiff(worktree: Worktree, path: String, staged: Bool, originalPath: String?) {
        if ImageFileType.isSupported(relativePath: path) {
            state.openFile(relativePath: path, worktreeId: worktree.id)
            return
        }

        state.openDiffTab(
            forFileInWorktree: worktree,
            relativePath: path,
            staged: staged,
            originalPath: originalPath,
            compareWithHEAD: false
        )
    }

    private func openOrFocusEditor(worktree: Worktree, path: String) {
        state.openFile(relativePath: path, worktreeId: worktree.id)
    }

    private func openOrFocusCommit(worktree: Worktree, commit: CommitInfo) {
        let existing = state.tabs.tabs(forWorktree: worktree.id).first { tab in
            if case .commit(let s) = tab { return s.sha == commit.sha } else { return false }
        }
        if let existing {
            state.tabs.activate(worktreeId: worktree.id, tabId: existing.id)
        } else {
            let title = "\(commit.shortSha) \(commit.subject)"
            let tab = state.tabs.appendCommit(worktreeId: worktree.id, sha: commit.sha, title: title)
            state.tabs.activate(worktreeId: worktree.id, tabId: tab.id)
        }
    }

    private func openOrFocusCommitEditor(worktree: Worktree, commit: CommitInfo, baseRef: String) {
        if let existing = state.tabs.commitEditorTab(worktreeId: worktree.id, currentSha: commit.sha) {
            state.tabs.activate(worktreeId: worktree.id, tabId: existing.id)
            return
        }

        let title = "\(commit.shortSha) \(commit.conventionalTag.map { "\($0): \(commit.subject)" } ?? commit.subject)"
        let tab = state.tabs.openCommitEditor(
            worktreeId: worktree.id,
            baseRef: baseRef,
            originalSha: commit.sha,
            currentSha: commit.sha,
            title: title
        )
        state.tabs.activate(worktreeId: worktree.id, tabId: tab.id)
    }

    static func commitReviewSessionTarget(worktree: Worktree, commit: CommitInfo) -> ReviewSessionTarget {
        CommitTabView.reviewSessionTarget(
            worktreeID: worktree.id,
            repositoryPath: worktree.path,
            sha: commit.sha,
            title: commit.subject
        )
    }

    @MainActor
    private func openOrFocusCommitReviewSession(worktree: Worktree, commit: CommitInfo) {
        let target = Self.commitReviewSessionTarget(worktree: worktree, commit: commit)
        let store = ReviewSessionStore()
        ReviewSessionLauncher.openOrFocus(
            target: target,
            findActive: { try store.findActive(targetID: $0) },
            save: { try store.save($0) },
            open: { record in
                commitReviewSessionLaunchError = nil
                state.tabs.openOrFocusReviewSession(worktreeId: worktree.id, record: record)
            },
            onFailure: { error in
                commitReviewSessionLaunchError = CommitReviewSessionLaunchError(
                    message: error.localizedDescription
                )
            }
        )
    }
}

private struct RootPresentationHandlers: ViewModifier {
    @Bindable var state: AppState
    @Binding var showNewProject: Bool
    @Binding var editingProject: ProjectConfig?
    @Binding var removingProject: ProjectConfig?
    @Binding var newWorktreePresentation: NewWorktreePresentation?
    @Binding var newMissionPresentation: NewMissionPresentation?

    func body(content: Content) -> some View {
        content
        .sheet(isPresented: $showNewProject) {
            NewProjectDialog(state: state, presented: $showNewProject)
        }
        .sheet(item: $editingProject) { project in
            EditProjectDialog(
                state: state,
                presented: Binding(
                    get: { editingProject != nil },
                    set: { if !$0 { editingProject = nil } }
                ),
                project: project
            )
        }
        .sheet(item: $newWorktreePresentation) { presentation in
            NewWorktreeDialog(
                state: state,
                presented: Binding(
                    get: { newWorktreePresentation != nil },
                    set: { if !$0 { newWorktreePresentation = nil } }
                ),
                presetProjectId: presentation.projectId
            )
        }
        .sheet(item: $newMissionPresentation) { _ in
            NewMissionDialog(
                presented: Binding(
                    get: { newMissionPresentation != nil },
                    set: { if !$0 { newMissionPresentation = nil } }
                ),
                projects: state.projects,
                environment: .live(state: state)
            )
        }
        .sheet(item: $state.pendingRunScriptCreation) { presentation in
            NewRunScriptDialog(
                state: state,
                presentation: presentation
            )
        }
        .alert(
            "'\(state.pendingForceDeleteWorktree?.branch ?? "")' \(state.pendingForceDeleteWorktree?.reason.alertTitleSuffix ?? "requires force delete.")",
            isPresented: Binding(
                get: { state.pendingForceDeleteWorktree != nil },
                set: { if !$0 { state.cancelForceDeletePendingWorktree() } }
            ),
            actions: {
                Button("Force Delete", role: .destructive) {
                    state.confirmForceDeletePendingWorktree()
                }
                Button("Cancel", role: .cancel) {
                    state.cancelForceDeletePendingWorktree()
                }
            },
            message: {
                Text(state.pendingForceDeleteWorktree?.reason.alertMessage ?? "Force delete?")
            }
        )
        .alert(
            "Remove \u{201C}\(removingProject?.name ?? "")\u{201D}?",
            isPresented: Binding(
                get: { removingProject != nil },
                set: { if !$0 { removingProject = nil } }
            ),
            presenting: removingProject,
            actions: { project in
                Button("Remove", role: .destructive) {
                    state.removeProject(id: project.id)
                    removingProject = nil
                }
                Button("Cancel", role: .cancel) {
                    removingProject = nil
                }
            },
            message: { _ in
                Text("Alas will stop tracking this project and its worktrees. No files will be deleted from disk. If any editor tabs have unsaved changes, you'll be asked to save or discard them.")
            }
        )
        .confirmationDialog(
            "Merge review request?",
            isPresented: Binding(
                get: { state.rightPaneStore.stateWithPendingMerge() != nil },
                set: { if !$0 { state.rightPaneStore.stateWithPendingMerge()?.cancelMerge() } }
            ),
            titleVisibility: .visible,
            presenting: state.rightPaneStore.stateWithPendingMerge()?.pendingMerge
        ) { snapshot in
            Button("Merge", role: .destructive) {
                state.rightPaneStore.stateWithPendingMerge()?.performMerge()
            }
            Button("Cancel", role: .cancel) {
                state.rightPaneStore.stateWithPendingMerge()?.cancelMerge()
            }
        } message: { snapshot in
            Text(RightPaneState.mergeConfirmationMessage(for: snapshot.reviewRequest))
        }
        .modifier(RootGGPresentationHandlers(state: state))
        .alert(
            "Merge failed",
            isPresented: Binding(
                get: { state.rightPaneStore.stateReportingMergeError() != nil },
                set: { if !$0 { state.rightPaneStore.stateReportingMergeError()?.clearMergeError() } }
            ),
            presenting: state.rightPaneStore.stateReportingMergeError()?.mergeError
        ) { _ in
            Button("OK", role: .cancel) {
                state.rightPaneStore.stateReportingMergeError()?.clearMergeError()
            }
        } message: { message in
            Text(message)
        }
        .alert(
            "Added to merge queue",
            isPresented: Binding(
                get: { state.rightPaneStore.stateReportingMergeQueuedMessage() != nil },
                set: { if !$0 { state.rightPaneStore.stateReportingMergeQueuedMessage()?.clearMergeQueuedMessage() } }
            ),
            presenting: state.rightPaneStore.stateReportingMergeQueuedMessage()?.mergeQueuedMessage
        ) { _ in
            Button("OK", role: .cancel) {
                state.rightPaneStore.stateReportingMergeQueuedMessage()?.clearMergeQueuedMessage()
            }
        } message: { message in
            Text(message)
        }
        .onAppear {
            state.updates.checkOnLaunch()
        }
        .sheet(item: Binding(
            get: { state.updates.presentedUpdate },
            set: { state.updates.presentedUpdate = $0 }
        ), onDismiss: {
            guard state.pendingSelfUpdate else { return }
            state.pendingSelfUpdate = false
            state.presentUpdateProgress = true
            Task {
                try? await state.selfUpdater.start(command: .homebrew)
            }
        }) { info in
            UpdateAvailableSheet(
                info: info,
                source: state.updates.track == .nightly ? .direct : state.updates.source,
                onDismiss: { state.updates.presentedUpdate = nil },
                onRunUpdate: {
                    state.pendingSelfUpdate = true
                    state.updates.presentedUpdate = nil
                }
            )
            .environment(\.theme, state.themeStore.current)
        }
        .sheet(isPresented: $state.presentUpdateProgress) {
            UpdateProgressSheet(updater: state.selfUpdater) {
                state.presentUpdateProgress = false
            }
            .environment(\.theme, state.themeStore.current)
        }
    }
}

private struct RootGGPresentationHandlers: ViewModifier {
    @Bindable var state: AppState

    func body(content: Content) -> some View {
        content
            .confirmationDialog(
                "Land stack?",
                isPresented: Binding(
                    get: { state.rightPaneStore.stateWithPendingGGLand() != nil },
                    set: { if !$0 { state.rightPaneStore.stateWithPendingGGLand()?.cancelGGLand() } }
                ),
                titleVisibility: .visible,
                presenting: state.rightPaneStore.stateWithPendingGGLand()?.pendingGGLand
            ) { _ in
                Button("Land", role: .destructive) {
                    state.rightPaneStore.stateWithPendingGGLand()?.performGGLand()
                }
                Button("Cancel", role: .cancel) {
                    state.rightPaneStore.stateWithPendingGGLand()?.cancelGGLand()
                }
            } message: { _ in
                Text(state.rightPaneStore.stateWithPendingGGLand()?.pendingGGLandConfirmationMessage ?? "")
            }
            .confirmationDialog(
                "Drop commit?",
                isPresented: Binding(
                    get: { state.rightPaneStore.stateWithPendingGGDrop() != nil },
                    set: { if !$0 { state.rightPaneStore.stateWithPendingGGDrop()?.cancelGGDrop() } }
                ),
                titleVisibility: .visible
            ) {
                Button("Drop Commit", role: .destructive) {
                    state.rightPaneStore.stateWithPendingGGDrop()?.performGGDrop()
                }
                Button("Cancel", role: .cancel) {
                    state.rightPaneStore.stateWithPendingGGDrop()?.cancelGGDrop()
                }
            } message: {
                Text(state.rightPaneStore.stateWithPendingGGDrop()?.pendingGGDrop?.message ?? "")
            }
            .confirmationDialog(
                "Clean all merged stacks?",
                isPresented: Binding(
                    get: { state.rightPaneStore.stateWithPendingGGCleanAll() != nil },
                    set: { if !$0 { state.rightPaneStore.stateWithPendingGGCleanAll()?.cancelGGCleanAll() } }
                ),
                titleVisibility: .visible
            ) {
                Button("Clean all merged stacks", role: .destructive) {
                    state.rightPaneStore.stateWithPendingGGCleanAll()?.performGGCleanAll()
                }
                Button("Cancel", role: .cancel) {
                    state.rightPaneStore.stateWithPendingGGCleanAll()?.cancelGGCleanAll()
                }
            } message: {
                Text("Remove every merged gg stack and associated worktree in this repository.")
            }
            .sheet(
                item: Binding(
                    get: { state.rightPaneStore.stateWithPendingGGUnstack()?.pendingGGUnstack },
                    set: { if $0 == nil { state.rightPaneStore.stateWithPendingGGUnstack()?.cancelGGUnstack() } }
                )
            ) { model in
                GGUnstackSheet(model: model) { editedModel in
                    guard let owner = state.rightPaneStore.stateWithPendingGGUnstack() else {
                        throw GGMutationError.staleConfirmation
                    }
                    return try await owner.submitGGUnstack(editedModel)
                }
                .environment(\.theme, state.themeStore.current)
            }
            .sheet(
                item: Binding(
                    get: { state.rightPaneStore.stateWithPendingGGReorder()?.pendingGGReorder },
                    set: { if $0 == nil { state.rightPaneStore.stateWithPendingGGReorder()?.cancelGGReorder() } }
                )
            ) { presentation in
                GGReorderSheet(
                    presentation: presentation,
                    onApply: { model in
                        guard let owner = state.rightPaneStore.stateWithPendingGGReorder() else {
                            throw GGMutationError.staleConfirmation
                        }
                        try await owner.submitGGReorder(model)
                    },
                    onCancel: {
                        state.rightPaneStore.stateWithPendingGGReorder()?.cancelGGReorder()
                    }
                )
                .environment(\.theme, state.themeStore.current)
            }
            .sheet(
                item: Binding(
                    get: { state.rightPaneStore.stateWithPendingGGRestack()?.pendingGGRestack },
                    set: { if $0 == nil { state.rightPaneStore.stateWithPendingGGRestack()?.cancelGGRestack() } }
                )
            ) { presentation in
                GGRestackSheet(
                    presentation: presentation,
                    onApply: {
                        guard let currentOwner = state.rightPaneStore.stateWithPendingGGRestack() else {
                            throw GGMutationError.staleConfirmation
                        }
                        try await currentOwner.submitGGRestack()
                    },
                    onCancel: {
                        state.rightPaneStore.stateWithPendingGGRestack()?.cancelGGRestack()
                    }
                )
                .environment(\.theme, state.themeStore.current)
            }
    }
}

private struct RootCommandHandlers: ViewModifier {
    @Bindable var state: AppState
    @Binding var newWorktreePresentation: NewWorktreePresentation?
    @Binding var showNewProject: Bool
    let selectedWorktree: () -> Worktree?
    let openSettings: () -> Void

    func body(content: Content) -> some View {
        content
            .modifier(RootBaseHandlers(
                state: state,
                newWorktreePresentation: $newWorktreePresentation,
                showNewProject: $showNewProject,
                selectedWorktree: selectedWorktree,
                openSettings: openSettings
            ))
            .modifier(RootPaneHandlers(
                state: state,
                selectedWorktree: selectedWorktree
            ))
    }
}

private struct RootBaseHandlers: ViewModifier {
    @Bindable var state: AppState
    @Binding var newWorktreePresentation: NewWorktreePresentation?
    @Binding var showNewProject: Bool
    let selectedWorktree: () -> Worktree?
    let openSettings: () -> Void

    func body(content: Content) -> some View {
        let aSidebar = content
            .onReceive(NotificationCenter.default.publisher(for: .alasToggleSidebar)) { _ in
                state.toggleSidebarVisibility()
            }
        let a = aSidebar
            .onReceive(NotificationCenter.default.publisher(for: .alasToggleRightPane)) { _ in
                state.toggleRightPaneVisibility()
            }
        let b = a
            .onReceive(NotificationCenter.default.publisher(for: .alasCreateProject)) { _ in
                showNewProject = true
            }
        let c = b
            .onReceive(NotificationCenter.default.publisher(for: .alasNewWorktree)) { notification in
                newWorktreePresentation = NewWorktreePresentation(projectId: notification.object as? String)
            }
        let d = c
            .onReceive(NotificationCenter.default.publisher(for: .alasFocusMainWorktree)) { _ in
                state.focusMainWorktreeForCurrentProject()
            }
        let e = d
            .onReceive(NotificationCenter.default.publisher(for: .alasNewTerminalTab)) { _ in
                if let wt = selectedWorktree() {
                    Task { @MainActor in
                        _ = try? await state.openTerminalTabPreparingRemoteZmxIfNeeded(for: wt)
                    }
                }
            }
        let f = e
            .onReceive(NotificationCenter.default.publisher(for: .alasCloseTab)) { _ in
                if let wt = selectedWorktree() {
                    state.handleCloseShortcut(worktreeId: wt.id)
                }
            }
        let g = f
            .onReceive(NotificationCenter.default.publisher(for: .alasActivateTabByNumber)) { notification in
                guard let number = notification.object as? Int,
                      let wt = selectedWorktree() else { return }
                state.tabs.activateTabNumber(number, worktreeId: wt.id)
            }
        let h = g
            .onReceive(NotificationCenter.default.publisher(for: .alasSaveActiveTab)) { _ in
                if let wt = selectedWorktree() {
                    state.saveActiveTab(worktreeId: wt.id)
                }
            }
        let i = h
            .onReceive(NotificationCenter.default.publisher(for: .alasSaveActiveTabAs)) { _ in
                if let wt = selectedWorktree() {
                    state.saveActiveTabAs(worktreeId: wt.id)
                }
            }
        let j = i
            .onReceive(NotificationCenter.default.publisher(for: .alasSaveAllTabs)) { _ in
                state.saveAllTabs()
            }
        let k = j
            .onReceive(NotificationCenter.default.publisher(for: .alasRevertActiveTab)) { _ in
                if let wt = selectedWorktree() {
                    state.revertActiveTab(worktreeId: wt.id)
                }
            }
        let l = k
            .onReceive(NotificationCenter.default.publisher(for: .alasNewFile)) { _ in
                if let wt = selectedWorktree() {
                    state.newFile(in: wt.id)
                }
            }
        let m = l
            .onReceive(NotificationCenter.default.publisher(for: .alasRenameActiveFile)) { _ in
                if let wt = selectedWorktree() {
                    state.renameActiveFile(worktreeId: wt.id)
                }
            }
        let n = m
            .onReceive(NotificationCenter.default.publisher(for: .alasOpenSettings)) { notification in
                if let section = notification.object as? SettingsSection {
                    state.pendingSettingsSection = section
                }
                openSettings()
            }
        let o = n
            .onReceive(NotificationCenter.default.publisher(for: .alasOpenSearch)) { _ in
                // Close the repo selector so the two overlays never overlap;
                // RepoSelectorDialog is mounted after FileSearchDialog and
                // would otherwise keep capturing keys.
                state.openSearchOverlay()
            }
        let p = o
            .onReceive(NotificationCenter.default.publisher(for: .alasOpenRepoSelector)) { _ in
                // Toggle: closing if already open, opening (and closing the
                // file searcher) if not. We also call `search.close()` so an
                // in-flight content search task is cancelled rather than
                // continuing in the background under the new overlay.
                state.toggleRepoSelectorOverlay()
            }
        let q = p
            .onReceive(NotificationCenter.default.publisher(for: .alasOpenReviewPalette)) { _ in
                guard !state.projects.isEmpty else { return }
                state.openReviewPaletteOverlay()
            }
        let r = q
            .onReceive(NotificationCenter.default.publisher(for: .alasOpenAgentLauncher)) { notification in
                guard selectedWorktree() != nil else { return }
                let mode = notification.object as? AppConfig.LauncherMode
                state.openAgentLauncherOverlay(mode: mode)
            }
        let r2 = r
            .onReceive(NotificationCenter.default.publisher(for: .alasOpenRunScriptPalette)) { _ in
                guard selectedWorktree() != nil else { return }
                state.openRunScriptPaletteOverlay()
            }
        let s = r2
            .onReceive(NotificationCenter.default.publisher(for: .alasRefreshWorktrees)) { _ in
                let beforeIds = state.allWorktreeIds()
                Task {
                    _ = await state.refreshAllProjectTopologies()
                    await state.cleanupMissingWorktrees(beforeIds: beforeIds)
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: .alasTerminateAllTerminals)) { _ in
                state.terminateAllTerminalSessions()
            }
        return s
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in
                state.flushScheduledSpacesSave()
                state.stopAllProjectGitWatchers()
                state.tabs.snapshotDirtyBuffersForQuit()
                // Cancel the hook socket accept loop and any pending cursor
                // idle debouncers before the process tears down. Otherwise
                // in-flight hook subprocesses (cursor-agent fires a 1s `nc -U`
                // per event) keep delivering events to a half-torn-down
                // HarnessService, which is one of the candidates for the
                // permission-prompt avalanche reported on quit.
                state.harness.stop()
                // Terminate any `alas mcp --http` processes spawned for the
                // HTTP transport so they don't outlive the app.
                state.mcpHTTPSupervisor.shutdown()
                // Block briefly so any in-flight `zmx kill` subprocesses
                // (dispatched from close-tab/delete-worktree paths) finish
                // talking to the daemon before our process exits — they'd
                // otherwise die with us mid-flight, leaving daemon-side
                // sessions orphaned. The boot-time sweep eventually cleans
                // those up, but only if the user relaunches Alas; meanwhile
                // they'd accumulate across the lifetime of the daemon.
                state.terminal.waitForPendingKills(timeout: 3.0)
            }
    }
}

private struct RootPaneHandlers: ViewModifier {
    @Bindable var state: AppState
    let selectedWorktree: () -> Worktree?

    func body(content: Content) -> some View {
        content
            .onReceive(NotificationCenter.default.publisher(for: .alasSplitRight)) { _ in
                if let wt = selectedWorktree() { state.splitFocusedPane(worktreeId: wt.id, axis: .vertical) }
            }
            .onReceive(NotificationCenter.default.publisher(for: .alasSplitDown)) { _ in
                if let wt = selectedWorktree() { state.splitFocusedPane(worktreeId: wt.id, axis: .horizontal) }
            }
            .onReceive(NotificationCenter.default.publisher(for: .alasFocusPaneLeft)) { _ in
                if let wt = selectedWorktree() { state.focusPane(worktreeId: wt.id, direction: .left) }
            }
            .onReceive(NotificationCenter.default.publisher(for: .alasFocusPaneRight)) { _ in
                if let wt = selectedWorktree() { state.focusPane(worktreeId: wt.id, direction: .right) }
            }
            .onReceive(NotificationCenter.default.publisher(for: .alasFocusPaneUp)) { _ in
                if let wt = selectedWorktree() { state.focusPane(worktreeId: wt.id, direction: .up) }
            }
            .onReceive(NotificationCenter.default.publisher(for: .alasFocusPaneDown)) { _ in
                if let wt = selectedWorktree() { state.focusPane(worktreeId: wt.id, direction: .down) }
            }
            .onReceive(NotificationCenter.default.publisher(for: .alasResizePaneLeft)) { _ in
                if let wt = selectedWorktree() { state.resizePane(worktreeId: wt.id, direction: .left) }
            }
            .onReceive(NotificationCenter.default.publisher(for: .alasResizePaneRight)) { _ in
                if let wt = selectedWorktree() { state.resizePane(worktreeId: wt.id, direction: .right) }
            }
            .onReceive(NotificationCenter.default.publisher(for: .alasResizePaneUp)) { _ in
                if let wt = selectedWorktree() { state.resizePane(worktreeId: wt.id, direction: .up) }
            }
            .onReceive(NotificationCenter.default.publisher(for: .alasResizePaneDown)) { _ in
                if let wt = selectedWorktree() { state.resizePane(worktreeId: wt.id, direction: .down) }
            }
    }
}

extension Notification.Name {
    static let alasToggleSidebar     = Notification.Name("AlasToggleSidebar")
    static let alasToggleRightPane   = Notification.Name("AlasToggleRightPane")
    static let alasCreateProject     = Notification.Name("AlasCreateProject")
    static let alasNewWorktree       = Notification.Name("AlasNewWorktree")
    static let alasFocusMainWorktree = Notification.Name("AlasFocusMainWorktree")
    static let alasRefreshWorktrees  = Notification.Name("AlasRefreshWorktrees")
    static let alasNewTerminalTab  = Notification.Name("AlasNewTerminalTab")
    static let alasOpenAgentLauncher = Notification.Name("AlasOpenAgentLauncher")
    static let alasCloseTab        = Notification.Name("AlasCloseTab")
    static let alasActivateTabByNumber = Notification.Name("AlasActivateTabByNumber")
    static let alasOpenSettings    = Notification.Name("AlasOpenSettings")
    static let alasOpenSearch      = Notification.Name("AlasOpenSearch")
    static let alasOpenRepoSelector = Notification.Name("AlasOpenRepoSelector")
    static let alasOpenReviewPalette = Notification.Name("AlasOpenReviewPalette")
    static let alasOpenRunScriptPalette = Notification.Name("AlasOpenRunScriptPalette")
    static let alasSaveActiveTab   = Notification.Name("AlasSaveActiveTab")
    static let alasSaveActiveTabAs = Notification.Name("AlasSaveActiveTabAs")
    static let alasSaveAllTabs     = Notification.Name("AlasSaveAllTabs")
    static let alasRevertActiveTab = Notification.Name("AlasRevertActiveTab")
    static let alasNewFile         = Notification.Name("AlasNewFile")
    static let alasRenameActiveFile = Notification.Name("AlasRenameActiveFile")
    static let alasSplitRight       = Notification.Name("AlasSplitRight")
    static let alasSplitDown        = Notification.Name("AlasSplitDown")
    static let alasFocusPaneLeft    = Notification.Name("AlasFocusPaneLeft")
    static let alasFocusPaneRight   = Notification.Name("AlasFocusPaneRight")
    static let alasFocusPaneUp      = Notification.Name("AlasFocusPaneUp")
    static let alasFocusPaneDown    = Notification.Name("AlasFocusPaneDown")
    static let alasResizePaneLeft   = Notification.Name("AlasResizePaneLeft")
    static let alasResizePaneRight  = Notification.Name("AlasResizePaneRight")
    static let alasResizePaneUp     = Notification.Name("AlasResizePaneUp")
    static let alasResizePaneDown   = Notification.Name("AlasResizePaneDown")
    static let alasTerminateAllTerminals = Notification.Name("AlasTerminateAllTerminals")
    static let alasShowFindReplace  = Notification.Name("AlasShowFindReplace")
    static let codeEditorDidAttach  = Notification.Name("CodeEditorDidAttach")
    static let codeEditorDidDetach  = Notification.Name("CodeEditorDidDetach")
}

enum EditorFindRequest: Equatable, Sendable {
    case showFind
    case showReplace
    case findNext
    case findPrevious
}
