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
    /// The transcript slice this header was built from. Carried so the pulse
    /// can tell a tool call finishing apart from the render window revealing
    /// calls that finished long ago — see
    /// `ACPToolCallGroupHeaderAnimation.absorbs(from:to:reduceMotion:)`.
    ///
    /// It is folded into the row's equality token, which is what keeps this
    /// value current. Were it left out, a window move that did not also change
    /// this bundle's count would skip the rebuild, and the mounted view would
    /// carry a stale window into the NEXT comparison — suppressing a genuine
    /// absorption instead of a spurious one.
    let window: ACPToolCallGroupHeaderAnimation.Window
    let onToggle: (Bool) -> Void
    @Environment(\.theme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Lit to 1 the moment a finished call folds into this bundle, then eased
    /// back to 0 — the "something just landed here" cue.
    ///
    /// View-local `@State` on purpose. It survives the in-place content
    /// update that carries a new count (the hosting pool swaps `rootView`
    /// without disturbing SwiftUI state), which is exactly when the pulse
    /// must fire. And it resets when the mount band releases and remounts the
    /// row, so scrolling a bundle back into view comes back quiet rather than
    /// flashing at a reader who absorbed nothing.
    @State private var absorbHighlight: Double = 0

    init(
        summary: ACPToolCallGroupSummary,
        expanded: Bool = false,
        window: ACPToolCallGroupHeaderAnimation.Window = .init(visibleTail: nil),
        onToggle: @escaping (Bool) -> Void = { _ in }
    ) {
        self.summary = summary
        self.expanded = expanded
        self.window = window
        self.onToggle = onToggle
    }

    private var label: String {
        expanded ? summary.expandedLabel : summary.collapsedLabel
    }

    private var snapshot: ACPToolCallGroupHeaderAnimation.Snapshot {
        .init(count: summary.count, window: window)
    }

    var body: some View {
        ACPToolCallGroupLane(highlight: absorbHighlight) {
            Button {
                onToggle(!expanded)
            } label: {
                HStack(spacing: 7) {
                    Image(systemName: "wrench.and.screwdriver")
                        .font(.system(size: 10))
                        .foregroundStyle(
                            theme.color("fg-faint")
                                .mix(with: theme.color("accent"), by: absorbHighlight)
                        )
                    Text(label)
                        .font(.system(size: 11))
                        .foregroundStyle(theme.color("fg-faint"))
                        // Rolls the digits instead of snapping them. Scoped to
                        // the count so toggling expanded — which rewrites the
                        // same label from "Ran" to "Hide" — stays instant.
                        .contentTransition(.numericText(value: Double(summary.count)))
                        .animation(reduceMotion ? nil : .easeOut(duration: 0.2), value: summary.count)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(label)
        }
        .onChange(of: snapshot) { previous, current in
            absorb(from: previous, to: current)
        }
    }

    /// A snapshot change can only reach an already-mounted header: a fresh
    /// mount has no previous value to compare against, so `onChange` stays
    /// silent there and first paint is never a pulse.
    private func absorb(
        from previous: ACPToolCallGroupHeaderAnimation.Snapshot,
        to current: ACPToolCallGroupHeaderAnimation.Snapshot
    ) {
        guard ACPToolCallGroupHeaderAnimation.absorbs(
            from: previous,
            to: current,
            reduceMotion: reduceMotion
        ) else { return }
        // Both halves are driven by animations, and the decay is started from
        // the ramp's COMPLETION rather than from a queued main-actor job. A
        // `Task` only promises another turn on the main actor, not a rendering
        // boundary, so the decay could land in the same SwiftUI transaction as
        // the ramp: the two mutations would coalesce into an update that both
        // starts and ends dark, and nothing would ever pulse. A completion
        // handler cannot run until the animation it belongs to has finished,
        // so the lit frame is always committed first.
        withAnimation(.easeIn(duration: 0.09)) {
            absorbHighlight = 1
        } completion: {
            withAnimation(.easeOut(duration: 0.5)) { absorbHighlight = 0 }
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
struct ACPToolCallGroupLane<Content: View>: View {
    /// 0 for the lane's resting gray, 1 for full accent. Only the bar's FILL
    /// may depend on this. The transcript is tiled by an AppKit reconciler
    /// that re-lays out the whole document whenever a row's measured height
    /// changes, so a highlight that touched geometry would re-tile the
    /// transcript on every frame of the pulse.
    let highlight: Double
    @ViewBuilder let content: () -> Content
    @Environment(\.theme) private var theme

    init(highlight: Double = 0, @ViewBuilder content: @escaping () -> Content) {
        self.highlight = highlight
        self.content = content
    }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Rectangle()
                .fill(theme.color("bg-4").mix(with: theme.color("accent"), by: highlight))
                .frame(width: 1.5)
                .padding(.vertical, 2)
            content()
        }
    }
}
