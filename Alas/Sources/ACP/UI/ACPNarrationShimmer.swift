import SwiftUI

/// Which narration row ("Thinking…" / "Working…") the agent is writing into
/// right now. Deciding this reads `StreamingText.phase`, which is
/// `@MainActor`-isolated, so unlike the otherwise-similar
/// `ACPToolCallGroupHeaderAnimation` this cannot be a plain nonisolated
/// enum — every call site (transcript row building, `ACPSubagentRowView`)
/// already runs on the main actor.
@MainActor
enum ACPNarrationLiveness {
    /// Index of the live narration row, or nil when nothing is being narrated.
    ///
    /// Deliberately NOT a tail scan. `lastContentTouchIndex` is the row the
    /// most recent real content update actually touched — see its doc
    /// comment on `ACPTranscript` — which is not always the trailing
    /// message: `ACPSession.appendStreaming` locates a chunk's target row
    /// by `messageId` regardless of array position, so an identified
    /// commentary stream can resume into an OLDER row after a later
    /// `.agent` row has already been appended after it. A tail scan would
    /// miss that resumed row entirely; reading the pointer directly follows
    /// whatever row is actually being written to.
    ///
    /// The pointer alone isn't sufficient, though — once something else
    /// (a tool call, a file edit, a fresh user prompt) appends after a
    /// narration row with no further chunk landing back on it, the pointer
    /// itself moves to that new row, and the kind check below naturally
    /// stops matching. So "the pointer's row is still a thought or
    /// commentary agent row" is the whole test; no separate closing scan
    /// is needed.
    ///
    /// Gated on `isStreaming` rather than any busy state: the broker flips
    /// to streaming on the first `session/update` of a prompt, so every
    /// chunk that could make a row live arrives under it, and it is the
    /// same state the tail caret keys on, so the two cues start and stop
    /// together.
    static func liveIndex(
        messages: [ACPMessage],
        isStreaming: Bool,
        lastContentTouchIndex: Int?
    ) -> Int? {
        guard isStreaming, let i = lastContentTouchIndex, messages.indices.contains(i) else {
            return nil
        }
        switch messages[i] {
        case .thought:
            return i
        case .agent(_, _, let buffer):
            return buffer.phase == .commentary ? i : nil
        default:
            return nil
        }
    }
}

extension View {
    /// Sweeps a soft accent highlight across the view while `isActive`, the
    /// "still being written" cue for narration rows: horizontally along the
    /// header label, vertically down the row's lane bar. Purely an overlay
    /// masked to the content, so it never changes the row's measured height
    /// (see `ACPToolCallGroupLane` for why that matters to the scroller).
    /// Holds still under Reduce Motion.
    func acpNarrationShimmer(isActive: Bool, axis: Axis = .horizontal) -> some View {
        modifier(ACPNarrationShimmer(isActive: isActive, axis: axis))
    }
}

struct ACPNarrationShimmer: ViewModifier {
    let isActive: Bool
    let axis: Axis
    @Environment(\.theme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content.overlay {
            if isActive && !reduceMotion {
                ACPNarrationShimmerSweep(highlight: theme.color("accent"), axis: axis)
                    .mask(content)
                    .allowsHitTesting(false)
            }
        }
    }
}

/// The moving band itself. Its own view so the sweep restarts from the edge
/// each time a row becomes live (the overlay is inserted fresh) and stops
/// outright when it goes quiet (the overlay is removed), rather than
/// animating a hidden band forever.
///
/// A row's label and lane bar each run their own sweep, but both are
/// inserted in the same update and share the period, so they travel
/// together: the glint crosses the label as it slides down the bar.
private struct ACPNarrationShimmerSweep: View {
    let highlight: Color
    let axis: Axis
    /// One full traverse per period. The band spans the content along the
    /// sweep axis and travels twice that distance, so each pass is followed
    /// by a rest about as long as the pass — a glint, not a strobe.
    static let period: TimeInterval = 1.6
    @State private var sweeping = false

    var body: some View {
        GeometryReader { geo in
            let extent = axis == .horizontal ? geo.size.width : geo.size.height
            LinearGradient(
                stops: [
                    .init(color: .clear, location: 0),
                    .init(color: highlight, location: 0.5),
                    .init(color: .clear, location: 1),
                ],
                startPoint: axis == .horizontal ? .leading : .top,
                endPoint: axis == .horizontal ? .trailing : .bottom
            )
            .frame(
                width: axis == .horizontal ? extent : nil,
                height: axis == .vertical ? extent : nil
            )
            .offset(
                x: axis == .horizontal ? (sweeping ? extent : -extent) : 0,
                y: axis == .vertical ? (sweeping ? extent : -extent) : 0
            )
            .animation(
                .linear(duration: Self.period).repeatForever(autoreverses: false),
                value: sweeping
            )
        }
        .onAppear { sweeping = true }
    }
}
