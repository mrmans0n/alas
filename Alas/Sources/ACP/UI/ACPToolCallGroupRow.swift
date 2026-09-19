import SwiftUI

/// Collapsed-by-default "Ran N tools" row standing in for a run of finished
/// tool calls. Click to expand and see the individual cards. Mirrors
/// `ACPThoughtView`'s accent-bar-plus-faint-header idiom so bundles read as
/// the same kind of de-emphasized detail as thinking.
///
/// `expanded` is view-local state, like the thinking row: it survives the
/// bundle growing (the hosting pool swaps the root view in place when the
/// row's token changes) but resets once the row is unmounted off-band.
struct ACPToolCallGroupRow<Content: View>: View {
    let summary: ACPToolCallGroupSummary
    @ViewBuilder let content: () -> Content
    @State private var expanded = false
    @Environment(\.theme) private var theme

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Rectangle()
                .fill(theme.color("bg-4"))
                .frame(width: 1.5)
                .padding(.vertical, 2)
            VStack(alignment: .leading, spacing: 10) {
                Button { expanded.toggle() } label: {
                    HStack(spacing: 7) {
                        Image(systemName: "wrench.and.screwdriver")
                            .font(.system(size: 10))
                            .foregroundStyle(theme.color("fg-faint"))
                        Text(expanded ? summary.expandedLabel : summary.collapsedLabel)
                            .font(.system(size: 11))
                            .foregroundStyle(theme.color("fg-faint"))
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(expanded ? summary.expandedLabel : summary.collapsedLabel)

                if expanded {
                    VStack(alignment: .leading, spacing: 12) {
                        content()
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }
}
