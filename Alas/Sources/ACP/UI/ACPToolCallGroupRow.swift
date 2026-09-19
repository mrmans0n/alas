import SwiftUI

/// The "Ran N tools" / "Hide N tools" toggle standing at the head of a run
/// of finished tool calls. Click to expand and see the individual cards.
/// Mirrors `ACPThoughtView`'s accent-bar-plus-faint-header idiom so bundles
/// read as the same kind of de-emphasized detail as thinking.
///
/// This row is ONLY the header. When the bundle is expanded its members are
/// tiled as their own sibling rows (`ACPToolCallGroupMemberRow`) rather than
/// nested inside this view — see `ACPTranscriptRenderRow` for why the
/// scroller needs them to be real rows.
///
/// `expanded` is a plain input, owned by `ACPToolCallGroupExpansionSeeds`
/// and folded into the row's equality token; this view holds no state of
/// its own, so a mounted row and the store can never disagree.
struct ACPToolCallGroupHeaderRow: View {
    let summary: ACPToolCallGroupSummary
    let expanded: Bool
    let onToggle: (Bool) -> Void
    @Environment(\.theme) private var theme

    init(
        summary: ACPToolCallGroupSummary,
        expanded: Bool = false,
        onToggle: @escaping (Bool) -> Void = { _ in }
    ) {
        self.summary = summary
        self.expanded = expanded
        self.onToggle = onToggle
    }

    private var label: String {
        expanded ? summary.expandedLabel : summary.collapsedLabel
    }

    var body: some View {
        ACPToolCallGroupLane {
            Button {
                onToggle(!expanded)
            } label: {
                HStack(spacing: 7) {
                    Image(systemName: "wrench.and.screwdriver")
                        .font(.system(size: 10))
                        .foregroundStyle(theme.color("fg-faint"))
                    Text(label)
                        .font(.system(size: 11))
                        .foregroundStyle(theme.color("fg-faint"))
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(label)
        }
    }
}

/// One member of an EXPANDED tool-call bundle, tiled as its own transcript
/// row. Carries the same accent lane as the header so the run still reads
/// as one visual unit while each card keeps an independent row identity
/// and measured frame.
struct ACPToolCallGroupMemberRow<Content: View>: View {
    @ViewBuilder let content: () -> Content

    init(@ViewBuilder content: @escaping () -> Content) {
        self.content = content
    }

    var body: some View {
        ACPToolCallGroupLane {
            content()
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// The shared accent bar + indent that marks a row as part of a tool-call
/// bundle. Factored out so the header and its members line up exactly.
private struct ACPToolCallGroupLane<Content: View>: View {
    @ViewBuilder let content: () -> Content
    @Environment(\.theme) private var theme

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Rectangle()
                .fill(theme.color("bg-4"))
                .frame(width: 1.5)
                .padding(.vertical, 2)
            content()
        }
    }
}
