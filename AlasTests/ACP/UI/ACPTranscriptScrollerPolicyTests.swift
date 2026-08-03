import Foundation
import Testing
@testable import Alas

/// Fabricates a fully-wired `ACPTranscriptScroller` host with no-op
/// callbacks, for tests that only care about the emitted row-spec id list —
/// not about what any particular callback does when invoked.
@MainActor
private func makeHost(
    session: ACPSession = ACPSession(id: "s", agentId: "claude", worktreeId: "w", title: "t")
) -> ACPTranscriptScroller {
    ACPTranscriptScroller(
        session: session,
        transcript: session.transcript,
        contentMaxWidth: 800,
        typography: .default,
        trustedImageRoot: nil,
        onOpenDiff: { _ in },
        onLoadFullToolCallContent: { _ in nil },
        forkTargets: [],
        onFork: { _, _ in },
        rememberedScrollAnchor: { nil },
        onRememberScrollAnchor: { _, _, _ in },
        onOpenTranscriptLink: { _ in true },
        policy: nil,
        scopeKey: "scope",
        onUserInputResponse: { _, _ in },
        onOpenElicitationURL: { _ in true },
        onDismissElicitationURLWait: { _ in },
        onQueueEdit: { _ in },
        onQueueForceSend: { _ in },
        onQueueRemove: { _ in },
        onQueueRetry: { _ in },
        onQueueReorder: { _, _ in },
        onQueueClearAll: {},
        onRetryContextRecovery: {},
        onOpenForkSource: { _ in },
        agentDisplayName: { $0 }
    )
}

@MainActor
@Suite("ACPTranscriptScroller rowSpecs id list")
struct ACPTranscriptScrollerRowSpecsTests {
    private func message() -> ACPMessage {
        .systemNotice(id: UUID(), text: "hello")
    }

    @Test("plain transcript: message rows followed by the composer spacer, no head sentinel")
    func plainTranscriptIdList() {
        let host = makeHost()
        let messages = (0..<3).map { _ in message() }
        host.transcript.messages = messages
        host.transcript.visibleHead = 0
        host.transcript.visibleTail = nil

        let specs = ACPTranscriptScroller.Coordinator.rowSpecs(host: host)
        let ids = specs.map(\.id)
        let expectedMessageIds = messages.map { host.transcript.stableId(for: $0) }

        #expect(ids == expectedMessageIds + ["__composer_spacer__"])
    }

    @Test("head pagination sentinel is first when older rows are hidden")
    func headSentinelIsFirst() {
        let host = makeHost()
        let messages = (0..<5).map { _ in message() }
        host.transcript.messages = messages
        host.transcript.visibleHead = 2
        host.transcript.visibleTail = nil

        let specs = ACPTranscriptScroller.Coordinator.rowSpecs(host: host)
        let ids = specs.map(\.id)
        let expectedMessageIds = messages[2...].map { host.transcript.stableId(for: $0) }

        #expect(ids.first == "__top_pagination__")
        #expect(ids == ["__top_pagination__"] + expectedMessageIds + ["__composer_spacer__"])
    }

    @Test("streaming caret and queue rows are ordered after messages and before the composer spacer")
    func syntheticTailOrdering() {
        let session = ACPSession(id: "s", agentId: "claude", worktreeId: "w", title: "t")
        session.queue = [
            QueuedPrompt(blocks: [.text("queued one")], status: .pending),
            QueuedPrompt(blocks: [.text("queued two")], status: .pending),
        ]
        let host = makeHost(session: session)
        let messages = (0..<2).map { _ in message() }
        host.transcript.messages = messages
        host.transcript.visibleHead = 0
        host.transcript.visibleTail = nil
        host.transcript.streamingState = .streaming

        let specs = ACPTranscriptScroller.Coordinator.rowSpecs(host: host)
        let ids = specs.map(\.id)
        let expectedMessageIds = messages.map { host.transcript.stableId(for: $0) }

        // Exact expected order: messages, then streaming caret, then the
        // queue header (2 pending items > 1), then each queued bubble in
        // order, then the composer spacer. No permission/user-input/
        // elicitation/context-recovery rows since none apply here.
        var expected = expectedMessageIds
        expected.append("__streaming_caret__")
        expected.append("__queue_header__")
        for item in session.queue { expected.append("__queue_\(item.id)") }
        expected.append("__composer_spacer__")

        #expect(ids == expected)
    }
}

@Suite("ACPTranscriptScroller policies")
struct ACPTranscriptScrollerPolicyTests {
    @Test("head step fires near the top during a user scroll when older rows exist")
    func headStep() {
        #expect(ACPTranscriptScroller.shouldStepHeadBack(
            visibleHead: 30, scrollY: 800, isUserDriven: true, threshold: 1500))
        #expect(!ACPTranscriptScroller.shouldStepHeadBack(
            visibleHead: 0, scrollY: 800, isUserDriven: true, threshold: 1500))
        #expect(!ACPTranscriptScroller.shouldStepHeadBack(
            visibleHead: 30, scrollY: 2000, isUserDriven: true, threshold: 1500))
        #expect(!ACPTranscriptScroller.shouldStepHeadBack(
            visibleHead: 30, scrollY: 800, isUserDriven: false, threshold: 1500))
    }

    @Test("tail step fires near the bottom when newer rows are hidden")
    func tailStep() {
        #expect(ACPTranscriptScroller.shouldStepTailForward(
            visibleTail: 100, messageCount: 200, distanceFromBottom: 900,
            isUserDriven: true, threshold: 1500))
        #expect(!ACPTranscriptScroller.shouldStepTailForward(
            visibleTail: 200, messageCount: 200, distanceFromBottom: 900,
            isUserDriven: true, threshold: 1500))
        #expect(!ACPTranscriptScroller.shouldStepTailForward(
            visibleTail: 100, messageCount: 200, distanceFromBottom: 5000,
            isUserDriven: true, threshold: 1500))
    }

    @Test("head step threshold scales with viewport but has a floor")
    func threshold() {
        #expect(ACPTranscriptScroller.headStepThreshold(viewportHeight: 500) == 1500)
        #expect(ACPTranscriptScroller.headStepThreshold(viewportHeight: 900) == 1800)
    }
}
