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
    typography: ACPChatTypography = .default,
    onRememberScrollAnchor: @escaping (String?, Int?, Bool) -> Void = { _, _, _ in }
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
        onRememberScrollAnchor: onRememberScrollAnchor,
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

/// Regression coverage for the P2 finding (codex round 6, Finding 2): the
/// fork divider's `build` closure derives its displayed title by CALLING
/// `host.agentDisplayName(fork.sourceAgentID)` — a value computed from the
/// host, not present anywhere in the token itself (which only folded
/// `fork`, theme, and contentMaxWidth). A live rename of the source agent's
/// display name therefore left an already-mounted divider showing the OLD
/// name, because the token still compared equal and the pool never called
/// `build()` again.
@MainActor
@Suite("ACPTranscriptScroller fork divider equality token")
struct ACPTranscriptScrollerForkDividerTokenTests {
    private func hostWithFork(agentDisplayName: @escaping (String) -> String) -> ACPTranscriptScroller {
        let session = ACPSession(id: "s", agentId: "claude", worktreeId: "w", title: "t")
        session.forkRecord = ACPSessionForkRecord(
            targetSessionID: "target", sourceSessionID: "source", sourceAgentID: "agentA",
            sourceBoundarySequence: 0, inheritedMessageCount: 1,
            phase: .ready, mechanism: .transcriptTransfer, contextDeliveryPending: false
        )
        let host = ACPTranscriptScroller(
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
            agentDisplayName: agentDisplayName
        )
        host.transcript.messages = [.systemNotice(id: UUID(), text: "hello")]
        host.transcript.visibleHead = 0
        host.transcript.visibleTail = nil
        return host
    }

    private func forkDividerToken(host: ACPTranscriptScroller) -> ACPRowEqualityToken? {
        ACPTranscriptScroller.Coordinator.rowSpecs(host: host)
            .first { $0.id == "__fork_divider__" }?.equalityToken
    }

    @Test("token changes when the resolved agent display name changes, everything else identical")
    func tokenChangesOnResolvedDisplayName() throws {
        let hostA = hostWithFork(agentDisplayName: { _ in "Claude" })
        let hostB = hostWithFork(agentDisplayName: { _ in "Claude (renamed)" })

        let tokenA = try #require(forkDividerToken(host: hostA))
        let tokenB = try #require(forkDividerToken(host: hostB))
        #expect(!tokenA.isEqual(to: tokenB))
    }

    @Test("token is unchanged when nothing relevant changed, including the resolved display name")
    func tokenStableWhenNothingChanged() throws {
        let hostA = hostWithFork(agentDisplayName: { _ in "Claude" })
        let hostB = hostWithFork(agentDisplayName: { _ in "Claude" })

        let tokenA = try #require(forkDividerToken(host: hostA))
        let tokenB = try #require(forkDividerToken(host: hostB))
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

    /// Regression test for the P1 finding (codex round 5): `attach()`'s
    /// first `update(host:)` always runs against `frame: .zero`, where
    /// `reconciler.apply` defers. Nothing besides a later SwiftUI-driven
    /// `updateNSView` used to re-run `update(host:)`, so a real width
    /// arriving purely through the scroller's own AppKit layout pass — with
    /// no accompanying model mutation — left a fully hydrated transcript
    /// empty. Unlike `restoreLatchWaitsForPositiveWidth` above, this test
    /// deliberately does NOT call `coordinator.update(host:)` again after
    /// the layout pass: the scroller's own layout must drive reconciliation
    /// on its own.
    @Test("a real width arriving only through the scroller's own layout pass reconciles, with no further update(host:) call")
    func layoutAloneReconcilesAfterZeroWidthBootstrap() {
        let host = makeHost() // default session: followsTranscriptTail == true
        let messages = (0..<40).map { _ in
            ACPMessage.systemNotice(id: UUID(), text: String(repeating: "line ", count: 20))
        }
        host.transcript.messages = messages
        host.transcript.visibleHead = 0
        host.transcript.visibleTail = nil

        // Mirrors `makeNSView`'s `ACPTranscriptScrollerView(frame: .zero)`.
        let scroller = ACPTranscriptScrollerView(frame: .zero)
        let coordinator = ACPTranscriptScroller.Coordinator()
        coordinator.attach(scroller: scroller, host: host)

        // Width-0 bootstrap pass: `reconciler.apply` deferred. Nothing
        // measured or mounted yet.
        #expect(scroller.flippedDocumentView.frame.height == 0)
        #expect(scroller.flippedDocumentView.subviews.isEmpty)

        // The view receives its real size purely through AppKit's own
        // layout pass — exactly what happens once SwiftUI actually places
        // the representable — with NO further `update(host:)` call.
        scroller.frame = NSRect(x: 0, y: 0, width: 600, height: 400)
        scroller.layoutSubtreeIfNeeded()

        // The reconciler must have run against the real width on its own:
        // the document is measured and rows are mounted.
        #expect(scroller.flippedDocumentView.frame.height > 0)
        #expect(!scroller.flippedDocumentView.subviews.isEmpty)
    }

    /// A layout pass at an UNCHANGED width must not re-run the reconciler —
    /// only a genuine width change (or the deferred zero-width case above)
    /// should. Verified indirectly: the document is only ever set to a
    /// positive height once, from the single genuine width change: a
    /// second no-op layout pass at the same width must not perturb it.
    @Test("a layout pass at an unchanged width does not re-run the reconciler")
    func layoutAtUnchangedWidthDoesNotReapply() {
        let host = makeHost()
        let messages = (0..<10).map { _ in ACPMessage.systemNotice(id: UUID(), text: "hello") }
        host.transcript.messages = messages
        host.transcript.visibleHead = 0
        host.transcript.visibleTail = nil

        let scroller = ACPTranscriptScrollerView(frame: .zero)
        let coordinator = ACPTranscriptScroller.Coordinator()
        coordinator.attach(scroller: scroller, host: host)

        scroller.frame = NSRect(x: 0, y: 0, width: 600, height: 400)
        scroller.layoutSubtreeIfNeeded()
        let heightAfterFirstLayout = scroller.flippedDocumentView.frame.height
        #expect(heightAfterFirstLayout > 0)

        // Scroll away from the bottom so a spurious re-apply (which
        // re-pins to the bottom while `followsTranscriptTail` is true)
        // would be observable.
        scroller.setScrollY(0)
        #expect(scroller.scrollY == 0)

        // A second layout pass at the SAME width/frame must be a no-op:
        // the document height is unchanged and the viewport was not
        // re-pinned to the bottom.
        scroller.layoutSubtreeIfNeeded()
        #expect(scroller.flippedDocumentView.frame.height == heightAfterFirstLayout)
        #expect(scroller.scrollY == 0)
    }
}

/// Regression coverage for the P2 finding (codex round 6, Finding 1):
/// `ACPTranscriptScrollerView.layout()` used to notify the Coordinator only
/// when `contentView.bounds.width` changed, so a HEIGHT-only resize (window
/// dragged taller/shorter, width unchanged) never re-ran anything — not
/// `onContentWidthChange` (width didn't change) and not `onScroll`
/// (`reportScroll` only fires when the clip view's y-origin moves, which a
/// pure height change does not do). The mount band
/// (`ACPTranscriptScrollerReconciler.performLayoutPass`) is derived from
/// `scroller.viewportHeight`, so nothing recomputed it: growing the window
/// revealed space no newly-mounted row filled.
@MainActor
@Suite("ACPTranscriptScroller viewport height reconciliation")
struct ACPTranscriptScrollerViewportHeightReconciliationTests {
    /// Enough real message rows, positioned deep enough into the document,
    /// that the mount band (viewport ± 1200pt overscan) neither covers the
    /// whole document nor runs out of rows below the viewport when the
    /// height grows — so a change in mounted count is a genuine signal, not
    /// an artifact of hitting either end.
    private func tallHost() -> (host: ACPTranscriptScroller, scroller: ACPTranscriptScrollerView) {
        let session = ACPSession(id: "s", agentId: "claude", worktreeId: "w", title: "t")
        session.followsTranscriptTail = false
        let host = makeHost(session: session)
        host.transcript.messages = (0..<300).map { _ in
            ACPMessage.systemNotice(id: UUID(), text: String(repeating: "line ", count: 20))
        }
        host.transcript.visibleHead = 0
        host.transcript.visibleTail = nil

        let scroller = ACPTranscriptScrollerView(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
        return (host, scroller)
    }

    @Test("a height-only resize mounts more rows for a taller viewport, and fewer for a shorter one, with no accompanying model update")
    func heightOnlyResizeUpdatesMountedRowCount() {
        let (host, scroller) = tallHost()
        let coordinator = ACPTranscriptScroller.Coordinator()
        coordinator.attach(scroller: scroller, host: host)
        scroller.layoutSubtreeIfNeeded()

        // Scrolled to the middle of a document tall enough that growing or
        // shrinking the viewport extends/shrinks the mount band without
        // hitting either edge of the document.
        let midY = max(0, (scroller.contentHeight - scroller.viewportHeight) / 2)
        scroller.setScrollY(midY)
        #expect(scroller.contentHeight > 10_000, "test fixture is not tall enough")

        let mountedAtSmallHeight = scroller.flippedDocumentView.subviews.count
        #expect(mountedAtSmallHeight > 0)

        // Height-only resize: width is unchanged. Deliberately does NOT call
        // `coordinator.update(host:)` — the scroller's own layout pass must
        // drive this on its own, exactly like the existing width case.
        scroller.frame = NSRect(x: 0, y: 0, width: 600, height: 1600)
        scroller.layoutSubtreeIfNeeded()
        let mountedAtLargeHeight = scroller.flippedDocumentView.subviews.count
        #expect(mountedAtLargeHeight > mountedAtSmallHeight)

        // Shrinking back down releases rows again.
        scroller.frame = NSRect(x: 0, y: 0, width: 600, height: 400)
        scroller.layoutSubtreeIfNeeded()
        let mountedAfterShrink = scroller.flippedDocumentView.subviews.count
        #expect(mountedAfterShrink < mountedAtLargeHeight)
    }

    @Test("a height-only resize does not change any row's measured height or the document height")
    func heightOnlyResizeDoesNotRemeasure() {
        let (host, scroller) = tallHost()
        let coordinator = ACPTranscriptScroller.Coordinator()
        coordinator.attach(scroller: scroller, host: host)
        scroller.layoutSubtreeIfNeeded()
        scroller.setScrollY(max(0, (scroller.contentHeight - scroller.viewportHeight) / 2))

        let documentHeightBefore = scroller.contentHeight
        let widthBefore = scroller.contentView.bounds.width

        scroller.frame = NSRect(x: 0, y: 0, width: 600, height: 1600)
        scroller.layoutSubtreeIfNeeded()

        // No row reflows on a height-only change: the document's total
        // height (the sum of every row's height) and the pinned content
        // width are exactly unchanged — a full re-measure at an unchanged
        // width would coincidentally reproduce the same numbers, but a
        // remeasure is never even attempted; see the reconciler-level
        // build-count proof in `ACPTranscriptScrollerReconcilerApplyTests`.
        #expect(scroller.contentHeight == documentHeightBefore)
        #expect(scroller.contentView.bounds.width == widthBefore)
    }

    @Test("a height-only resize keeps a tail-following transcript pinned to the bottom")
    func heightOnlyResizeRepinsWhileFollowingTail() {
        // A height-only resize never changes `contentHeight`, but it does
        // move the maximum legal offset: a shorter viewport pushes the
        // bottom further down, leaving the unchanged `scrollY` legal yet no
        // longer at the end. Re-tiling alone would let the newest content
        // drift below the viewport while tail-follow still reports true.
        let session = ACPSession(id: "s", agentId: "claude", worktreeId: "w", title: "t")
        session.followsTranscriptTail = true
        let host = makeHost(session: session)
        host.transcript.messages = (0..<300).map { _ in
            ACPMessage.systemNotice(id: UUID(), text: String(repeating: "line ", count: 20))
        }
        host.transcript.visibleHead = 0
        host.transcript.visibleTail = nil

        let scroller = ACPTranscriptScrollerView(frame: NSRect(x: 0, y: 0, width: 600, height: 1200))
        let coordinator = ACPTranscriptScroller.Coordinator()
        coordinator.attach(scroller: scroller, host: host)
        scroller.layoutSubtreeIfNeeded()
        #expect(scroller.distanceFromBottom < 1, "fixture should start pinned to the tail")

        // Shrink the viewport only. Width is untouched, so this drives the
        // height path rather than the width-settle reset.
        scroller.frame = NSRect(x: 0, y: 0, width: 600, height: 400)
        scroller.layoutSubtreeIfNeeded()

        #expect(scroller.distanceFromBottom < 1)
    }

    @Test("a height-only resize does not drag a browsing user back to the bottom")
    func heightOnlyResizeDoesNotRepinWhileBrowsing() {
        // The mirror of the above: re-pinning must be conditional on
        // tail-follow, not on the resize itself.
        let (host, scroller) = tallHost()   // followsTranscriptTail == false
        let coordinator = ACPTranscriptScroller.Coordinator()
        coordinator.attach(scroller: scroller, host: host)
        scroller.layoutSubtreeIfNeeded()
        scroller.setScrollY(max(0, (scroller.contentHeight - scroller.viewportHeight) / 2))
        let scrollYBefore = scroller.scrollY

        scroller.frame = NSRect(x: 0, y: 0, width: 600, height: 300)
        scroller.layoutSubtreeIfNeeded()

        #expect(abs(scroller.scrollY - scrollYBefore) < 0.5)
    }
}

@MainActor
@Suite("ACPTranscriptScroller logical navigation")
struct ACPTranscriptScrollerLogicalNavigationTests {
    private func messages(_ count: Int) -> [ACPMessage] {
        (0..<count).map { index in
            .systemNotice(id: UUID(), text: "message \(index)")
        }
    }

    private func attach(
        session: ACPSession,
        size: NSSize = NSSize(width: 600, height: 400)
    ) throws -> (ACPTranscriptScroller.Coordinator, ACPTranscriptScrollerView, NSScroller) {
        let host = makeHost(session: session)
        let scroller = ACPTranscriptScrollerView(frame: NSRect(origin: .zero, size: size))
        let coordinator = ACPTranscriptScroller.Coordinator()
        coordinator.attach(scroller: scroller, host: host)
        scroller.layoutSubtreeIfNeeded()
        return (coordinator, scroller, try #require(scroller.verticalScroller))
    }

    private func commit(_ value: Double, through scroller: NSScroller) {
        scroller.doubleValue = value
        _ = scroller.sendAction(scroller.action, to: scroller.target)
    }

    @Test("a released historical position swaps a bounded window and aligns its target")
    func loadedHistoricalJump() throws {
        let session = ACPSession(id: "s", agentId: "claude", worktreeId: "w", title: "t")
        let allMessages = messages(200)
        session.replaceTranscriptMessages(allMessages)
        session.transcript.resetWindowToTail()
        session.followsTranscriptTail = true
        let (coordinator, _, nativeScroller) = try attach(session: session)

        commit(0.5, through: nativeScroller)

        // 400pt / 96pt leaves a maximum logical top of 195.833; halfway
        // rounds to global/local message 98. One 30-row page is preloaded.
        #expect(!session.followsTranscriptTail)
        #expect(session.transcript.visibleHead == 68)
        #expect(session.transcript.visibleTail == 158)
        #expect(coordinator.pendingLogicalTargetGlobalIndexForTesting == nil)
        #expect(coordinator.topVisibleMessageIdForTesting == allMessages[98].stableId)
    }

    @Test("a release into the unmaterialized prefix waits for backfill")
    func queuedHydrationJump() async throws {
        let session = ACPSession(id: "s", agentId: "claude", worktreeId: "w", title: "t")
        let allMessages = messages(200)
        session.replaceTranscriptMessages(Array(allMessages.suffix(30)), messageIndexOffset: 170)
        session.transcript.visibleHead = 0
        session.transcript.visibleTail = nil
        session.followsTranscriptTail = true
        let (coordinator, _, nativeScroller) = try attach(session: session)

        commit(0.25, through: nativeScroller)

        #expect(!session.followsTranscriptTail)
        #expect(coordinator.pendingLogicalTargetGlobalIndexForTesting == 49)

        session.prependTranscriptMessages(Array(allMessages.prefix(170)))
        coordinator.update(host: makeHost(session: session))

        // `update(host:)` is the NSViewRepresentable update boundary in
        // production. Resolving must defer its published window mutation
        // until that synchronous update has returned.
        #expect(coordinator.pendingLogicalTargetGlobalIndexForTesting == 49)
        await Task.yield()

        #expect(coordinator.pendingLogicalTargetGlobalIndexForTesting == nil)
        #expect(session.transcript.visibleHead == 19)
        #expect(session.transcript.visibleTail == 109)
        #expect(coordinator.topVisibleMessageIdForTesting == allMessages[49].stableId)
    }

    @Test("a later user scroll cancels a queued hydration jump")
    func userScrollCancelsQueuedHydrationJump() async throws {
        let session = ACPSession(id: "s", agentId: "claude", worktreeId: "w", title: "t")
        let allMessages = messages(200)
        session.replaceTranscriptMessages(Array(allMessages.suffix(30)), messageIndexOffset: 170)
        session.transcript.visibleHead = 0
        session.transcript.visibleTail = nil
        session.followsTranscriptTail = true
        let (coordinator, scroller, nativeScroller) = try attach(session: session)

        commit(0.25, through: nativeScroller)
        #expect(coordinator.pendingLogicalTargetGlobalIndexForTesting == 49)

        // A wheel/trackpad scroll in the materialized tail is newer user
        // intent than the queued release into unhydrated history.
        scroller.contentView.setBoundsOrigin(NSPoint(x: 0, y: 0))
        scroller.reflectScrolledClipView(scroller.contentView)
        #expect(coordinator.pendingLogicalTargetGlobalIndexForTesting == nil)

        session.prependTranscriptMessages(Array(allMessages.prefix(170)))
        coordinator.update(host: makeHost(session: session))
        await Task.yield()

        // Backfill keeps the currently viewed tail window instead of
        // reviving the stale jump to message 49.
        #expect(session.transcript.visibleHead == 170)
        #expect(session.transcript.visibleTailBound == 200)
    }

    @Test("tail-only scrolling remembers a global anchor index")
    func tailOnlyScrollRemembersGlobalAnchorIndex() throws {
        let session = ACPSession(id: "s", agentId: "claude", worktreeId: "w", title: "t")
        let allMessages = messages(200)
        session.replaceTranscriptMessages(Array(allMessages.suffix(30)), messageIndexOffset: 170)
        session.transcript.visibleHead = 0
        session.transcript.visibleTail = nil
        session.followsTranscriptTail = false
        var remembered: (id: String?, index: Int?, followsTail: Bool)?
        let host = makeHost(session: session) { id, index, followsTail in
            remembered = (id, index, followsTail)
        }
        let scroller = ACPTranscriptScrollerView(
            frame: NSRect(x: 0, y: 0, width: 600, height: 400)
        )
        let coordinator = ACPTranscriptScroller.Coordinator()
        coordinator.attach(scroller: scroller, host: host)
        scroller.layoutSubtreeIfNeeded()

        scroller.contentView.setBoundsOrigin(NSPoint(x: 0, y: 0))
        scroller.reflectScrolledClipView(scroller.contentView)

        let anchor = try #require(remembered)
        let anchorId = try #require(anchor.id)
        let anchorIndex = try #require(anchor.index)
        let localIndex = try #require(
            session.transcript.messages.firstIndex { $0.stableId == anchorId }
        )
        #expect(anchorIndex == 170 + localIndex)
        #expect(!anchor.followsTail)
    }

    @Test("releasing at the logical end resumes the live tail")
    func tailJump() throws {
        let session = ACPSession(id: "s", agentId: "claude", worktreeId: "w", title: "t")
        session.replaceTranscriptMessages(messages(200))
        session.transcript.setVisibleWindow(containing: 40)
        session.followsTranscriptTail = false
        let (coordinator, scroller, nativeScroller) = try attach(session: session)

        commit(1, through: nativeScroller)

        _ = coordinator // Retain the weak callback owner through the action.
        #expect(session.followsTranscriptTail)
        #expect(session.transcript.visibleHead == 170)
        #expect(session.transcript.visibleTail == nil)
        #expect(scroller.distanceFromBottom < 1)
    }

    @Test("AppKit head pagination discards the opposite page")
    func headPaginationStaysBounded() throws {
        let session = ACPSession(id: "s", agentId: "claude", worktreeId: "w", title: "t")
        session.replaceTranscriptMessages(messages(200))
        session.transcript.setVisibleWindow(containing: 70)
        session.followsTranscriptTail = false
        let (coordinator, scroller, _) = try attach(session: session)

        scroller.contentView.setBoundsOrigin(NSPoint(x: 0, y: 0))
        scroller.reflectScrolledClipView(scroller.contentView)

        _ = coordinator // Retain the weak callback owner through the scroll.
        #expect(session.transcript.visibleHead == 40)
        #expect(session.transcript.visibleTail == 130)
        #expect(session.transcript.visibleTailBound - session.transcript.visibleHead == ACPTranscript.maxVisibleRows)
    }
}

@Suite("ACPTranscriptScroller policies")
struct ACPTranscriptScrollerPolicyTests {
    @Test("head step fires near the top when older rows exist")
    func headStep() {
        #expect(ACPTranscriptScroller.shouldStepHeadBack(
            visibleHead: 30, scrollY: 800, threshold: 1500))
        #expect(!ACPTranscriptScroller.shouldStepHeadBack(
            visibleHead: 0, scrollY: 800, threshold: 1500))
        #expect(!ACPTranscriptScroller.shouldStepHeadBack(
            visibleHead: 30, scrollY: 2000, threshold: 1500))
    }

    /// Pagination is geometric, not event-gated. `NSApp.currentEvent` is only
    /// the scroll event while the bounds change happens inside event
    /// dispatch, and under `NSScrollView`'s responsive scrolling it usually
    /// does not: 97% of scroll ticks measured in the running app classified
    /// as not user-driven, which left the user parked at the top of the
    /// render window waiting seconds for a tick to coincide with a
    /// recognizable event before older messages loaded at all.
    @Test("head step does not wait for a recognizable user event")
    func headStepIsNotEventGated() {
        // The exact state a trackpad fling leaves behind: at the top of the
        // window, older rows available, and no fresh event to be found.
        #expect(ACPTranscriptScroller.shouldStepHeadBack(
            visibleHead: 30, scrollY: 0, threshold: 1500))
        #expect(!ACPUserScrollEvent.isUserDriven(nil))
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
            visibleHead: 30, scrollY: 800, threshold: 1500,
            hasPendingHeadStep: true))
        #expect(ACPTranscriptScroller.shouldStepHeadBack(
            visibleHead: 30, scrollY: 800, threshold: 1500,
            hasPendingHeadStep: false))
    }

    @Test("tail step fires near the bottom when newer rows are hidden and the user is scrolling down")
    func tailStep() {
        #expect(ACPTranscriptScroller.shouldStepTailForward(
            visibleTail: 100, messageCount: 200, distanceFromBottom: 900,
            threshold: 1500,
            previousScrollY: 1000, newScrollY: 1050))
        #expect(!ACPTranscriptScroller.shouldStepTailForward(
            visibleTail: 200, messageCount: 200, distanceFromBottom: 900,
            threshold: 1500,
            previousScrollY: 1000, newScrollY: 1050))
        #expect(!ACPTranscriptScroller.shouldStepTailForward(
            visibleTail: 100, messageCount: 200, distanceFromBottom: 5000,
            threshold: 1500,
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
            threshold: 1500,
            previousScrollY: 1050, newScrollY: 1000))
    }

    @Test("tail step withholds when direction is unknown (no previous offset yet)")
    func tailStepWithholdsWithoutPreviousOffset() {
        #expect(!ACPTranscriptScroller.shouldStepTailForward(
            visibleTail: 100, messageCount: 200, distanceFromBottom: 900,
            threshold: 1500,
            previousScrollY: nil, newScrollY: 1050))
    }

    @Test("tail step ignores sub-epsilon jitter as downward movement")
    func tailStepWithholdsOnJitter() {
        // A change smaller than `ACPScrollDirectionClassifier.upwardEpsilon`
        // (0.5pt) must not be treated as a deliberate downward scroll.
        #expect(!ACPTranscriptScroller.shouldStepTailForward(
            visibleTail: 100, messageCount: 200, distanceFromBottom: 900,
            threshold: 1500,
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
/// `ACPUserScrollEvent.isUserDriven` alone rejects. `handleScroll` widens the
/// tail-follow pause/resume classification to
/// `ACPUserScrollEvent.isHeadPaginationDriven` — which additionally accepts a
/// `.leftMouseDown` when it is a genuine scrollbar-track hit AND the geometry
/// actually moved upward.
///
/// That classification governs the tail-follow PAUSE only. Pagination (head
/// and tail) no longer consults the event stream at all — see
/// `ACPTranscriptScroller.shouldStepHeadBack`'s doc comment on why the event
/// signal is unusable under responsive scrolling — so a track click paginates
/// for the same reason any other way of arriving near the window's edge
/// does: the geometry says so.
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

    /// However the viewport got near the top of the render window — a track
    /// click, a trackpad fling whose events were never seen, a restored
    /// anchor — older rows load. The event classification that decides
    /// whether to PAUSE tail-follow does not decide this.
    @Test("head pagination follows the geometry, whatever the click was")
    func headPaginationIsGeometricNotEventClassified() {
        for isScrollbarTrackHit in [true, false] {
            let isHeadPaginationDriven = ACPUserScrollEvent.isHeadPaginationDriven(
                .leftMouseDown, previousMinY: 2000, newMinY: 100,
                isScrollbarTrackHit: isScrollbarTrackHit
            )
            #expect(isHeadPaginationDriven == isScrollbarTrackHit)
            // Same answer either way: the viewport is near the top and older
            // rows exist.
            #expect(ACPTranscriptScroller.shouldStepHeadBack(
                visibleHead: 30, scrollY: 100, threshold: Self.threshold
            ))
        }
    }

    /// Tail pagination's intent signal is the direction the viewport moved,
    /// not the event that moved it: a click that jumps DOWN the document
    /// pages in newer messages, one that jumps up does not.
    @Test("tail pagination follows the direction of travel, not the event")
    func tailPaginationFollowsDirectionOfTravel() {
        #expect(ACPTranscriptScroller.shouldStepTailForward(
            visibleTail: 100, messageCount: 200, distanceFromBottom: 900,
            threshold: Self.threshold,
            previousScrollY: 2000, newScrollY: 2050
        ))
        #expect(!ACPTranscriptScroller.shouldStepTailForward(
            visibleTail: 100, messageCount: 200, distanceFromBottom: 900,
            threshold: Self.threshold,
            previousScrollY: 2050, newScrollY: 2000
        ))
    }
}
