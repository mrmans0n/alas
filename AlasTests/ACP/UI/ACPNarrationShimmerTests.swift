import AppKit
import SwiftUI
import Testing
@testable import Alas

@MainActor
@Suite("ACP narration liveness")
struct ACPNarrationLivenessTests {
    private static func thought(_ text: String = "hmm") -> ACPMessage {
        .thought(id: UUID(), messageId: nil, StreamingText(text))
    }

    private static func commentary(_ text: String = "Looking around") -> ACPMessage {
        .agent(id: UUID(), messageId: nil, StreamingText(text, phase: .commentary))
    }

    private static func finalAnswer(_ text: String = "Done.") -> ACPMessage {
        .agent(id: UUID(), messageId: nil, StreamingText(text, phase: .finalAnswer))
    }

    private static func toolCall() -> ACPMessage {
        .toolCall(.init(toolCallId: "tc", title: "read", status: "in_progress"))
    }

    private static func plan() -> ACPMessage {
        .plan(id: UUID(), [])
    }

    @Test("the last-touched row is live while the transcript streams")
    func lastTouchedThoughtIsLive() {
        let messages = [Self.commentary(), Self.thought()]
        #expect(liveIndex(messages, touched: 1, streaming: true) == 1)
    }

    @Test("a last-touched commentary row is live while the transcript streams")
    func lastTouchedCommentaryIsLive() {
        let messages = [Self.thought(), Self.commentary()]
        #expect(liveIndex(messages, touched: 1, streaming: true) == 1)
    }

    /// Regression for a real Codex finding: `ACPSession.appendStreaming`
    /// locates a chunk's target row by `messageId` regardless of array
    /// position, so an identified commentary stream can resume into an
    /// OLDER row after a later `.agent` row has already been appended —
    /// exactly what `ACPSessionTests.interleavedPhasedChunks` exercises at
    /// the session layer. A tail scan would report nothing live here; the
    /// pointer must still find the row actually being written to.
    @Test("a resumed commentary row stays live even with a later agent row after it")
    func resumedCommentaryBehindALaterRowIsLive() {
        let messages = [Self.commentary(), Self.finalAnswer()]
        #expect(liveIndex(messages, touched: 0, streaming: true) == 0)
    }

    @Test("a plan touch does not move or close the live row")
    func planTouchDoesNotMoveLiveness() {
        let messages = [Self.thought(), Self.plan()]
        // The plan row itself is never the touched index — `ACPSession.apply`
        // excludes `.plan` from `lastContentTouchIndex` — so the pointer
        // stays on the thought that was actually last written to.
        #expect(liveIndex(messages, touched: 0, streaming: true) == 0)
    }

    @Test("a tool call becoming the touched row closes the prior narration")
    func toolCallTouchClosesNarration() {
        let messages = [Self.thought(), Self.toolCall()]
        #expect(liveIndex(messages, touched: 1, streaming: true) == nil)
    }

    @Test("the final answer is never narration even when it is the touched row")
    func finalAnswerIsNotLive() {
        let messages = [Self.thought(), Self.finalAnswer()]
        #expect(liveIndex(messages, touched: 1, streaming: true) == nil)
    }

    @Test("nothing is live unless the transcript is streaming")
    func quietOutsideStreaming() {
        let messages = [Self.thought()]
        #expect(liveIndex(messages, touched: 0, streaming: false) == nil)
    }

    @Test("nothing is live with no touched index, even while streaming")
    func quietWithNoTouch() {
        let messages = [Self.thought()]
        #expect(liveIndex(messages, touched: nil, streaming: true) == nil)
    }

    @Test("an empty transcript has no live row")
    func emptyTranscript() {
        #expect(liveIndex([], touched: 0, streaming: true) == nil)
    }

    private func liveIndex(_ messages: [ACPMessage], touched: Int?, streaming: Bool) -> Int? {
        ACPNarrationLiveness.liveIndex(
            messages: messages, isStreaming: streaming, lastContentTouchIndex: touched)
    }
}

@MainActor
@Suite(.serialized)
struct ACPNarrationShimmerTests {
    /// The shimmer is allowed to paint over the header and nothing else. A
    /// row whose measured height changed when it went live would make the
    /// scroller re-tile the transcript on the exact update that starts a
    /// turn — see `ACPToolCallGroupRowTests.laneHeightIsIndependentOfHighlight`.
    @Test("the thought header's height does not depend on whether it is live")
    func thoughtHeightIsIndependentOfLiveness() throws {
        let theme = try ThemeStore().current
        let buffer = StreamingText("reasoning")
        let live = measure(ACPThoughtView(buffer: buffer, isLive: true), theme: theme)
        let quiet = measure(ACPThoughtView(buffer: buffer, isLive: false), theme: theme)
        #expect(live == quiet)
    }

    @Test("the shimmer modifier does not change a label's height")
    func shimmerModifierPreservesHeight() throws {
        let theme = try ThemeStore().current
        let live = measure(Text("Working…").acpNarrationShimmer(isActive: true), theme: theme)
        let quiet = measure(Text("Working…").acpNarrationShimmer(isActive: false), theme: theme)
        #expect(live == quiet)
    }

    /// Regression for a real Codex finding: `ACPSubagentMessageRow` used to
    /// render every `.agent` message through `ACPSubagentTextRow` with no
    /// distinction for the commentary phase, so a native subagent's
    /// "Working…" narration never got the header or shimmer the parent
    /// transcript's `ACPCommentaryRow` shows for the same phase.
    @Test("a commentary-phase child row gets the same height whether live or not")
    func childCommentaryHeightIsIndependentOfLiveness() throws {
        let theme = try ThemeStore().current
        let buffer = StreamingText("Looking around", phase: .commentary)
        let live = measure(
            ACPSubagentTextRow(buffer: buffer, typography: .default, isLive: true), theme: theme)
        let quiet = measure(
            ACPSubagentTextRow(buffer: buffer, typography: .default, isLive: false), theme: theme)
        #expect(live == quiet)
    }

    /// A commentary-phase child row must be visibly TALLER than a plain
    /// (final-answer / no-phase) one — otherwise the "Working…" header
    /// silently isn't being rendered at all, which the height-invariance
    /// test above can't catch on its own (it only compares live vs. quiet
    /// of the SAME phase).
    @Test("a commentary-phase child row renders the Working… header the plain row doesn't")
    func childCommentaryRowIsTallerThanPlainRow() throws {
        let theme = try ThemeStore().current
        let commentary = measure(
            ACPSubagentTextRow(buffer: StreamingText("Looking around", phase: .commentary), typography: .default),
            theme: theme)
        let plain = measure(
            ACPSubagentTextRow(buffer: StreamingText("Looking around"), typography: .default),
            theme: theme)
        #expect(commentary > plain)
    }

    /// The lane bar takes its height from the row beside it. A vertical
    /// sweep that reported an intrinsic height of its own would stretch a
    /// collapsed header into a taller row the moment it went live.
    @Test("a vertical shimmer on the lane bar does not give it a height of its own")
    func verticalShimmerPreservesBarHeight() throws {
        let theme = try ThemeStore().current
        func bar(isActive: Bool) -> some View {
            HStack(alignment: .top, spacing: 12) {
                Rectangle()
                    .fill(Color.gray)
                    .frame(width: 1.5)
                    .acpNarrationShimmer(isActive: isActive, axis: .vertical)
                Text("Thinking…")
            }
        }
        #expect(measure(bar(isActive: true), theme: theme) == measure(bar(isActive: false), theme: theme))
    }

    private func measure(_ view: some View, theme: Theme) -> CGFloat {
        let root = view
            .environment(\.theme, theme)
            .frame(width: 400)
        let controller = NSHostingController(rootView: root)
        controller.view.frame = NSRect(x: 0, y: 0, width: 400, height: 10)
        drainSwiftUI(controller.view)
        return controller.view.fittingSize.height
    }

    private func drainSwiftUI(_ view: NSView) {
        for _ in 0..<8 {
            view.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.001))
        }
    }
}
