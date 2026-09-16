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
    let worktrees: [Worktree]
    @Binding var collapsed: Bool
    let selectedWorktreeId: String?
    let isMain: (Worktree) -> Bool
    let upstreamStatus: (Worktree) -> WorktreeUpstreamStatus?
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
    let onRetryDelete: (Worktree) -> Void
    let onSetGGWorktreeMode: (Worktree, GGWorktreeMode) -> Void
    let onRemoveFailed: (Worktree) -> Void
    let onDropWorktree: (_ draggedId: String, _ destinationId: String) -> Void
    let onDropProject: (_ draggedId: String, _ destinationId: String) -> Void
    @Environment(\.theme) var theme
    @ObservedObject private var hostStatus = RemoteHostStatusStore.shared
    @State private var hovering = false
    @State private var plusHovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Collapse toggle and the inline + are independent controls in the
            // same row. Don't wrap the row in a parent Button — that nests the
            // + inside another button's hit region and clicking the + can also
            // fire the collapse action.
            HStack(spacing: 7) {
                HStack(spacing: 7) {
                    Icon(name: collapsed ? "chev-right" : "chev-down", size: 10, color: theme.color("fg-faint"))
                        .frame(width: 12, height: 14)
                        .contentShape(Rectangle())
                    ProjectIconView(icon: project.icon, fallbackName: project.name, size: .repoHeader)
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
                .onTapGesture { collapsed.toggle() }
                headerAccessory
            }
            .padding(5)
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
            if !collapsed {
                VStack(spacing: 1) {
                    ForEach(worktrees) { wt in
                        WorktreeRowView(
                            worktree: wt,
                            isSelected: wt.id == selectedWorktreeId,
                            isMain: isMain(wt),
                            upstreamStatus: upstreamStatus(wt),
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
                            onRetryDelete: { onRetryDelete(wt) },
                            onSetGGWorktreeMode: { mode in onSetGGWorktreeMode(wt, mode) }
                        )
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
            if collapsed, let summary = projectSummary() {
                HarnessPill(
                    summary: summary,
                    variant: .dotOnly,
                    tooltip: headerTooltip()
                )
            }
            ZStack {
                Text("\(worktrees.count)")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(theme.color("fg-faint"))
                    .monospacedDigit()
                    .opacity(hovering ? 0 : 1)
                    .allowsHitTesting(false)
                Button(action: onNewWorktree) {
                    Icon(name: "plus", size: 11,
                         color: plusHovering ? theme.color("fg") : theme.color("fg-faint"))
                        .frame(width: 18, height: 18)
                        .background(plusHovering ? theme.color("bg-4") : .clear)
                        .clipShape(RoundedRectangle(cornerRadius: 4))
                }
                .buttonStyle(.plain)
                .onHover { plusHovering = $0 }
                .help("New worktree in \(project.name)")
                .opacity(hovering ? 1 : 0)
                .allowsHitTesting(hovering)
            }
            .frame(width: 18, height: 18)
        }
    }

    private var summaries: [HarnessService.WorktreeHarnessSummary] {
        worktrees.compactMap { harnessSummary($0.id) }
    }

    /// Project-level rollup: awaiting wins across worktrees, else running.
    /// Returns nil if no worktree in this project has any busy session.
    private func projectSummary() -> HarnessService.WorktreeHarnessSummary? {
        if let s = summaries.first(where: { $0.state == .awaiting }) { return s }
        return summaries.first(where: { $0.state == .running })
    }

    private func headerTooltip() -> String {
        let runningCount = summaries.reduce(0) { $0 + $1.runningSessionCount }
        let awaitingCount = summaries.reduce(0) { $0 + $1.awaitingSessionCount }
        let distinctAgents: [AgentKind] = AgentKind.allCases.filter { agent in
            summaries.contains { $0.agent == agent }
        }
        let kindList = distinctAgents.map(\.displayName).joined(separator: ", ")

        var parts: [String] = []
        if runningCount > 0 { parts.append("\(runningCount) running") }
        if awaitingCount > 0 { parts.append("\(awaitingCount) awaiting") }
        let head = parts.joined(separator: ", ")
        return kindList.isEmpty ? head : "\(head) (\(kindList))"
    }
}
