import SwiftUI

/// The disclosure row for a run of thinking and tool calls: icon, a
/// verb-count label ("Read 2 files, ran 1 command"), and a chevron. While
/// the run is live the label shimmers.
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
    /// Earlier members left out of an automatically expanded live run.
    let hiddenMemberCount: Int
    let onToggle: (Bool) -> Void
    @Environment(\.theme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(
        summary: ACPToolCallGroupSummary,
        expanded: Bool = false,
        hiddenMemberCount: Int = 0,
        onToggle: @escaping (Bool) -> Void = { _ in }
    ) {
        self.summary = summary
        self.expanded = expanded
        self.hiddenMemberCount = hiddenMemberCount
        self.onToggle = onToggle
    }

    var body: some View {
        HStack(spacing: 8) {
            toggle
            if hiddenMemberCount > 0 {
                // Expanding explicitly lifts the live cap (see
                // `ACPToolCallGroupExpansionSeeds.memberLimit`).
                Button("Show \(hiddenMemberCount) earlier") { onToggle(true) }
                    .buttonStyle(.plain)
                    .font(.system(size: 11))
                    .foregroundStyle(theme.color("fg-faint"))
                    .fixedSize()
            }
        }
    }

    private var toggle: some View {
        Button {
            onToggle(!expanded)
        } label: {
            HStack(spacing: 7) {
                Image(systemName: summary.iconSystemName)
                    .font(.system(size: 11))
                    .frame(width: 16)
                    .foregroundStyle(theme.color("fg-faint"))
                    .accessibilityHidden(true)
                Text(summary.label)
                    .font(.system(size: 12))
                    .foregroundStyle(theme.color("fg-faint"))
                    // Rolls the digits instead of snapping them.
                    .contentTransition(.numericText(value: Double(summary.count)))
                    .animation(reduceMotion ? nil : .easeOut(duration: 0.2), value: summary.count)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .acpNarrationShimmer(isActive: summary.isLive)
                Image(systemName: expanded ? "chevron.down" : "chevron.right")
                    .font(.system(size: 9))
                    .foregroundStyle(theme.color("fg-faint"))
                    .accessibilityHidden(true)
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityValue(expanded ? "Expanded" : "Collapsed")
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
        .padding(.leading, 7)
    }
}

/// The shared bar + indent that marks a row as part of a tool-call bundle.
/// Factored out so members (and subagent rows) line up exactly.
struct ACPToolCallGroupLane<Content: View>: View {
    @ViewBuilder let content: () -> Content
    @Environment(\.theme) private var theme

    init(@ViewBuilder content: @escaping () -> Content) {
        self.content = content
    }

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
