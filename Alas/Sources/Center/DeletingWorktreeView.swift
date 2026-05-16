import SwiftUI

struct DeletingWorktreeView: View {
    let worktree: Worktree
    @Environment(\.theme) var theme

    var body: some View {
        VStack(spacing: 14) {
            ZStack {
                LinearGradient(colors: [theme.color("bg-3"), theme.color("bg-2")],
                               startPoint: .topLeading, endPoint: .bottomTrailing)
                    .frame(width: 80, height: 80)
                    .clipShape(RoundedRectangle(cornerRadius: 22))
                Image(systemName: "trash")
                    .font(.system(size: 30))
                    .foregroundColor(theme.color("fg-dim"))
            }
            Text("Deleting worktree…")
                .font(.system(size: 15, weight: .semibold))
                .foregroundColor(theme.color("fg"))
            Text("Removing \(worktree.branch) from this project. This may take a moment.")
                .font(.system(size: 12))
                .foregroundColor(theme.color("fg-dim"))
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(theme.color("bg-1"))
    }
}
