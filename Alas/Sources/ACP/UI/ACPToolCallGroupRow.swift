import SwiftUI

/// Collapsed-by-default "Ran N tools" row standing in for a run of finished
/// tool calls. Click to expand and see the individual cards. Mirrors
/// `ACPThoughtView`'s accent-bar-plus-faint-header idiom so bundles read as
/// the same kind of de-emphasized detail as thinking.
///
/// Unlike the thinking row, `expanded` is NOT view-local state: it is a
/// plain input, owned by `ACPToolCallGroupExpansionSeeds` and folded into
/// the row's equality token, so toggling goes store → fresh spec → this
/// view rebuilt with the new value. Caching a copy here would let a
/// mounted row and the store disagree — see that type's doc comment.
struct ACPToolCallGroupRow<Content: View>: View {
    let summary: ACPToolCallGroupSummary
    let expanded: Bool
    let onToggle: (Bool) -> Void
    @ViewBuilder let content: () -> Content
    @Environment(\.theme) private var theme

    init(
        summary: ACPToolCallGroupSummary,
        expanded: Bool = false,
        onToggle: @escaping (Bool) -> Void = { _ in },
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.summary = summary
        self.expanded = expanded
        self.onToggle = onToggle
        self.content = content
    }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Rectangle()
                .fill(theme.color("bg-4"))
                .frame(width: 1.5)
                .padding(.vertical, 2)
            VStack(alignment: .leading, spacing: 10) {
                Button {
                    onToggle(!expanded)
                } label: {
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
