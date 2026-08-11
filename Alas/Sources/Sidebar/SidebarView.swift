import SwiftUI
import AppKit

struct SidebarView: View {
    @Bindable var state: AppState
    @Binding var collapsedProjects: Set<String>
    let onSettings: () -> Void
    let onAddProject: () -> Void
    let onEditProject: (_ projectId: String) -> Void
    let onRemoveProject: (_ projectId: String) -> Void
    let onNewWorktree: (_ projectId: String?) -> Void
    let onNewMission: () -> Void
    let onHideSidebar: () -> Void
    @Environment(\.theme) var theme
    @State private var spaceTitleVisible = false
    @State private var hideTitleTask: Task<Void, Never>?

    var body: some View {
        let override = state.config.sidebarChromeOverride(forThemeId: state.themeStore.current.id)
        ZStack {
            SidebarMaterialBackground(
                choice: state.config.sidebarMaterial,
                backgroundOpacity: override.backgroundOpacity
            )
            VStack(spacing: 0) {
                SidebarHeaderView(
                    worktreeSortMode: state.config.worktrees.defaultOrdering,
                    onSetWorktreeSortMode: { state.setDefaultWorktreeOrdering($0) },
                    onSettings: onSettings,
                    onAddProject: onAddProject,
                    onSearch: {
                        NotificationCenter.default.post(name: .alasOpenSearch, object: nil)
                    },
                    onHideSidebar: onHideSidebar
                )
                ScrollView(.vertical, showsIndicators: true) {
                    VStack(alignment: .leading, spacing: 8) {
                        if state.missionsEnabled {
                            MissionSidebarSection(
                                model: missionSidebarModel,
                                selectedMissionID: selectedMissionID,
                                onOpenMission: { missionID in
                                    _ = state.openMission(id: missionID)
                                },
                                onNewMission: onNewMission,
                                onDeleteMission: { missionID in
                                    Task { await state.deleteMission(id: missionID) }
                                },
                                onDeleteCompleted: { missionIDs in
                                    Task { await state.deleteCompletedMissions(ids: missionIDs) }
                                }
                            )
                        }
                        ForEach(state.activeSpaceProjects) { project in
                            RepoGroupView(
                                project: project,
                                worktrees: state.projectsManager.visibleWorktrees(projectId: project.id),
                                collapsed: Binding(
                                    get: { collapsedProjects.contains(project.id) },
                                    set: { collapsed in
                                        if collapsed { collapsedProjects.insert(project.id) }
                                        else { collapsedProjects.remove(project.id) }
                                    }
                                ),
                                selectedWorktreeId: Self.effectiveSelectedWorktreeId(
                                    selectedWorktreeId: state.selectedWorktreeId,
                                    activeMissionTab: state.missionsEnabled
                                        ? state.globalTabs.activeMissionTab()
                                        : nil
                                ),
                                isMain: { wt in state.projectsManager.isMain(wt, in: project) },
                                operationState: { wt in
                                    state.projectsManager.operationState(for: wt.id)
                                },
                                harnessSummary: { worktreeId in
                                    let ids = state.tabs.tabs(forWorktree: worktreeId).flatMap { tab -> [String] in
                                        switch tab {
                                        case .terminal(let s):   return s.root.leaves().map(\.sessionId)
                                        case .acpSession(let s): return [s.sessionId]
                                        default:                 return []
                                        }
                                    }
                                    return state.harness.summary(forSessionIds: ids)
                                },
                                ggMenuModel: { wt in
                                    state.ggWorktreeMenuModel(project: project, worktree: wt)
                                },
                                onSelect: { wt in state.selectWorktree(id: wt.id) },
                                onNewWorktree: { onNewWorktree(project.id) },
                                onEditProject: { onEditProject(project.id) },
                                onRemoveProject: { onRemoveProject(project.id) },
                                onOpenGGInbox: state.ggInboxAvailable(projectId: project.id)
                                    ? { state.openGGInbox(projectId: project.id) }
                                    : nil,
                                onResetSort: {
                                    state.projectsManager.resetWorktreeOrder(projectId: project.id)
                                    state.saveProjects()
                                },
                                spaces: state.spacesManager.spaces,
                                activeSpaceId: state.spacesManager.activeSpaceId,
                                isProjectInSpace: { spaceId in
                                    state.spacesManager.space(id: spaceId)?.projectIds.contains(project.id) == true
                                },
                                canRemoveFromSpace: { _ in
                                    state.spacesManager.membershipCount(forProject: project.id) > 1
                                },
                                onToggleSpaceMembership: { spaceId in
                                    state.toggleProject(projectId: project.id, inSpace: spaceId)
                                },
                                onOpenTerminal: { wt in
                                    state.selectWorktree(id: wt.id)
                                    Task { @MainActor in
                                        _ = try? await state.openTerminalTabPreparingRemoteZmxIfNeeded(for: wt)
                                    }
                                },
                                onOpenIssue: { wt in
                                    guard let attachment = state.projectsManager.issueAttachment(
                                        projectId: project.id,
                                        worktreeId: wt.id
                                    ) else { return nil }
                                    return { NSWorkspace.shared.open(attachment.canonicalURL) }
                                },
                                onCopyPath: { wt in
                                    let pb = NSPasteboard.general
                                    pb.clearContents()
                                    pb.setString(wt.path.path, forType: .string)
                                },
                                onCopyBranch: { wt in
                                    let pb = NSPasteboard.general
                                    pb.clearContents()
                                    pb.setString(wt.branch, forType: .string)
                                },
                                onRevealInFinder: { wt in
                                    NSWorkspace.shared.activateFileViewerSelecting([wt.path])
                                },
                                onArchive: { wt in state.archiveWorktree(wt) },
                                onDelete: { wt in state.deleteWorktree(wt) },
                                onDeleteKeepBranch: { wt in state.deleteWorktree(wt, keepBranch: true) },
                                showKeepBranchOption: state.config.worktrees.deleteBranchOnRemove,
                                onActivateHarness: { wt in
                                    let ids = state.tabs.tabs(forWorktree: wt.id).flatMap { tab -> [String] in
                                        switch tab {
                                        case .terminal(let s):   return s.root.leaves().map(\.sessionId)
                                        case .acpSession(let s): return [s.sessionId]
                                        default:                 return []
                                        }
                                    }
                                    guard let summary = state.harness.summary(forSessionIds: ids) else { return }
                                    state.activateHarnessSession(
                                        projectId: project.id,
                                        worktreeId: wt.id,
                                        sessionId: summary.primarySessionId
                                    )
                                },
                                onCopyError: { message in
                                    let pb = NSPasteboard.general
                                    pb.clearContents()
                                    pb.setString(message, forType: .string)
                                },
                                onRetryCreate: { wt in
                                    let retry = Self.retryCreateParameters(
                                        operationState: state.projectsManager.operationState(for: wt.id),
                                        defaultBase: state.config.worktrees.baseBranch
                                    )
                                    Task { @MainActor in
                                        await state.createWorktree(
                                            projectId: project.id,
                                            base: retry.base,
                                            branch: wt.branch,
                                            destination: wt.path,
                                            runStartup: false,
                                            launchSurface: retry.launchSurface,
                                            ggWorktreeMode: retry.ggWorktreeMode,
                                            issueAttachment: retry.issueAttachment
                                        )
                                    }
                                },
                                onRetryDelete: { wt in state.deleteWorktree(wt) },
                                onSetGGWorktreeMode: { wt, mode in
                                    state.setGGWorktreeMode(
                                        projectId: project.id,
                                        worktreeId: wt.id,
                                        mode: mode
                                    )
                                },
                                onRemoveFailed: { wt in
                                    state.removeFailedOptimisticWorktree(id: wt.id, projectId: project.id)
                                },
                                onDropWorktree: { draggedId, destinationId in
                                    state.projectsManager.reorderWorktree(
                                        projectId: project.id,
                                        movingId: draggedId,
                                        destinationId: destinationId
                                    )
                                    state.saveProjects()
                                },
                                onDropProject: { draggedId, destinationId in
                                    state.spacesManager.reorderProjectInActiveSpace(
                                        movingId: draggedId,
                                        destinationId: destinationId
                                    )
                                    state.saveSpaces()
                                }
                            )
                        }
                        Color.clear
                            .frame(maxWidth: .infinity, minHeight: 40)
                            .contentShape(Rectangle())
                            .dropDestination(for: ProjectDragId.self) { items, _ in
                                guard let draggedId = items.first?.id else { return false }
                                state.spacesManager.moveProjectToEndInActiveSpace(id: draggedId)
                                state.saveSpaces()
                                return true
                            }
                    }
                    .padding(.top, 8)
                }
                if state.spacesManager.shouldShowSpaceAffordance {
                    SpacePagerIndicator(
                        spaces: state.spacesManager.spaces,
                        activeSpaceId: state.spacesManager.activeSpaceId,
                        titleVisible: spaceTitleVisible,
                        onSelectSpace: { spaceId in
                            if state.switchToSpace(id: spaceId) {
                                showTransientSpaceTitle()
                            }
                        },
                        onEditSpaces: {
                            state.pendingSettingsSection = .spaces
                            onSettings()
                        },
                        onScrollPage: { offset in
                            if state.switchToAdjacentSpace(offset: offset) {
                                showTransientSpaceTitle()
                            }
                        }
                    )
                    .contentShape(Rectangle())
                    .gesture(spacePagingGesture)
                }
            }
            .sidebarChromeTheme(textContrast: override.textContrast)
            .background {
                if state.spacesManager.shouldShowSpaceAffordance {
                    SpacePagerScrollCaptureView { offset in
                        if state.switchToAdjacentSpace(offset: offset) {
                            showTransientSpaceTitle()
                        }
                    }
                }
            }
        }
        .onDisappear {
            hideTitleTask?.cancel()
            hideTitleTask = nil
        }
    }

    private var spacePagingGesture: some Gesture {
        DragGesture(minimumDistance: 24)
            .onEnded { value in
                guard abs(value.translation.width) > abs(value.translation.height) * 1.4 else { return }
                let offset = value.translation.width < 0 ? 1 : -1
                if state.switchToAdjacentSpace(offset: offset) {
                    showTransientSpaceTitle()
                }
            }
    }

    nonisolated static func retryCreateParameters(
        operationState: WorktreeOperationState?,
        defaultBase: String
    ) -> (
        base: String,
        ggWorktreeMode: GGWorktreeMode,
        launchSurface: WorktreeLaunchSurface,
        issueAttachment: IssueAttachment?
    ) {
        guard case .createFailed(_, _, let base, let ggWorktreeMode, let launchSurface, let issueAttachment) = operationState else {
            return (defaultBase, .inherit, .none, nil)
        }
        return (base, ggWorktreeMode, launchSurface, issueAttachment)
    }

    nonisolated static func effectiveSelectedWorktreeId(
        selectedWorktreeId: String?,
        activeMissionTab: MissionTabState?
    ) -> String? {
        activeMissionTab == nil ? selectedWorktreeId : nil
    }

    private func showTransientSpaceTitle() {
        hideTitleTask?.cancel()
        spaceTitleVisible = true
        hideTitleTask = Task { @MainActor in
            do {
                try await Task.sleep(for: .seconds(2))
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            spaceTitleVisible = false
        }
    }

    private var missionSidebarModel: MissionSidebarModel {
        guard state.missionsEnabled else {
            return MissionSidebarModel.make(
                aggregates: [],
                activeProjectIds: [],
                existingProjectIds: [],
                knownWorktreeIds: []
            )
        }
        return state.missions.sidebarModel(
            activeProjectIds: state.spacesManager.activeSpace?.projectIds ?? state.projects.map(\.id),
            existingProjectIds: state.projects.map(\.id),
            knownWorktreeIds: state.allWorktreeIds()
        )
    }

    private var selectedMissionID: MissionID? {
        guard state.missionsEnabled else { return nil }
        if let tabState = state.globalTabs.activeMissionTab() {
            return tabState.missionID
        }
        if let tabState = state.missingMissionTab {
            return tabState.missionID
        }
        guard let worktreeID = state.selectedWorktreeId,
              let tab = state.tabs.activeTab(forWorktree: worktreeID),
              case .mission(let tabState) = tab
        else { return nil }
        return tabState.missionID
    }
}
