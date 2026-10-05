import SwiftUI
import UniformTypeIdentifiers

struct ProjectDragId: Codable, Transferable {
    let id: String
    static var transferRepresentation: some TransferRepresentation {
        CodableRepresentation(contentType: .json)
    }
}

struct RepoGroupView: View {
    /// Leading inset that nests worktree rows under their repo header.
    static let worktreeIndent: CGFloat = 26

    let project: ProjectConfig
    /// Resolves the icon to display for a project, which may come from the
    /// repo's `.alas/` directory when the project has no explicit icon.
    let icon: (ProjectConfig) -> ProjectIcon
    let worktrees: [Worktree]
    @Binding var collapsed: Bool
    let selectedWorktreeId: String?
    let isMain: (Worktree) -> Bool
    let upstreamStatus: (Worktree) -> WorktreeUpstreamStatus?
    var onPullUpstream: ((Worktree) -> Void)? = nil
    var isPullUpstreamInFlight: ((Worktree) -> Bool)? = nil
    let workspaceCheckout: (Worktree) -> WorktreeWorkspaceCheckoutPresentation?
    let operationState: (Worktree) -> WorktreeOperationState?
    let harnessSummary: (String) -> HarnessService.WorktreeHarnessSummary?
    let ggMenuModel: (Worktree) -> GGWorktreeMenuModel
    let onSelect: (Worktree) -> Void
    let onNewWorktree: () -> Void
    let onEditProject: () -> Void
    let onRemoveProject: () -> Void
    let onOpenGGInbox: (() -> Void)?
    let onResetSort: () -> Void
    let spaces: [SpaceConfig]
    let activeSpaceId: String
    let isProjectInSpace: (_ spaceId: String) -> Bool
    let canRemoveFromSpace: (_ spaceId: String) -> Bool
    let onToggleSpaceMembership: (_ spaceId: String) -> Void
    let onOpenTerminal: (Worktree) -> Void
    var onOpenIssue: ((Worktree) -> (() -> Void)?)? = nil
    let onCopyPath: (Worktree) -> Void
    let onCopyBranch: (Worktree) -> Void
    let onRevealInFinder: (Worktree) -> Void
    let onArchive: (Worktree) -> Void
    let onCleanupWorktrees: () -> Void
    let onDelete: (Worktree) -> Void
    let onDeleteKeepBranch: (Worktree) -> Void
    let showKeepBranchOption: Bool
    let onActivateHarness: (Worktree, String) -> Void
    let onCopyError: (String) -> Void
    let onRetryCreate: (Worktree) -> Void
    let onRetryLaunch: (Worktree) -> Void
    let onRetryDelete: (Worktree) -> Void
    let onSetGGWorktreeMode: (Worktree, GGWorktreeMode) -> Void
    let onRemoveFailed: (Worktree) -> Void
    let onDropWorktree: (_ draggedId: String, _ destinationId: String) -> Void
    let onDropProject: (_ draggedId: String, _ destinationId: String) -> Void
    var commitQuery: (Worktree) -> WorktreeRowView.CommitQuery? = { _ in nil }
    var worktreeExplanation: (Worktree) -> String? = { _ in nil }
    var worktreeExplainerEvidence: (Worktree) -> WorktreeExplainerEvidence? = { _ in nil }
    var onPrepareWorktreeExplanation:
        @MainActor (Worktree, WorktreeExplainerEvidence) async -> Bool = { _, _ in true }

    var pluginCommands: (PluginCommandSlot) -> [PluginCommandItem] = { _ in [] }
    var onRunPluginCommand: (PluginCommandItem, PluginCommandSlot, Worktree?) -> Void = { _, _, _ in }
    /// Plugin badges for a worktree row, or for the project's header when nil.
    var pluginDecorations: (Worktree?) -> [PluginDecorationItem] = { _ in [] }
    var onRunPluginDecoration: (PluginDecorationItem) -> Void = { _ in }
    /// Set while the sidebar filter is active and `worktrees` holds only the
    /// matches. Rows then follow the matches rather than `collapsed`, which is
    /// left untouched so clearing the filter restores the tree exactly.
    var isFiltering = false
    var highlightedWorktreeId: String? = nil
    @Environment(\.theme) var theme
    @ObservedObject private var hostStatus = RemoteHostStatusStore.shared
    @State private var hovering = false

    private var isCollapsed: Bool { isFiltering ? worktrees.isEmpty : collapsed }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Collapse toggle and the inline + are independent controls in the
            // same row. Don't wrap the row in a parent Button — that nests the
            // + inside another button's hit region and clicking the + can also
            // fire the collapse action.
            HStack(spacing: 7) {
                HStack(spacing: 7) {
                    Icon(name: isCollapsed ? "chev-right" : "chev-down", size: 10, color: theme.color("fg-faint"))
                        .frame(width: 12, height: 14)
                        .contentShape(Rectangle())
                    ProjectIconView(icon: icon(project), fallbackName: project.name, size: .repoHeader)
                        .accessibilityLabel(ProjectIconView.accessibilityLabel(project: project))
                    Text(project.name)
                        .font(.system(size: 12.5, weight: .semibold))
                        .tracking(-0.12)
                        .foregroundColor(theme.color("fg"))
                        .lineLimit(1)
                    if let host = project.host {
                        HStack(spacing: 3) {
                            if hostStatus.isOffline(host) {
                                Image(systemName: "bolt.horizontal.circle")
                                    .font(.system(size: 9))
                                    .foregroundColor(.orange)
                            }
                            Text(host)
                        }
                        .font(.system(size: 9, weight: .medium, design: .monospaced))
                        .foregroundColor(theme.color("fg-dim"))
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                        .background(theme.color("bg-4"))
                        .clipShape(RoundedRectangle(cornerRadius: 4))
                        .help(hostStatus.isOffline(host)
                            ? "Host \(host) is unreachable"
                            : "Remote project on \(host) (SSH)")
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
                .onTapGesture { if !isFiltering { collapsed.toggle() } }
                headerAccessory
            }
            .padding(5)
            // A project with no filter matches stays in place, dimmed.
            .opacity(isFiltering && worktrees.isEmpty ? 0.45 : 1)
            .background(hovering ? theme.color("bg-3").opacity(0.55) : .clear, in: RoundedRectangle(cornerRadius: 8))
            .overlay {
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(theme.color("line").opacity(hovering ? 0.75 : 0), lineWidth: 0.75)
            }
            .padding(.top, 3)
            .contentShape(Rectangle())
            .nativeContextMenu {
                Button("Edit Project…", action: onEditProject)
                if let onOpenGGInbox {
                    Button("gg Inbox", action: onOpenGGInbox)
                }
                Button("Reset Sort to Default", action: onResetSort)
                    .disabled(!project.worktreeOrderIsManual)
                Button("Clean Up Worktrees…", action: onCleanupWorktrees)
                Menu("Spaces") {
                    ForEach(spaces) { space in
                        let isMember = isProjectInSpace(space.id)
                        Button {
                            onToggleSpaceMembership(space.id)
                        } label: {
                            HStack {
                                Text("\(space.emoji) \(space.name)")
                                if isMember { Text("✓") }
                            }
                        }
                        .disabled(isMember && !canRemoveFromSpace(space.id))
                    }
                }
                let commands = pluginCommands(.repoMenu)
                if !commands.isEmpty {
                    Divider()
                    PluginCommandButtons(items: commands) { onRunPluginCommand($0, .repoMenu, nil) }
                }
                Divider()
                Button("Remove Project…", role: .destructive, action: onRemoveProject)
            }
            .onHover { hovering = $0 }
            .draggable(ProjectDragId(id: project.id))
            .dropDestination(for: ProjectDragId.self) { items, _ in
                guard let draggedId = items.first?.id, draggedId != project.id else { return false }
                onDropProject(draggedId, project.id)
                return true
            }
            if !isCollapsed {
                VStack(spacing: 1) {
                    ForEach(worktrees) { wt in
                        WorktreeRowView(
                            worktree: wt,
                            isSelected: wt.id == selectedWorktreeId,
                            isMain: isMain(wt),
                            upstreamStatus: upstreamStatus(wt),
                            onPullUpstream: onPullUpstream.map { pull in { pull(wt) } },
                            isPullUpstreamInFlight: isPullUpstreamInFlight?(wt) ?? false,
                            operationState: operationState(wt),
                            harnessSummary: harnessSummary(wt.id),
                            ggMenuModel: ggMenuModel(wt),
                            onTap: { onSelect(wt) },
                            onOpenTerminal: { onOpenTerminal(wt) },
                            onOpenIssue: onOpenIssue?(wt),
                            onCopyPath: { onCopyPath(wt) },
                            onCopyBranch: { onCopyBranch(wt) },
                            onRevealInFinder: { onRevealInFinder(wt) },
                            onArchive: { onArchive(wt) },
                            onDelete: { onDelete(wt) },
                            onDeleteKeepBranch: { onDeleteKeepBranch(wt) },
                            showKeepBranchOption: showKeepBranchOption,
                            onActivateHarness: { sessionId in onActivateHarness(wt, sessionId) },
                            onCopyError: onCopyError,
                            onRemoveFailed: { onRemoveFailed(wt) },
                            onRetryCreate: { onRetryCreate(wt) },
                            onRetryLaunch: { onRetryLaunch(wt) },
                            onRetryDelete: { onRetryDelete(wt) },
                            onSetGGWorktreeMode: { mode in onSetGGWorktreeMode(wt, mode) },
                            workspaceCheckout: workspaceCheckout(wt),
                            commitQuery: commitQuery(wt),
                            worktreeExplanation: worktreeExplanation(wt),
                            worktreeExplainerEvidence: worktreeExplainerEvidence(wt),
                            onPrepareWorktreeExplanation: { evidence in
                                await onPrepareWorktreeExplanation(wt, evidence)
                            },
                            pluginCommands: pluginCommands(.worktreeMenu),
                            onRunPluginCommand: { onRunPluginCommand($0, .worktreeMenu, wt) },
                            pluginDecorations: pluginDecorations(wt),
                            onRunPluginDecoration: onRunPluginDecoration,
                            isHighlighted: wt.id == highlightedWorktreeId
                        )
                        // Scroll target for the sidebar filter's highlight.
                        .id(wt.id)
                        .draggable(wt.id)
                        .dropDestination(for: String.self) { ids, _ in
                            guard let draggedId = ids.first, draggedId != wt.id else { return false }
                            onDropWorktree(draggedId, wt.id)
                            return true
                        }
                    }
                }
                // Worktrees are nested under their repo by indentation alone.
                // This was previously split either side of a tree-guide rail;
                // the rail is gone but the total inset is unchanged.
                .padding(.leading, Self.worktreeIndent)
                .padding(.trailing, 6)
            }
        }
    }

    private var headerAccessory: some View {
        // This lives in the header's HStack rather than a trailing overlay so
        // the project title always yields space to the count and new-worktree
        // control at narrow sidebar widths.
        HStack(spacing: 6) {
            PluginDecorationBadges(items: pluginDecorations(nil), run: onRunPluginDecoration)
            if isCollapsed, let summary = projectSummary() {
                HarnessPill(
                    summary: summary,
                    variant: .dotOnly,
                    tooltip: headerTooltip()
                )
            }
            SidebarHeaderCountPlusButton(
                count: worktrees.count,
                rowHovering: hovering,
                help: "New worktree in \(project.name)",
                action: onNewWorktree
            )
        }
    }

    private var summaries: [HarnessService.WorktreeHarnessSummary] {
        worktrees.compactMap { harnessSummary($0.id) }
    }

    /// Project-level rollup: awaiting wins across worktrees, then failed,
    /// then running, then limited. Returns nil if no worktree in this project has any badge.
    private func projectSummary() -> HarnessService.WorktreeHarnessSummary? {
        summaries.min { $0.state.rollUpRank < $1.state.rollUpRank }
    }

    private func headerTooltip() -> String {
        let runningCount = summaries.reduce(0) { $0 + $1.runningSessionCount }
        let awaitingCount = summaries.reduce(0) { $0 + $1.awaitingSessionCount }
        let limitedCount = summaries.reduce(0) { $0 + $1.sessions.count { $0.state == .limited } }
        let failedCount = summaries.reduce(0) { $0 + $1.sessions.count { $0.state == .failed } }
        let distinctAgents: [AgentKind] = AgentKind.allCases.filter { agent in
            summaries.contains { $0.agent == agent }
        }
        let kindList = distinctAgents.map(\.displayName).joined(separator: ", ")

        var parts: [String] = []
        if runningCount > 0 { parts.append("\(runningCount) running") }
        if awaitingCount > 0 { parts.append("\(awaitingCount) awaiting") }
        if failedCount > 0 { parts.append("\(failedCount) failed") }
        if limitedCount > 0 { parts.append("\(limitedCount) limited") }
        let head = parts.joined(separator: ", ")
        return kindList.isEmpty ? head : "\(head) (\(kindList))"
    }
}
