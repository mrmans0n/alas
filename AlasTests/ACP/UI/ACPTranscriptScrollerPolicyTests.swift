import AppKit
import Foundation
import Testing
@testable import Alas

/// Fabricates a fully-wired `ACPTranscriptScroller` host with no-op
/// callbacks, for tests that only care about the emitted row-spec id list —
/// not about what any particular callback does when invoked.
@MainActor
private func makeHost(
    session: ACPSession = ACPSession(id: "s", agentId: "claude", worktreeId: "w", title: "t"),
    contentMaxWidth: CGFloat = 800,
    typography: ACPChatTypography = .default
) -> ACPTranscriptScroller {
    ACPTranscriptScroller(
        session: session,
        transcript: session.transcript,
        contentMaxWidth: contentMaxWidth,
        typography: typography,
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

    /// Regression test for the P2 finding (codex round 4): `ACPUserInputPrompt`
    /// holds live `@State`/`@FocusState` form data that a fresh
    /// `NSHostingView` would silently discard, so its spec must opt out of
    /// the reconciler's ordinary "unmount when off-band" policy. Ordinary
    /// synthetic rows (the streaming caret, a queued bubble — neither holds
    /// state whose loss is user-visible) and message rows must NOT opt in,
    /// or the exemption would stop being small and bounded.
    @Test("only the pending user-input row opts into staying mounted off-band")
    func onlyPendingUserInputKeepsMountedOffscreen() {
        let session = ACPSession(id: "s", agentId: "claude", worktreeId: "w", title: "t")
        session.queue = [QueuedPrompt(blocks: [.text("queued")], status: .pending)]
        let host = makeHost(session: session)
        let messages = (0..<2).map { _ in message() }
        host.transcript.messages = messages
        host.transcript.visibleHead = 0
        host.transcript.visibleTail = nil
        host.transcript.streamingState = .streaming
        host.transcript.pendingUserInputs = [
            ACPUserInputRequest(
                id: UUID(),
                source: .cursor(
                    id: .string("q1"),
                    params: ACPQuestionRequestParams(toolCallId: "t1", title: "Pick one", questions: [])
                ),
                title: "Pick one",
                message: "Pick one",
                fields: [],
                mode: .form
            ),
        ]

        let specs = ACPTranscriptScroller.Coordinator.rowSpecs(host: host)
        let byId = Dictionary(uniqueKeysWithValues: specs.map { ($0.id, $0) })

        let pendingInputId = specs.map(\.id).first { $0.hasPrefix("__pending_user_input_") }
        #expect(pendingInputId != nil)
        #expect(byId[pendingInputId!]?.keepsMountedOffscreen == true)

        // Every other row — message rows and the other synthetic rows —
        // stays with the default (unmount when off-band).
        for id in specs.map(\.id) where id != pendingInputId {
            #expect(byId[id]?.keepsMountedOffscreen == false, "\(id) unexpectedly opted into keepsMountedOffscreen")
        }
    }
}

/// Regression coverage for the review's fix-round-2 finding: the queued-
/// bubble spec's `build` closure captures `host.contentMaxWidth`,
/// `host.typography`, and the enumeration index `idx` (used by the drop
/// handler for reordering), but its equality token used to fold in only the
/// `QueuedPrompt` and `host.theme`. A mounted bubble whose closure was
/// retained (because the token still compared equal) rendered/measured
/// with stale typography or width, and — worse — its retained drop handler
/// kept dragging against a stale `idx` after the queue reordered.
///
/// These tests exercise `rowSpecs(host:)`'s emitted `equalityToken` (via
/// `ACPRowEqualityToken.isEqual(to:)`) directly, the same token the
/// hosting pool compares to decide whether to rebuild a mounted row.
@MainActor
@Suite("ACPTranscriptScroller queue bubble equality token")
struct ACPTranscriptScrollerQueueBubbleTokenTests {
    private func queueBubbleToken(host: ACPTranscriptScroller, id: UUID) -> ACPRowEqualityToken? {
        ACPTranscriptScroller.Coordinator.rowSpecs(host: host)
            .first { $0.id == "__queue_\(id)" }?
            .equalityToken
    }

    @Test("token is unchanged when nothing relevant changed")
    func tokenStableAcrossIdenticalHosts() throws {
        let id = UUID()
        let session = ACPSession(id: "s", agentId: "claude", worktreeId: "w", title: "t")
        session.queue = [QueuedPrompt(id: id, blocks: [.text("hello")], status: .pending)]
        let hostA = makeHost(session: session, contentMaxWidth: 800, typography: .default)
        let hostB = makeHost(session: session, contentMaxWidth: 800, typography: .default)

        let tokenA = try #require(queueBubbleToken(host: hostA, id: id))
        let tokenB = try #require(queueBubbleToken(host: hostB, id: id))
        #expect(tokenA.isEqual(to: tokenB))
    }

    @Test("token changes when contentMaxWidth changes, QueuedPrompt unchanged")
    func tokenChangesOnContentMaxWidth() throws {
        let id = UUID()
        let session = ACPSession(id: "s", agentId: "claude", worktreeId: "w", title: "t")
        session.queue = [QueuedPrompt(id: id, blocks: [.text("hello")], status: .pending)]
        let narrow = makeHost(session: session, contentMaxWidth: 600, typography: .default)
        let wide = makeHost(session: session, contentMaxWidth: 900, typography: .default)

        let narrowToken = try #require(queueBubbleToken(host: narrow, id: id))
        let wideToken = try #require(queueBubbleToken(host: wide, id: id))
        #expect(!narrowToken.isEqual(to: wideToken))
    }

    @Test("token changes when typography changes, QueuedPrompt unchanged")
    func tokenChangesOnTypography() throws {
        let id = UUID()
        let session = ACPSession(id: "s", agentId: "claude", worktreeId: "w", title: "t")
        session.queue = [QueuedPrompt(id: id, blocks: [.text("hello")], status: .pending)]
        let hostA = makeHost(session: session, typography: .default)
        let hostB = makeHost(session: session, typography: ACPChatTypography(fontFamily: "Menlo", fontSize: 18))

        let tokenA = try #require(queueBubbleToken(host: hostA, id: id))
        let tokenB = try #require(queueBubbleToken(host: hostB, id: id))
        #expect(!tokenA.isEqual(to: tokenB))
    }

    @Test("token changes when the item's queue position changes, QueuedPrompt unchanged")
    func tokenChangesOnIndex() throws {
        let movedId = UUID()
        let movedItem = QueuedPrompt(id: movedId, blocks: [.text("hello")], status: .pending)
        let otherItem = QueuedPrompt(id: UUID(), blocks: [.text("other")], status: .pending)

        // `movedItem` sits at index 0 in the first session, index 1 in the
        // second — same QueuedPrompt value, different enumeration index.
        let sessionFirst = ACPSession(id: "s", agentId: "claude", worktreeId: "w", title: "t")
        sessionFirst.queue = [movedItem, otherItem]
        let sessionSecond = ACPSession(id: "s2", agentId: "claude", worktreeId: "w", title: "t")
        sessionSecond.queue = [otherItem, movedItem]

        let hostFirst = makeHost(session: sessionFirst)
        let hostSecond = makeHost(session: sessionSecond)

        let tokenFirst = try #require(queueBubbleToken(host: hostFirst, id: movedId))
        let tokenSecond = try #require(queueBubbleToken(host: hostSecond, id: movedId))
        #expect(!tokenFirst.isEqual(to: tokenSecond))
    }
}

/// Regression coverage for the same finding, generalized: `wrapRow` applies
/// `.frame(maxWidth: host.contentMaxWidth, ...)` to EVERY row, synthetic
/// rows included, via the shared `token(_:host:)` helper. Picks one
/// representative synthetic spec (the top pagination sentinel) to confirm
/// the fix is systemic, not just applied to the queue bubble.
@MainActor
@Suite("ACPTranscriptScroller synthetic row tokens fold contentMaxWidth")
struct ACPTranscriptScrollerSyntheticTokenTests {
    @Test("top pagination sentinel token changes when contentMaxWidth changes")
    func topPaginationTokenChangesOnContentMaxWidth() throws {
        let session = ACPSession(id: "s", agentId: "claude", worktreeId: "w", title: "t")
        let messages = (0..<5).map { _ in ACPMessage.systemNotice(id: UUID(), text: "hello") }
        session.transcript.messages = messages
        session.transcript.visibleHead = 2
        session.transcript.visibleTail = nil

        let narrow = makeHost(session: session, contentMaxWidth: 600)
        let wide = makeHost(session: session, contentMaxWidth: 900)

        let narrowToken = try #require(
            ACPTranscriptScroller.Coordinator.rowSpecs(host: narrow).first { $0.id == "__top_pagination__" }?.equalityToken
        )
        let wideToken = try #require(
            ACPTranscriptScroller.Coordinator.rowSpecs(host: wide).first { $0.id == "__top_pagination__" }?.equalityToken
        )
        #expect(!narrowToken.isEqual(to: wideToken))
    }

    @Test("top pagination sentinel token unchanged when nothing relevant changed")
    func topPaginationTokenStable() throws {
        let session = ACPSession(id: "s", agentId: "claude", worktreeId: "w", title: "t")
        let messages = (0..<5).map { _ in ACPMessage.systemNotice(id: UUID(), text: "hello") }
        session.transcript.messages = messages
        session.transcript.visibleHead = 2
        session.transcript.visibleTail = nil

        let hostA = makeHost(session: session, contentMaxWidth: 800)
        let hostB = makeHost(session: session, contentMaxWidth: 800)

        let tokenA = try #require(
            ACPTranscriptScroller.Coordinator.rowSpecs(host: hostA).first { $0.id == "__top_pagination__" }?.equalityToken
        )
        let tokenB = try #require(
            ACPTranscriptScroller.Coordinator.rowSpecs(host: hostB).first { $0.id == "__top_pagination__" }?.equalityToken
        )
        #expect(tokenA.isEqual(to: tokenB))
    }
}

@MainActor
@Suite("ACPTranscriptScroller restore latch")
struct ACPTranscriptScrollerRestoreLatchTests {
    /// Regression test for the review's fix-round-2 finding: `attach()`
    /// (mirroring `makeNSView`, which builds the scroller at `frame: .zero`)
    /// always runs its first `update(host:)` at `contentWidth == 0`, where
    /// `reconciler.apply` defers and the tiling map stays empty even though
    /// `hasNonSyntheticRow` is already true from the spec list alone. A
    /// non-tail-following host with real messages and no remembered anchor
    /// must NOT latch `didRestoreInitialPosition` on that width-0 pass —
    /// otherwise the real restore, once actual rows exist, is skipped
    /// forever and the transcript opens at `scrollY == 0` instead of at the
    /// bottom (the correct fallback when there is nothing to restore).
    @Test("the restore latch waits for a positive-width apply before consuming itself")
    func restoreLatchWaitsForPositiveWidth() {
        let session = ACPSession(id: "s", agentId: "claude", worktreeId: "w", title: "t")
        session.followsTranscriptTail = false
        let host = makeHost(session: session)
        // Enough real content that the measured document is taller than the
        // eventual 400pt viewport, so `scrollToBottom()` is distinguishable
        // from "nothing happened, still at 0".
        let messages = (0..<40).map { _ in
            ACPMessage.systemNotice(id: UUID(), text: String(repeating: "line ", count: 20))
        }
        host.transcript.messages = messages
        host.transcript.visibleHead = 0
        host.transcript.visibleTail = nil
        // `makeHost`'s `rememberedScrollAnchor` always returns nil — no
        // anchor to restore, so the correct outcome is `scrollToBottom()`.

        // Mirrors `makeNSView`'s `ACPTranscriptScrollerView(frame: .zero)`.
        let scroller = ACPTranscriptScrollerView(frame: .zero)
        let coordinator = ACPTranscriptScroller.Coordinator()
        coordinator.attach(scroller: scroller, host: host)

        // Width-0 pass: `reconciler.apply` deferred, tiling map is empty.
        // Nothing should have latched or moved.
        #expect(scroller.scrollY == 0)

        // The view is laid out for real (as SwiftUI does once the
        // representable actually gets placed), and `update` runs again.
        scroller.frame = NSRect(x: 0, y: 0, width: 600, height: 400)
        scroller.layoutSubtreeIfNeeded()
        coordinator.update(host: host)

        // The restore must actually run on this first positive-width pass —
        // if the latch had been consumed prematurely, this would still be 0.
        #expect(scroller.distanceFromBottom < 1)
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

    @Test("a head step already awaiting its compensating update does not queue another")
    func headStepIsLatchedUntilTheNextUpdate() {
        // `stepHeadBack` mutates `visibleHead` synchronously, but the
        // compensating prepend only lands on the NEXT SwiftUI update. Every
        // intervening scroll tick still sees a positive `visibleHead` and a
        // `scrollY` under threshold, so without a latch a single flick near
        // the head queues several steps that arrive as one 60-150 row
        // insertion measured in a single synchronous pass.
        #expect(!ACPTranscriptScroller.shouldStepHeadBack(
            visibleHead: 30, scrollY: 800, isUserDriven: true, threshold: 1500,
            hasPendingHeadStep: true))
        #expect(ACPTranscriptScroller.shouldStepHeadBack(
            visibleHead: 30, scrollY: 800, isUserDriven: true, threshold: 1500,
            hasPendingHeadStep: false))
    }

    @Test("tail step fires near the bottom when newer rows are hidden and the user is scrolling down")
    func tailStep() {
        #expect(ACPTranscriptScroller.shouldStepTailForward(
            visibleTail: 100, messageCount: 200, distanceFromBottom: 900,
            isUserDriven: true, threshold: 1500,
            previousScrollY: 1000, newScrollY: 1050))
        #expect(!ACPTranscriptScroller.shouldStepTailForward(
            visibleTail: 200, messageCount: 200, distanceFromBottom: 900,
            isUserDriven: true, threshold: 1500,
            previousScrollY: 1000, newScrollY: 1050))
        #expect(!ACPTranscriptScroller.shouldStepTailForward(
            visibleTail: 100, messageCount: 200, distanceFromBottom: 5000,
            isUserDriven: true, threshold: 1500,
            previousScrollY: 1000, newScrollY: 1050))
    }

    @Test("tail step does not fire while the user is scrolling up, even within threshold")
    func tailStepWithholdsOnUpwardScroll() {
        // Same visibleTail/messageCount/distanceFromBottom/isUserDriven/threshold
        // as the passing case in `tailStep`, but the offset moved UP
        // (newScrollY < previousScrollY) — browsing older content should not
        // page in hidden newer messages.
        #expect(!ACPTranscriptScroller.shouldStepTailForward(
            visibleTail: 100, messageCount: 200, distanceFromBottom: 900,
            isUserDriven: true, threshold: 1500,
            previousScrollY: 1050, newScrollY: 1000))
    }

    @Test("tail step withholds when direction is unknown (no previous offset yet)")
    func tailStepWithholdsWithoutPreviousOffset() {
        #expect(!ACPTranscriptScroller.shouldStepTailForward(
            visibleTail: 100, messageCount: 200, distanceFromBottom: 900,
            isUserDriven: true, threshold: 1500,
            previousScrollY: nil, newScrollY: 1050))
    }

    @Test("tail step ignores sub-epsilon jitter as downward movement")
    func tailStepWithholdsOnJitter() {
        // A change smaller than `ACPScrollDirectionClassifier.upwardEpsilon`
        // (0.5pt) must not be treated as a deliberate downward scroll.
        #expect(!ACPTranscriptScroller.shouldStepTailForward(
            visibleTail: 100, messageCount: 200, distanceFromBottom: 900,
            isUserDriven: true, threshold: 1500,
            previousScrollY: 1000, newScrollY: 1000.2))
    }

    @Test("head step threshold scales with viewport but has a floor")
    func threshold() {
        #expect(ACPTranscriptScroller.headStepThreshold(viewportHeight: 500) == 1500)
        #expect(ACPTranscriptScroller.headStepThreshold(viewportHeight: 900) == 1800)
    }
}

/// Regression coverage for the review's fix-round-2 finding: a click on the
/// scrollbar track arrives as a plain `.leftMouseDown`, which
/// `ACPUserScrollEvent.isUserDriven` alone rejects. `handleScroll` now
/// widens the tail-follow pause/resume classification and the head-step
/// gate to `ACPUserScrollEvent.isHeadPaginationDriven` — which additionally
/// accepts a `.leftMouseDown` when it is a genuine scrollbar-track hit AND
/// the geometry actually moved upward — while leaving `shouldStepTailForward`
/// on the plain `isUserDriven` signal, mirroring
/// `ACPMessageList.handleScrollGeometry` exactly (compare
/// `ACPMessageList.swift`'s `handleScrollGeometry`/
/// `shouldStepHeadBackFromGeometry` call sites).
///
/// `handleScroll` itself is a private, `NSApp.currentEvent`-driven method
/// that needs a real `NSEvent` routed through an actual window's view
/// hierarchy (for `isScrollbarTrackMouseDown`'s hit-test) to exercise for
/// real — not something a headless unit test can synthesize. These tests
/// instead exercise the pure `nonisolated static` predicates directly
/// (`ACPUserScrollEvent.isHeadPaginationDriven`, `ACPScrollDirectionClassifier
/// .decide`, `ACPTranscriptScroller.shouldStepHeadBack`/
/// `shouldStepTailForward`), composed exactly the way `handleScroll` composes
/// them, which is why those predicates are `nonisolated static` in the first
/// place.
@Suite("ACPTranscriptScroller scrollbar-track click classification")
struct ACPTranscriptScrollerScrollbarTrackClickTests {
    private static let threshold: CGFloat = 1500

    @Test("an upward scrollbar-track click pauses tail-follow, same as a live scroll gesture")
    func scrollbarTrackClickPausesTailFollow() {
        // A track click landing above the current position: previousMinY
        // 2000 -> newMinY 100, a genuine scrollbar hit.
        let isHeadPaginationDriven = ACPUserScrollEvent.isHeadPaginationDriven(
            .leftMouseDown, previousMinY: 2000, newMinY: 100, isScrollbarTrackHit: true
        )
        #expect(isHeadPaginationDriven)

        let decision = ACPScrollDirectionClassifier.decide(
            previousOffsetY: 2000, newOffsetY: 100,
            viewportHeight: 400, contentHeight: 5000,
            isRestoring: false, isUserDriven: isHeadPaginationDriven
        )
        #expect(decision == .userScrolledUp)
    }

    @Test("a scrollbar-track click away from the track does not pause tail-follow")
    func nonScrollbarClickDoesNotPauseTailFollow() {
        // Same geometry as the passing case above, but the click did not
        // land on the scrollbar (e.g. a transcript control).
        let isHeadPaginationDriven = ACPUserScrollEvent.isHeadPaginationDriven(
            .leftMouseDown, previousMinY: 2000, newMinY: 100, isScrollbarTrackHit: false
        )
        #expect(!isHeadPaginationDriven)

        let decision = ACPScrollDirectionClassifier.decide(
            previousOffsetY: 2000, newOffsetY: 100,
            viewportHeight: 400, contentHeight: 5000,
            isRestoring: false, isUserDriven: isHeadPaginationDriven
        )
        #expect(decision == .noChange)
    }

    @Test("a scrollbar-track click that does not move the geometry upward does not pause tail-follow")
    func scrollbarClickWithoutUpwardMovementDoesNotPauseTailFollow() {
        // Downward or no-op track click: geometry did not move up.
        let isHeadPaginationDriven = ACPUserScrollEvent.isHeadPaginationDriven(
            .leftMouseDown, previousMinY: 100, newMinY: 2000, isScrollbarTrackHit: true
        )
        #expect(!isHeadPaginationDriven)

        let decision = ACPScrollDirectionClassifier.decide(
            previousOffsetY: 100, newOffsetY: 2000,
            viewportHeight: 400, contentHeight: 5000,
            isRestoring: false, isUserDriven: isHeadPaginationDriven
        )
        #expect(decision == .noChange)
    }

    @Test("an upward scrollbar-track click can also trigger head pagination")
    func scrollbarTrackClickTriggersHeadPagination() {
        let isHeadPaginationDriven = ACPUserScrollEvent.isHeadPaginationDriven(
            .leftMouseDown, previousMinY: 2000, newMinY: 100, isScrollbarTrackHit: true
        )
        #expect(ACPTranscriptScroller.shouldStepHeadBack(
            visibleHead: 30, scrollY: 100, isUserDriven: isHeadPaginationDriven, threshold: Self.threshold
        ))
    }

    @Test("a non-scrollbar click does not trigger head pagination")
    func nonScrollbarClickDoesNotTriggerHeadPagination() {
        let isHeadPaginationDriven = ACPUserScrollEvent.isHeadPaginationDriven(
            .leftMouseDown, previousMinY: 2000, newMinY: 100, isScrollbarTrackHit: false
        )
        #expect(!ACPTranscriptScroller.shouldStepHeadBack(
            visibleHead: 30, scrollY: 100, isUserDriven: isHeadPaginationDriven, threshold: Self.threshold
        ))
    }

    @Test("a scrollbar-track click does not drive tail pagination, matching the legacy plain-isUserDriven gate")
    func scrollbarTrackClickDoesNotDriveTailPagination() {
        // `shouldStepTailForward` mirrors `ACPMessageList
        // .shouldStepTailForwardFromBottomGeometry`, which the legacy path
        // gates on plain `isUserDriven`, NOT `isHeadPaginationDriven` — a
        // scrollbar-track click must not page in hidden newer messages.
        let plainIsUserDriven = ACPUserScrollEvent.isUserDriven(.leftMouseDown)
        #expect(!plainIsUserDriven)
        #expect(!ACPTranscriptScroller.shouldStepTailForward(
            visibleTail: 100, messageCount: 200, distanceFromBottom: 900,
            isUserDriven: plainIsUserDriven, threshold: Self.threshold,
            previousScrollY: 2000, newScrollY: 2050
        ))
    }
}
