import Testing
@testable import Alas

@Suite("ACP tool-call group absorb animation")
struct ACPToolCallGroupHeaderAnimationTests {
    struct Case: Sendable, CustomStringConvertible {
        let previous: Int
        let current: Int
        let reduceMotion: Bool
        let expected: Bool

        var description: String {
            "\(previous)->\(current), reduceMotion: \(reduceMotion)"
        }
    }

    /// The pulse means "a tool call just finished and folded in here". Only a
    /// growing bundle can mean that. A header whose count is unchanged (a
    /// re-render from an unrelated transcript update) or whose count SHRANK
    /// (history backfill regrouping a run, a fork boundary splitting one)
    /// must stay quiet, or the transcript flickers at moments nothing was
    /// absorbed.
    @Test(
        "the header pulses only when its bundle grew, and never under Reduce Motion",
        arguments: [
            Case(previous: 1, current: 2, reduceMotion: false, expected: true),
            Case(previous: 2, current: 5, reduceMotion: false, expected: true),
            Case(previous: 3, current: 3, reduceMotion: false, expected: false),
            Case(previous: 4, current: 2, reduceMotion: false, expected: false),
            Case(previous: 1, current: 2, reduceMotion: true, expected: false),
            Case(previous: 2, current: 5, reduceMotion: true, expected: false),
        ]
    )
    func absorbDecision(testCase: Case) {
        #expect(
            ACPToolCallGroupHeaderAnimation.absorbs(
                previousCount: testCase.previous,
                currentCount: testCase.current,
                reduceMotion: testCase.reduceMotion
            ) == testCase.expected
        )
    }
}
