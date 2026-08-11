import SwiftUI
import UniformTypeIdentifiers

struct ProjectDragId: Codable, Transferable {
    let id: String
    static var transferRepresentation: some TransferRepresentation {
        CodableRepresentation(contentType: .json)
    }
}

struct RepoGroupView: View {
    let project: ProjectConfig
    let worktrees: [Worktree]
    @Binding var collapsed: Bool
    let selectedWorktreeId: String?
    let isMain: (Worktree) -> Bool
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
    let onDelete: (Worktree) -> Void
    let onDeleteKeepBranch: (Worktree) -> Void
    let showKeepBranchOption: Bool
    let onActivateHarness: (Worktree) -> Void
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
                Icon(name: collapsed ? "chev-right" : "chev-down", size: 10, color: theme.color("fg-faint"))
                    .frame(width: 14, height: 14)
                    .contentShape(Rectangle())
                ProjectIconView(icon: project.icon, fallbackName: project.name, size: .sidebar)
                    .accessibilityLabel(ProjectIconView.accessibilityLabel(project: project))
                Text(project.name)
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundColor(theme.color("fg-muted"))
                if let host = project.host {
                    HStack(spacing: 3) {
                        if hostStatus.isOffline(host) {
                            Image(systemName: "bolt.horizontal.circle")
                                .font(.system(size: 9))
                                .foregroundColor(.orange)
                        }
                        Text(host)
                    }
                        .font(.system(size: 9.5, weight: .medium))
                        .foregroundColor(theme.color("fg-faint"))
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(theme.color("bg-4"))
                        .clipShape(Capsule())
                        .help(hostStatus.isOffline(host)
                            ? "Host \(host) is unreachable"
                            : "Remote project on \(host) (SSH)")
                }
                Spacer(minLength: 0)
            }
            .padding(.leading, 12)
            .padding(.vertical, 5)
            .contentShape(Rectangle())
            .onTapGesture { collapsed.toggle() }
            .contextMenu {
                Button("Edit Project…", action: onEditProject)
                if let onOpenGGInbox {
                    Button("gg Inbox", action: onOpenGGInbox)
                }
                Button("Reset Sort to Default", action: onResetSort)
                    .disabled(!project.worktreeOrderIsManual)
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
            .overlay(alignment: .trailing) {
                // The header dot lives OUTSIDE the count/plus swap group so
                // it stays visible — and its tooltip stays reachable — when
                // the user hovers the row.
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
                .padding(.trailing, 12)
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
                            onActivateHarness: { onActivateHarness(wt) },
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
                .padding(.horizontal, 6)
            }
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
