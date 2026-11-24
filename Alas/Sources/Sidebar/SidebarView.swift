import SwiftUI
import AppKit

struct SidebarAttentionPresentation {
    let count: Int

    init(aggregation: AttentionAggregation, peerRows: [RemoteSessionSummary] = [], pluginUpdateCount: Int = 0,
         appUpdate: ReleaseInfo? = nil, cleanupReminderCount: Int = 0, hostUpdateCount: Int = 0) {
        count = aggregation.unresolvedCount + peerRows.count + pluginUpdateCount + (appUpdate == nil ? 0 : 1)
            + cleanupReminderCount + hostUpdateCount
    }
}

struct SidebarView: View {
    @Bindable var state: AppState
    @Binding var collapsedProjects: Set<String>
    let onSettings: () -> Void
    let onAddProject: () -> Void
    let onAddFolder: () -> Void
    let onEditProject: (_ projectId: String) -> Void
    let onRemoveProject: (_ projectId: String) -> Void
    let onNewWorktree: (_ projectId: String?) -> Void
    let onCleanupWorktrees: (_ projectId: String) -> Void
    let onHideSidebar: () -> Void
    @Environment(\.theme) var theme
    @Environment(\.designScale) private var scale
    @State private var spaceTitleVisible = false
    @State private var hideTitleTask: Task<Void, Never>?
    @State private var showingNewWorkspace = false
    @State private var renamingBranchWorktree: Worktree?
    /// Transient: never persisted and never applied outside this sidebar.
    @State private var worktreeFilter = ""
    @AppStorage("sidebar.groupWorktreesByMachine") private var groupWorktreesByMachine = false
    @State private var highlightedWorktreeId: String?
    @FocusState private var worktreeFilterFocused: Bool
    /// Per space, since every page keeps its own scroll view. Read only by the
    /// filter row, so per-frame scroll updates re-render it alone rather than
    /// the whole tree.
    @State private var scrollOffsets = SidebarScrollOffsets()
    @State var peerSidebarModel = NativePeerSidebarModel()

    var body: some View {
        let override = state.config.sidebarChromeOverride(forThemeId: state.themeStore.current.id)
        ZStack {
            SidebarMaterialBackground(
                choice: state.config.sidebarMaterial,
                backgroundOpacity: override.backgroundOpacity
            )
            DeviceStatusKeeper(state: state)
            VStack(spacing: 0) {
                SidebarAttentionHeader(
                    state: state,
                    onSettings: onSettings,
                    // Projects land in a local space, so adding one from a
                    // peer's page goes back there first.
                    onAddProject: { returnToLocalSpace(); onAddProject() },
                    onAddFolder: { returnToLocalSpace(); onAddFolder() },
                    onHideSidebar: onHideSidebar,
                    showingNewWorkspace: $showingNewWorkspace
                )
                let activePage = state.activeSidebarPage
                SpacePagerContent(pages: state.sidebarPages, selection: activePage) { spaceID in
                    WorkspaceSidebarTreeHost(state: state) { treeModel in
                        SidebarFilterSlotScrollView(
                            isActive: activePage == .space(spaceID),
                            peerModel: peerSidebarModel,
                            scrollTarget: activePage == .space(spaceID) ? highlightedWorktreeId : nil,
                            onScroll: { scrollOffsets.setOffset($0, forSpace: spaceID) }
                        ) {
                            // Lazy, and every header and row below is its own
                            // element: a scroll frame costs SwiftUI work for each
                            // mounted row (display list and hover hit-testing),
                            // so only the rows on screen may be mounted.
                            LazyVStack(alignment: .leading, spacing: 0) {
                                // The filter row's slot; the row itself is drawn
                                // by the overlay below so it can also pin.
                                Color.clear.frame(height: SidebarFilterRowMetrics.slotHeight)
                                    .padding(.bottom, SidebarFilterRowMetrics.slotSpacing)
                                WorkspaceSidebarTree(
                                    state: state,
                                    model: treeModel,
                                    spaceID: spaceID,
                                    isInteractive: activePage == .space(spaceID)
                                ) { project in
                                    let liveWorktrees = state.projectsManager.visibleWorktrees(includingLinkedTo: project.id)
                                    let landingSession = GGLandingStore.shared.sessions[project.id]
                                    let landingHostWorktreeId = landingSession.flatMap { session in
                                        AppState.landingHostWorktreeId(
                                            sessionWorktreeId: session.worktreeId,
                                            selectedWorktreeId: state.selectedWorktreeId,
                                            projectWorktreeIds: liveWorktrees.map(\.id)
                                        )
                                    }
                                    return RepoGroupView(
                                        project: project,
                                        icon: { state.sidebarIcon(for: $0) },
                                        worktrees: displayedWorktrees(liveWorktrees),
                                        collapsed: Binding(
                                            get: { collapsedProjects.contains(project.id) },
                                            set: { collapsed in
                                                if collapsed { collapsedProjects.insert(project.id) }
                                                else { collapsedProjects.remove(project.id) }
                                            }
                                        ),
                                        alsoInNotes: state.projectsManager.alsoInNotes(projectId: project.id),
                                        // A peer worktree takes the highlight
                                        // while it covers the center pane.
                                        selectedWorktreeId: state.nativePeerSessions?.coversCenterPane == true
                                            ? nil : state.selectedWorktreeId,
                                        // A linked record's row is main within its own record.
                                        isMain: { wt in state.projectsManager.isMain(wt, in: rowProject(wt, in: project)) },
                                        upstreamStatus: { wt in state.worktreeUpstreamStatusStore.status(for: wt.id) },
                                        onPullUpstream: { wt in state.pullWorktreeFromSidebar(id: wt.id) },
                                        isPullUpstreamInFlight: { wt in
                                            state.worktreeUpstreamStatusStore.isPullingUpstream(worktreeID: wt.id)
                                                || state.rightPaneStore.activeState(worktreeId: wt.id)?.pullInFlight == true
                                        },
                                        workspaceCheckout: { wt in
                                            WorkspaceCheckoutWorktreeResolver.presentation(
                                                for: wt,
                                                checkouts: state.workspacesManager.checkouts
                                            )
                                        },
                                        onOpenWorkspaceCheckout: { checkout in
                                            state.openWorkspaceCheckoutMember(
                                                checkoutID: checkout.checkoutID,
                                                memberID: checkout.memberID
                                            )
                                        },
                                        operationState: { wt in
                                            state.projectsManager.operationState(
                                                forWorktreeId: wt.id,
                                                projectId: wt.projectId
                                            )
                                        },
                                        landingHostWorktreeId: landingHostWorktreeId,
                                        landingStatus: landingSession.flatMap {
                                            GGLandingPresentation.sidebarStatus(for: $0)
                                        },
                                        onOpenGGLanding: { state.openGGLanding(projectId: project.id) },
                                        harnessSummary: { state.harnessSummary(forWorktree: $0) },
                                        harnessBadges: { state.harnessBadges(forWorktree: $0) },
                                        badgePopoverModel: {
                                            state.agentBadgePopoverModel(sessionId: $0, worktreeId: $1)
                                        },
                                        ggMenuModel: { wt in
                                            state.ggWorktreeMenuModel(project: rowProject(wt, in: project), worktree: wt)
                                        },
                                        onSelect: { wt in state.selectWorktreeFromSidebar(id: wt.id) },
                                        onNewWorktree: { onNewWorktree(project.id) },
                                        onEditProject: { onEditProject(project.id) },
                                        onRemoveProject: { onRemoveProject(project.id) },
                                        onOpenGGInbox: state.ggSidebarInboxAvailable(projectId: project.id)
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
                                                projectId: wt.projectId,
                                                worktreeId: wt.id
                                            ) else { return nil }
                                            return { NSWorkspace.shared.open(attachment.canonicalURL) }
                                        },
                                        onCopyPath: { wt in
                                            let pb = NSPasteboard.general
                                            pb.clearContents()
                                            pb.setString(RemotePath.realPath(wt.path.path), forType: .string)
                                        },
                                        onCopyBranch: { wt in
                                            let pb = NSPasteboard.general
                                            pb.clearContents()
                                            pb.setString(wt.branch, forType: .string)
                                        },
                                        onRenameBranch: { wt in renamingBranchWorktree = wt },
                                        isBranchNamePending: { wt in state.isBranchNamePending(wt) },
                                        isNamingBranch: { wt in state.autoNamingWorktreeIds.contains(wt.id) },
                                        onRevealInFinder: { wt in
                                            NSWorkspace.shared.activateFileViewerSelecting([wt.path])
                                        },
                                        onArchive: { wt in state.archiveWorktree(wt) },
                                        onCleanupWorktrees: { onCleanupWorktrees(project.id) },
                                        onDelete: { wt in state.deleteWorktree(wt) },
                                        onDeleteKeepBranch: { wt in state.deleteWorktree(wt, keepBranch: true) },
                                        showKeepBranchOption: state.config.worktrees.deleteBranchOnRemove,
                                        onActivateHarness: { wt, sessionId in
                                            state.activateHarnessSession(
                                                projectId: wt.projectId,
                                                worktreeId: wt.id,
                                                sessionId: sessionId
                                            )
                                        },
                                        onCopyError: { message in
                                            let pb = NSPasteboard.general
                                            pb.clearContents()
                                            pb.setString(message, forType: .string)
                                        },
                                        onRetryCreate: { wt in
                                            let retry = Self.retryCreateParameters(
                                                operationState: state.projectsManager.operationState(
                                                    forWorktreeId: wt.id,
                                                    projectId: wt.projectId
                                                ),
                                                defaultBase: state.config.worktrees.baseBranch
                                            )
                                            Task { @MainActor in
                                                await state.createWorktree(
                                                    projectId: wt.projectId,
                                                    base: retry.base,
                                                    branch: wt.branch,
                                                    destination: wt.path,
                                                    runStartup: false,
                                                    launchSurface: retry.launchSurface,
                                                    ggWorktreeMode: retry.ggWorktreeMode,
                                                    issueAttachment: retry.issueAttachment,
                                                    namesBranchFromFirstPrompt: retry.namesBranchFromFirstPrompt
                                                )
                                            }
                                        },
                                        onRetryLaunch: { wt in
                                            Task { @MainActor in
                                                await state.retryWorktreeLaunch(wt, project: rowProject(wt, in: project))
                                            }
                                        },
                                        onRetryDelete: { wt in state.deleteWorktree(wt) },
                                        onSetGGWorktreeMode: { wt, mode in
                                            state.setGGWorktreeMode(
                                                projectId: wt.projectId,
                                                worktreeId: wt.id,
                                                mode: mode
                                            )
                                        },
                                        onRemoveFailed: { wt in
                                            state.removeFailedOptimisticWorktree(id: wt.id, projectId: wt.projectId)
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
                                        },
                                        commitQuery: { wt in
                                            guard !state.projectsManager.isMain(wt, in: rowProject(wt, in: project)) else { return nil }
                                            let pane = state.rightPaneStore.activeState(worktreeId: wt.id)
                                            let override = pane.flatMap { pane in
                                                pane.userOverrodeBaseBranch
                                                    && pane.lastConfigBaseBranch == state.config.worktrees.baseBranch
                                                    ? pane.baseBranch : nil
                                            }
                                            return WorktreeRowView.CommitQuery(
                                                path: wt.path,
                                                branch: wt.branch,
                                                baseBranch: override ?? state.config.worktrees.baseBranch,
                                                preferLocal: override != nil,
                                                revision: state.revisionChangeGeneration(worktreeID: wt.id)
                                            )
                                        },
                                        worktreeExplanation: { wt in
                                            guard let evidence = state.worktreeExplainerEvidence(
                                                for: wt,
                                                in: rowProject(wt, in: project)
                                            ) else { return nil }
                                            return state.worktreeExplainerStore.explanation(
                                                for: wt.id,
                                                evidence: evidence
                                            )
                                        },
                                        worktreeExplainerEvidence: { wt in
                                            state.worktreeExplainerEvidence(for: wt, in: rowProject(wt, in: project))
                                        },
                                        onPrepareWorktreeExplanation: { wt, evidence in
                                            await state.worktreeExplainerStore.prepare(
                                                worktreeID: wt.id,
                                                evidence: evidence
                                            )
                                        },
                                        pluginCommands: { slot, wt in state.pluginCommands(slot, projectID: wt?.projectId ?? project.id) },
                                        onRunPluginCommand: { item, slot, wt in
                                            state.runPluginCommand(item, slot: slot, worktreeID: wt?.id)
                                        },
                                        pluginDecorations: { wt in
                                            wt.map { state.pluginDecorations(.worktreeRow, projectID: $0.projectId, target: $0.id) }
                                                ?? state.pluginDecorations(.repoRow, projectID: project.id, target: project.id)
                                        },
                                        onRunPluginDecoration: { state.runPluginDecoration($0) },
                                        isFiltering: WorktreeSidebarFilter.isActive(worktreeFilter),
                                        highlightedWorktreeId: highlightedWorktreeId,
                                        machineBadge: { wt in machineBadge(wt, in: project) },
                                        onRemoveLinkedCheckout: { wt in onRemoveProject(wt.projectId) },
                                        onReconnectMachine: { wt in state.reconnectMachine(projectId: wt.projectId) },
                                        liveActivity: { wt, hasMachineBadge in liveActivity(wt, hasMachineBadge: hasMachineBadge) },
                                        onOpenVM: { wt, guest in
                                            state.focusGlobalWorktree(id: wt.id, projectId: wt.projectId)
                                            state.openVirtualMachine(in: wt, guest: guest)
                                        },
                                        onShowDevice: { wt, id in showDevice(id, in: wt) }
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
                                    .padding(.top, SidebarFilterRowMetrics.slotSpacing)
                            }
                            .padding(.top, SidebarFilterRowMetrics.restY)
                            .padding(.horizontal, scale.space[2])
                            // Leaves room below the last repo for the drop target.
                            .padding(.bottom, scale.space[5])
                        }
                    }
                } peer: { serverId in
                    peerPage(serverId: serverId, isActive: activePage == .peer(serverId: serverId))
                }
                .overlay(alignment: .top) {
                    SidebarWorktreeFilterRow(
                        state: state,
                        scrollOffsets: scrollOffsets,
                        spaceID: Self.scrollKey(activePage),
                        text: $worktreeFilter,
                        groupByMachine: $groupWorktreesByMachine,
                        showsGroupByMachine: activePage.peerServerId == nil,
                        focused: $worktreeFilterFocused,
                        onMoveHighlight: moveFilterHighlight(by:),
                        onSubmit: openHighlightedWorktree,
                        onClear: clearWorktreeFilter
                    )
                    // A peer's page pins its header above the list.
                    .padding(.top, activePage.peerServerId == nil ? 0 : NativePeerSpaceHeader.height)
                }
                .clipped()
                if showsPager {
                    SpacePagerIndicator(
                        spaces: state.spacesManager.spaces,
                        peers: state.nativePeerSessions?.peerPages ?? [],
                        active: activePage,
                        titleVisible: spaceTitleVisible,
                        onSelect: { page in
                            if state.switchToPage(page) {
                                showTransientSpaceTitle()
                            }
                        },
                        onEditSpaces: {
                            state.pendingSettingsSection = .spaces
                            onSettings()
                        },
                        onRemoteSettings: openRemoteSettings,
                        onScrollPage: { offset in
                            pageSpace(offset: offset)
                        }
                    )
                    .contentShape(Rectangle())
                    .gesture(spacePagingGesture)
                }
            }
            .sidebarChromeTheme(textContrast: override.textContrast)
            .background {
                if showsPager {
                    SpacePagerScrollCaptureView { offset in
                        pageSpace(offset: offset)
                    }
                }
            }
        }
        .task(id: state.config.changes.stackedDiffsEnabled && GGAvailability.shared.isInstalled) {
            state.refreshGGSidebar()
        }
        .onChange(of: worktreeFilter) { resetFilterHighlight() }
        // A workspace, like a project, belongs to a local space.
        .onChange(of: showingNewWorkspace) { _, showing in
            if showing { returnToLocalSpace() }
        }
        // Matches change without a query change on a space switch, or when a
        // highlighted worktree is archived, deleted or refreshed away. Only a
        // highlight that is no longer a match moves, back to the first one.
        .onChange(of: WorktreeSidebarFilter.isActive(worktreeFilter) && state.activeSidebarPage.peerServerId == nil
                  ? filteredWorktreeIds() : []) { _, ids in
            keepFilterHighlight(in: ids)
        }
        // A peer page's matches move with every streamed update, so only this
        // child reads them, never the whole sidebar.
        .background {
            if WorktreeSidebarFilter.isActive(worktreeFilter), let serverId = state.activeSidebarPage.peerServerId,
               let client = state.nativePeerSessions {
                PeerFilterMatchesObserver(
                    client: client, serverId: serverId, filter: worktreeFilter,
                    ordering: state.config.worktrees.defaultOrdering, onChange: keepFilterHighlight(in:)
                )
            }
        }
        .onDisappear {
            hideTitleTask?.cancel()
            hideTitleTask = nil
        }
        #if DEBUG
        .onAppear { DesignCaptureSidebar.peerModel = peerSidebarModel }
        #endif
        .sheet(isPresented: $showingNewWorkspace) {
            NewWorkspaceDialog(state: state, presented: $showingNewWorkspace)
        }
        .sheet(item: $renamingBranchWorktree) { worktree in
            RenameBranchDialog(state: state, worktree: worktree) { renamingBranchWorktree = nil }
        }
        .sheet(item: $peerSidebarModel.renamingBranch) { rename in
            // The suggestion reads the branch's changes, which live on the host.
            RenameBranchDialog(
                branch: rename.worktree.snapshot.worktree.branch,
                subtitle: "\((RemotePath.realPath(rename.worktree.snapshot.worktree.path.path) as NSString).abbreviatingWithTildeInPath) on \(rename.peerName)",
                suggest: nil,
                rename: { branch in
                    guard let hosts = state.nativePeerSessions?.hosts else { return FederatedSessionsProvider.peerUnavailableMessage }
                    return await hosts.renameBranch(rename.worktree, to: branch, serverId: rename.serverId)
                },
                onDismiss: { peerSidebarModel.renamingBranch = nil }
            )
        }
    }

    /// The project a row belongs to: a linked record's rows show in their
    /// primary's group but act on their own record.
    private func rowProject(_ worktree: Worktree, in group: ProjectConfig) -> ProjectConfig {
        state.projects.first { $0.id == worktree.projectId } ?? group
    }

    /// The machine a linked record's row runs on; nil for the group's own rows.
    private func machineBadge(_ wt: Worktree, in group: ProjectConfig) -> WorktreeRowPresentation.MachineBadge? {
        // The group's own rows never have one; skip the project scan for them.
        guard wt.projectId != group.id else { return nil }
        let host = state.projects.first { $0.id == wt.projectId }?.host
        return WorktreeRowPresentation.machineBadge(
            rowProjectId: wt.projectId,
            groupProjectId: group.id,
            host: host,
            machines: state.config.machines,
            reachability: host.map { RemoteHostStatusStore.shared.reachability(for: $0) } ?? .unknown
        )
    }

    /// Read here rather than in the row, so a row never observes the VM
    /// manager, the device panes or the shepherds itself.
    private func liveActivity(_ wt: Worktree, hasMachineBadge: Bool) -> WorktreeRowPresentation.LiveActivity {
        #if DEBUG
        if let scripted = DesignCaptureLiveActivity.shared.byBranch { return scripted[wt.branch] ?? .none }
        #endif
        guard !hasMachineBadge else {
            return WorktreeRowPresentation.liveActivity(
                hasMachineBadge: true, vms: [:], devices: [], ship: nil, pr: nil, stack: nil
            )
        }
        var vms: [VMGuestOS: VMDeviceStatus] = [:]
        if state.canOpenVirtualMachine(in: wt) {
            for guest in [VMGuestOS.macOS, .linux] {
                vms[guest] = sidebarVMStatus(worktreeID: wt.id, guest: guest)
            }
        }
        let pr = state.reviewShepherd.record(forWorktree: wt.id)
        let stack = state.stackShepherd.activeRecord(forWorktree: wt.id)
        return WorktreeRowPresentation.liveActivity(
            hasMachineBadge: false,
            vms: vms,
            devices: ownedDevices(worktreeID: wt.id),
            ship: state.core.stackShipActivity[wt.id],
            pr: pr,
            stack: stack,
            seen: shepherdObservations(pr: pr, stack: stack)
        )
    }

    /// What the shepherds last saw, read the way `HostSessionShepherd` reads
    /// it. Only a row with a shepherd reads these, so the rest never redraw
    /// on a shepherd's poll.
    private func shepherdObservations(
        pr: ShepherdRecord?,
        stack: StackShepherdRecord?
    ) -> WorktreeRowPresentation.ShepherdObservations {
        var seen = WorktreeRowPresentation.ShepherdObservations()
        if let stack, !stack.isFinished {
            seen.stackRequests = state.stackShepherd.requests[stack.id] ?? [:]
            seen.stackGatePasses = state.stackShepherd.gatePasses[stack.id] ?? false
        } else if let pr {
            // A snapshot of another request on the branch doesn't describe this record.
            seen.prRequest = state.reviewShepherd.snapshots[pr.id]?.reviewRequest
                .flatMap { ShepherdRecordID(worktreeID: pr.id.worktreeID, request: $0) == pr.id ? $0 : nil }
            seen.prGatePasses = state.reviewShepherd.gatePasses[pr.id] ?? false
        }
        return seen
    }

    /// A device glyph's click: selects the row's worktree, makes sure it has a
    /// right pane, then shows the device there. `showDevice` itself does not
    /// focus, so an agent's `device_open` never steals the selection.
    private func showDevice(_ id: String, in wt: Worktree) {
        state.focusGlobalWorktree(id: wt.id, projectId: wt.projectId)
        _ = state.rightPaneStore.state(
            for: wt,
            baseBranch: state.config.worktrees.baseBranch,
            comparisonMode: state.config.changes.comparisonMode
        )
        state.showDevice(id, in: wt.id)
    }

    /// A VM's state from memory only. `vmDeviceStatus` also reads the VM
    /// registry and bundle on disk, too slow for every sidebar render, so a
    /// paused or stopped VM reads as stopped here and shows no glyph.
    private func sidebarVMStatus(worktreeID: String, guest: VMGuestOS) -> VMDeviceStatus {
        let id = VMIdentity.recordID(worktree: worktreeID, guest: guest)
        if state.vmManager.pausing.contains(id) { return .pausing }
        if state.vmManager.isStarting(id) { return .starting }
        if state.vmManager.running(worktreeID, guest: guest) != nil { return .running }
        return .stopped
    }

    /// The devices this worktree used last, with their live state. An owned
    /// `avd:<name>` follows its running emulator; ids that resolve to the
    /// same emulator count once.
    private func ownedDevices(worktreeID: String) -> [WorktreeRowPresentation.OwnedDevice] {
        // Ownership first: a row that owns nothing never observes the device
        // panes, so their polls do not redraw it.
        let ids = state.deviceUseTracker.devices(ownedBy: worktreeID)
        guard !ids.isEmpty else { return [] }
        let simulators = state.devicePane.devices ?? []
        let bootingSimulators = state.devicePane.bootingUDIDs
        let androids = state.androidPane.devices ?? []
        let bootingAVDs = state.androidPane.bootingAVDs
        var seen: Set<String> = []
        var owned: [WorktreeRowPresentation.OwnedDevice] = []
        for id in ids {
            if AgentDevice.isSimulatorID(id) {
                let device = simulators.first { $0.udid == id }
                let deviceState: WorktreeRowPresentation.ResourceState? =
                    if device?.state == .booting || bootingSimulators.contains(id) { .starting }
                    else if device?.state == .booted { .on }
                    else { nil }
                guard seen.insert(id).inserted else { continue }
                owned.append(.init(id: id, name: device?.name ?? id, isAndroid: false, isEmulator: false, state: deviceState))
            } else {
                let avd = id.hasPrefix("avd:") ? String(id.dropFirst(4)) : nil
                let running = androids.first { avd != nil ? $0.avdName == avd : $0.serial == id }
                let deviceState: WorktreeRowPresentation.ResourceState? =
                    if running?.state == .ready { .on }
                    else if let avd, bootingAVDs.contains(avd) { .starting }
                    else { nil }
                guard seen.insert(running?.serial ?? id).inserted else { continue }
                let name = running?.title ?? (avd ?? id).replacingOccurrences(of: "_", with: " ")
                let isEmulator = avd != nil || running?.isEmulator == true || id.hasPrefix("emulator-")
                owned.append(.init(id: id, name: name, isAndroid: true, isEmulator: isEmulator, state: deviceState))
            }
        }
        return owned
    }

    private func displayedWorktrees(_ worktrees: [Worktree]) -> [Worktree] {
        WorktreeSidebarFilter.apply(worktreeFilter, to: worktrees, groupByMachine: groupWorktreesByMachine)
    }

    /// Matched worktree ids of the page on screen, in sidebar display order.
    private func filteredWorktreeIds() -> [String] {
        if let serverId = state.activeSidebarPage.peerServerId {
            guard let client = state.nativePeerSessions else { return [] }
            return NativePeerSidebarView.filteredWorktreeIds(
                client, serverId: serverId, filter: worktreeFilter, ordering: state.config.worktrees.defaultOrdering
            )
        }
        let space = state.spacesManager.activeSpace
        let members = space?.members ?? space?.projectIds.map(SpaceMemberReference.project) ?? []
        return members.flatMap { member -> [String] in
            guard case .project(let projectId) = member else { return [] }
            return displayedWorktrees(state.projectsManager.visibleWorktrees(includingLinkedTo: projectId)).map(\.id)
        }
    }

    private func resetFilterHighlight() {
        highlightedWorktreeId = WorktreeSidebarFilter.isActive(worktreeFilter) ? filteredWorktreeIds().first : nil
    }

    private func keepFilterHighlight(in ids: [String]) {
        guard let id = highlightedWorktreeId, !ids.contains(id) else { return }
        highlightedWorktreeId = ids.first
    }

    private func moveFilterHighlight(by offset: Int) {
        guard WorktreeSidebarFilter.isActive(worktreeFilter) else { return }
        highlightedWorktreeId = WorktreeSidebarFilter.moveHighlight(
            from: highlightedWorktreeId, by: offset, in: filteredWorktreeIds()
        )
    }

    /// Keeps the filter applied so the user can keep hopping between matches;
    /// Escape restores the full tree.
    private func openHighlightedWorktree() {
        guard WorktreeSidebarFilter.isActive(worktreeFilter) else { return }
        let ids = filteredWorktreeIds()
        guard let id = highlightedWorktreeId.flatMap({ ids.contains($0) ? $0 : nil }) ?? ids.first else { return }
        if let serverId = state.activeSidebarPage.peerServerId {
            state.nativePeerSessions?.selectWorktree(NativePeerWorktreeSelection(serverId: serverId, worktreeId: id))
        } else {
            state.selectWorktreeFromSidebar(id: id)
        }
        worktreeFilterFocused = false
    }

    private func clearWorktreeFilter() {
        worktreeFilter = ""
        worktreeFilterFocused = false
    }

    private var spacePagingGesture: some Gesture {
        DragGesture(minimumDistance: 24)
            .onEnded { value in
                guard abs(value.translation.width) > abs(value.translation.height) * 1.4 else { return }
                let offset = value.translation.width < 0 ? 1 : -1
                pageSpace(offset: offset)
            }
    }

    private func pageSpace(offset: Int) {
        if state.pageSidebar(offset: offset) { showTransientSpaceTitle() }
    }

    private var showsPager: Bool {
        SidebarPages.showsPager(
            spaceCount: state.spacesManager.spaces.count,
            peerCount: state.nativePeerSessions?.peerPages.count ?? 0,
            showSingleSpaceAffordance: state.spacesManager.showSingleSpaceAffordance
        )
    }

    /// Scroll offsets are kept per page; a space keeps the key it always had.
    private static func scrollKey(_ page: SidebarPage) -> String {
        switch page {
        case .space(let id): id
        case .peer: page.id
        }
    }

    private func returnToLocalSpace() {
        guard state.activeSidebarPage.peerServerId != nil else { return }
        _ = state.switchToSpace(id: state.spacesManager.activeSpaceId)
    }

    private func openRemoteSettings() {
        state.pendingSettingsSection = .remote
        onSettings()
    }

    /// A paired Mac's page: its header pinned on top, then its repos in the
    /// same scroll view, filter slot and insets a space's page uses.
    @ViewBuilder
    private func peerPage(serverId: String, isActive: Bool) -> some View {
        if let client = state.nativePeerSessions {
            VStack(spacing: 0) {
                NativePeerSpaceHeaderHost(client: client, serverId: serverId, onRemoteSettings: openRemoteSettings)
                SidebarFilterSlotScrollView(
                    isActive: isActive,
                    peerModel: peerSidebarModel,
                    scrollTarget: isActive ? highlightedWorktreeId : nil,
                    onScroll: { scrollOffsets.setOffset($0, forSpace: SidebarPage.peer(serverId: serverId).id) }
                ) {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        Color.clear.frame(height: SidebarFilterRowMetrics.slotHeight)
                            .padding(.bottom, SidebarFilterRowMetrics.slotSpacing)
                        NativePeerSidebarView(
                            client: client,
                            model: peerSidebarModel,
                            serverId: serverId,
                            filter: worktreeFilter,
                            highlightedWorktreeId: isActive ? highlightedWorktreeId : nil,
                            icon: { name in
                                state.projectsManager.projects
                                    .first { $0.name == name }
                                    .map { state.sidebarIcon(for: $0) } ?? .default()
                            },
                            onRemoteSettings: openRemoteSettings,
                            worktreeOrdering: state.config.worktrees.defaultOrdering,
                            showKeepBranchOption: state.config.worktrees.deleteBranchOnRemove
                        )
                    }
                    .padding(.top, SidebarFilterRowMetrics.restY)
                    .padding(.horizontal, scale.space[2])
                    .padding(.bottom, scale.space[5])
                }
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
        issueAttachment: IssueAttachment?,
        namesBranchFromFirstPrompt: Bool
    ) {
        guard case .createFailed(
            _, _, let base, let ggWorktreeMode, let launchSurface, let issueAttachment, let namesBranchFromFirstPrompt
        ) = operationState else {
            return (defaultBase, .inherit, .none, nil, false)
        }
        return (base, ggWorktreeMode, launchSurface, issueAttachment, namesBranchFromFirstPrompt)
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
}

/// Keep attention aggregation out of the tree's selection-driven body updates.
private struct SidebarAttentionHeader: View {
    @Bindable var state: AppState
    let onSettings: () -> Void
    let onAddProject: () -> Void
    let onAddFolder: () -> Void
    let onHideSidebar: () -> Void
    @Binding var showingNewWorkspace: Bool

    private static func inputs(for state: AppState) -> (
        aggregation: AttentionAggregation, peerRows: [RemoteSessionSummary],
        cleanupReminders: [WorktreeCleanupReminder], rollUpSummarizer: AttentionRollUpSummarizer
    ) {
        #if DEBUG
        if let demo = DesignCaptureAttention.shared.content,
           let summarizer = DesignCaptureAttention.shared.summarizer(engine: state.localTextInference) {
            return (demo.aggregation, demo.peerRows, demo.cleanupReminders, summarizer)
        }
        #endif
        return (state.attentionAggregation, state.nativePeerSessions?.attentionRows ?? [],
                state.worktreeCleanupReminders, state.makeAttentionRollUpSummarizer())
    }

    var body: some View {
        let inputs = Self.inputs(for: state)
        let aggregation = inputs.aggregation
        let peerRows = inputs.peerRows
        let pluginUpdates = state.pluginManager?.catalogUpdates ?? []
        let appUpdate = state.updates.availableUpdate
        let cleanupReminders = inputs.cleanupReminders
        let hostUpdates = state.hostUpdateReminders
        let rollUpSummarizer = inputs.rollUpSummarizer
        let presentation = SidebarAttentionPresentation(
            aggregation: aggregation,
            peerRows: peerRows, pluginUpdateCount: pluginUpdates.count, appUpdate: appUpdate,
            cleanupReminderCount: cleanupReminders.count, hostUpdateCount: hostUpdates.count
        )
        SidebarHeaderView(
            onSettings: onSettings,
            onAddProject: onAddProject,
            onAddFolder: onAddFolder,
            onSearch: { NotificationCenter.default.post(name: .alasOpenSearch, object: nil) },
            onHideSidebar: onHideSidebar,
            onNewWorkspace: { showingNewWorkspace = true },
            attentionCount: presentation.count,
            attentionInboxOpen: $state.isAttentionInboxOpen,
            attentionAggregation: aggregation,
            peerAttentionRows: peerRows,
            pluginUpdates: pluginUpdates,
            appUpdate: appUpdate,
            appUpdateReadyToRelaunch: state.updates.isReadyToRelaunch,
            cleanupReminders: cleanupReminders,
            hostUpdates: hostUpdates,
            hostUpdatesInFlight: state.hostUpdatesInFlight,
            peerIcons: state.peerIconsByServerId,
            attentionLoadError: state.attentionStore.loadError?.localizedDescription,
            attentionWriteError: state.attentionStore.writeError?.localizedDescription,
            attentionNavigationErrors: state.attentionNavigationErrors,
            onDismissAttentionItem: { state.dismissAttentionItem($0) },
            onOpenAttentionItem: { item in _ = await state.openAttentionItem(item) },
            onOpenPeerSession: { row in
                state.nativePeerSessions?.select(row.id)
                state.isAttentionInboxOpen = false
            },
            onOpenPluginSettings: {
                state.isAttentionInboxOpen = false
                state.pendingSettingsSection = .plugins
                onSettings()
            },
            onOpenAppUpdate: {
                state.isAttentionInboxOpen = false
                if state.updates.isReadyToRelaunch {
                    AppRelaunch.relaunch()
                } else {
                    state.updates.presentAvailableUpdate()
                }
            },
            onOpenWorktreeCleanup: { projectId in
                state.isAttentionInboxOpen = false
                state.presentWorktreeCleanup(projectId: projectId)
            },
            onDismissWorktreeCleanup: { state.dismissWorktreeCleanupReminder(projectId: $0) },
            onUpdateHost: { state.updateHost(from: $0) },
            onDismissHostUpdate: { state.dismissHostUpdateReminder($0) },
            attentionRollUpSummarizer: rollUpSummarizer
        )
        // The catalog throttles itself, so a long-running app picks up new releases without fetching on every open.
        .onChange(of: state.isAttentionInboxOpen) { _, isOpen in
            if isOpen { Task { await state.pluginManager?.catalog.refresh() } }
        }
    }
}

/// Reports a peer page's filter matches as streamed updates change them.
private struct PeerFilterMatchesObserver: View {
    let client: NativePeerSessions
    let serverId: String
    let filter: String
    let ordering: AppConfig.WorktreeSortMode
    let onChange: ([String]) -> Void

    var body: some View {
        Color.clear.onChange(of: NativePeerSidebarView.filteredWorktreeIds(
            client, serverId: serverId, filter: filter, ordering: ordering
        )) { _, ids in onChange(ids) }
    }
}

/// Reads the peer's worktree count from the streamed snapshot itself, so a
/// session update redraws this header and not the whole sidebar.
private struct NativePeerSpaceHeaderHost: View {
    let client: NativePeerSessions
    let serverId: String
    let onRemoteSettings: () -> Void

    var body: some View {
        if let peer = client.peerPages.first(where: { $0.serverId == serverId }) {
            let group = client.snapshot.groups.first { $0.serverId == serverId }
            NativePeerSpaceHeader(
                peer: peer,
                worktreeCount: group.map { $0.repos(ordering: .manual).reduce(0) { $0 + $1.worktrees.count } },
                onRemoteSettings: onRemoteSettings
            )
        }
    }
}

enum SidebarFilterRowMetrics {
    static let slotHeight: CGFloat = 24
    static let slotSpacing: CGFloat = 8
    /// The scroll content's top padding: where the slot sits at rest.
    static let restY: CGFloat = 6
    /// Scrolled just past the slot, so the tree sits where it would with no
    /// slot at all.
    static let parkedOffset = slotHeight + slotSpacing
}

/// Parks the content just past the filter-row slot once it is tall enough,
/// so the row starts hidden and scrolling to the top reveals it. A scroll that
/// comes to rest partway through the slot snaps fully open or hidden. The
/// content is kept at least a viewport plus the slot tall so a short sidebar
/// can park too.
private struct SidebarFilterSlotScrollView<Content: View>: View {
    /// Whether this is the Space page on screen.
    let isActive: Bool
    let peerModel: NativePeerSidebarModel
    /// Worktree row to keep in view, i.e. the filter's keyboard highlight.
    let scrollTarget: String?
    /// Content offset from the top, including any top inset.
    let onScroll: (CGFloat) -> Void
    @ViewBuilder let content: () -> Content
    @State private var position = ScrollPosition(idType: String.self)
    @State private var viewportHeight: CGFloat = 0
    @State private var parked = false
    @State private var dropTargets = SidebarWorktreeDropTargets()
    @State private var hoverTracker = SidebarHoverTracker()
    /// The latest geometry, for a collapse to read. Not state: it moves every frame.
    @State private var latestGeometry = LatestScrollGeometry()

    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            content()
                .environment(\.sidebarWorktreeDropTargets, dropTargets)
                .coordinateSpace(.named(SidebarWorktreeDropTargets.coordinateSpace))
                .sidebarHoverTracking(hoverTracker)
                .dropDestination(for: String.self) { ids, location in
                    guard let draggedId = ids.first else { return false }
                    return dropTargets.drop(draggedId, at: location)
                }
                // Lay the tree out at its ideal height, as the bare ScrollView
                // did, and only then pad it. A min-height frame alone proposes
                // that height to the content, and flexible views inside it
                // (row selection/hover shapes) grow to absorb the slack.
                .fixedSize(horizontal: false, vertical: true)
                .frame(minHeight: viewportHeight + SidebarFilterRowMetrics.parkedOffset, alignment: .top)
        }
        .scrollPosition($position)
        .scrollTargetBehavior(FilterSlotSnapBehavior())
        .onChange(of: isActive, initial: true) { _, active in
            hoverTracker.isEnabled = active
            if active {
                peerModel.willShrinkContent = { [latestGeometry] shrink in
                    guard let geometry = latestGeometry.value,
                          let offset = WorktreeSidebarFilter.offsetBeforeShrinking(
                              offset: geometry.contentOffset.y,
                              viewportHeight: geometry.containerSize.height,
                              contentHeight: geometry.contentSize.height,
                              shrink: shrink
                          ) else { return }
                    position.scrollTo(y: offset)
                }
            }
        }
        .onChange(of: scrollTarget) { _, id in
            // Centered so the pinned filter row never covers the highlight.
            guard let id else { return }
            withAnimation(.snappy(duration: 0.2)) { position.scrollTo(id: id, anchor: .center) }
        }
        .onScrollGeometryChange(for: ScrollGeometry.self, of: { $0 }) { old, new in
            latestGeometry.value = new
            if !parked, let initialOffset = WorktreeSidebarFilter.initialParkingOffset(
                contentHeight: new.contentSize.height,
                viewportHeight: new.containerSize.height,
                slot: SidebarFilterRowMetrics.parkedOffset
            ) {
                parked = true
                position.scrollTo(y: initialOffset)
            }
            if let padded = WorktreeSidebarFilter.viewportHeightToPadTo(
                stored: viewportHeight,
                viewportHeight: new.containerSize.height,
                contentHeight: new.contentSize.height,
                slot: SidebarFilterRowMetrics.parkedOffset
            ) {
                viewportHeight = padded
            }
            onScroll(new.contentOffset.y + new.contentInsets.top)
            hoverTracker.scrolled(to: new.contentOffset.y)
        }
    }
}

@MainActor
private final class LatestScrollGeometry {
    var value: ScrollGeometry?
}

private struct FilterSlotSnapBehavior: ScrollTargetBehavior {
    func updateTarget(_ target: inout ScrollTarget, context: TargetContext) {
        target.rect.origin.y = WorktreeSidebarFilter.snappedOffset(
            target.rect.minY, slot: SidebarFilterRowMetrics.parkedOffset
        )
    }
}

/// Scroll offsets published on every scroll frame. They live in an observable
/// object rather than in `SidebarView` state: a `@State` write re-evaluated the
/// whole sidebar tree each frame, even though only the filter row reads them.
@MainActor
@Observable
final class SidebarScrollOffsets {
    private var offsets: [String: CGFloat] = [:]

    func offset(forSpace spaceID: String) -> CGFloat {
        offsets[spaceID] ?? 0
    }

    /// Past the filter row's slot its position no longer changes, so a long
    /// scroll settles at one value and stops invalidating it every frame.
    func setOffset(_ offset: CGFloat, forSpace spaceID: String) {
        let clamped = min(offset, Self.offsetCeiling)
        if offsets[spaceID] != clamped { offsets[spaceID] = clamped }
    }

    /// Well above the slot, whose row has fully faded by `parkedOffset`.
    private static let offsetCeiling = SidebarFilterRowMetrics.parkedOffset + SidebarFilterRowMetrics.slotHeight
}

/// Rides its slot at the top of the scroll content, and pins over the list
/// while filtering. Owns the offset read so it does not re-render the sidebar
/// tree.
private struct SidebarWorktreeFilterRow: View {
    @Environment(\.designScale) private var scale
    @Bindable var state: AppState
    let scrollOffsets: SidebarScrollOffsets
    let spaceID: String
    @Binding var text: String
    @Binding var groupByMachine: Bool
    /// False on a peer's page, whose worktrees all live on one machine.
    let showsGroupByMachine: Bool
    var focused: FocusState<Bool>.Binding
    let onMoveHighlight: (Int) -> Void
    let onSubmit: () -> Void
    let onClear: () -> Void

    var body: some View {
        // An active filter keeps its row pinned so the narrowed tree never
        // loses the field that explains it.
        let pinned = !text.isEmpty || focused.wrappedValue
        let y = WorktreeSidebarFilter.rowY(
            scrollOffset: scrollOffsets.offset(forSpace: spaceID), pinned: pinned, restY: SidebarFilterRowMetrics.restY
        )
        let opacity = WorktreeSidebarFilter.rowOpacity(y: y, height: SidebarFilterRowMetrics.slotHeight)
        let inset = SidebarFilterRowMetrics.restY
        HStack(spacing: 4) {
            SidebarWorktreeFilterField(
                text: $text,
                focused: focused,
                // Points at the worktree switcher, which finds worktrees too,
                // under whatever key the user has bound it to.
                placeholder: state.binding(for: .switchRepository)
                    .map { "Filter worktrees · \($0.displayString)" } ?? "Filter worktrees"
            )
            .onKeyPress(.downArrow) {
                onMoveHighlight(1)
                return .handled
            }
            .onKeyPress(.upArrow) {
                onMoveHighlight(-1)
                return .handled
            }
            .onSubmit(onSubmit)
            .onExitCommand(perform: onClear)
            WorktreeSortMenu(
                selection: state.config.worktrees.defaultOrdering,
                onSelect: { state.setDefaultWorktreeOrdering($0) },
                groupByMachine: $groupByMachine,
                showsGroupByMachine: showsGroupByMachine
            )
        }
        .frame(height: SidebarFilterRowMetrics.slotHeight)
        .padding(.leading, scale.space[3])
        .padding(.trailing, scale.space[2])
        .padding(.vertical, inset)
        // Hides the content that scrolls beneath the row while a filter is
        // applied; fades in and out as the text appears and clears.
        .background {
            let override = state.config.sidebarChromeOverride(forThemeId: state.themeStore.current.id)
            SidebarMaterialBackground(
                choice: state.config.sidebarMaterial,
                backgroundOpacity: override.backgroundOpacity
            )
            .opacity(text.isEmpty ? 0 : 1)
            .animation(.easeInOut(duration: 0.2), value: text.isEmpty)
        }
        .offset(y: y - inset)
        .opacity(opacity)
        .allowsHitTesting(opacity > 0.5)
    }
}

private struct SidebarWorktreeFilterField: View {
    @Binding var text: String
    var focused: FocusState<Bool>.Binding
    let placeholder: String
    @Environment(\.theme) private var theme
    @Environment(\.designScale) private var scale

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "line.3.horizontal.decrease")
                .font(scale.metaFont)
                .foregroundStyle(theme.color("fg-dim"))
                .accessibilityHidden(true)
            TextField(placeholder, text: $text)
                .textFieldStyle(.plain)
                .font(scale.metaFont)
                .foregroundStyle(theme.color("fg"))
                .autocorrectionDisabled(true)
                .focused(focused)
                // The filter is the window's first text field, so AppKit would
                // otherwise make it first responder when the window opens.
                .background(KeyViewRefusingTextField())
            if !text.isEmpty {
                Button {
                    text = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(scale.metaFont)
                        .foregroundStyle(theme.color("fg-faint"))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear worktree filter")
            }
        }
        .padding(.horizontal, scale.space[2])
        .frame(height: 24)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: scale.radius.medium))
        .overlay(
            RoundedRectangle(cornerRadius: scale.radius.medium)
                .strokeBorder(theme.color(focused.wrappedValue ? "accent" : "line"), lineWidth: 0.5)
        )
    }
}

/// Sets `refusesFirstResponder` on the `NSTextField` backing the SwiftUI
/// `TextField` it sits behind, only while the window is first presented, so
/// AppKit skips the field when it picks the initial first responder. The
/// property is restored once the window is key, which keeps the field in the
/// key view loop for keyboard navigation.
private struct KeyViewRefusingTextField: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { MarkerView() }
    func updateNSView(_ nsView: NSView, context: Context) {
        (nsView as? MarkerView)?.markTextField()
    }

    private final class MarkerView: NSView {
        private weak var markedField: NSTextField?

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            markTextField()
        }

        // Frames are still zero when the view first joins the window.
        override func layout() {
            super.layout()
            markTextField()
        }

        func markTextField() {
            guard window != nil, markedField?.window != window else { return }
            let center = convert(NSPoint(x: bounds.midX, y: bounds.midY), to: nil)
            var ancestor = superview
            while let view = ancestor {
                if let field = Self.textField(in: view, containing: center) {
                    field.refusesFirstResponder = true
                    markedField = field
                    restoreAfterInitialFocus(of: field)
                    return
                }
                ancestor = view.superview
            }
        }

        private func restoreAfterInitialFocus(of field: NSTextField) {
            guard let window else { return }
            let restore = { [weak field] in
                // Initial responder selection runs during the key-window
                // transition, so restore on the turn after it.
                DispatchQueue.main.async { field?.refusesFirstResponder = false }
            }
            if window.isKeyWindow {
                restore()
                return
            }
            var token: NSObjectProtocol?
            token = NotificationCenter.default.addObserver(
                forName: NSWindow.didBecomeKeyNotification, object: window, queue: .main
            ) { _ in
                token.map(NotificationCenter.default.removeObserver)
                restore()
            }
        }

        private static func textField(in view: NSView, containing point: NSPoint) -> NSTextField? {
            for subview in view.subviews {
                if let field = subview as? NSTextField, field.isEditable,
                   field.convert(field.bounds, to: nil).contains(point) {
                    return field
                }
                if let field = textField(in: subview, containing: point) { return field }
            }
            return nil
        }
    }
}
