import SwiftUI

struct RepoSelectorRowView: View {
    let row: RepoSelectorRow
    let isSelected: Bool
    let projectsById: [String: ProjectConfig]
    let onTap: () -> Void
    let onHover: () -> Void
    @Environment(\.theme) private var theme

    var body: some View {
        switch row {
        case .recentHeader:
            headerLabel("Recent")
        case .projectHeader(let projectId):
            headerLabel(projectsById[projectId]?.name ?? "")
        case .actionsHeader:
            headerRule
        case .emptyHint(.noProjects):
            emptyHintRow
        default:
            selectableRow
        }
    }

    private var emptyHintRow: some View {
        Text("No repositories. Press ⇥ to add one.")
            .font(.system(size: 12))
            .foregroundColor(theme.color("fg-dim"))
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.vertical, 16)
            .contentShape(Rectangle())
            .onTapGesture { onTap() }
            .onHover { hovering in if hovering { onHover() } }
    }

    // MARK: - Selectable rows

    private var selectableRow: some View {
        ZStack(alignment: .leading) {
            Rectangle()
                .fill(isSelected ? theme.color("accent-soft") : Color.clear)
            Rectangle()
                .fill(isSelected ? theme.color("accent") : Color.clear)
                .frame(width: 2)
                .frame(maxHeight: .infinity)
            content
                .padding(.horizontal, 14)
        }
        .frame(height: 28)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .onTapGesture {
            if row.isSelectable { onTap() }
        }
        .onHover { hovering in
            if hovering, row.isSelectable { onHover() }
        }
    }

    @ViewBuilder
    private var content: some View {
        switch row {
        case .worktree(let worktree, let indices, let isCurrent):
            worktreeContent(worktree: worktree, indices: indices, isCurrent: isCurrent)

        case .action(.newWorktreeForRepo):
            actionContent(label: "New worktree…")

        case .action(.newProject):
            actionContent(label: "Add project…")

        case .emptyHint, .recentHeader, .projectHeader, .actionsHeader:
            EmptyView()
        }
    }

    @ViewBuilder
    private func worktreeContent(worktree: Worktree, indices: [Int], isCurrent: Bool) -> some View {
        HStack(spacing: 10) {
            if let project = projectsById[worktree.projectId] {
                ProjectIconView(icon: project.icon, fallbackName: project.name, size: .sidebar)
            }
            if isCurrent {
                Circle()
                    .fill(theme.color("accent"))
                    .frame(width: 5, height: 5)
                    .overlay(
                        Circle()
                            .stroke(theme.color("accent").opacity(0.25), lineWidth: 2)
                    )
            }
            Highlighted(text: worktree.branch, indices: indices)
                .font(.system(size: 12.5, weight: isCurrent ? .semibold : .medium, design: .monospaced))
                .foregroundColor(theme.color("fg"))
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
            Spacer(minLength: 8)
            statusText(for: worktree)
            if let project = projectsById[worktree.projectId] {
                Text(project.name)
                    .font(.system(size: 10, design: .monospaced))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1)
                    .background(theme.color("bg-3"))
                    .foregroundColor(theme.color("fg-faint"))
                    .clipShape(Capsule())
            }
            if isSelected {
                SearchKbd(label: "↵")
            }
        }
    }

    @ViewBuilder
    private func actionContent(label: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "plus")
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(theme.color("fg-faint"))
                .frame(width: 16)
            Text(label)
                .font(.system(size: 12))
                .foregroundColor(theme.color("fg"))
            Spacer(minLength: 0)
        }
    }

    @ViewBuilder
    private func statusText(for w: Worktree) -> some View {
        if w.addedLines == 0, w.deletedLines == 0 {
            Text("clean")
                .font(.system(size: 11))
                .foregroundColor(theme.color("fg-faint"))
        } else {
            HStack(spacing: 4) {
                if w.addedLines > 0 {
                    Text("+\(w.addedLines)")
                        .font(.system(size: 11))
                        .foregroundColor(theme.color("add"))
                }
                if w.deletedLines > 0 {
                    Text("−\(w.deletedLines)")
                        .font(.system(size: 11))
                        .foregroundColor(theme.color("del"))
                }
            }
        }
    }

    // MARK: - Headers

    private func headerLabel(_ text: String) -> some View {
        HStack(spacing: 6) {
            Text(text.uppercased())
                .font(.system(size: 10, weight: .semibold))
                .foregroundColor(theme.color("fg-faint"))
            Rectangle()
                .fill(theme.color("line-soft"))
                .frame(height: 0.5)
        }
        .padding(.horizontal, 14)
        .padding(.top, 8)
        .padding(.bottom, 2)
    }

    private var headerRule: some View {
        Rectangle()
            .fill(theme.color("line-soft"))
            .frame(height: 0.5)
            .padding(.horizontal, 14)
            .padding(.top, 6)
            .padding(.bottom, 2)
    }
}
