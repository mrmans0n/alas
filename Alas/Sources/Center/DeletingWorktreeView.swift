import SwiftUI

struct DeletingWorktreeView: View {
    @Environment(\.designScale) private var scale
    let worktree: Worktree
    @Environment(\.theme) var theme

    var body: some View {
        VStack(spacing: scale.space[3]) {
            ZStack {
                LinearGradient(colors: [theme.color("bg-3"), theme.color("bg-2")],
                               startPoint: .topLeading, endPoint: .bottomTrailing)
                    .frame(width: 80, height: 80)
                    .clipShape(RoundedRectangle(cornerRadius: 22)) // design-literal: hero icon tile
                Image(systemName: "trash")
                    .font(.system(size: 30)) // design-literal: hero icon
                    .foregroundColor(theme.color("fg-dim"))
            }
            Text("Deleting worktree…")
                .font(.system(size: 15, weight: .semibold)) // design-literal: hero title
                .foregroundColor(theme.color("fg"))
            Text("Removing \(worktree.branch) from this project. This may take a moment.")
                .font(scale.metaFont)
                .foregroundColor(theme.color("fg-dim"))
                .multilineTextAlignment(.center)
                .padding(.horizontal, scale.space[5])
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(theme.color("bg-1"))
    }
}
