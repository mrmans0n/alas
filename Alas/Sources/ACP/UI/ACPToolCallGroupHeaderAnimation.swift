import Foundation

/// Animation policy for `ACPToolCallGroupHeaderRow`. Pure, so the decision
/// can be tested without standing up SwiftUI — same shape as
/// `ACPPlanPillState.outlineIsAnimated(reduceMotion:)`.
enum ACPToolCallGroupHeaderAnimation {
    /// The transcript slice a header was built from, as local message
    /// indices. Any move means rows entered or left the render window.
    struct Window: Equatable, Sendable {
        let head: Int
        let tail: Int

        init(head: Int, tail: Int) {
            self.head = head
            self.tail = tail
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
    ///   mounted header in place. Head backfill does the same from the other
    ///   side. Pulsing there would flash at a reader who absorbed nothing.
    static func absorbs(from previous: Snapshot, to current: Snapshot, reduceMotion: Bool) -> Bool {
        guard !reduceMotion else { return false }
        guard previous.window == current.window else { return false }
        return current.count > previous.count
    }
}
