import SwiftUI

struct DeleteFailedWorktreeView: View {
    let worktree: Worktree
    let message: String
    let allowsRemovalActions: Bool
    let onRetry: () -> Void
    let onArchive: () -> Void
    let onCopyError: () -> Void
    @Environment(\.theme) var theme

    var body: some View {
        VStack(spacing: 14) {
            ZStack {
                LinearGradient(colors: [theme.color("bg-3"), theme.color("bg-2")],
                               startPoint: .topLeading, endPoint: .bottomTrailing)
                    .frame(width: 80, height: 80)
                    .clipShape(RoundedRectangle(cornerRadius: 22))
                Image(systemName: "exclamationmark.triangle")
                    .font(.system(size: 30))
                    .foregroundColor(theme.color("warning"))
            }
            Text("Delete failed")
                .font(.system(size: 15, weight: .semibold))
                .foregroundColor(theme.color("fg"))
            Text("Could not remove worktree \(worktree.branch).")
                .font(.system(size: 12))
                .foregroundColor(theme.color("fg-dim"))
                .multilineTextAlignment(.center)
            Text(message)
                .font(.system(size: 11, design: .monospaced))
                .foregroundColor(theme.color("fg-dim"))
                .multilineTextAlignment(.leading)
                .lineLimit(4)
                .padding(.horizontal, 24)
            HStack(spacing: 10) {
                AlasButton(title: "Copy Error", icon: "doc.on.doc", style: .normal, action: onCopyError)
                if allowsRemovalActions {
                    AlasButton(title: "Archive", icon: "archivebox", style: .normal, action: onArchive)
                    AlasButton(title: "Retry Delete", icon: "arrow.clockwise", style: .primary, action: onRetry)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(theme.color("bg-1"))
    }
}
