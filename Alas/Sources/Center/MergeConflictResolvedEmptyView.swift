import SwiftUI

/// Shown in a merge-conflict tab when the underlying file is no longer
/// in a conflicted state (resolved or staged from elsewhere while the
/// tab stayed open). Matches the centered-empty-state pattern used by
/// `EmptyTabView` so the user gets a clear "nothing to do here" signal
/// instead of a mid-pane error banner.
struct MergeConflictResolvedEmptyView: View {
    let relativePath: String
    let onOpenFile: () -> Void
    let onCloseTab: () -> Void

    @Environment(\.theme) var theme

    var body: some View {
        VStack(spacing: 14) {
            ZStack {
                LinearGradient(
                    colors: [theme.color("bg-3"), theme.color("bg-2")],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
                .frame(width: 80, height: 80)
                .clipShape(RoundedRectangle(cornerRadius: 22))
                Image(systemName: "checkmark.seal.fill")
                    .font(.system(size: 30))
                    .foregroundColor(.green)
            }
            Text("No conflict here")
                .font(.system(size: 15, weight: .semibold))
                .foregroundColor(theme.color("fg"))
            Text("\(relativePath) is no longer in a conflicted state.")
                .font(.system(size: 12))
                .foregroundColor(theme.color("fg-dim"))
                .multilineTextAlignment(.center)
                .frame(maxWidth: 400)
            HStack(spacing: 8) {
                AlasButton(title: "Open file", icon: "code", style: .primary, action: onOpenFile)
                AlasButton(title: "Close tab", icon: "x", style: .normal, action: onCloseTab)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(theme.color("bg-1"))
    }
}
