import Testing
@testable import Alas

@Suite("ACP tool-call group absorb animation")
struct ACPToolCallGroupHeaderAnimationTests {
    private typealias Snapshot = ACPToolCallGroupHeaderAnimation.Snapshot

    struct Case: Sendable, CustomStringConvertible {
        let previous: ACPToolCallGroupHeaderAnimation.Snapshot
        let current: ACPToolCallGroupHeaderAnimation.Snapshot
        let reduceMotion: Bool
        let expected: Bool
        let reason: String

        var description: String { reason }
    }

    private static func snapshot(count: Int, head: Int = 10, tail: Int = 90) -> Snapshot {
        Snapshot(count: count, window: .init(head: head, tail: tail))
    }

    /// The pulse claims "a tool call just finished and folded in here". Only a
    /// bundle that grew WITHIN AN UNCHANGED render window can mean that.
    ///
    /// Two other things grow a mounted header's count and must stay quiet.
    /// Scrolling down through a bounded history window calls
    /// `ACPTranscript.stepTailForward`, which reveals already-finished calls
    /// after a bundle whose first member — and therefore whose row id — is
    /// unchanged, so the reconciler updates that same header in place.
    /// Backfilling history at the head does the same from the other side.
    /// Neither finished anything; flashing there is the exact lie the policy
    /// exists to prevent.
    @Test(
        "the header pulses only for a bundle that grew inside an unchanged render window",
        arguments: [
            Case(
                previous: snapshot(count: 1), current: snapshot(count: 2),
                reduceMotion: false, expected: true,
                reason: "a call finished and folded in"
            ),
            Case(
                previous: snapshot(count: 2), current: snapshot(count: 5),
                reduceMotion: false, expected: true,
                reason: "several calls folded in at once"
            ),
            Case(
                previous: snapshot(count: 3), current: snapshot(count: 3),
                reduceMotion: false, expected: false,
                reason: "an unrelated re-render left the count alone"
            ),
            Case(
                previous: snapshot(count: 4), current: snapshot(count: 2),
                reduceMotion: false, expected: false,
                reason: "a regroup shrank the bundle"
            ),
            Case(
                previous: snapshot(count: 2, tail: 90), current: snapshot(count: 6, tail: 150),
                reduceMotion: false, expected: false,
                reason: "scrolling down revealed already-finished calls at the tail"
            ),
            Case(
                previous: snapshot(count: 2, head: 10), current: snapshot(count: 6, head: 0),
                reduceMotion: false, expected: false,
                reason: "history backfill revealed already-finished calls at the head"
            ),
            Case(
                previous: snapshot(count: 1), current: snapshot(count: 2),
                reduceMotion: true, expected: false,
                reason: "Reduce Motion is on"
            ),
        ]
    )
    func absorbDecision(testCase: Case) {
        #expect(
            ACPToolCallGroupHeaderAnimation.absorbs(
                from: testCase.previous,
                to: testCase.current,
                reduceMotion: testCase.reduceMotion
            ) == testCase.expected
        )
    }
}
