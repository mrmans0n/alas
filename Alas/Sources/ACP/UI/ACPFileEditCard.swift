import SwiftUI

/// Compact card that announces a file edit landed in the worktree, with
/// a click target that opens the existing diff tab against HEAD.
struct ACPFileEditCard: View {
    let edit: ACPMessage.FileEdit
    let onOpenDiff: () -> Void
    @Environment(\.theme) private var theme

    var body: some View {
        HStack(spacing: 8) {
            ZStack {
                RoundedRectangle(cornerRadius: 4)
                    .fill(theme.color("accent").opacity(0.18))
                Image(systemName: "pencil")
                    .font(.system(size: 10))
                    .foregroundStyle(theme.color("accent"))
            }
            .frame(width: 18, height: 18)

            Text("Edit")
                .font(.system(size: 10.5, weight: .semibold))
                .tracking(0.6)
                .textCase(.uppercase)
                .foregroundStyle(theme.color("accent"))

            FileChip(path: edit.path, lines: nil, iconSystemName: nil)

            Text("+\(edit.added) −\(edit.removed)")
                .font(.system(size: 10.5, design: .monospaced))
                .foregroundStyle(theme.color("fg-faint"))

            Spacer(minLength: 6)

            Button("Open diff", action: onOpenDiff)
                .buttonStyle(.plain)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(theme.color("accent"))
        }
        .padding(.horizontal, 10).padding(.vertical, 8)
        .background(theme.color("bg-1").opacity(0.5))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(theme.color("line"), lineWidth: 0.5))
    }
}
