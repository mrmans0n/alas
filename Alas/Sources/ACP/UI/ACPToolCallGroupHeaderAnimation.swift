import Foundation

/// Animation policy for `ACPToolCallGroupHeaderRow`. Pure, so the decision
/// can be tested without standing up SwiftUI — same shape as
/// `ACPPlanPillState.outlineIsAnimated(reduceMotion:)`.
enum ACPToolCallGroupHeaderAnimation {
    /// Where the transcript's render window has been pinned, if anywhere.
    ///
    /// This is `ACPTranscript.visibleTail` — the RAW optional — and
    /// deliberately not `visibleTailBound`. That bound resolves to
    /// `messages.count` while the transcript follows the live tail, so it
    /// advances with every arriving message and would read as navigation on
    /// exactly the updates this pulse exists for, suppressing the animation
    /// throughout a live turn. The raw value stays `nil` for the whole of
    /// that turn and only takes a number once the reader has pinned the
    /// window, which is the thing worth reacting to.
    ///
    /// `visibleHead` is deliberately absent. Head backfill can only grow a
    /// bundle by revealing finished calls contiguous with its current FIRST
    /// member, and a bundle's row id is derived from that member (see
    /// `ACPTranscriptToolCallGroup.id`). Such a bundle is therefore re-keyed
    /// and remounted fresh, which means no previous value to compare against
    /// and no pulse, with or without a guard here.
    struct Window: Equatable, Sendable {
        let boundedTail: Int?

        init(visibleTail: Int?) {
            self.boundedTail = visibleTail
        }
    }

    /// What a mounted header compares across an in-place content update.
    ///
    /// The window travels alongside the count because a bundle can grow for
    /// two unrelated reasons, and only one of them is an absorption — see
    /// `absorbs(from:to:reduceMotion:)`.
    struct Snapshot: Equatable, Sendable {
        let count: Int
        let window: Window

        init(count: Int, window: Window) {
            self.count = count
            self.window = window
        }
    }

    /// Whether a header whose content just changed should play the absorb
    /// pulse.
    ///
    /// Growth inside an UNCHANGED render window is the only thing that means
    /// "a tool call just finished and folded in here". Three other shapes
    /// reach this predicate and must stay quiet:
    ///
    /// - An unchanged count is an unrelated re-render.
    /// - A shrinking count is a regroup, where nothing was absorbed.
    /// - Growth alongside a moved window is the transcript revealing calls
    ///   that finished long ago. Scrolling down through a bounded history
    ///   window calls `ACPTranscript.stepTailForward`, which appends
    ///   already-finished calls to a bundle whose first member — and so whose
    ///   row id — never changed, leaving the reconciler to update that same
    ///   mounted header in place. Pulsing there would flash at a reader who
    ///   absorbed nothing.
    ///
    /// A live turn keeps the window at `nil` throughout, so absorptions
    /// during one always pass the window check — see `Window`.
    static func absorbs(from previous: Snapshot, to current: Snapshot, reduceMotion: Bool) -> Bool {
        guard !reduceMotion else { return false }
        guard previous.window == current.window else { return false }
        return current.count > previous.count
    }
}
