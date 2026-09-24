import AppKit
import Testing
@testable import Alas

/// Regression tests for the tail-follow trap at the bottom of the transcript.
///
/// The scroller used to infer "a human is scrolling" solely from
/// `NSApp.currentEvent`. That is unreliable in an AppKit scroll view: as the
/// transcript slides under a stationary cursor, AppKit generates a stream of
/// `mouseEntered`/`mouseExited` tracking events, and those — not the scroll
/// wheel event — are what is current when the clip view posts its
/// bounds-change notification. A live capture of a single real gesture showed
/// 414 of 417 scroll ticks classified as NOT user-driven (309 `mouseEntered`,
/// 73 `mouseExited`, 28 `cursorUpdate`, versus 3 `scrollWheel`).
///
/// The consequence was a trap rather than a cosmetic misclassification:
/// `ACPScrollDirectionClassifier.decide` only returns `.userScrolledUp` for a
/// user-driven tick, so `pauseTailFollow()` never ran, `followsTail` stayed
/// true, and every `remeasureRow`/`apply` re-pinned the viewport to the bottom
/// via `scrollToBottom()`. The user was dragged back to the tail and could not
/// scroll away at all while the session was streaming.
///
/// `NSScrollView`'s own live-scroll notifications are the authoritative signal
/// — they are posted for genuine user scrolling and never for a programmatic
/// `setBoundsOrigin` — so these tests drive them directly. Note that
/// `NSApp.currentEvent` is nil throughout a unit-test run, which is exactly
/// the condition the old code failed under.
@MainActor
@Suite("ACPTranscriptScroller live-scroll user intent")
struct ACPTranscriptScrollerLiveScrollTests {
    private func tailFollowingHost() -> (
        host: ACPTranscriptScroller,
        scroller: ACPTranscriptScrollerView,
        coordinator: ACPTranscriptScroller.Coordinator
    ) {
        let session = ACPSession(id: "s", agentId: "claude", worktreeId: "w", title: "t")
        session.followsTranscriptTail = true
        let host = makeLiveScrollHost(session: session)
        host.transcript.messages = (0..<120).map { _ in
            ACPMessage.systemNotice(id: UUID(), text: String(repeating: "line ", count: 20))
        }
        host.transcript.visibleHead = 0
        host.transcript.visibleTail = nil

        let scroller = ACPTranscriptScrollerView(frame: NSRect(x: 0, y: 0, width: 600, height: 500))
        let coordinator = ACPTranscriptScroller.Coordinator()
        coordinator.attach(scroller: scroller, host: host)
        scroller.layoutSubtreeIfNeeded()
        return (host, scroller, coordinator)
    }

    /// Moves the viewport the way a real trackpad gesture does: bracketed by
    /// the scroll view's live-scroll notifications, with the clip view's
    /// bounds set directly (NOT through `setScrollY`, which would mark the
    /// change programmatic).
    private func liveScroll(_ scroller: ACPTranscriptScrollerView, to y: CGFloat) {
        NotificationCenter.default.post(
            name: NSScrollView.willStartLiveScrollNotification, object: scroller
        )
        scroller.contentView.setBoundsOrigin(
            NSPoint(x: scroller.contentView.bounds.origin.x, y: y)
        )
        scroller.reflectScrolledClipView(scroller.contentView)
        NotificationCenter.default.post(
            name: NSScrollView.didEndLiveScrollNotification, object: scroller
        )
    }

    @Test("settling folded activity retains visible explanations", arguments: [false, true], [0, 100])
    func settlingFoldedTranscriptKeepsVisibleText(fork: Bool, leadingCount: Int) throws {
        let session = ACPSession(id: "s", agentId: "claude", worktreeId: "w", title: "t")
        session.followsTranscriptTail = false
        var host = makeLiveScrollHost(session: session)
        host.collapsesFinishedToolCalls = true
        host.transcript.messages = (0..<leadingCount).map { index in
            .systemNotice(id: UUID(), text: "Older message \(index)")
        }
        let prompt = ACPMessage.user(id: UUID(), text: "Investigate", attachments: [])
        host.transcript.messages.append(prompt)
        for block in 0..<3 {
            for index in 0..<100 {
                host.transcript.messages.append(.toolCall(.init(
                    toolCallId: "\(block)-\(index)", title: "Read source", status: "completed"
                )))
            }
            host.transcript.messages.append(.agent(
                id: UUID(), messageId: "explanation-\(block)", StreamingText("Visible explanation \(block)")
            ))
        }
        if fork {
            session.forkRecord = ACPSessionForkRecord(
                targetSessionID: "s", sourceSessionID: "source", sourceAgentID: "claude",
                sourceBoundarySequence: Int64(leadingCount + 101), inheritedMessageCount: leadingCount + 101,
                phase: .ready, mechanism: .transcriptTransfer, contextDeliveryPending: false
            )
        }
        let scroller = ACPTranscriptScrollerView(frame: NSRect(x: 0, y: 0, width: 600, height: 900))
        let coordinator = ACPTranscriptScroller.Coordinator()
        coordinator.attach(scroller: scroller, host: host)
        scroller.layoutSubtreeIfNeeded()
        let promptFrame = try #require(coordinator.rowFrameForTesting(id: prompt.stableId))
        scroller.setScrollY(promptFrame.minY)
        #expect(scroller.contentHeight - promptFrame.minY < scroller.viewportHeight)

        coordinator.settleUserScrollForTesting()

        for block in 0..<3 {
            #expect(coordinator.rowFrameForTesting(id: "acp-agent:explanation-\(block)") != nil)
        }
        if leadingCount == 0 { #expect(host.transcript.visibleHead == 0) }
        else { #expect(host.transcript.visibleHead > 0) }
        #expect(host.transcript.visibleTailBound == host.transcript.messages.count)
    }

    @Test("folding completed activity keeps a windowed transcript pinned through layout", arguments: [false, true])
    func completedActivityKeepsTailPinned(whileSettling: Bool) async throws {
        let (originalHost, scroller, coordinator) = tailFollowingHost()
        var host = originalHost
        host.collapsesFinishedToolCalls = true
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 600, height: 500),
            styleMask: [.titled, .resizable], backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = scroller
        defer {
            window.orderOut(nil)
            window.contentView = nil
            window.close()
            withExtendedLifetime(coordinator) {}
        }
        window.orderFront(nil)
        host.transcript.messages.append(.user(
            id: UUID(), messageId: "prompt", text: "Investigate", attachments: []
        ))
        for index in 0..<8 {
            host.transcript.messages.append(.agent(
                id: UUID(), messageId: "status\(index)",
                StreamingText(String(repeating: "Investigating the scroll regression. ", count: 30), phase: .commentary)
            ))
            host.transcript.messages.append(.toolCall(.init(
                toolCallId: "read\(index)", title: "Read source", kind: "read", status: "completed"
            )))
        }
        coordinator.update(host: host)
        for _ in 0..<5 {
            window.layoutIfNeeded()
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(host.session.followsTranscriptTail)
        if whileSettling {
            liveScroll(scroller, to: scroller.scrollY - 20)
            liveScroll(scroller, to: scroller.contentHeight - scroller.viewportHeight)
        }
        #expect(scroller.distanceFromBottom < 1)

        host.transcript.messages.append(.agent(
            id: UUID(), messageId: "answer",
            StreamingText(String(repeating: "The final answer remains visible while earlier activity folds. ", count: 100), phase: .finalAnswer)
        ))
        host.transcript.messages.append(.user(
            id: UUID(), messageId: "next", text: "Continue", attachments: []
        ))
        coordinator.update(host: host)
        for _ in 0..<10 {
            window.layoutIfNeeded()
            try await Task.sleep(for: .milliseconds(20))
            #expect(host.session.followsTranscriptTail)
            #expect(scroller.distanceFromBottom < 1, "folding left the viewport \(scroller.distanceFromBottom)pt above the tail")
        }
    }

    @Test("layout-driven bounds movement does not suppress the next tail update")
    func layoutMovementDoesNotSuppressTailFollow() {
        let (host, scroller, coordinator) = tailFollowingHost()
        // AppKit may move the clip view outside our explicit scroll primitives.
        // With no live gesture, this is layout, not a request to browse history.
        scroller.contentView.setBoundsOrigin(NSPoint(x: 0, y: scroller.scrollY - 100))
        scroller.reflectScrolledClipView(scroller.contentView)
        #expect(scroller.distanceFromBottom < 1, "idle layout must retain the tail without waiting for more output")
        host.transcript.messages.append(.systemNotice(id: UUID(), text: "New streamed content"))
        coordinator.update(host: host)

        #expect(host.session.followsTranscriptTail)
        #expect(scroller.distanceFromBottom < 1)
    }

    @Test("layout reaching the bottom does not resume paused tail-follow")
    func layoutMovementDoesNotResumeTailFollow() async throws {
        let (host, scroller, coordinator) = tailFollowingHost()
        liveScroll(scroller, to: scroller.scrollY - 400)
        #expect(!host.session.followsTranscriptTail)
        try await Task.sleep(for: .milliseconds(700))
        // An idle layout correction reaching the bottom is not a user gesture.
        scroller.contentView.setBoundsOrigin(NSPoint(x: 0, y: scroller.contentHeight - scroller.viewportHeight))
        scroller.reflectScrolledClipView(scroller.contentView)
        coordinator.update(host: host)
        #expect(!host.session.followsTranscriptTail)
    }

    @Test("an upward live scroll pauses tail-follow, with no current NSEvent")
    func liveScrollUpPausesTailFollow() {
        // The coordinator must stay in scope: its `onScroll` closure captures
        // it weakly, so binding it to `_` would silently disable every scroll
        // handler under test.
        let (host, scroller, coordinator) = tailFollowingHost()
        #expect(host.session.followsTranscriptTail, "fixture should start following the tail")
        #expect(scroller.distanceFromBottom < 1, "fixture should start pinned to the bottom")

        // 470pt from the bottom: the furthest the real captured gesture got.
        liveScroll(scroller, to: max(0, scroller.contentHeight - scroller.viewportHeight - 470))

        #expect(
            host.session.followsTranscriptTail == false,
            "a deliberate upward scroll must pause tail-follow even though NSApp.currentEvent is not a scrollWheel"
        )
        withExtendedLifetime(coordinator) {}
    }

    @Test("a small upward live scroll remains where the reader stopped after settling")
    func smallLiveScrollDoesNotSnapBackAfterSettling() async throws {
        let (host, scroller, coordinator) = tailFollowingHost()
        let target = max(0, scroller.contentHeight - scroller.viewportHeight - 80)

        liveScroll(scroller, to: target)
        let distanceFromBottom = scroller.distanceFromBottom
        try await Task.sleep(for: .milliseconds(700))

        #expect(!host.session.followsTranscriptTail)
        #expect(
            abs(scroller.distanceFromBottom - distanceFromBottom) < 1,
            "the settled transcript changed its tail distance from \(distanceFromBottom) to \(scroller.distanceFromBottom)"
        )
        withExtendedLifetime(coordinator) {}
    }

    @Test("after an upward live scroll, a tail row re-measuring does not drag the viewport back to the bottom")
    func remeasureDoesNotYankBackAfterLiveScroll() {
        let (_, scroller, coordinator) = tailFollowingHost()
        let target = max(0, scroller.contentHeight - scroller.viewportHeight - 470)
        liveScroll(scroller, to: target)
        let yAfterScroll = scroller.scrollY
        #expect(abs(yAfterScroll - target) < 1, "the live scroll itself should land where asked")

        // The exact event that used to yank the user back: a mounted row
        // re-measures while the reconciler still believes it is following the
        // tail. This is constant during streaming (`acp-thought:`/`tc-*` rows).
        #expect(
            coordinator.mountedRowCountForTesting > 0,
            "fixture must have mounted rows, or the re-pin path is never exercised"
        )
        coordinator.remeasureMountedRowsForTesting()

        #expect(
            abs(scroller.scrollY - yAfterScroll) < 1,
            "the viewport must stay where the user left it, not snap back to the bottom"
        )
    }

    @Test("a programmatic scroll is never mistaken for a user gesture")
    func programmaticScrollDoesNotPauseTailFollow() {
        let (host, scroller, coordinator) = tailFollowingHost()
        // No live-scroll notifications: this is the app moving the viewport,
        // which must not be read as the user abandoning the tail.
        scroller.setScrollY(max(0, scroller.contentHeight - scroller.viewportHeight - 470))

        #expect(
            host.session.followsTranscriptTail,
            "a programmatic offset change must not pause tail-follow"
        )
        withExtendedLifetime(coordinator) {}
    }

    @Test("a settled history fling compacts the temporary grow-only window")
    func settledHistoryFlingCompactsWindow() async throws {
        let (host, scroller, coordinator) = tailFollowingHost()
        liveScroll(scroller, to: max(0, scroller.contentHeight - scroller.viewportHeight - 470))

        try await Task.sleep(for: .milliseconds(600))

        #expect(
            host.transcript.visibleTailBound - host.transcript.visibleHead
                <= ACPTranscript.maxVisibleRows
        )
        withExtendedLifetime(coordinator) {}
    }

    @Test("returning to the tail keeps the history window until rubberband scrolling settles")
    func returningToTailDefersWindowCompaction() async throws {
        let (host, scroller, coordinator) = tailFollowingHost()
        defer { withExtendedLifetime(coordinator) {} }
        let originalHeight = scroller.contentHeight
        let bottom = originalHeight - scroller.viewportHeight
        liveScroll(scroller, to: bottom - 470)
        #expect(!host.session.followsTranscriptTail)

        NotificationCenter.default.post(
            name: NSScrollView.willStartLiveScrollNotification, object: scroller
        )
        scroller.contentView.setBoundsOrigin(NSPoint(x: 0, y: bottom))
        scroller.reflectScrolledClipView(scroller.contentView)
        #expect(host.session.followsTranscriptTail)
        #expect(host.transcript.visibleTail == nil, "new messages must remain visible while following")
        #expect(host.transcript.visibleHead == 0, "do not discard history during the gesture")

        coordinator.update(host: host)
        try await Task.sleep(for: .milliseconds(400))
        #expect(host.transcript.visibleHead == 0, "the settle timer must wait for live scrolling to end")
        #expect(scroller.contentHeight == originalHeight)

        NotificationCenter.default.post(
            name: NSScrollView.didEndLiveScrollNotification, object: scroller
        )
        try await Task.sleep(for: .milliseconds(700))
        #expect(host.transcript.visibleHead == 120 - ACPTranscript.tailWindow)
        #expect(host.transcript.visibleTail == nil)
        #expect(scroller.distanceFromBottom < 1)
    }

    @Test("settling an input-request chat does not compact the reading window")
    func settlingInputRequestChatDoesNotCompactReadingWindow() async throws {
        let session = ACPSession(id: "s", agentId: "claude", worktreeId: "w", title: "t")
        session.followsTranscriptTail = false
        let host = makeLiveScrollHost(session: session)
        host.transcript.messages = (0..<240).map { index in
            .systemNotice(id: UUID(), text: String(repeating: "message \(index) ", count: 20))
        }
        host.transcript.visibleHead = 0
        host.transcript.visibleTail = nil
        host.transcript.streamingState = .awaitingInput
        host.transcript.pendingUserInputs = [
            ACPUserInputRequest(
                id: UUID(),
                source: .cursor(
                    id: .string("question"),
                    params: ACPQuestionRequestParams(toolCallId: "tool", title: "Question", questions: [])
                ),
                title: "Question",
                message: "Question",
                fields: [],
                mode: .form
            ),
        ]

        let scroller = ACPTranscriptScrollerView(frame: NSRect(x: 0, y: 0, width: 600, height: 500))
        let coordinator = ACPTranscriptScroller.Coordinator()
        coordinator.attach(scroller: scroller, host: host)
        scroller.layoutSubtreeIfNeeded()
        scroller.setScrollY(scroller.contentHeight / 2)

        liveScroll(scroller, to: scroller.scrollY - 80)
        let expectedMessage = coordinator.topVisibleMessageIdForTesting
        try await Task.sleep(for: .milliseconds(700))

        #expect(host.transcript.visibleTailBound - host.transcript.visibleHead > ACPTranscript.maxVisibleRows)
        #expect(coordinator.topVisibleMessageIdForTesting == expectedMessage)
        withExtendedLifetime(coordinator) {}
    }

    @Test("live-scroll activity lapses after the gesture settles")
    func userScrollActivityLapses() {
        let (_, scroller, coordinator) = tailFollowingHost()
        defer { withExtendedLifetime(coordinator) {} }
        NotificationCenter.default.post(
            name: NSScrollView.willStartLiveScrollNotification, object: scroller
        )
        #expect(scroller.isUserScrollActive, "a gesture in flight is user activity")

        NotificationCenter.default.post(
            name: NSScrollView.didEndLiveScrollNotification, object: scroller
        )
        // Still active immediately after the gesture ends: momentum and the
        // elastic bounce-back are still the user's scroll, and re-pinning
        // during that settle is exactly the rebound jank being fixed.
        #expect(scroller.isUserScrollActive, "the settle right after a gesture is still user activity")

        #expect(
            ACPTranscriptScrollerView.isUserScrollActive(
                isLiveScrolling: false,
                lastLiveScrollEnd: 100,
                now: 100 + ACPTranscriptScrollerView.userScrollGracePeriod + 0.01
            ) == false,
            "well after the gesture, the scroller is idle again"
        )
    }
}

@MainActor
private func makeLiveScrollHost(session: ACPSession) -> ACPTranscriptScroller {
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
        onPlanResponse: { _, _ in },
        onOpenElicitationURL: { _ in true },
        onDismissElicitationURLWait: { _ in },
        onQueueEdit: { _ in },
        onQueueForceSend: { _ in },
        onQueuePromote: { _ in },
        onQueueRemove: { _ in },
        onQueueRetry: { _ in },
        onQueueReorder: { _, _ in },
        onQueueClearAll: {},
        onRetryContextRecovery: {},
        onOpenForkSource: { _ in },
        agentDisplayName: { $0 }
    )
}
