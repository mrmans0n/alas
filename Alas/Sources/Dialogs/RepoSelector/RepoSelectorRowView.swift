import SwiftUI

struct RepoSelectorRowView: View {
    let row: RepoSelectorRow
    let isSelected: Bool
    let projectsById: [String: ProjectConfig]
    let onTap: () -> Void
    let onHover: () -> Void
    @Environment(\.theme) private var theme

    var body: some View {
        ZStack(alignment: .leading) {
            if isSelected, row.isSelectable {
                RoundedRectangle(cornerRadius: 6)
                    .fill(theme.color("bg-4"))
                    .padding(.horizontal, 4)
            }
            content
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
        }
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
        case .repo(let project, let indices):
            HStack(spacing: 8) {
                RepoDot(color: project.color, letter: String(project.name.prefix(1)).uppercased())
                Highlighted(text: project.name, indices: indices)
                    .font(.system(size: 12))
                    .foregroundColor(theme.color("fg"))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 0)
            }

        case .worktree(let worktree, let indices):
            HStack(spacing: 8) {
                if let project = projectsById[worktree.projectId] {
                    Circle()
                        .fill(Color(hex: project.color))
                        .frame(width: 8, height: 8)
                }
                Highlighted(text: worktree.branch, indices: indices)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundColor(theme.color("fg"))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 0)
                statusText(for: worktree)
                    .font(.system(size: 11))
                    .foregroundColor(theme.color("fg-faint"))
            }

        case .action(.newWorktreeForRepo):
            HStack(spacing: 8) {
                Image(systemName: "plus")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(theme.color("fg-faint"))
                Text("New worktree…")
                    .font(.system(size: 12))
                    .foregroundColor(theme.color("fg"))
                Spacer(minLength: 0)
            }

        case .action(.newProject):
            HStack(spacing: 8) {
                Image(systemName: "plus")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(theme.color("fg-faint"))
                Text("Add project…")
                    .font(.system(size: 12))
                    .foregroundColor(theme.color("fg"))
                Spacer(minLength: 0)
            }

        case .emptyHint(.noProjects):
            Text("No repositories. Press ⇥ to add one.")
                .font(.system(size: 12))
                .foregroundColor(theme.color("fg-dim"))
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.vertical, 16)

        case .emptyHint(.noVisibleWorktrees):
            Text("No open worktrees. Press ⇥ to create one.")
                .font(.system(size: 12))
                .foregroundColor(theme.color("fg-dim"))
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.vertical, 16)

        case .divider(let label):
            HStack(spacing: 6) {
                Text(label.uppercased())
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(theme.color("fg-faint"))
                Rectangle()
                    .fill(theme.color("line-soft"))
                    .frame(height: 0.5)
            }
            .padding(.top, 6)
            .padding(.bottom, 2)
        }
    }

    @ViewBuilder
    private func statusText(for w: Worktree) -> some View {
        if w.addedLines == 0, w.deletedLines == 0 {
            Text("clean")
        } else {
            HStack(spacing: 4) {
                if w.addedLines > 0 { Text("+\(w.addedLines)").foregroundColor(theme.color("add")) }
                if w.deletedLines > 0 { Text("−\(w.deletedLines)").foregroundColor(theme.color("del")) }
            }
        }
    }
}
