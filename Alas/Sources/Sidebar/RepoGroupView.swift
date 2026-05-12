import SwiftUI

struct RepoGroupView: View {
    let project: ProjectConfig
    let worktrees: [Worktree]
    @Binding var collapsed: Bool
    let selectedWorktreeId: String?
    let harnessSummary: (String) -> HarnessService.WorktreeHarnessSummary?
    let onSelect: (Worktree) -> Void
    let onNewWorktree: () -> Void
    let onEditProject: () -> Void
    let onOpenTerminal: (Worktree) -> Void
    let onCopyPath: (Worktree) -> Void
    let onCopyBranch: (Worktree) -> Void
    let onRevealInFinder: (Worktree) -> Void
    let onArchive: (Worktree) -> Void
    let onDelete: (Worktree) -> Void
    let onActivateHarness: (Worktree) -> Void
    @Environment(\.theme) var theme
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
                RepoDot(color: project.color, letter: letter)
                Text(project.name)
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundColor(theme.color("fg-muted"))
                Spacer(minLength: 0)
            }
            .padding(.leading, 12)
            .padding(.vertical, 5)
            .contentShape(Rectangle())
            .onTapGesture { collapsed.toggle() }
            .contextMenu {
                Button("Edit Project…", action: onEditProject)
            }
            .overlay(alignment: .trailing) {
                ZStack {
                    HStack(spacing: 6) {
                        if collapsed, let summary = projectSummary() {
                            HarnessPill(
                                summary: summary,
                                variant: .dotOnly,
                                tooltip: headerTooltip()
                            )
                        }
                        Text("\(worktrees.count)")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundColor(theme.color("fg-faint"))
                            .monospacedDigit()
                    }
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
                .frame(height: 18)
                .padding(.trailing, 12)
            }
            .onHover { hovering = $0 }
            if !collapsed {
                VStack(spacing: 1) {
                    ForEach(worktrees) { wt in
                        WorktreeRowView(
                            worktree: wt,
                            isSelected: wt.id == selectedWorktreeId,
                            harnessSummary: harnessSummary(wt.id),
                            onTap: { onSelect(wt) },
                            onOpenTerminal: { onOpenTerminal(wt) },
                            onCopyPath: { onCopyPath(wt) },
                            onCopyBranch: { onCopyBranch(wt) },
                            onRevealInFinder: { onRevealInFinder(wt) },
                            onArchive: { onArchive(wt) },
                            onDelete: { onDelete(wt) },
                            onActivateHarness: { onActivateHarness(wt) }
                        )
                    }
                }
                .padding(.horizontal, 6)
            }
        }
    }

    private var letter: String {
        let after = project.name.split(separator: "/").last ?? Substring(project.name)
        return after.prefix(1).uppercased()
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

    /// Tooltip for the collapsed-header dot. Counts independently across
    /// worktrees, lists distinct harness kinds in `HarnessKind.allCases` order.
    private func headerTooltip() -> String {
        let runningCount = summaries.filter { $0.state == .running }.count
        let awaitingCount = summaries.filter { $0.state == .awaiting }.count
        let distinctKinds = HarnessKind.allCases.filter { kind in
            summaries.contains { $0.kind == kind }
        }
        let kindList = distinctKinds.map(\.displayName).joined(separator: ", ")

        var parts: [String] = []
        if runningCount > 0 {
            parts.append("\(runningCount) running")
        }
        if awaitingCount > 0 {
            parts.append("\(awaitingCount) awaiting")
        }
        let head = parts.joined(separator: ", ")
        return kindList.isEmpty ? head : "\(head) (\(kindList))"
    }
}
