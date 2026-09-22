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

    @Test("a trailing thought is live while the transcript streams")
    func trailingThoughtIsLive() {
        let messages = [Self.commentary(), Self.thought()]
        #expect(ACPNarrationLiveness.liveIndex(messages: messages, streamingState: .streaming) == 1)
    }

    @Test("a trailing commentary row is live while the transcript streams")
    func trailingCommentaryIsLive() {
        let messages = [Self.thought(), Self.commentary()]
        #expect(ACPNarrationLiveness.liveIndex(messages: messages, streamingState: .streaming) == 1)
    }

    @Test("a plan after the narration does not close it")
    func planIsSkipped() {
        let messages = [Self.thought(), Self.plan()]
        #expect(ACPNarrationLiveness.liveIndex(messages: messages, streamingState: .streaming) == 0)
    }

    @Test("a tool call after the narration closes it")
    func toolCallClosesNarration() {
        let messages = [Self.thought(), Self.toolCall()]
        #expect(ACPNarrationLiveness.liveIndex(messages: messages, streamingState: .streaming) == nil)
    }

    @Test("the final answer is never narration")
    func finalAnswerIsNotLive() {
        let messages = [Self.thought(), Self.finalAnswer()]
        #expect(ACPNarrationLiveness.liveIndex(messages: messages, streamingState: .streaming) == nil)
    }

    @Test(
        "nothing is live unless the transcript is streaming",
        arguments: [ACPSession.StreamingState.idle, .sending, .awaitingPermission, .awaitingInput]
    )
    func quietOutsideStreaming(state: ACPSession.StreamingState) {
        let messages = [Self.thought()]
        #expect(ACPNarrationLiveness.liveIndex(messages: messages, streamingState: state) == nil)
    }

    @Test("an empty transcript has no live row")
    func emptyTranscript() {
        #expect(ACPNarrationLiveness.liveIndex(messages: [], streamingState: .streaming) == nil)
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
