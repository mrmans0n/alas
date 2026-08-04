import AppKit
import SwiftUI

struct ACPMessageList: View {
    @ObservedObject var session: ACPSession
    @ObservedObject var transcript: ACPTranscript
    let contentMaxWidth: CGFloat
    let typography: ACPChatTypography
    let onOpenDiff: (String) -> Void
    let onOpenTranscriptLink: (URL) -> Bool
    let policy: ACPPermissionPolicy?
    let trustedImageRoot: URL?
    let scopeKey: String
    let onUserInputResponse: (UUID, ACPUserInputAction) -> Void
    let onOpenElicitationURL: (UUID) async -> Bool
    let onDismissElicitationURLWait: (String) -> Void
    /// Callbacks invoked by the pending bubbles + header. The host wires
    /// these to the runner.
    let onQueueEdit: (QueuedPrompt) -> Void
    let onQueueForceSend: (UUID) -> Void
    let onQueueRemove: (UUID) -> Void
    let onQueueRetry: (UUID) -> Void
    let onQueueReorder: (Int, Int) -> Void
    let onQueueClearAll: () -> Void
    let onRetryContextRecovery: () -> Void
    let rememberedScrollAnchor: () -> String?
    let onRememberScrollAnchor: (String?, Int?, Bool) -> Void
    /// Resolves the full persisted content of a tool call by id when an
    /// expanded card's in-memory content was truncated. Wired by the host
    /// to `ACPSessionManager.reloadFullToolCallContent`. Returns nil when
    /// the row is gone or the payload is undecodable.
    let onLoadFullToolCallContent: (String) async -> String?
    let forkTargets: [ACPSessionForkTarget]
    let onFork: (ACPForkMessageBoundary, String) -> Void
    let onOpenForkSource: (String) -> Void
    let agentDisplayName: (String) -> String
    @Environment(\.theme) private var theme
    // Cached rather than read fresh from `ACPTranscriptScrollerFlag.isEnabled`
    // on every body evaluation (which happens per streamed chunk) so that a
    // flag flip is the ONLY thing that changes it. `.id(scrollerFlagState)`
    // below then forces SwiftUI to tear down and rebuild the whole transcript
    // subtree when it changes — switching between the AppKit scroller and the
    // legacy ScrollView mid-flight, sharing this view's scroll bookkeeping
    // `@State`, is not something either implementation is designed to
    // tolerate, so a full identity change (losing scroll position, as
    // documented in the settings row) is the deliberate, safe behavior.
    @State private var scrollerFlagState = ACPTranscriptScrollerFlag.isEnabled
    @State private var scrollViewRef = ACPWeakScrollViewRef()
    @State private var latestTopVisibleAnchor = ACPMutableScrollAnchor()
    @State private var scrollBook = ACPTranscriptScrollBookkeeping()
    // Geometry callbacks can run while AppKit is tracking a native menu. Keep
    // their per-row bookkeeping out of SwiftUI-observed value state: changing
    // a cached frame must not invalidate the entire lazy transcript list.
    @State private var modernRowFrameCache = ACPRowFrameCache()
    // Rebuilding the window-sliced row list + stable-id lookup is O(rows); it
    // used to happen from scratch inside every per-row geometry callback,
    // making a full layout pass O(rows²). Memoized per (messages generation,
    // window bounds) so a pass rebuilds it once instead of once per row.
    @State private var visibleRowsCache = ACPVisibleRowsCache()

    /// Height of an invisible spacer at the tail of the transcript stack. The
    /// composer pill plus its outer padding occupies roughly this much
    /// vertical space, so by scrolling THAT element to the viewport
    /// bottom we guarantee the streaming caret / last message sits
    /// above the composer instead of behind it.
    private let composerSpacerHeight: CGFloat = 220
    private let goToNewestButtonSize: CGFloat = 32
    private let goToNewestButtonComposerGap: CGFloat = 12
    /// Step the visible head back when the "Earlier messages…" marker
    /// crosses this many points from the top edge during scroll.
    private let headStepScrollThreshold: CGFloat = 200
    /// `visibleMessageLookup.firstStableId` is safe to persist only when the
    /// viewport is effectively at the start of the rendered window. Otherwise
    /// it may be older than the row the user actually stopped on.
    private let firstRenderedAnchorFallbackThreshold: CGFloat = 1
    /// Minimum gap between automatic head-back steps so a single scroll
    /// doesn't decrement multiple times before layout settles.
    private let headStepDebounceInterval: TimeInterval = 0.3
    /// A named coordinate space only needs to be unambiguous relative to its
    /// nearest `.coordinateSpace(.named(...))` ancestor, and each
    /// `ACPMessageList` instance declares its own locally, so a shared
    /// constant here is safe even with multiple transcript lists mounted at
    /// once (e.g. across windows).
    private static let scrollSpaceName = "acp-message-list"
    private static let contentShrinkBookmarkResetDebounceNanoseconds: UInt64 = 50_000_000

    /// Window-sliced, plan-filtered list of rows to render. The slice
    /// bounds first-paint cost on long transcripts (`visibleHead` is
    /// reset to `max(0, count - tailWindow)` after hydration); the
    /// filter drops `.plan` entries because the toolbar pill renders
    /// the current turn's plan instead of an inline card.
    private var visibleRows: [VisibleRow] {
        visibleRowsCache.rows(
            generation: transcript.messagesGeneration,
            head: transcript.visibleHead,
            tail: transcript.visibleTailBound,
            build: buildVisibleRows
        )
    }

    private func buildVisibleRows() -> [VisibleRow] {
        Self.visibleRows(
            messages: transcript.messages,
            visibleHead: transcript.visibleHead,
            visibleTail: transcript.visibleTailBound,
            stableId: { transcript.stableId(for: $0) }
        )
    }

    /// Cheap signature of the entire transcript. SwiftUI re-evaluates when
    /// any cell mutates (e.g. an agent_message_chunk merging into the
    /// trailing message) so the scroll-to-bottom hook fires for streaming
    /// edits in addition to brand-new rows.
    private var scrollSignature: Int {
        var hasher = Hasher()
        hasher.combine(transcript.messages.count)
        hasher.combine(session.queue.count)
        hasher.combine(session.queue.first?.status)
        hasher.combine(session.contextRecoveryStatus)
        hasher.combine(transcript.pendingUserInputs.first?.id)
        hasher.combine(transcript.urlElicitationWaits.map(\.id))
        // Streaming chunks mutate the buffer in place without re-publishing
        // the transcript array; the tick gives the body a reason to re-eval
        // so this signature changes and the tail-scroll fires per chunk.
        hasher.combine(transcript.streamingTick)
        if let last = transcript.messages.last {
            hasher.combine(last.kind)
            switch last {
            case .agent, .thought, .systemNotice, .user:
                hasher.combine(last.contentUTF8Length)
            case .toolCall(let tc):
                hasher.combine(tc.status)
                hasher.combine(last.contentUTF8Length)
            case .fileEdit(_, let e):
                hasher.combine(e.added)
                hasher.combine(e.removed)
            case .plan:
                break
            }
        }
        return hasher.finalize()
    }

    private var openTranscriptURLAction: OpenURLAction {
        OpenURLAction { url in
            onOpenTranscriptLink(url) ? .handled : .systemAction
        }
    }

    nonisolated static func usesAppKitScroller(flagEnabled: Bool) -> Bool {
        flagEnabled
    }

    var body: some View {
        Group {
            if Self.usesAppKitScroller(flagEnabled: scrollerFlagState) {
                appKitScrollerBody
            } else {
                legacyScrollViewBody
            }
        }
        .id(scrollerFlagState)
        .onReceive(
            NotificationCenter.default.publisher(for: ACPTranscriptScrollerFlag.overrideDidChangeNotification)
        ) { _ in
            let flagEnabled = ACPTranscriptScrollerFlag.isEnabled
            guard flagEnabled != scrollerFlagState else { return }
            // `.id(scrollerFlagState)` rebuilds the transcript subtree, but
            // this view's own `@State` sits OUTSIDE that subtree and
            // survives the identity change. Reset the scroll bookkeeping
            // and per-row caches explicitly so the incoming implementation
            // starts clean instead of inheriting the outgoing one's
            // restore state and cached geometry.
            scrollBook.reset()
            scrollViewRef = ACPWeakScrollViewRef()
            latestTopVisibleAnchor = ACPMutableScrollAnchor()
            modernRowFrameCache = ACPRowFrameCache()
            visibleRowsCache = ACPVisibleRowsCache()
            scrollerFlagState = flagEnabled
        }
        .background(
            LinearGradient(
                colors: [theme.color("bg-1"), theme.color("bg-0")],
                startPoint: .top, endPoint: .bottom
            )
        )
    }

    private var appKitScrollerBody: some View {
        ZStack(alignment: .bottomTrailing) {
            ACPTranscriptScroller(
                session: session,
                transcript: transcript,
                contentMaxWidth: contentMaxWidth,
                typography: typography,
                trustedImageRoot: trustedImageRoot,
                onOpenDiff: onOpenDiff,
                onLoadFullToolCallContent: onLoadFullToolCallContent,
                forkTargets: forkTargets,
                onFork: onFork,
                rememberedScrollAnchor: rememberedScrollAnchor,
                onRememberScrollAnchor: onRememberScrollAnchor,
                onOpenTranscriptLink: onOpenTranscriptLink,
                policy: policy,
                scopeKey: scopeKey,
                onUserInputResponse: onUserInputResponse,
                onOpenElicitationURL: onOpenElicitationURL,
                onDismissElicitationURLWait: onDismissElicitationURLWait,
                onQueueEdit: onQueueEdit,
                onQueueForceSend: onQueueForceSend,
                onQueueRemove: onQueueRemove,
                onQueueRetry: onQueueRetry,
                onQueueReorder: onQueueReorder,
                onQueueClearAll: onQueueClearAll,
                onRetryContextRecovery: onRetryContextRecovery,
                onOpenForkSource: onOpenForkSource,
                agentDisplayName: agentDisplayName
            )
            if Self.shouldShowGoToNewestAffordance(
                followsTranscriptTail: session.followsTranscriptTail
            ) {
                goToNewestButton {
                    session.followsTranscriptTail = true
                    transcript.resetWindowToTail()
                    onRememberScrollAnchor(nil, nil, true)
                }
            }
        }
    }

    private var legacyScrollViewBody: some View {
        ScrollViewReader { proxy in
            GeometryReader { viewport in
                ZStack(alignment: .bottomTrailing) {
                    ScrollView {
                        // Eager VStack, not LazyVStack: the render window is
                        // hard-capped at `ACPTranscript.maxVisibleRows` (see
                        // ACPTranscriptWindowTests) and heavy rows are
                        // `.equatable()`-gated (ACPTranscriptRowContent), so at
                        // most ~90 already-diffed rows are ever laid out. The
                        // cap holds in every state: while following the tail the
                        // window is the last `tailWindow` rows, and pausing the
                        // follow freezes `visibleTail` (setFollowsTranscriptTail
                        // → ACPTranscript.freezeVisibleTail) so a long turn's
                        // later appends can't grow the eager window. A LazyVStack
                        // mis-places rows on macOS 26 when the scroll-up reveal
                        // path grafts a chunk at the top of the ForEach while
                        // `scrollTo` re-anchors the viewport, drawing a band of
                        // messages overlapping. An eager VStack computes every
                        // child's real height and stacks them sequentially, so
                        // rows cannot overlap regardless of scroll/anchor timing.
                        VStack(alignment: .leading, spacing: 18) {
                            switch Self.topPaginationIndicator(
                                visibleHead: transcript.visibleHead,
                                isBackfillingOlderMessages: transcript.isBackfillingOlderMessages
                            ) {
                            case .hidden:
                                EmptyView()
                            case .sentinel:
                                topPaginationSentinel
                            case .spinner:
                                Spinner(lineWidth: 1.5)
                                    .frame(width: 14, height: 14)
                                    .frame(maxWidth: .infinity, alignment: .center)
                                    .padding(.bottom, 4)
                                    .background(topPaginationSentinel)
                            }
                            ForEach(visibleRows) { row in
                                visibleRow(row)
                                if let fork = session.forkRecord,
                                   fork.phase == .ready,
                                   row.index == fork.inheritedMessageCount - 1,
                                   let mechanism = fork.mechanism {
                                    ACPSessionForkDivider(
                                        presentation: .init(
                                            sourceAgentName: agentDisplayName(fork.sourceAgentID),
                                            mechanism: mechanism
                                        ),
                                        onOpenSource: { onOpenForkSource(fork.sourceSessionID) }
                                    )
                                    .id("__fork_divider__")
                                }
                            }
                            if Self.shouldShowBottomPaginationSentinel(
                                visibleTail: transcript.visibleTailBound,
                                messageCount: transcript.messages.count
                            ) {
                                bottomPaginationSentinel
                            }
                            if transcript.pendingPermission != nil, let policy = policy {
                                ACPPermissionPrompt(session: session, policy: policy, scopeKey: scopeKey)
                                    .id("__pending_perm__")
                            }
                            if let request = transcript.pendingUserInputs.first {
                                ACPUserInputPrompt(
                                    request: request,
                                    onRespond: onUserInputResponse,
                                    onOpenURL: onOpenElicitationURL
                                )
                                .id("__pending_user_input_\(request.id)")
                            }
                            ForEach(transcript.urlElicitationWaits) { wait in
                                ACPURLElicitationWaitView(
                                    wait: wait,
                                    onOpenAgain: { NSWorkspace.shared.open($0) },
                                    onDismiss: onDismissElicitationURLWait
                                )
                                .id("__elicitation_wait_\(wait.id)")
                            }
                            if transcript.streamingState == .streaming {
                                StreamingCaret().frame(width: 8, height: 14)
                                    .id("__streaming_caret__")
                            }
                            let queueHeaderCount = Self.queueHeaderCount(
                                statuses: session.queue.map(\.status)
                            )
                            if queueHeaderCount > 1 {
                                ACPQueueHeader(count: queueHeaderCount, onClear: onQueueClearAll)
                                    .id("__queue_header__")
                            }
                            ForEach(Array(session.queue.enumerated()), id: \.element.id) { idx, item in
                                if Self.shouldRenderQueueBubble(status: item.status) {
                                    ACPQueuedBubble(
                                        item: item,
                                        contentMaxWidth: contentMaxWidth,
                                        typography: typography,
                                        onForceSend: { onQueueForceSend(item.id) },
                                        onEdit: { onQueueEdit(item) },
                                        onRemove: { onQueueRemove(item.id) },
                                        onRetry: { onQueueRetry(item.id) }
                                    )
                                    .dropDestination(for: String.self) { items, _ in
                                        guard let s = items.first,
                                              let uuid = UUID(uuidString: s),
                                              let src = session.queue.firstIndex(where: { $0.id == uuid })
                                        else { return false }
                                        guard Self.canDropQueuedItem(
                                            sourceStatus: session.queue[src].status,
                                            targetStatus: item.status
                                        ) else { return false }
                                        onQueueReorder(src, idx)
                                        return true
                                    }
                                    .id("__queue_\(item.id)")
                                }
                            }
                            if let status = session.contextRecoveryStatus {
                                contextRecoveryRow(status)
                                    .id("__context_recovery__")
                            }
                            // Invisible tail spacer that the auto-scroll pins to
                            // the viewport bottom; this guarantees the streaming
                            // caret / last message sits above the composer pill.
                            Color.clear
                                .frame(height: composerSpacerHeight)
                                .id("__composer_spacer__")
                        }
                        .frame(maxWidth: contentMaxWidth, alignment: .leading)
                        .padding(.horizontal, 28 + ACPMessageGutterLayout.laneWidth)
                        .padding(.top, 24)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .environment(\.openURL, openTranscriptURLAction)
                    }
                    .coordinateSpace(.named(Self.scrollSpaceName))
                    .modifier(ACPTranscriptScrollTracking(
                        isRestoring: { scrollBook.isRestoringTail },
                        onResolveScrollView: { scrollViewRef.scrollView = $0 },
                        onHeadFrame: { handleHeadFramePreference($0, proxy: proxy) },
                        onPaused: { setFollowsTranscriptTail(false) },
                        onAtBottom: { shouldPageHiddenTail in
                            handleAtBottom(proxy: proxy, shouldPageHiddenTail: shouldPageHiddenTail)
                        },
                        onGeometry: { old, new in
                            handleScrollGeometry(
                                previousMinY: old.minY,
                                newMinY: new.minY,
                                viewportHeight: new.viewportHeight,
                                previousContentHeight: old.contentHeight,
                                contentHeight: new.contentHeight,
                                proxy: proxy)
                        }
                    ))
                    .onAppear {
                        restoreTailIfNeeded(proxy: proxy, animated: false)
                        restoreRememberedAnchorIfNeeded(proxy: proxy)
                    }
                    .onDisappear {
                        scrollBook.pendingTailScrollTask?.cancel()
                        scrollBook.pendingTailScrollTask = nil
                        scrollBook.pendingContentGrowthTailRestore = nil
                        scrollBook.pendingContentShrinkResetTask?.cancel()
                        scrollBook.pendingContentShrinkResetTask = nil
                        scrollBook.contentShrinkBookmarkResetState = .none
                    }
                    .onChange(of: viewport.size.height) { _, _ in
                        restoreTailIfNeeded(proxy: proxy, animated: false)
                        restoreRememberedAnchorIfNeeded(proxy: proxy)
                    }
                    .onChange(of: viewport.size.width) { oldWidth, newWidth in
                        if Self.shouldRestoreTailAfterViewportWidthChange(
                            previousWidth: oldWidth,
                            newWidth: newWidth,
                            followsTranscriptTail: session.followsTranscriptTail
                        ) {
                            restoreTailIfNeeded(proxy: proxy, animated: false)
                        }
                        restoreRememberedAnchorIfNeeded(proxy: proxy)
                    }
                    .onChange(of: scrollSignature) { _, _ in
                        if session.followsTranscriptTail {
                            transcript.resetWindowToTail()
                            scheduleTailScroll(
                                proxy: proxy,
                                animated: Self.shouldAnimateTailScroll(
                                    trigger: .contentSignature,
                                    streamingState: transcript.streamingState
                                )
                            )
                        }
                        restoreRememberedAnchorIfNeeded(proxy: proxy)
                    }
                    .onChange(of: transcript.streamingState) { _, new in
                        if session.followsTranscriptTail && (new == .streaming || new == .sending) {
                            scheduleTailScroll(
                                proxy: proxy,
                                animated: Self.shouldAnimateTailScroll(
                                    trigger: .streamingState,
                                    streamingState: new
                                )
                            )
                        }
                    }
                    .onChange(of: transcript.visibleHead) { _, _ in
                        restoreRememberedAnchorIfNeeded(proxy: proxy)
                    }
                    .modifier(ACPRowFramePreferenceTracking { frames in
                        handleRowFramePreference(frames, proxy: proxy)
                    })

                    if Self.shouldShowGoToNewestAffordance(
                        followsTranscriptTail: session.followsTranscriptTail
                    ) {
                        goToNewestButton {
                            goToNewestMessage(proxy: proxy)
                        }
                    }
                }
            }
        }
    }

    private func goToNewestButton(action: @escaping () -> Void) -> some View {
        Button {
            action()
        } label: {
            Image(systemName: "arrow.down")
                .font(.system(size: 14, weight: .semibold))
                .frame(width: goToNewestButtonSize, height: goToNewestButtonSize)
        }
        .buttonStyle(.plain)
        .foregroundStyle(theme.color("fg"))
        .background(
            Circle()
                .fill(theme.color("bg-1").opacity(0.95))
                .shadow(color: .black.opacity(0.18), radius: 10, y: 4)
        )
        .overlay(
            Circle()
                .strokeBorder(theme.color("line").opacity(0.9), lineWidth: 0.5)
        )
        .accessibilityLabel("Go to newest message")
        .help("Go to newest message")
        .padding(.trailing, 20)
        .padding(.bottom, Self.goToNewestAffordanceBottomPadding(
            composerSpacerHeight: composerSpacerHeight,
            gap: goToNewestButtonComposerGap
        ))
        .transition(.opacity.combined(with: .scale(scale: 0.94)))
    }

    private func restoreTailIfNeeded(proxy: ScrollViewProxy, animated: Bool) {
        guard session.followsTranscriptTail else { return }
        transcript.resetWindowToTail()
        scrollToTail(proxy: proxy, animated: animated)
    }

    private func goToNewestMessage(proxy: ScrollViewProxy) {
        let action = Self.goToNewestAffordanceAction()
        if action.resumesTailFollow {
            setFollowsTranscriptTail(true)
        }
        if action.schedulesTailScroll {
            scheduleTailScroll(proxy: proxy, animated: action.animatedTailScroll)
        }
    }

    private func restoreRememberedAnchorIfNeeded(proxy: ScrollViewProxy) {
        guard !scrollBook.isRestoringTail else { return }
        guard !session.followsTranscriptTail else {
            scrollBook.restoredRememberedAnchor = nil
            return
        }
        guard let anchor = rememberedScrollAnchor(), scrollBook.restoredRememberedAnchor != anchor else { return }
        guard visibleMessageLookup.contains(anchor) else { return }
        scrollBook.isRestoringTail = true
        proxy.scrollTo(anchor, anchor: .top)
        scrollBook.restoredRememberedAnchor = anchor
        DispatchQueue.main.async {
            scrollBook.isRestoringTail = false
        }
    }

    @discardableResult
    private func scrollToTail(proxy: ScrollViewProxy, animated: Bool) -> Bool {
        let pendingContentGrowthTailRestore = scrollBook.pendingContentGrowthTailRestore
        scrollBook.pendingTailScrollTask?.cancel()
        scrollBook.pendingTailScrollTask = nil
        let distance = scrollBook.lastScrollProbe.map {
            max(0, $0.contentHeight - $0.viewportHeight - $0.minY)
        }
        guard Self.shouldPerformTailScroll(distanceFromBottom: distance) else { return false }
        scrollBook.isRestoringTail = true
        let scroll = {
            proxy.scrollTo("__composer_spacer__", anchor: .bottom)
        }
        if animated {
            withAnimation(.easeOut(duration: 0.12)) {
                scroll()
            }
        } else {
            scroll()
        }
        let releaseRestoring = {
            scrollBook.isRestoringTail = false
        }
        if animated {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) {
                releaseRestoring()
            }
        } else {
            DispatchQueue.main.async {
                releaseRestoring()
            }
        }
        if let pendingContentGrowthTailRestore {
            scrollBook.lastContentGrowthTailRestoreSourceHeight = pendingContentGrowthTailRestore.sourceHeight
            scrollBook.lastContentGrowthTailRestoreHeight = pendingContentGrowthTailRestore.targetHeight
            scrollBook.contentShrinkBookmarkResetState = Self.contentShrinkBookmarkResetStateAfterScheduledTailScroll(
                didScroll: true,
                hasContentGrowthRestore: true,
                currentState: scrollBook.contentShrinkBookmarkResetState
            )
            scrollBook.pendingContentGrowthTailRestore = nil
        }
        return true
    }

    private func scheduleTailScroll(
        proxy: ScrollViewProxy,
        animated: Bool,
        contentGrowthRestore: ACPContentGrowthTailRestore? = nil
    ) {
        if Self.shouldStoreContentGrowthRestoreBeforeCoalescing(
            hasPendingTailScroll: scrollBook.pendingTailScrollTask != nil,
            hasContentGrowthRestore: contentGrowthRestore != nil
        ) {
            scrollBook.pendingContentGrowthTailRestore = Self.mergedContentGrowthTailRestore(
                existing: scrollBook.pendingContentGrowthTailRestore,
                new: contentGrowthRestore
            )
            scrollBook.pendingContentShrinkResetTask?.cancel()
            scrollBook.pendingContentShrinkResetTask = nil
        }
        guard Self.shouldScheduleTailScroll(hasPendingTailScroll: scrollBook.pendingTailScrollTask != nil) else {
            return
        }
        scrollBook.pendingTailScrollTask?.cancel()
        if contentGrowthRestore != nil {
            scrollBook.pendingContentShrinkResetTask?.cancel()
            scrollBook.pendingContentShrinkResetTask = nil
        }
        scrollBook.pendingContentGrowthTailRestore = Self.mergedContentGrowthTailRestore(
            existing: scrollBook.pendingContentGrowthTailRestore,
            new: contentGrowthRestore
        )
        scrollBook.pendingTailScrollGeneration &+= 1
        let scheduledGeneration = scrollBook.pendingTailScrollGeneration
        scrollBook.pendingTailScrollTask = Task { @MainActor in
            await Task.yield()
            guard !Task.isCancelled,
                  ACPMessageList.shouldRunScheduledTailScroll(
                    followsTranscriptTail: session.followsTranscriptTail
                  )
            else {
                if ACPMessageList.shouldClearScheduledTailScrollBookkeeping(
                    scheduledGeneration: scheduledGeneration,
                    currentGeneration: scrollBook.pendingTailScrollGeneration
                ) {
                    scrollBook.pendingTailScrollTask = nil
                    scrollBook.pendingContentGrowthTailRestore = nil
                }
                return
            }
            let pendingContentGrowthTailRestore = scrollBook.pendingContentGrowthTailRestore
            let didScroll = scrollToTail(proxy: proxy, animated: animated)
            if didScroll, let pendingContentGrowthTailRestore {
                scrollBook.lastContentGrowthTailRestoreSourceHeight = pendingContentGrowthTailRestore.sourceHeight
                scrollBook.lastContentGrowthTailRestoreHeight = pendingContentGrowthTailRestore.targetHeight
            }
            scrollBook.contentShrinkBookmarkResetState = ACPMessageList.contentShrinkBookmarkResetStateAfterScheduledTailScroll(
                didScroll: didScroll,
                hasContentGrowthRestore: pendingContentGrowthTailRestore != nil,
                currentState: scrollBook.contentShrinkBookmarkResetState
            )
            if ACPMessageList.shouldClearScheduledTailScrollBookkeeping(
                scheduledGeneration: scheduledGeneration,
                currentGeneration: scrollBook.pendingTailScrollGeneration
            ) {
                scrollBook.pendingTailScrollTask = nil
                scrollBook.pendingContentGrowthTailRestore = nil
            }
        }
    }

    @ViewBuilder
    private func contextRecoveryRow(_ status: ACPSession.ContextRecoveryStatus) -> some View {
        HStack(spacing: 8) {
            switch status {
            case .restoring, .sendingTranscript:
                Spinner(lineWidth: 1.5)
                    .frame(width: 12, height: 12)
            case .restored:
                Image(systemName: "checkmark.circle")
                    .foregroundStyle(theme.color("accent"))
            case .failed:
                Image(systemName: "exclamationmark.arrow.triangle.2.circlepath")
                    .foregroundStyle(theme.color("warn"))
            }

            Text(contextRecoveryText(status))
                .font(.system(size: 12))
                .foregroundStyle(theme.color("fg-muted"))

            if case .failed = status {
                Button("Retry") {
                    onRetryContextRecovery()
                }
                .buttonStyle(.borderless)
                .controlSize(.small)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(theme.color("bg-1").opacity(0.65))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(theme.color("line").opacity(0.8), lineWidth: 0.5)
        )
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func contextRecoveryText(_ status: ACPSession.ContextRecoveryStatus) -> String {
        switch status {
        case .restoring:
            return "Restoring model context..."
        case .sendingTranscript:
            return "Restoring model context from transcript..."
        case .restored:
            return "Transcript restored as model context."
        case .failed(let message):
            return message
        }
    }

    private func setFollowsTranscriptTail(
        _ follows: Bool,
        allowFirstRenderedAnchorFallback: Bool = true
    ) {
        if follows {
            guard !session.followsTranscriptTail else { return }
            session.followsTranscriptTail = true
            transcript.resetWindowToTail()
            onRememberScrollAnchor(nil, nil, true)
            scrollBook.latestRememberedScrollAnchorIndex = nil
            // `latestTopVisibleAnchor` is only maintained while NOT following
            // the tail (see `shouldTrackAnchorFromRowFrames`), so a value left
            // over from a previous pause must not survive a resume: without
            // this reset, the NEXT pause would reuse that stale anchor instead
            // of falling through to a fresh computation from
            // `modernRowFrameCache.frames`.
            latestTopVisibleAnchor.value = Self.trackedAnchorAfterFollowsChange(
                follows: true,
                previousTrackedAnchor: latestTopVisibleAnchor.value
            )
        } else {
            session.followsTranscriptTail = false
            // Freeze the render window's tail the moment we stop following it.
            // While following, `visibleTail` is nil so the window tracks the
            // growing end; once paused, later appends must not grow the eager
            // window past its bound (see `ACPTranscript.freezeVisibleTail`).
            transcript.freezeVisibleTail()
            scrollBook.pendingTailScrollTask?.cancel()
            scrollBook.pendingTailScrollTask = nil
            scrollBook.pendingContentGrowthTailRestore = nil
            scrollBook.pendingContentShrinkResetTask?.cancel()
            scrollBook.pendingContentShrinkResetTask = nil
            scrollBook.contentShrinkBookmarkResetState = .none
            scrollBook.lastContentGrowthTailRestoreSourceHeight = nil
            scrollBook.lastContentGrowthTailRestoreHeight = nil
            let lookup = visibleMessageLookup
            // Tail-follow no longer maintains `latestTopVisibleAnchor` on every
            // row callback (see `handleModernRowFrame`), so compute it here,
            // lazily, only now that we actually need a pause anchor.
            let pauseAnchor = latestTopVisibleAnchor.value
                ?? Self.topVisibleAnchorID(in: modernRowFrameCache.frames)
            let anchor = Self.rememberedAnchorWhenPausingTailFollow(
                latestTopVisibleAnchor: pauseAnchor,
                lookup: lookup,
                allowFirstRenderedAnchorFallback: allowFirstRenderedAnchorFallback
            )
            let anchorIndex = lookup.transcriptIndex(for: anchor)
            onRememberScrollAnchor(
                anchor,
                anchorIndex,
                false
            )
            scrollBook.latestRememberedScrollAnchorIndex = anchorIndex
            scrollBook.restoredRememberedAnchor = anchor
        }
    }

    private func handleRowFramePreference(_ frames: [String: CGRect], proxy: ScrollViewProxy) {
        restoreRememberedAnchorIfNeeded(proxy: proxy)
        guard let anchor = Self.topVisibleAnchorID(in: frames) else { return }
        // Unlike the modern per-row `onGeometryChange` callback (fired once per
        // ROW), this legacy path receives the full frame dictionary once per
        // PreferenceKey change — effectively once per layout pass already — so
        // keeping `latestTopVisibleAnchor` current here isn't the O(rows) cost
        // the early-out below guards against on the modern path. This is also
        // the ONLY place that populates `latestTopVisibleAnchor` on the legacy
        // path (there is no unconditional frame cache to fall back to here,
        // unlike `modernRowFrameCache` on the modern path) — gating this write
        // left `setFollowsTranscriptTail`'s pause-anchor fallback with nothing
        // correct to use on macOS 14, so it must stay live even while
        // following the tail.
        let anchorChanged = latestTopVisibleAnchor.value != anchor
        if anchorChanged {
            latestTopVisibleAnchor.value = anchor
        }
        // Same early-out as `handleModernRowFrame`: while following the tail,
        // restoring, or backfilling older messages, the remainder of this
        // method (the remembered-anchor persistence bookkeeping) is discarded
        // work.
        guard Self.shouldTrackAnchorFromRowFrames(
            followsTranscriptTail: session.followsTranscriptTail,
            isRestoringTail: scrollBook.isRestoringTail,
            isBackfillingOlderMessages: transcript.isBackfillingOlderMessages
        ) else { return }
        let lookup = visibleMessageLookup
        let rememberedAnchor = rememberedScrollAnchor()
        let anchorIndex = lookup.transcriptIndex(for: anchor)
        let anchorIndexChanged = rememberedAnchor == anchor && scrollBook.latestRememberedScrollAnchorIndex != anchorIndex
        guard anchorChanged || rememberedAnchor != anchor || anchorIndexChanged else { return }
        if !Self.shouldRememberVisibleAnchor(
            anchor,
            rememberedAnchor: rememberedAnchor,
            restoredRememberedAnchor: scrollBook.restoredRememberedAnchor,
            visibleMessageIds: lookup.ids,
            isBackfillingOlderMessages: transcript.isBackfillingOlderMessages
        ) {
            return
        }
        onRememberScrollAnchor(anchor, anchorIndex, false)
        scrollBook.latestRememberedScrollAnchorIndex = anchorIndex
        scrollBook.restoredRememberedAnchor = anchor
    }

    private func handleModernRowFrame(id: String, frame: CGRect) {
        let lookup = visibleMessageLookup
        // `windowKey` gates `ACPRowFrameCache`'s stale-entry scan to only run
        // when the render window has actually moved since the last cleanup
        // (see `ACPRowFrameCache.update`), so this call is O(1) per row on
        // every callback except the first one after the window shifts.
        modernRowFrameCache.update(
            id: id,
            frame: frame,
            lookup: lookup,
            windowKey: ACPRowFrameCache.WindowKey(
                generation: transcript.messagesGeneration,
                head: transcript.visibleHead,
                tail: transcript.visibleTailBound
            )
        )
        // While following the tail (streaming), restoring, or backfilling
        // older messages, the anchor bookkeeping below is discarded by the
        // guards further down anyway — skip it entirely so every streamed
        // row's geometry callback stays O(1) instead of paying an O(rows)
        // lookup + min-scan that's thrown away.
        guard Self.shouldTrackAnchorFromRowFrames(
            followsTranscriptTail: session.followsTranscriptTail,
            isRestoringTail: scrollBook.isRestoringTail,
            isBackfillingOlderMessages: transcript.isBackfillingOlderMessages
        ) else { return }
        guard let anchor = Self.topVisibleAnchorID(in: modernRowFrameCache.frames) else { return }
        let anchorChanged = latestTopVisibleAnchor.value != anchor
        if anchorChanged {
            latestTopVisibleAnchor.value = anchor
        }
        let rememberedAnchor = rememberedScrollAnchor()
        let anchorIndex = lookup.transcriptIndex(for: anchor)
        let anchorIndexChanged = rememberedAnchor == anchor && scrollBook.latestRememberedScrollAnchorIndex != anchorIndex
        guard anchorChanged || rememberedAnchor != anchor || anchorIndexChanged else { return }
        onRememberScrollAnchor(anchor, anchorIndex, false)
        scrollBook.latestRememberedScrollAnchorIndex = anchorIndex
        scrollBook.restoredRememberedAnchor = anchor
    }

    private func pauseTailFollowFromGeometry(newMinY: CGFloat) {
        let shouldUseWindowStartFallback = Self.shouldUseFirstRenderedAnchorFallback(
            newMinY: newMinY,
            threshold: firstRenderedAnchorFallbackThreshold
        )
        setFollowsTranscriptTail(
            false,
            allowFirstRenderedAnchorFallback: shouldUseWindowStartFallback
        )
    }

    private func stepTailForwardPreservingScroll(
        proxy: ScrollViewProxy,
        lookup: VisibleMessageLookup
    ) {
        guard !scrollBook.isRestoringTail else { return }
        guard transcript.visibleTailBound < transcript.messages.count else { return }
        let now = Date()
        guard now.timeIntervalSince(scrollBook.lastTailStepAt) > headStepDebounceInterval else { return }
        scrollBook.lastTailStepAt = now
        let anchorId = Self.anchorForTailForwardPreservation(
            latestTopVisibleAnchor: latestTopVisibleAnchor.value,
            lookup: lookup
        )
        let anchorIndex = lookup.transcriptIndex(for: anchorId)
        scrollBook.isRestoringTail = true
        transcript.stepTailForward(preserving: anchorIndex)
        // `visibleTailBound` has already advanced (stepTailForward guarantees
        // newTail > currentTail), so the cache key differs from the
        // pre-mutation lookup above and this recomputes rather than reusing
        // the stale entry.
        let updatedLookup = visibleMessageLookup
        let scrollTargetId = updatedLookup.contains(anchorId) ? anchorId : updatedLookup.firstStableId
        DispatchQueue.main.async {
            if let scrollTargetId {
                proxy.scrollTo(scrollTargetId, anchor: .top)
            }
            DispatchQueue.main.async {
                scrollBook.isRestoringTail = false
            }
        }
    }

    private func handleAtBottom(
        proxy: ScrollViewProxy,
        shouldPageHiddenTail: Bool
    ) {
        if Self.shouldResumeTailFollowAtBottom(
            visibleTail: transcript.visibleTailBound,
            messageCount: transcript.messages.count
        ) {
            setFollowsTranscriptTail(true)
        } else if shouldPageHiddenTail {
            stepTailForwardPreservingScroll(
                proxy: proxy,
                lookup: visibleMessageLookup
            )
        }
    }

    @ViewBuilder
    private func rowFrameReporter(id: String) -> some View {
        if #available(macOS 15, *) {
            if Self.shouldUseLegacyRowFramePreferences(isModernScrollTrackingAvailable: true) {
                legacyRowFrameReporter(id: id)
            } else {
                modernRowFrameReporter(id: id)
            }
        } else if Self.shouldUseLegacyRowFramePreferences(isModernScrollTrackingAvailable: false) {
            legacyRowFrameReporter(id: id)
        } else {
            EmptyView()
        }
    }

    private func legacyRowFrameReporter(id: String) -> some View {
        GeometryReader { rowGeometry in
            Color.clear.preference(
                key: ACPRowFramesPreferenceKey.self,
                value: [id: rowGeometry.frame(in: .named(Self.scrollSpaceName))]
            )
        }
    }

    @available(macOS 15, *)
    private func modernRowFrameReporter(id: String) -> some View {
        Color.clear.onGeometryChange(for: CGRect.self) { rowGeometry in
            rowGeometry.frame(in: .named(Self.scrollSpaceName))
        } action: { frame in
            handleModernRowFrame(id: id, frame: frame)
        }
    }

    private var visibleMessageLookup: VisibleMessageLookup {
        visibleRowsCache.lookup(
            generation: transcript.messagesGeneration,
            head: transcript.visibleHead,
            tail: transcript.visibleTailBound,
            build: buildVisibleRows
        )
    }

    private var topPaginationSentinel: some View {
        GeometryReader { headGeom in
            Color.clear.preference(
                key: ACPHeadFramePreferenceKey.self,
                value: headGeom.frame(in: .named(Self.scrollSpaceName))
            )
        }
        .frame(height: 1)
    }

    private var bottomPaginationSentinel: some View {
        Color.clear
            .frame(height: 1)
            .id(Self.bottomPaginationSentinelID)
    }

    private static let bottomPaginationSentinelID = "__transcript_later__"

    nonisolated static func topPaginationIndicator(
        visibleHead: Int,
        isBackfillingOlderMessages: Bool
    ) -> ACPTopPaginationIndicator {
        if isBackfillingOlderMessages { return .spinner }
        if visibleHead > 0 { return .sentinel }
        return .hidden
    }

    nonisolated static func shouldRenderQueueBubble(status: QueuedPrompt.Status) -> Bool {
        switch status {
        case .pending:
            return true
        case .sending:
            return false
        }
    }

    nonisolated static func shouldShowBottomPaginationSentinel(
        visibleTail: Int,
        messageCount: Int
    ) -> Bool {
        visibleTail < messageCount
    }

    nonisolated static func shouldResumeTailFollowAtBottom(
        visibleTail: Int,
        messageCount: Int
    ) -> Bool {
        visibleTail >= messageCount
    }

    nonisolated static func shouldStepTailForwardFromBottomGeometry(
        isUserDriven: Bool,
        isRestoring: Bool,
        previousMinY: CGFloat,
        newMinY: CGFloat,
        visibleTail: Int,
        messageCount: Int
    ) -> Bool {
        guard visibleTail < messageCount else { return false }
        guard isUserDriven else { return false }
        guard !isRestoring else { return false }
        return newMinY > previousMinY + ACPScrollDirectionClassifier.upwardEpsilon
    }

    nonisolated static func queueHeaderCount(statuses: [QueuedPrompt.Status]) -> Int {
        statuses.reduce(0) { count, status in
            count + (shouldRenderQueueBubble(status: status) ? 1 : 0)
        }
    }

    nonisolated static func canDropQueuedItem(
        sourceStatus: QueuedPrompt.Status?,
        targetStatus: QueuedPrompt.Status
    ) -> Bool {
        sourceStatus == .pending && targetStatus == .pending
    }

    nonisolated static func shouldRestoreTailAfterContentGrowth(
        previousContentHeight: CGFloat,
        newContentHeight: CGFloat,
        viewportHeight: CGFloat,
        newMinY: CGFloat,
        followsTranscriptTail: Bool,
        isRestoring: Bool,
        contentShrinkBookmarkResetState: ACPContentShrinkBookmarkResetState = .none,
        lastRestoreSourceContentHeight: CGFloat? = nil,
        lastRestoredContentHeight: CGFloat? = nil
    ) -> Bool {
        guard !isRestoring else { return false }
        guard followsTranscriptTail else { return false }
        guard newContentHeight > previousContentHeight + ACPScrollDirectionClassifier.upwardEpsilon else {
            return false
        }
        if let lastRestoreSourceContentHeight,
           let lastRestoredContentHeight,
           abs(previousContentHeight - lastRestoreSourceContentHeight) <= ACPScrollDirectionClassifier.bottomTolerance,
           newContentHeight <= lastRestoredContentHeight + ACPScrollDirectionClassifier.bottomTolerance {
            guard contentShrinkBookmarkResetState == .verified else {
                return false
            }
        }
        let distanceFromBottom = max(0, newContentHeight - viewportHeight - newMinY)
        return distanceFromBottom > ACPScrollDirectionClassifier.bottomTolerance
    }

    nonisolated static func shouldResetContentGrowthTailRestoreAfterShrink(
        previousContentHeight: CGFloat,
        newContentHeight: CGFloat,
        viewportHeight: CGFloat,
        newMinY: CGFloat,
        followsTranscriptTail: Bool,
        isRestoring: Bool,
        hasPendingTailScroll: Bool,
        lastRestoredContentHeight: CGFloat?
    ) -> Bool {
        guard followsTranscriptTail else { return false }
        guard !hasPendingTailScroll else { return false }
        guard let lastRestoredContentHeight else { return false }
        guard previousContentHeight > newContentHeight + ACPScrollDirectionClassifier.bottomTolerance else {
            return false
        }
        guard newContentHeight < lastRestoredContentHeight - ACPScrollDirectionClassifier.bottomTolerance else {
            return false
        }
        let distanceFromBottom = max(0, newContentHeight - viewportHeight - newMinY)
        return distanceFromBottom <= ACPScrollDirectionClassifier.bottomTolerance
    }

    nonisolated static func shouldApplyDeferredContentShrinkBookmarkReset(
        expectedContentHeight: CGFloat,
        latestContentHeight: CGFloat,
        latestViewportHeight: CGFloat,
        latestMinY: CGFloat,
        followsTranscriptTail: Bool,
        isRestoring: Bool,
        hasPendingTailScroll: Bool
    ) -> Bool {
        guard followsTranscriptTail else { return false }
        guard !hasPendingTailScroll else { return false }
        guard abs(latestContentHeight - expectedContentHeight) <= ACPScrollDirectionClassifier.bottomTolerance else {
            return false
        }
        let distanceFromBottom = max(0, latestContentHeight - latestViewportHeight - latestMinY)
        return distanceFromBottom <= ACPScrollDirectionClassifier.bottomTolerance
    }

    nonisolated static func shouldUseScrollProbeForDeferredShrinkReset(
        latestProbeGeneration: UInt64,
        scheduledProbeGeneration: UInt64,
        didDebounce: Bool
    ) -> Bool {
        didDebounce || latestProbeGeneration > scheduledProbeGeneration
    }

    /// Whether `scrollToTail` should actually issue `proxy.scrollTo`. A
    /// programmatic scroll that lands where the viewport already sits is
    /// itself a geometry change that can retrigger the very callback that
    /// scheduled it — so skip it once the last known probe says we're
    /// already within tolerance of the bottom. Unknown geometry (no probe
    /// yet, or the legacy pre-macOS 15 path, which never populates the
    /// probe) always scrolls, preserving prior behavior there.
    nonisolated static func shouldPerformTailScroll(distanceFromBottom: CGFloat?) -> Bool {
        guard let distanceFromBottom else { return true }
        return distanceFromBottom > ACPScrollDirectionClassifier.bottomTolerance
    }

    enum TailScrollTrigger {
        case contentSignature
        case streamingState
        case contentGrowth
    }

    nonisolated static func shouldAnimateTailScroll(
        trigger: TailScrollTrigger,
        streamingState: ACPSession.StreamingState
    ) -> Bool {
        switch trigger {
        case .contentSignature:
            return streamingState != .sending && streamingState != .streaming
        case .streamingState, .contentGrowth:
            return false
        }
    }

    nonisolated static func shouldShowGoToNewestAffordance(
        followsTranscriptTail: Bool
    ) -> Bool {
        !followsTranscriptTail
    }

    nonisolated static func shouldAnimateGoToNewestTailScroll() -> Bool {
        true
    }

    struct GoToNewestAffordanceAction: Equatable {
        let resumesTailFollow: Bool
        let schedulesTailScroll: Bool
        let animatedTailScroll: Bool
    }

    nonisolated static func goToNewestAffordanceAction() -> GoToNewestAffordanceAction {
        GoToNewestAffordanceAction(
            resumesTailFollow: true,
            schedulesTailScroll: true,
            animatedTailScroll: shouldAnimateGoToNewestTailScroll()
        )
    }

    nonisolated static func goToNewestAffordanceBottomPadding(
        composerSpacerHeight: CGFloat,
        gap: CGFloat
    ) -> CGFloat {
        composerSpacerHeight + gap
    }

    nonisolated static func shouldRunScheduledTailScroll(followsTranscriptTail: Bool) -> Bool {
        followsTranscriptTail
    }

    nonisolated static func shouldScheduleTailScroll(hasPendingTailScroll: Bool) -> Bool {
        !hasPendingTailScroll
    }

    nonisolated static func shouldStoreContentGrowthRestoreBeforeCoalescing(
        hasPendingTailScroll: Bool,
        hasContentGrowthRestore: Bool
    ) -> Bool {
        hasPendingTailScroll && hasContentGrowthRestore
    }

    nonisolated static func mergedContentGrowthTailRestore(
        existing: ACPContentGrowthTailRestore?,
        new: ACPContentGrowthTailRestore?
    ) -> ACPContentGrowthTailRestore? {
        guard let new else { return nil }
        guard let existing else { return new }
        return ACPContentGrowthTailRestore(
            sourceHeight: min(existing.sourceHeight, new.sourceHeight),
            targetHeight: max(existing.targetHeight, new.targetHeight)
        )
    }

    nonisolated static func shouldClearScheduledTailScrollBookkeeping(
        scheduledGeneration: UInt64,
        currentGeneration: UInt64
    ) -> Bool {
        scheduledGeneration == currentGeneration
    }

    nonisolated static func shouldClearContentShrinkResetBookkeeping(
        scheduledGeneration: UInt64,
        currentGeneration: UInt64
    ) -> Bool {
        scheduledGeneration == currentGeneration
    }

    nonisolated static func contentShrinkBookmarkResetStateAfterScheduledTailScroll(
        didScroll: Bool,
        hasContentGrowthRestore: Bool,
        currentState: ACPContentShrinkBookmarkResetState
    ) -> ACPContentShrinkBookmarkResetState {
        guard didScroll, hasContentGrowthRestore else { return currentState }
        return .none
    }

    nonisolated static func shouldRestoreTailAfterViewportWidthChange(
        previousWidth: CGFloat,
        newWidth: CGFloat,
        followsTranscriptTail: Bool
    ) -> Bool {
        guard followsTranscriptTail else { return false }
        return abs(newWidth - previousWidth) > 0.5
    }

    /// Whether a row-frame callback should bother finding/remembering the
    /// top-visible anchor at all. While following the tail (streaming),
    /// restoring a programmatic scroll, or backfilling older messages, the
    /// result is discarded by later guards anyway — skipping the lookup here
    /// keeps every row's geometry callback O(1) instead of O(rows) per row.
    nonisolated static func shouldTrackAnchorFromRowFrames(
        followsTranscriptTail: Bool,
        isRestoringTail: Bool,
        isBackfillingOlderMessages: Bool
    ) -> Bool {
        !followsTranscriptTail && !isRestoringTail && !isBackfillingOlderMessages
    }

    nonisolated static func topVisibleAnchorID(in frames: [String: CGRect]) -> String? {
        frames
            .filter { _, frame in frame.height > 0 && frame.maxY > 0 }
            .min { lhs, rhs in
                let lhsDistance = lhs.value.minY <= 0 ? CGFloat.zero : lhs.value.minY
                let rhsDistance = rhs.value.minY <= 0 ? CGFloat.zero : rhs.value.minY
                if lhsDistance != rhsDistance { return lhsDistance < rhsDistance }
                if lhs.value.maxY != rhs.value.maxY { return lhs.value.maxY < rhs.value.maxY }
                return lhs.key < rhs.key
            }?
            .key
    }

    nonisolated static func shouldUseLegacyRowFramePreferences(
        isModernScrollTrackingAvailable: Bool
    ) -> Bool {
        !isModernScrollTrackingAvailable
    }

    struct VisibleRow: Identifiable, Equatable {
        let index: Int
        let stableId: String

        var id: String { stableId }
    }

    static func visibleRows(
        messages: [ACPMessage],
        visibleHead: Int,
        visibleTail: Int,
        stableId: (ACPMessage) -> String
    ) -> [VisibleRow] {
        let head = min(visibleHead, messages.count)
        let tail = max(head, min(visibleTail, messages.count))
        return (head..<tail).compactMap { index in
            let message = messages[index]
            if case .plan = message { return nil }
            return VisibleRow(index: index, stableId: stableId(message))
        }
    }

    struct VisibleMessageLookup {
        let ids: Set<String>
        let indexByStableId: [String: Int]
        let firstStableId: String?

        func contains(_ id: String?) -> Bool {
            guard let id else { return false }
            return ids.contains(id)
        }

        func transcriptIndex(for id: String?) -> Int? {
            guard let id else { return nil }
            return indexByStableId[id]
        }
    }

    nonisolated static func visibleMessageLookup(
        rows: [(index: Int, stableId: String)]
    ) -> VisibleMessageLookup {
        var ids = Set<String>()
        ids.reserveCapacity(rows.count)
        var indexByStableId: [String: Int] = [:]
        indexByStableId.reserveCapacity(rows.count)
        for row in rows {
            ids.insert(row.stableId)
            indexByStableId[row.stableId] = row.index
        }
        return VisibleMessageLookup(
            ids: ids,
            indexByStableId: indexByStableId,
            firstStableId: rows.first?.stableId
        )
    }

    /// The value `latestTopVisibleAnchor.value` should hold after a
    /// tail-follow transition. Resuming (`follows == true`) always clears it:
    /// the anchor-tracking row callbacks are skipped while following the
    /// tail, so a value left over from before the resume is stale by
    /// construction and must not be reused by a later pause. Pausing leaves
    /// it untouched — the pause path computes its own anchor separately.
    nonisolated static func trackedAnchorAfterFollowsChange(
        follows: Bool,
        previousTrackedAnchor: String?
    ) -> String? {
        follows ? nil : previousTrackedAnchor
    }

    nonisolated static func rememberedAnchorWhenPausingTailFollow(
        latestTopVisibleAnchor: String?,
        lookup: VisibleMessageLookup,
        allowFirstRenderedAnchorFallback: Bool
    ) -> String? {
        if lookup.contains(latestTopVisibleAnchor) { return latestTopVisibleAnchor }
        guard allowFirstRenderedAnchorFallback else { return nil }
        return lookup.firstStableId
    }

    nonisolated static func shouldUseFirstRenderedAnchorFallback(
        newMinY: CGFloat,
        threshold: CGFloat
    ) -> Bool {
        newMinY.isFinite && newMinY <= threshold
    }

    nonisolated static func anchorForTailForwardPreservation(
        latestTopVisibleAnchor: String?,
        lookup: VisibleMessageLookup
    ) -> String? {
        if lookup.contains(latestTopVisibleAnchor) { return latestTopVisibleAnchor }
        return lookup.firstStableId
    }

    nonisolated static func shouldRememberVisibleAnchor(
        _ anchor: String,
        rememberedAnchor: String?,
        restoredRememberedAnchor: String?,
        visibleMessageIds: Set<String>,
        isBackfillingOlderMessages: Bool
    ) -> Bool {
        guard !isBackfillingOlderMessages else { return false }
        guard let rememberedAnchor else { return true }
        if restoredRememberedAnchor == rememberedAnchor { return true }
        if anchor == rememberedAnchor { return true }
        return !visibleMessageIds.contains(rememberedAnchor)
    }

    /// macOS 14 fallback path. The Tahoe (macOS 15+) ScrollView is no longer
    /// backed by an `NSScrollView`, and `frame(in:.named:)` reported through a
    /// `PreferenceKey` stops delivering live values during scroll, so this
    /// handler never fires there — scroll position comes from
    /// `handleScrollGeometry` instead. On macOS 14 the legacy pipeline still
    /// works, so we keep it: step the window back when the head sentinel
    /// enters the threshold band at the top of the viewport.
    ///
    /// `frame.maxY > 0` ensures the sentinel is actually visible — without it,
    /// restoring to the tail of a long transcript puts the sentinel far above
    /// the viewport (negative minY *and* maxY) and the initial preference fire
    /// would still satisfy `minY < threshold`, defeating the window before the
    /// user scrolled.
    private func handleHeadFramePreference(_ frame: CGRect, proxy: ScrollViewProxy) {
        guard transcript.visibleHead > 0 else { return }
        guard frame.minY < headStepScrollThreshold, frame.maxY > 0 else { return }
        let now = Date()
        guard now.timeIntervalSince(scrollBook.lastHeadStepAt) > headStepDebounceInterval else { return }
        scrollBook.lastHeadStepAt = now
        stepHeadBackPreservingScroll(proxy: proxy)
    }

    /// macOS 15+ path. `onScrollGeometryChange` feeds the live scroll position
    /// straight from the SwiftUI ScrollView, replacing both the (now unreachable)
    /// `NSScrollView` bounds observer and the dead `PreferenceKey` pipeline.
    /// `minY` is `visibleRect.minY` (distance the viewport top has scrolled into
    /// the content); paired with viewport/content heights it gives the shared
    /// classifier the same offset/“distance from bottom” it computed from the
    /// NSScrollView before.
    private func handleScrollGeometry(
        previousMinY: CGFloat,
        newMinY: CGFloat,
        viewportHeight: CGFloat,
        previousContentHeight: CGFloat,
        contentHeight: CGFloat,
        proxy: ScrollViewProxy
    ) {
        // Always current for `scrollToTail`'s idempotency check below, even
        // when none of the branches in this function fire.
        scrollBook.scrollGeometryGeneration &+= 1
        scrollBook.lastScrollProbe = ACPScrollProbe(
            generation: scrollBook.scrollGeometryGeneration,
            minY: newMinY,
            viewportHeight: viewportHeight,
            contentHeight: contentHeight
        )
        // Tail-follow pause/resume — reuse the shared classifier so the rules
        // match the legacy observer exactly. `NSApp.currentEvent` reports the
        // most recently processed event, not necessarily the cause of this
        // geometry change, so a stale event (from a scroll gesture long over)
        // must not be classified as driving the current bounds change.
        let event = NSApp.currentEvent
        let eventIsFresh = ACPUserScrollEvent.isFresh(
            eventTimestamp: event?.timestamp,
            now: ProcessInfo.processInfo.systemUptime
        )
        let currentEventType = eventIsFresh ? event?.type : nil
        let isUserDriven = eventIsFresh && ACPUserScrollEvent.isUserDriven(currentEventType)
        let isHeadPaginationDriven = ACPUserScrollEvent.isHeadPaginationDriven(
            currentEventType,
            previousMinY: previousMinY,
            newMinY: newMinY,
            isScrollbarTrackHit: ACPUserScrollEvent.isScrollbarTrackMouseDown(eventIsFresh ? event : nil)
        )
        let decision = ACPScrollDirectionClassifier.decide(
            previousOffsetY: previousMinY,
            newOffsetY: newMinY,
            viewportHeight: viewportHeight,
            contentHeight: contentHeight,
            isRestoring: scrollBook.isRestoringTail,
            isUserDriven: isUserDriven
        )
        switch decision {
        case .userScrolledUp:
            pauseTailFollowFromGeometry(newMinY: newMinY)
        case .userAtBottom:
            handleAtBottom(
                proxy: proxy,
                shouldPageHiddenTail: Self.shouldStepTailForwardFromBottomGeometry(
                    isUserDriven: isUserDriven,
                    isRestoring: scrollBook.isRestoringTail,
                    previousMinY: previousMinY,
                    newMinY: newMinY,
                    visibleTail: transcript.visibleTailBound,
                    messageCount: transcript.messages.count
                )
            )
        case .noChange: break
        }
        scheduleContentShrinkBookmarkResetIfNeeded(
            previousContentHeight: previousContentHeight,
            contentHeight: contentHeight,
            viewportHeight: viewportHeight,
            newMinY: newMinY
        )
        if Self.shouldRestoreTailAfterContentGrowth(
            previousContentHeight: previousContentHeight,
            newContentHeight: contentHeight,
            viewportHeight: viewportHeight,
            newMinY: newMinY,
            followsTranscriptTail: session.followsTranscriptTail,
            isRestoring: scrollBook.isRestoringTail,
            contentShrinkBookmarkResetState: scrollBook.contentShrinkBookmarkResetState,
            lastRestoreSourceContentHeight: scrollBook.lastContentGrowthTailRestoreSourceHeight,
            lastRestoredContentHeight: scrollBook.lastContentGrowthTailRestoreHeight
        ) {
            scheduleTailScroll(
                proxy: proxy,
                animated: Self.shouldAnimateTailScroll(
                    trigger: .contentGrowth,
                    streamingState: session.transcript.streamingState
                ),
                contentGrowthRestore: ACPContentGrowthTailRestore(
                    sourceHeight: previousContentHeight,
                    targetHeight: contentHeight
                )
            )
            return
        }
        // Head-step pagination: reveal older messages only while a live scroll
        // gesture is driving the viewport near the top. Initial post-restore
        // geometry can briefly report top-like offsets before tail restoration
        // settles; geometry alone must not page the transcript upward.
        guard Self.shouldStepHeadBackFromGeometry(
            visibleHead: transcript.visibleHead,
            isRestoring: scrollBook.isRestoringTail,
            isHeadPaginationDriven: isHeadPaginationDriven,
            newMinY: newMinY,
            threshold: headStepScrollThreshold
        ) else { return }
        let now = Date()
        guard now.timeIntervalSince(scrollBook.lastHeadStepAt) > headStepDebounceInterval else { return }
        scrollBook.lastHeadStepAt = now
        stepHeadBackPreservingScroll(proxy: proxy)
    }

    private func scheduleContentShrinkBookmarkResetIfNeeded(
        previousContentHeight: CGFloat,
        contentHeight: CGFloat,
        viewportHeight: CGFloat,
        newMinY: CGFloat
    ) {
        guard Self.shouldResetContentGrowthTailRestoreAfterShrink(
            previousContentHeight: previousContentHeight,
            newContentHeight: contentHeight,
            viewportHeight: viewportHeight,
            newMinY: newMinY,
            followsTranscriptTail: session.followsTranscriptTail,
            isRestoring: scrollBook.isRestoringTail,
            hasPendingTailScroll: scrollBook.pendingTailScrollTask != nil,
            lastRestoredContentHeight: scrollBook.lastContentGrowthTailRestoreHeight
        ) else { return }

        scrollBook.pendingContentShrinkResetTask?.cancel()
        scrollBook.contentShrinkBookmarkResetState = .pending
        scrollBook.pendingContentShrinkResetGeneration &+= 1
        let scheduledGeneration = scrollBook.pendingContentShrinkResetGeneration
        let scheduledProbeGeneration = scrollBook.scrollGeometryGeneration
        scrollBook.pendingContentShrinkResetTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: Self.contentShrinkBookmarkResetDebounceNanoseconds)
            defer {
                if ACPMessageList.shouldClearContentShrinkResetBookkeeping(
                    scheduledGeneration: scheduledGeneration,
                    currentGeneration: scrollBook.pendingContentShrinkResetGeneration
                ) {
                    scrollBook.pendingContentShrinkResetTask = nil
                }
            }
            guard !Task.isCancelled else {
                if ACPMessageList.shouldClearContentShrinkResetBookkeeping(
                    scheduledGeneration: scheduledGeneration,
                    currentGeneration: scrollBook.pendingContentShrinkResetGeneration
                ) {
                    scrollBook.contentShrinkBookmarkResetState = .none
                }
                return
            }
            guard let latestProbe = scrollBook.lastScrollProbe else {
                if ACPMessageList.shouldClearContentShrinkResetBookkeeping(
                    scheduledGeneration: scheduledGeneration,
                    currentGeneration: scrollBook.pendingContentShrinkResetGeneration
                ) {
                    scrollBook.contentShrinkBookmarkResetState = .none
                }
                return
            }
            guard Self.shouldUseScrollProbeForDeferredShrinkReset(
                latestProbeGeneration: latestProbe.generation,
                scheduledProbeGeneration: scheduledProbeGeneration,
                didDebounce: true
            ) else {
                if ACPMessageList.shouldClearContentShrinkResetBookkeeping(
                    scheduledGeneration: scheduledGeneration,
                    currentGeneration: scrollBook.pendingContentShrinkResetGeneration
                ) {
                    scrollBook.contentShrinkBookmarkResetState = .none
                }
                return
            }
            guard Self.shouldApplyDeferredContentShrinkBookmarkReset(
                expectedContentHeight: contentHeight,
                latestContentHeight: latestProbe.contentHeight,
                latestViewportHeight: latestProbe.viewportHeight,
                latestMinY: latestProbe.minY,
                followsTranscriptTail: session.followsTranscriptTail,
                isRestoring: scrollBook.isRestoringTail,
                hasPendingTailScroll: scrollBook.pendingTailScrollTask != nil
            ) else {
                if ACPMessageList.shouldClearContentShrinkResetBookkeeping(
                    scheduledGeneration: scheduledGeneration,
                    currentGeneration: scrollBook.pendingContentShrinkResetGeneration
                ) {
                    scrollBook.contentShrinkBookmarkResetState = .none
                }
                return
            }
            if ACPMessageList.shouldClearContentShrinkResetBookkeeping(
                scheduledGeneration: scheduledGeneration,
                currentGeneration: scrollBook.pendingContentShrinkResetGeneration
            ) {
                scrollBook.contentShrinkBookmarkResetState = .verified
            }
        }
    }

    nonisolated static func shouldStepHeadBackFromGeometry(
        visibleHead: Int,
        isRestoring: Bool,
        isHeadPaginationDriven: Bool,
        newMinY: CGFloat,
        threshold: CGFloat
    ) -> Bool {
        guard visibleHead > 0 else { return false }
        guard !isRestoring else { return false }
        guard isHeadPaginationDriven else { return false }
        guard newMinY < threshold else { return false }
        return true
    }

    /// Reveal an older chunk while keeping the viewport anchored to the same
    /// content.
    private func stepHeadBackPreservingScroll(proxy: ScrollViewProxy) {
        // Anchor the row currently at the top of the window and pin it back after
        // the older rows lay out. This works on both scroll-tracking paths and
        // does not depend on net content-height changes when the bounded window
        // also trims newer rows from the bottom.
        let anchorId = visibleMessageLookup.firstStableId
        scrollBook.isRestoringTail = true
        transcript.stepHeadBack()
        DispatchQueue.main.async {
            if let anchorId {
                proxy.scrollTo(anchorId, anchor: .top)
            }
            DispatchQueue.main.async { scrollBook.isRestoringTail = false }
        }
    }

    @ViewBuilder
    private func visibleRow(_ visibleRow: VisibleRow) -> some View {
        if transcript.messages.indices.contains(visibleRow.index) {
            let message = transcript.messages[visibleRow.index]
            ACPTranscriptRowContent(
                stableId: visibleRow.stableId,
                messageIndex: visibleRow.index,
                message: message,
                contentMaxWidth: contentMaxWidth,
                typography: typography,
                trustedImageRoot: trustedImageRoot,
                transcript: transcript,
                session: session,
                onOpenDiff: onOpenDiff,
                onLoadFullToolCallContent: onLoadFullToolCallContent,
                isForkEligible: session.canForkMessage(at: visibleRow.index),
                forkTargets: forkTargets,
                onFork: onFork
            )
            .equatable()
            .background(rowFrameReporter(id: visibleRow.stableId))
        } else {
            EmptyView()
        }
    }

    static func markdownCacheMessageId(for message: ACPMessage) -> String {
        message.stableId
    }
}

/// A single transcript row's content, extracted from `ACPMessageList.body` so
/// it can be gated with `.equatable()`. A full-list body re-eval (from a
/// scroll/geometry pass) used to re-diff every visible row's deep modifier
/// tree even when nothing about the row had changed — the dominant cost in
/// the live-lock sample (`ModifiedViewList.applyNodes`,
/// `LazySubviewPlacements.placeSubviews`). Gating on the render-relevant
/// values below lets SwiftUI skip re-diffing a row's subtree entirely when
/// they're unchanged. See docs/plans/2026-07-17-acp-transcript-livelock-fix.md
/// (Task 7) for the stale-closure audit backing the excluded fields below.
struct ACPTranscriptRowContent: View, Equatable {
    // Compared (render-relevant values):
    let stableId: String
    let messageIndex: Int
    let message: ACPMessage
    let contentMaxWidth: CGFloat
    let typography: ACPChatTypography
    let trustedImageRoot: URL?
    // Excluded from equality — reference-stable for the session's lifetime
    // (`transcript`/`session` are `let` properties on `ACPSession`, never
    // reassigned), or closures whose behavior only depends on already-compared
    // data:
    // - `onOpenDiff` / queue callbacks capture stable host references
    //   (`state`, `worktree`, `manager`, `sessionId`) wired once by
    //   `ACPTabView`, not per-render-varying state.
    // - `onLoadFullToolCallContent` is only ever invoked when
    //   `tc.isContentTruncated` is true; that flag is intentionally excluded
    //   from `ACPMessage.ToolCall`'s own `==`/`hash` (a row must stay equal
    //   across the in-memory truncation boundary), but `truncateForOffWindow`
    //   only fires on messages that are, at that same moment, leaving the
    //   render window (`ACPTranscript.trimHiddenMessage`) — so the flag never
    //   flips on a message that remains part of an already-rendered,
    //   gate-compared row. When a row re-enters the window later it is
    //   constructed fresh (no prior instance to gate against), so the current
    //   `isContentTruncated` value is always picked up correctly.
    // - `session.terminalHost` is itself a `let` (stable reference) on
    //   `ACPSession`; the terminal card's own live output flows through a
    //   nested `@ObservedObject var terminal: ACPTerminal` inside
    //   `ACPTerminalTailView`, which keeps reacting independently of this
    //   gate — the same pattern already relied on for streaming `StreamingText`
    //   buffers inside `AgentMessageRow`. New terminal-id associations arrive
    //   via `tc.terminalIds`, which IS part of `message` and thus compared.
    let transcript: ACPTranscript
    let session: ACPSession
    let onOpenDiff: (String) -> Void
    let onLoadFullToolCallContent: (String) async -> String?
    let isForkEligible: Bool
    let forkTargets: [ACPSessionForkTarget]
    let onFork: (ACPForkMessageBoundary, String) -> Void

    static func == (lhs: Self, rhs: Self) -> Bool {
        equalityKey(
            stableId: lhs.stableId, message: lhs.message,
            contentMaxWidth: lhs.contentMaxWidth, typography: lhs.typography,
            trustedImageRoot: lhs.trustedImageRoot,
            isForkEligible: lhs.isForkEligible, forkTargets: lhs.forkTargets
        )
        == equalityKey(
            stableId: rhs.stableId, message: rhs.message,
            contentMaxWidth: rhs.contentMaxWidth, typography: rhs.typography,
            trustedImageRoot: rhs.trustedImageRoot,
            isForkEligible: rhs.isForkEligible, forkTargets: rhs.forkTargets
        )
    }

    /// Exposed so equality can be exercised in tests without constructing
    /// (and rendering) a `View`.
    static func equalityKey(
        stableId: String,
        message: ACPMessage,
        contentMaxWidth: CGFloat,
        typography: ACPChatTypography,
        trustedImageRoot: URL?,
        isForkEligible: Bool = false,
        forkTargets: [ACPSessionForkTarget] = []
    ) -> EqualityKey {
        EqualityKey(
            stableId: stableId, message: message, contentMaxWidth: contentMaxWidth,
            typography: typography, trustedImageRoot: trustedImageRoot,
            isForkEligible: isForkEligible, forkTargets: forkTargets
        )
    }

    struct EqualityKey: Equatable {
        let stableId: String
        let message: ACPMessage
        let contentMaxWidth: CGFloat
        let typography: ACPChatTypography
        let trustedImageRoot: URL?
        let isForkEligible: Bool
        let forkTargets: [ACPSessionForkTarget]
    }

    var body: some View {
        switch message {
        case .user(_, _, let text, let attachments, let delegatedSource):
            ACPMessageGutter(
                copySource: .text(text),
                forkBoundary: forkBoundary(kind: .user),
                forkTargets: forkTargets,
                onFork: onFork
            ) {
                UserMessageRow(
                    text: text,
                    attachments: attachments,
                    isDelegated: delegatedSource != nil,
                    contentMaxWidth: contentMaxWidth,
                    typography: typography
                )
            }
        case .agent(_, _, let buf):
            ACPMessageGutter(
                copySource: .streaming(buf),
                forkBoundary: forkBoundary(kind: .agent),
                forkTargets: forkTargets,
                onFork: onFork
            ) {
                AgentMessageRow(
                    messageId: stableId,
                    transcript: transcript,
                    buffer: buf,
                    typography: typography
                )
            }
        case .thought(_, _, let buf):
            ACPThoughtView(buffer: buf)
        case .toolCall(let tc):
            ACPToolCallCard(
                toolCall: tc,
                trustedImageRoot: trustedImageRoot,
                loadFullContent: tc.isContentTruncated ? onLoadFullToolCallContent : nil)
                .environment(\.acpTerminalHost, session.terminalHost)
        case .fileEdit(_, let edit):
            ACPFileEditCard(edit: edit, onOpenDiff: onOpenDiff)
        case .plan:
            EmptyView()
        case .systemNotice(_, let text):
            ACPSystemNoticeView(text: text)
        }
    }

    private func forkBoundary(kind: ACPForkMessageBoundary.Kind) -> ACPForkMessageBoundary? {
        guard ACPMessageForkMenuPolicy.showsForkAction(
            messageKind: message.kind,
            isEligible: isForkEligible,
            targetCount: forkTargets.count
        ) else { return nil }
        return ACPForkMessageBoundary(stableID: stableId, kind: kind)
    }
}

private final class ACPWeakScrollViewRef {
    weak var scrollView: NSScrollView?
}

private final class ACPMutableScrollAnchor {
    var value: String?
}

struct ACPContentGrowthTailRestore: Equatable {
    let sourceHeight: CGFloat
    let targetHeight: CGFloat
}

enum ACPContentShrinkBookmarkResetState {
    case none
    case pending
    case verified
}

/// Non-observed bookkeeping for scroll/restore callbacks. These values are
/// only read from callbacks (never from `body`), so keeping them in plain
/// `@State` value storage would buy nothing except a full-list invalidation
/// on every write — which is exactly the transaction-feedback edge behind
/// the transcript live-lock. See docs/plans/2026-07-17-acp-transcript-livelock-fix.md.
@MainActor
/// Internal rather than file-private so a test can drive `reset()` directly:
/// the flag-flip path that needs it lives in a SwiftUI `onReceive` closure,
/// which is not reachable from a unit test.
final class ACPTranscriptScrollBookkeeping {
    var isRestoringTail = false
    var restoredRememberedAnchor: String?
    var latestRememberedScrollAnchorIndex: Int?
    var lastHeadStepAt: Date = .distantPast
    var lastTailStepAt: Date = .distantPast
    var pendingTailScrollTask: Task<Void, Never>?
    var pendingTailScrollGeneration: UInt64 = 0
    var pendingContentGrowthTailRestore: ACPContentGrowthTailRestore?
    var pendingContentShrinkResetTask: Task<Void, Never>?
    var pendingContentShrinkResetGeneration: UInt64 = 0
    var contentShrinkBookmarkResetState: ACPContentShrinkBookmarkResetState = .none
    var scrollGeometryGeneration: UInt64 = 0
    /// Most recent modern-path scroll geometry, refreshed on every
    /// `handleScrollGeometry` call. Lets programmatic scrolls (`scrollToTail`)
    /// check whether the viewport is already at rest before issuing another
    /// `proxy.scrollTo`, so a redundant scroll doesn't retrigger the geometry
    /// callback that scheduled it.
    var lastScrollProbe: ACPScrollProbe?
    /// Highest content height that has already scheduled an automatic tail
    /// restore from the content-growth path. Lazy stack estimates can
    /// oscillate between two heights; remembering the restored height makes
    /// that path converge instead of scheduling again on every low-to-high
    /// estimate flip.
    var lastContentGrowthTailRestoreSourceHeight: CGFloat?
    var lastContentGrowthTailRestoreHeight: CGFloat?

    /// Returns every field to its initial value, cancelling any scheduled
    /// work first so a task queued against the outgoing scroll view cannot
    /// land on the incoming one.
    ///
    /// Needed when the transcript switches between the legacy and AppKit
    /// scrollers. That switch rebuilds the transcript subtree via
    /// `.id(scrollerFlagState)`, but this object is `@State` on
    /// `ACPMessageList` itself — outside the subtree the id replaces — so it
    /// survives. `restoredRememberedAnchor` surviving is the sharp edge: the
    /// rebuilt scroll view would see the current anchor as already restored,
    /// skip `restoreRememberedAnchorIfNeeded`, and leave a paused chat at
    /// the new scroll view's default position.
    func reset() {
        pendingTailScrollTask?.cancel()
        pendingContentShrinkResetTask?.cancel()
        isRestoringTail = false
        restoredRememberedAnchor = nil
        latestRememberedScrollAnchorIndex = nil
        lastHeadStepAt = .distantPast
        lastTailStepAt = .distantPast
        pendingTailScrollTask = nil
        pendingTailScrollGeneration = 0
        pendingContentGrowthTailRestore = nil
        pendingContentShrinkResetTask = nil
        pendingContentShrinkResetGeneration = 0
        contentShrinkBookmarkResetState = .none
        scrollGeometryGeneration = 0
        lastScrollProbe = nil
        lastContentGrowthTailRestoreSourceHeight = nil
        lastContentGrowthTailRestoreHeight = nil
    }
}

/// Non-observed cache for the modern per-row geometry callbacks. SwiftUI's
/// `onGeometryChange` may be serviced by nested AppKit run loops (such as an
/// open `NSMenu`), so assigning a dictionary held in `@State` here would
/// invalidate the full list for every callback.
final class ACPRowFrameCache {
    /// Same shape/idiom as `ACPVisibleRowsCache.Key`: identifies the render
    /// window a row-frame report belongs to. Kept as its own type (rather
    /// than sharing that private type) since the two caches are otherwise
    /// independent.
    struct WindowKey: Equatable {
        let generation: UInt64
        let head: Int
        let tail: Int
    }

    private(set) var frames: [String: CGRect] = [:]
    /// The window key the stale-entry scan below last ran against. `nil`
    /// until the first `update` call, guaranteeing that call always cleans.
    private var lastCleanedWindowKey: WindowKey?

    /// Returns whether the cached frame set changed. Keeping stable reports as
    /// no-ops prevents needless work even outside nested menu tracking loops.
    ///
    /// The stale-key scan below is O(rows) — it used to run unconditionally
    /// on every call, which made a full layout pass (up to
    /// `ACPTranscript.maxVisibleRows` per-row callbacks) O(rows²). It only
    /// needs to run once per render window: `lookup` (and therefore which
    /// keys are stale) only changes when the window moves, so `windowKey`
    /// lets every row after the first in a pass skip straight to the O(1)
    /// single-entry update below.
    @discardableResult
    func update(
        id: String,
        frame: CGRect,
        lookup: ACPMessageList.VisibleMessageLookup,
        windowKey: WindowKey
    ) -> Bool {
        var changed = false
        if lastCleanedWindowKey != windowKey {
            let staleIDs = frames.keys.filter { !lookup.contains($0) }
            for staleID in staleIDs {
                frames.removeValue(forKey: staleID)
                changed = true
            }
            lastCleanedWindowKey = windowKey
        }

        if lookup.contains(id), frame.height > 0, frame.maxY > 0 {
            guard frames[id] != frame else { return changed }
            frames[id] = frame
            return true
        }

        if frames.removeValue(forKey: id) != nil {
            changed = true
        }
        return changed
    }
}

/// Non-observed memo for the window-sliced row list + id lookup. Keyed on
/// (messages generation, window bounds); geometry callbacks hit this once
/// per layout pass instead of rebuilding an O(rows) dictionary per row.
/// See docs/plans/2026-07-17-acp-transcript-livelock-fix.md (Task 2).
@MainActor
final class ACPVisibleRowsCache {
    private struct Key: Equatable {
        let generation: UInt64
        let head: Int
        let tail: Int
    }
    private var key: Key?
    private var rows: [ACPMessageList.VisibleRow] = []
    private var lookup: ACPMessageList.VisibleMessageLookup?

    func rows(
        generation: UInt64, head: Int, tail: Int,
        build: () -> [ACPMessageList.VisibleRow]
    ) -> [ACPMessageList.VisibleRow] {
        let k = Key(generation: generation, head: head, tail: tail)
        if key != k {
            rows = build()
            lookup = nil
            key = k
        }
        return rows
    }

    func lookup(
        generation: UInt64, head: Int, tail: Int,
        build: () -> [ACPMessageList.VisibleRow]
    ) -> ACPMessageList.VisibleMessageLookup {
        let r = rows(generation: generation, head: head, tail: tail, build: build)
        if let lookup { return lookup }
        let l = ACPMessageList.visibleMessageLookup(rows: r.map { ($0.index, $0.stableId) })
        lookup = l
        return l
    }
}

private struct ACPHeadFramePreferenceKey: PreferenceKey {
    static let defaultValue: CGRect = .zero
    static func reduce(value: inout CGRect, nextValue: () -> CGRect) {
        value = nextValue()
    }
}

private struct ACPRowFramesPreferenceKey: PreferenceKey {
    static let defaultValue: [String: CGRect] = [:]
    static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { _, new in new })
    }
}

private struct ACPRowFramePreferenceTracking: ViewModifier {
    let onFrames: ([String: CGRect]) -> Void

    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(macOS 15, *) {
            if ACPMessageList.shouldUseLegacyRowFramePreferences(isModernScrollTrackingAvailable: true) {
                content.onPreferenceChange(ACPRowFramesPreferenceKey.self, perform: onFrames)
            } else {
                content
            }
        } else if ACPMessageList.shouldUseLegacyRowFramePreferences(isModernScrollTrackingAvailable: false) {
            content.onPreferenceChange(ACPRowFramesPreferenceKey.self, perform: onFrames)
        } else {
            content
        }
    }
}

/// Drives transcript scroll tracking with the right mechanism per OS version.
///
/// macOS 15+ (including Tahoe) stopped backing SwiftUI `ScrollView` with an
/// `NSScrollView`, and `frame(in:.named:)` reported through a `PreferenceKey`
/// no longer delivers live values during scroll — so on those systems the
/// legacy path silently never paginates and never pauses tail-follow.
/// `onScrollGeometryChange` reads scroll position straight from the ScrollView
/// and feeds both behaviours. macOS 14 keeps the original NSScrollView-observer
/// plus preference path, which still works there.
private struct ACPTranscriptScrollTracking: ViewModifier {
    let isRestoring: () -> Bool
    let onResolveScrollView: (NSScrollView) -> Void
    let onHeadFrame: (CGRect) -> Void
    let onPaused: () -> Void
    let onAtBottom: (Bool) -> Void
    let onGeometry: (ACPScrollProbe, ACPScrollProbe) -> Void

    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(macOS 15, *) {
            content.onScrollGeometryChange(for: ACPScrollProbe.self) { geo in
                ACPScrollProbe(
                    generation: 0,
                    minY: geo.visibleRect.minY,
                    viewportHeight: geo.visibleRect.height,
                    contentHeight: geo.contentSize.height)
            } action: { old, new in
                onGeometry(old, new)
            }
        } else {
            content
                .background(
                    ACPScrollEventObserver(
                        onPaused: onPaused,
                        onAtBottom: onAtBottom,
                        isRestoring: isRestoring,
                        onScrollViewResolved: onResolveScrollView
                    )
                )
                .onPreferenceChange(ACPHeadFramePreferenceKey.self, perform: onHeadFrame)
        }
    }
}

/// Equatable snapshot of the parts of `ScrollGeometry` the transcript needs.
/// Version-agnostic so `ACPTranscriptScrollTracking` doesn't require blanket
/// macOS 15 availability — the `ScrollGeometry` reference is confined to the
/// `#available` branch above.
/// Internal rather than file-private only because it appears in
/// `ACPTranscriptScrollBookkeeping`'s stored properties, and that type is
/// internal so its `reset()` can be unit-tested.
struct ACPScrollProbe: Equatable {
    var generation: UInt64
    var minY: CGFloat
    var viewportHeight: CGFloat
    var contentHeight: CGFloat
}

private struct ACPScrollEventObserver: NSViewRepresentable {
    let onPaused: () -> Void
    let onAtBottom: (Bool) -> Void
    let isRestoring: () -> Bool
    var onScrollViewResolved: ((NSScrollView) -> Void)?

    func makeCoordinator() -> Coordinator {
        Coordinator(onPaused: onPaused, onAtBottom: onAtBottom, isRestoring: isRestoring)
    }

    func makeNSView(context: Context) -> ResolverView {
        let view = ResolverView()
        view.onResolve = { scrollView in
            context.coordinator.observe(scrollView: scrollView)
        }
        return view
    }

    func updateNSView(_ nsView: ResolverView, context: Context) {
        context.coordinator.onPaused = onPaused
        context.coordinator.onAtBottom = onAtBottom
        context.coordinator.isRestoring = isRestoring
        context.coordinator.onScrollViewResolved = onScrollViewResolved
        nsView.resolve()
    }

    @MainActor
    final class Coordinator {
        var onPaused: () -> Void
        var onAtBottom: (Bool) -> Void
        var isRestoring: () -> Bool
        var onScrollViewResolved: ((NSScrollView) -> Void)?
        private weak var observedScrollView: NSScrollView?
        private var observer: NSObjectProtocol?
        private var lastOffsetY: CGFloat?

        init(onPaused: @escaping () -> Void,
             onAtBottom: @escaping (Bool) -> Void,
             isRestoring: @escaping () -> Bool) {
            self.onPaused = onPaused
            self.onAtBottom = onAtBottom
            self.isRestoring = isRestoring
        }

        deinit {
            if let observer {
                NotificationCenter.default.removeObserver(observer)
            }
        }

        func observe(scrollView: NSScrollView) {
            guard observedScrollView !== scrollView else {
                onScrollViewResolved?(scrollView)
                return
            }
            if let observer {
                NotificationCenter.default.removeObserver(observer)
            }
            observedScrollView = scrollView
            onScrollViewResolved?(scrollView)
            lastOffsetY = scrollView.contentView.bounds.origin.y
            scrollView.contentView.postsBoundsChangedNotifications = true
            observer = NotificationCenter.default.addObserver(
                forName: NSView.boundsDidChangeNotification,
                object: scrollView.contentView,
                queue: .main
            ) { [weak self, weak scrollView] _ in
                // queue: .main delivers on the main thread; assume MainActor
                // isolation rather than hopping through a Task so the decision
                // lands before the next streaming chunk fires scrollToTail.
                MainActor.assumeIsolated {
                    guard let self, let scrollView else { return }
                    self.handleBoundsChange(scrollView)
                }
            }
        }

        private func handleBoundsChange(_ scrollView: NSScrollView) {
            let cv = scrollView.contentView
            let newY = cv.bounds.origin.y
            let viewportH = cv.bounds.height
            let contentH = scrollView.documentView?.bounds.height ?? 0
            let restoring = isRestoring()
            let isUserDriven = Self.isUserDrivenScrollEvent
            let decision = ACPScrollDirectionClassifier.decide(
                previousOffsetY: lastOffsetY,
                newOffsetY: newY,
                viewportHeight: viewportH,
                contentHeight: contentH,
                isRestoring: restoring,
                isUserDriven: isUserDriven
            )
            lastOffsetY = newY
            switch decision {
            case .userScrolledUp: onPaused()
            case .userAtBottom: onAtBottom(isUserDriven && !restoring)
            case .noChange: break
            }
        }

        private static var isUserDrivenScrollEvent: Bool {
            let event = NSApp.currentEvent
            let eventIsFresh = ACPUserScrollEvent.isFresh(
                eventTimestamp: event?.timestamp,
                now: ProcessInfo.processInfo.systemUptime
            )
            return eventIsFresh && ACPUserScrollEvent.isUserDriven(event?.type)
        }
    }

    final class ResolverView: NSView {
        var onResolve: ((NSScrollView) -> Void)?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            resolve()
        }

        func resolve() {
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                var ancestor = self.superview
                while let view = ancestor {
                    if let scrollView = view as? NSScrollView {
                        self.onResolve?(scrollView)
                        return
                    }
                    ancestor = view.superview
                }
            }
        }
    }
}

/// Maps an `NSEvent.EventType` to whether it represents a live user scroll
/// gesture, used by `ACPScrollEventObserver` to decide if an upward bounds
/// change is deliberate. Extracted as a pure function so the mapping is unit
/// testable without a running event loop.
///
/// The set is deliberately narrow. `NSApp.currentEvent` reports the most
/// recent app-wide event, not the cause of the bounds change, so any event
/// type that also occurs away from scrolling would misattribute layout reflow
/// during streaming and re-latch the false pause this guards against:
///   - `.keyDown`: the transcript `ScrollView` never holds key focus here (the
///     composer owns it), so keyboard paging can't scroll it; accepting it
///     would catch composer typing during streaming.
///   - `.leftMouseDown` / `.leftMouseUp`: a bare click can't be told apart from
///     clicking a transcript control (expanding a card, the copy button) by
///     type alone, so it would catch reflow that coincides with such a click.
/// The covered cases (trackpad and dragging the scroller knob) only fire while
/// actually scrolling, so they can't be confused with idle layout reflow.
enum ACPUserScrollEvent {
    /// `NSApp.currentEvent` lingers after the gesture ends; only treat it as
    /// the cause of a bounds change when it happened within this window.
    /// Trackpad momentum keeps emitting scrollWheel events, so live scrolling
    /// stays fresh.
    static let freshnessWindow: TimeInterval = 0.35

    /// `NSEvent.timestamp` is seconds since system startup, the same
    /// timebase as `ProcessInfo.processInfo.systemUptime` (per Apple's
    /// documentation for `NSEvent.timestamp`), so the two are directly
    /// comparable without conversion.
    static func isFresh(
        eventTimestamp: TimeInterval?,
        now: TimeInterval,
        window: TimeInterval = freshnessWindow
    ) -> Bool {
        guard let eventTimestamp else { return false }
        return now - eventTimestamp <= window
    }

    static func isUserDriven(_ type: NSEvent.EventType?) -> Bool {
        guard let type else { return false }
        switch type {
        case .scrollWheel, .leftMouseDragged, .gesture, .magnify, .swipe:
            return true
        default:
            return false
        }
    }

    static func isHeadPaginationDriven(
        _ type: NSEvent.EventType?,
        previousMinY: CGFloat? = nil,
        newMinY: CGFloat? = nil,
        isScrollbarTrackHit: Bool = false
    ) -> Bool {
        guard let type else { return false }
        if isUserDriven(type) { return true }
        // Track-click paging arrives as a plain mouse-down. Keep that out of
        // tail-follow pause detection, and require both scrollbar provenance
        // and actual upward geometry movement so tab/content clicks cannot
        // reveal older rows during restore or layout.
        guard type == .leftMouseDown, isScrollbarTrackHit, let previousMinY, let newMinY else {
            return false
        }
        return newMinY < previousMinY - ACPScrollDirectionClassifier.upwardEpsilon
    }

    static func isScrollbarTrackMouseDown(_ event: NSEvent?) -> Bool {
        guard let event, event.type == .leftMouseDown, let contentView = event.window?.contentView else {
            return false
        }
        return isScrollbarView(contentView.hitTest(event.locationInWindow))
    }

    private static func isScrollbarView(_ view: NSView?) -> Bool {
        var current = view
        while let view = current {
            if view is NSScroller { return true }
            let className = NSStringFromClass(type(of: view)).lowercased()
            if className.contains("scroller") || className.contains("scrollbar") {
                return true
            }
            current = view.superview
        }
        return false
    }
}

@MainActor
final class ACPDelayedHoverVisibility: ObservableObject {
    @Published private(set) var isVisible = false

    private let hideDelayNanoseconds: UInt64
    private var hideTask: Task<Void, Never>?

    init(hideDelayNanoseconds: UInt64 = 350_000_000) {
        self.hideDelayNanoseconds = hideDelayNanoseconds
    }

    deinit {
        hideTask?.cancel()
    }

    func enter() {
        hideTask?.cancel()
        hideTask = nil
        isVisible = true
    }

    func leave() {
        hideTask?.cancel()
        let delay = hideDelayNanoseconds
        hideTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: delay)
            guard !Task.isCancelled else { return }
            await MainActor.run {
                self?.isVisible = false
                self?.hideTask = nil
            }
        }
    }
}

// MARK: - User bubble (right-aligned)

private struct UserMessageRow: View {
    let text: String
    let attachments: [ACPMessage.Attachment]
    let isDelegated: Bool
    let contentMaxWidth: CGFloat
    let typography: ACPChatTypography
    @Environment(\.theme) private var theme
    var body: some View {
        HStack {
            Spacer(minLength: 40)
            VStack(alignment: .trailing, spacing: 4) {
                if isDelegated {
                    Text("Delegated prompt")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(theme.color("fg-faint"))
                }
                if !attachments.isEmpty {
                    let images = attachments.filter { ($0.mimeType?.hasPrefix("image/")) == true }
                    let others = attachments.filter { ($0.mimeType?.hasPrefix("image/")) != true }
                    if !images.isEmpty {
                        HStack(spacing: 6) {
                            // Key by index, not uri: content-addressed staging
                            // means the same image attached twice shares a uri,
                            // and duplicate ForEach ids collapse the row.
                            ForEach(Array(images.enumerated()), id: \.offset) { _, a in
                                if let url = URL(string: a.uri) {
                                    ACPImageThumbnail(fileURL: url)
                                }
                            }
                        }
                    }
                    if !others.isEmpty {
                        HStack(spacing: 4) {
                            ForEach(others, id: \.uri) { a in
                                FileChip(path: a.name ?? a.uri, lines: nil, iconSystemName: "at")
                            }
                        }
                    }
                }
                ACPMarkdownText(raw: text, typography: typography)
                    .padding(.vertical, 9)
                    .padding(.horizontal, 13)
                    .background(
                        LinearGradient(
                            colors: [
                                theme.color("accent").opacity(0.32),
                                theme.color("accent").opacity(0.20)
                            ],
                            startPoint: .top, endPoint: .bottom
                        )
                    )
                    .clipShape(
                        UnevenRoundedRectangle(
                            cornerRadii: .init(topLeading: 12, bottomLeading: 12, bottomTrailing: 4, topTrailing: 12)
                        )
                    )
                    .overlay(
                        UnevenRoundedRectangle(
                            cornerRadii: .init(topLeading: 12, bottomLeading: 12, bottomTrailing: 4, topTrailing: 12)
                        )
                        .strokeBorder(theme.color("accent").opacity(0.5), lineWidth: 0.5)
                    )
                    .shadow(color: .black.opacity(0.2), radius: 8, y: 2)
            }
            .frame(maxWidth: contentMaxWidth * 0.75, alignment: .trailing)
        }
        .frame(maxWidth: .infinity)
    }
}

// MARK: - Agent prose (markdown-rendered, full-width)

private struct AgentMessageRow: View {
    let messageId: String
    let transcript: ACPTranscript
    @ObservedObject var buffer: StreamingText
    let typography: ACPChatTypography
    var body: some View {
        ACPMarkdownText(
            raw: buffer.value,
            cache: transcript.markdownCache(forMessage: messageId),
            knownAppendedSuffix: buffer.lastAppendedSuffix,
            updateRevision: buffer.revision,
            updateSourceID: ObjectIdentifier(buffer),
            typography: typography
        )
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Streaming caret

private struct StreamingCaret: View {
    @State private var on = false
    @Environment(\.theme) private var theme
    var body: some View {
        RoundedRectangle(cornerRadius: 1)
            .fill(theme.color("accent"))
            .opacity(on ? 1 : 0)
            .animation(.easeInOut(duration: 0.5).repeatForever(autoreverses: true), value: on)
            .onAppear { on = true }
    }
}
