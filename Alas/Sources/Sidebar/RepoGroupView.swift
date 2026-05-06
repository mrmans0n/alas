import SwiftUI

struct RepoGroupView: View {
    let project: ProjectConfig
    let worktrees: [Worktree]
    @Binding var collapsed: Bool
    let selectedWorktreeId: String?
    let onSelect: (Worktree) -> Void
    @Environment(\.theme) var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button { collapsed.toggle() } label: {
                HStack(spacing: 7) {
                    Icon(name: collapsed ? "chev-right" : "chev-down", size: 10, color: theme.color("fg-faint"))
                    RepoDot(color: project.color, letter: letter)
                    Text(project.name)
                        .font(.system(size: 11.5, weight: .semibold))
                        .foregroundColor(theme.color("fg-muted"))
                    Spacer()
                    Text("\(worktrees.count)")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(theme.color("fg-faint"))
                }
                .padding(.horizontal, 12).padding(.vertical, 5)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if !collapsed {
                VStack(spacing: 1) {
                    ForEach(worktrees) { wt in
                        WorktreeRowView(
                            worktree: wt,
                            isSelected: wt.id == selectedWorktreeId,
                            onTap: { onSelect(wt) }
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
}
