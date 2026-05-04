import SwiftUI

struct WorktreeRowView: View {
    let worktree: Worktree
    let isSelected: Bool
    let onTap: () -> Void
    @Environment(\.theme) var theme

    var body: some View {
        Button(action: onTap) {
            ZStack(alignment: .leading) {
                if isSelected {
                    RoundedRectangle(cornerRadius: 6)
                        .fill(theme.color("bg-4"))
                    Rectangle()
                        .fill(theme.color("accent"))
                        .frame(width: 3, height: 14)
                        .cornerRadius(2)
                        .offset(x: 2, y: 0)
                }
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Icon(name: "branch", size: 11, color: theme.color("fg-faint"))
                        Text(worktree.branch)
                            .font(.system(size: 12, weight: .medium, design: .monospaced))
                            .foregroundColor(theme.color("fg"))
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                    HStack(spacing: 8) {
                        Text(relative(worktree.lastActivity))
                            .font(.system(size: 10.5))
                            .foregroundColor(theme.color("fg-faint"))
                        if worktree.addedLines > 0 {
                            Text("+\(worktree.addedLines)")
                                .font(.system(size: 10.5, design: .monospaced))
                                .foregroundColor(theme.color("add"))
                        }
                        if worktree.deletedLines > 0 {
                            Text("−\(worktree.deletedLines)")
                                .font(.system(size: 10.5, design: .monospaced))
                                .foregroundColor(theme.color("del"))
                        }
                    }
                }
                .padding(.leading, 32)
                .padding(.trailing, 10)
                .padding(.vertical, 7)
            }
        }
        .buttonStyle(.plain)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func relative(_ date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: date, relativeTo: Date())
    }
}
