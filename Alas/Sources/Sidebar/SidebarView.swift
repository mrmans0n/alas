import SwiftUI
import AppKit

struct SidebarAttentionPresentation {
    let showsInbox: Bool
    let count: Int

    init(enabled: Bool, aggregation: AttentionAggregation, peerRows: [RemoteSessionSummary] = []) {
        showsInbox = enabled
        count = enabled ? aggregation.unresolvedCount + peerRows.count : 0
    }
}

struct SidebarView: View {
    @Bindable var state: AppState
    @Binding var collapsedProjects: Set<String>
    let onSettings: () -> Void
    let onAddProject: () -> Void
    let onEditProject: (_ projectId: String) -> Void
    let onRemoveProject: (_ projectId: String) -> Void
    let onNewWorktree: (_ projectId: String?) -> Void
    let onCleanupWorktrees: (_ projectId: String) -> Void
    let onHideSidebar: () -> Void
    @Environment(\.theme) var theme
    @State private var spaceTitleVisible = false
    @State private var hideTitleTask: Task<Void, Never>?
    @State private var showingNewWorkspace = false
    /// Transient: never persisted and never applied outside this sidebar.
    @State private var worktreeFilter = ""
    @State private var highlightedWorktreeId: String?
    @FocusState private var worktreeFilterFocused: Bool
    /// Per space, since every page keeps its own scroll view. Read only by the
    /// filter row, so per-frame scroll updates re-render it alone rather than
    /// the whole tree.
    @State private var scrollOffsets = SidebarScrollOffsets()
    @State private var peerSidebarModel = NativePeerSidebarModel()

    var body: some View {
        let override = state.config.sidebarChromeOverride(forThemeId: state.themeStore.current.id)
        ZStack {
            SidebarMaterialBackground(
                choice: state.config.sidebarMaterial,
                backgroundOpacity: override.backgroundOpacity
            )
            VStack(spacing: 0) {
                SidebarAttentionHeader(
                    state: state,
                    onSettings: onSettings,
                    onAddProject: onAddProject,
                    onHideSidebar: onHideSidebar,
                    showingNewWorkspace: $showingNewWorkspace
                )
                SpacePagerContent(spaces: state.spacesManager.spaces, selection: state.spacesManager.activeSpaceId) { spaceID in
                    WorkspaceSidebarTreeHost(state: state) { treeModel in
                        SidebarFilterSlotScrollView(
                            scrollTarget: spaceID == state.spacesManager.activeSpaceId ? highlightedWorktreeId : nil,
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
                                    isInteractive: spaceID == state.spacesManager.activeSpaceId
                                ) { project in
                                    RepoGroupView(
                                        project: project,
                                        icon: { state.effectiveIcon(for: $0) },
                                        worktrees: WorktreeSidebarFilter.apply(
                                            worktreeFilter,
                                            to: state.projectsManager.visibleWorktrees(projectId: project.id)
                                        ),
                                        collapsed: Binding(
                                            get: { collapsedProjects.contains(project.id) },
                                            set: { collapsed in
                                                if collapsed { collapsedProjects.insert(project.id) }
                                                else { collapsedProjects.remove(project.id) }
                                            }
                                        ),
                                        selectedWorktreeId: state.selectedWorktreeId,
                                        isMain: { wt in state.projectsManager.isMain(wt, in: project) },
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
                                                projectId: project.id,
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
                                                projectId: project.id,
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
                                        onRetryLaunch: { wt in
                                            Task { @MainActor in
                                                await state.retryWorktreeLaunch(wt, project: project)
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
                                        },
                                        commitQuery: { wt in
                                            guard !state.projectsManager.isMain(wt, in: project) else { return nil }
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
                                                in: project
                                            ) else { return nil }
                                            return state.worktreeExplainerStore.explanation(
                                                for: wt.id,
                                                evidence: evidence
                                            )
                                        },
                                        worktreeExplainerEvidence: { wt in
                                            state.worktreeExplainerEvidence(for: wt, in: project)
                                        },
                                        onPrepareWorktreeExplanation: { wt, evidence in
                                            await state.worktreeExplainerStore.prepare(
                                                worktreeID: wt.id,
                                                evidence: evidence
                                            )
                                        },
                                        pluginCommands: { state.pluginCommands($0, projectID: project.id) },
                                        onRunPluginCommand: { item, slot, wt in
                                            state.runPluginCommand(item, slot: slot, worktreeID: wt?.id)
                                        },
                                        pluginDecorations: { wt in
                                            wt.map { state.pluginDecorations(.worktreeRow, projectID: project.id, target: $0.id) }
                                                ?? state.pluginDecorations(.repoRow, projectID: project.id, target: project.id)
                                        },
                                        onRunPluginDecoration: { state.runPluginDecoration($0) },
                                        isFiltering: WorktreeSidebarFilter.isActive(worktreeFilter),
                                        highlightedWorktreeId: highlightedWorktreeId
                                    )
                                }
                                if let nativePeerSessions = state.nativePeerSessions {
                                    NativePeerSidebarView(
                                        client: nativePeerSessions,
                                        model: peerSidebarModel,
                                        icon: { name in
                                            state.projectsManager.projects
                                                .first { $0.name == name }
                                                .map { state.effectiveIcon(for: $0) } ?? .default()
                                        },
                                        onAddPeer: {
                                            state.pendingSettingsSection = .remote
                                            onSettings()
                                        },
                                        worktreeOrdering: state.config.worktrees.defaultOrdering,
                                        topSpacing: SidebarFilterRowMetrics.slotSpacing
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
                            .padding(.top, 6)
                            .padding(.horizontal, 8)
                            // Leaves room below the last repo for the drop target.
                            .padding(.bottom, 20)
                        }
                    }
                }
                .overlay(alignment: .top) {
                    SidebarWorktreeFilterRow(
                        state: state,
                        scrollOffsets: scrollOffsets,
                        spaceID: state.spacesManager.activeSpaceId,
                        text: $worktreeFilter,
                        focused: $worktreeFilterFocused,
                        onMoveHighlight: moveFilterHighlight(by:),
                        onSubmit: openHighlightedWorktree,
                        onClear: clearWorktreeFilter
                    )
                }
                .clipped()
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
                            pageSpace(offset: offset)
                        }
                    )
                    .contentShape(Rectangle())
                    .gesture(spacePagingGesture)
                }
            }
            .sidebarChromeTheme(textContrast: override.textContrast)
            .background {
                if let nativePeerSessions = state.nativePeerSessions {
                    NativePeerSidebarExpansion(client: nativePeerSessions, model: peerSidebarModel)
                }
            }
            .background {
                if state.spacesManager.shouldShowSpaceAffordance {
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
        // Matches change without a query change on a space switch, or when a
        // highlighted worktree is archived, deleted or refreshed away. Only a
        // highlight that is no longer a match moves, back to the first one.
        .onChange(of: WorktreeSidebarFilter.isActive(worktreeFilter) ? filteredWorktreeIds() : []) { _, ids in
            guard let id = highlightedWorktreeId, !ids.contains(id) else { return }
            highlightedWorktreeId = ids.first
        }
        .onDisappear {
            hideTitleTask?.cancel()
            hideTitleTask = nil
        }
        .sheet(isPresented: $showingNewWorkspace) {
            NewWorkspaceDialog(state: state, presented: $showingNewWorkspace)
        }
    }

    /// Matched worktree ids of the active space, in sidebar display order.
    private func filteredWorktreeIds() -> [String] {
        let space = state.spacesManager.activeSpace
        let members = space?.members ?? space?.projectIds.map(SpaceMemberReference.project) ?? []
        return members.flatMap { member -> [String] in
            guard case .project(let projectId) = member else { return [] }
            return WorktreeSidebarFilter.apply(
                worktreeFilter,
                to: state.projectsManager.visibleWorktrees(projectId: projectId)
            ).map(\.id)
        }
    }

    private func resetFilterHighlight() {
        highlightedWorktreeId = WorktreeSidebarFilter.isActive(worktreeFilter) ? filteredWorktreeIds().first : nil
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
        state.selectWorktreeFromSidebar(id: id)
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
        let spaces = state.spacesManager.spaces
        guard let current = spaces.firstIndex(where: { $0.id == state.spacesManager.activeSpaceId }),
              let next = SpacePagerNavigation.destination(current: current, offset: offset, count: spaces.count)
        else { return }
        if state.switchToSpace(id: spaces[next].id) { showTransientSpaceTitle() }
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
    let onHideSidebar: () -> Void
    @Binding var showingNewWorkspace: Bool

    var body: some View {
        let aggregation = state.attentionAggregation
        let peerRows = state.config.needsAttentionEnabled
            ? state.nativePeerSessions?.snapshot.attentionRows ?? [] : []
        let presentation = SidebarAttentionPresentation(
            enabled: state.config.needsAttentionEnabled, aggregation: aggregation,
            peerRows: peerRows
        )
        SidebarHeaderView(
            onSettings: onSettings,
            onAddProject: onAddProject,
            onSearch: { NotificationCenter.default.post(name: .alasOpenSearch, object: nil) },
            onHideSidebar: onHideSidebar,
            onNewWorkspace: { showingNewWorkspace = true },
            attentionCount: presentation.count,
            showsAttentionInbox: presentation.showsInbox,
            attentionInboxOpen: $state.isAttentionInboxOpen,
            attentionAggregation: aggregation,
            peerAttentionRows: peerRows,
            attentionLoadError: state.attentionStore.loadError?.localizedDescription,
            attentionWriteError: state.attentionStore.writeError?.localizedDescription,
            attentionNavigationErrors: state.attentionNavigationErrors,
            onDismissAttentionItem: { state.dismissAttentionItem($0) },
            onOpenAttentionItem: { item in _ = await state.openAttentionItem(item) },
            onOpenPeerSession: { row in
                state.nativePeerSessions?.select(row.id)
                state.isAttentionInboxOpen = false
            },
            attentionRollUpSummarizer: state.makeAttentionRollUpSummarizer()
        )
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
    /// Worktree row to keep in view, i.e. the filter's keyboard highlight.
    let scrollTarget: String?
    /// Content offset from the top, including any top inset.
    let onScroll: (CGFloat) -> Void
    @ViewBuilder let content: () -> Content
    @State private var position = ScrollPosition(idType: String.self)
    @State private var viewportHeight: CGFloat = 0
    @State private var parked = false
    @State private var dropTargets = SidebarWorktreeDropTargets()

    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            content()
                .environment(\.sidebarWorktreeDropTargets, dropTargets)
                .coordinateSpace(.named(SidebarWorktreeDropTargets.coordinateSpace))
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
        .onGeometryChange(for: CGFloat.self, of: { $0.size.height }) { viewportHeight = $0 }
        .onChange(of: scrollTarget) { _, id in
            // Centered so the pinned filter row never covers the highlight.
            guard let id else { return }
            withAnimation(.snappy(duration: 0.2)) { position.scrollTo(id: id, anchor: .center) }
        }
        .onScrollGeometryChange(for: ScrollGeometry.self, of: { $0 }) { old, new in
            if !parked, let initialOffset = WorktreeSidebarFilter.initialParkingOffset(
                contentHeight: new.contentSize.height,
                viewportHeight: new.containerSize.height,
                slot: SidebarFilterRowMetrics.parkedOffset
            ) {
                parked = true
                position.scrollTo(y: initialOffset)
            }
            onScroll(new.contentOffset.y + new.contentInsets.top)
        }
    }
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

    func setOffset(_ offset: CGFloat, forSpace spaceID: String) {
        offsets[spaceID] = offset
    }
}

/// Rides its slot at the top of the scroll content, and pins over the list
/// while filtering. Owns the offset read so it does not re-render the sidebar
/// tree.
private struct SidebarWorktreeFilterRow: View {
    @Bindable var state: AppState
    let scrollOffsets: SidebarScrollOffsets
    let spaceID: String
    @Binding var text: String
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
                onSelect: { state.setDefaultWorktreeOrdering($0) }
            )
        }
        .frame(height: SidebarFilterRowMetrics.slotHeight)
        .padding(.leading, 12)
        .padding(.trailing, 8)
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

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "line.3.horizontal.decrease")
                .font(.system(size: 11))
                .foregroundStyle(theme.color("fg-dim"))
                .accessibilityHidden(true)
            TextField(placeholder, text: $text)
                .textFieldStyle(.plain)
                .font(.system(size: 11.5))
                .foregroundStyle(theme.color("fg"))
                .autocorrectionDisabled(true)
                .focused(focused)
            if !text.isEmpty {
                Button {
                    text = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(theme.color("fg-faint"))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear worktree filter")
            }
        }
        .padding(.horizontal, 8)
        .frame(height: 24)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 6))
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .strokeBorder(theme.color(focused.wrappedValue ? "accent" : "line"), lineWidth: 0.5)
        )
    }
}
