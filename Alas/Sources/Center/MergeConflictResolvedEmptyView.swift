import SwiftUI

/// Shown in a merge-conflict tab when the underlying file is no longer
/// in a conflicted state (resolved or staged from elsewhere while the
/// tab stayed open). Matches the centered-empty-state pattern used by
/// `EmptyTabView` so the user gets a clear "nothing to do here" signal
/// instead of a mid-pane error banner.
struct MergeConflictResolvedEmptyView: View {
    @Environment(\.designScale) private var scale
    let relativePath: String
    let onOpenFile: () -> Void
    let onCloseTab: () -> Void

    @Environment(\.theme) var theme

    var body: some View {
        VStack(spacing: scale.space[3]) {
            ZStack {
                LinearGradient(
                    colors: [theme.color("bg-3"), theme.color("bg-2")],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
                .frame(width: 80, height: 80)
                .clipShape(RoundedRectangle(cornerRadius: 22)) // design-literal: hero icon tile
                Image(systemName: "checkmark.seal.fill")
                    .font(.system(size: 30)) // design-literal: hero icon
                    .foregroundColor(.green)
            }
            Text("No conflict here")
                .font(.system(size: 15, weight: .semibold)) // design-literal: hero title
                .foregroundColor(theme.color("fg"))
            Text("\(relativePath) is no longer in a conflicted state.")
                .font(scale.metaFont)
                .foregroundColor(theme.color("fg-dim"))
                .multilineTextAlignment(.center)
                .frame(maxWidth: 400)
            HStack(spacing: scale.space[2]) {
                AlasButton(title: "Open file", icon: "code", style: .primary, action: onOpenFile)
                AlasButton(title: "Close tab", icon: "x", style: .normal, action: onCloseTab)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(theme.color("bg-1"))
    }
}
