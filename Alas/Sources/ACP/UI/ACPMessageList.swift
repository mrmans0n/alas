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
    @Environment(\.theme) private var theme
    @State private var isRestoringTail = false
    @State private var headFrame: CGRect = .zero
    @State private var lastHeadStepAt: Date = .distantPast
    @State private var lastTailStepAt: Date = .distantPast
    @State private var scrollViewRef = ACPWeakScrollViewRef()
    @State private var latestTopVisibleAnchor = ACPMutableScrollAnchor()
    @State private var latestRememberedScrollAnchorIndex: Int?
    @State private var restoredRememberedAnchor: String?
    @State private var pendingTailScrollTask: Task<Void, Never>?
    @State private var modernRowFrames: [String: CGRect] = [:]

    /// Height of an invisible spacer at the tail of the transcript stack. The
    /// composer pill plus its outer padding occupies roughly this much
    /// vertical space, so by scrolling THAT element to the viewport
    /// bottom we guarantee the streaming caret / last message sits
    /// above the composer instead of behind it.
    private let composerSpacerHeight: CGFloat = 220
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
    private var scrollSpaceName: String { "acp-message-list-\(session.id)" }

    /// Window-sliced, plan-filtered list of rows to render. The slice
    /// bounds first-paint cost on long transcripts (`visibleHead` is
    /// reset to `max(0, count - tailWindow)` after hydration); the
    /// filter drops `.plan` entries because the toolbar pill renders
    /// the current turn's plan instead of an inline card.
    private var visibleRows: [VisibleRow] {
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

    var body: some View {
        ScrollViewReader { proxy in
            GeometryReader { viewport in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 18) {
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
                .coordinateSpace(.named(scrollSpaceName))
                .modifier(ACPTranscriptScrollTracking(
                    isRestoring: { isRestoringTail },
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
                    pendingTailScrollTask?.cancel()
                    pendingTailScrollTask = nil
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
            }
        }
        .background(
            LinearGradient(
                colors: [theme.color("bg-1"), theme.color("bg-0")],
                startPoint: .top, endPoint: .bottom
            )
        )
    }

    private func restoreTailIfNeeded(proxy: ScrollViewProxy, animated: Bool) {
        guard session.followsTranscriptTail else { return }
        transcript.resetWindowToTail()
        scrollToTail(proxy: proxy, animated: animated)
    }

    private func restoreRememberedAnchorIfNeeded(proxy: ScrollViewProxy) {
        guard !session.followsTranscriptTail else {
            restoredRememberedAnchor = nil
            return
        }
        guard let anchor = rememberedScrollAnchor(), restoredRememberedAnchor != anchor else { return }
        guard visibleMessageLookup.contains(anchor) else { return }
        isRestoringTail = true
        proxy.scrollTo(anchor, anchor: .top)
        restoredRememberedAnchor = anchor
        DispatchQueue.main.async {
            isRestoringTail = false
        }
    }

    private func scrollToTail(proxy: ScrollViewProxy, animated: Bool) {
        pendingTailScrollTask?.cancel()
        pendingTailScrollTask = nil
        isRestoringTail = true
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
            isRestoringTail = false
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
    }

    private func scheduleTailScroll(proxy: ScrollViewProxy, animated: Bool) {
        guard Self.shouldScheduleTailScroll(hasPendingTailScroll: pendingTailScrollTask != nil) else {
            return
        }
        pendingTailScrollTask?.cancel()
        pendingTailScrollTask = Task { @MainActor in
            await Task.yield()
            guard !Task.isCancelled,
                  ACPMessageList.shouldRunScheduledTailScroll(
                    followsTranscriptTail: session.followsTranscriptTail
                  )
            else {
                pendingTailScrollTask = nil
                return
            }
            scrollToTail(proxy: proxy, animated: animated)
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
            latestRememberedScrollAnchorIndex = nil
        } else {
            session.followsTranscriptTail = false
            pendingTailScrollTask?.cancel()
            pendingTailScrollTask = nil
            let lookup = visibleMessageLookup
            let anchor = Self.rememberedAnchorWhenPausingTailFollow(
                latestTopVisibleAnchor: latestTopVisibleAnchor.value,
                lookup: lookup,
                allowFirstRenderedAnchorFallback: allowFirstRenderedAnchorFallback
            )
            let anchorIndex = lookup.transcriptIndex(for: anchor)
            onRememberScrollAnchor(
                anchor,
                anchorIndex,
                false
            )
            latestRememberedScrollAnchorIndex = anchorIndex
            restoredRememberedAnchor = anchor
        }
    }

    private func handleRowFramePreference(_ frames: [String: CGRect], proxy: ScrollViewProxy) {
        restoreRememberedAnchorIfNeeded(proxy: proxy)
        guard let anchor = Self.topVisibleAnchorID(in: frames) else { return }
        let anchorChanged = latestTopVisibleAnchor.value != anchor
        if anchorChanged {
            latestTopVisibleAnchor.value = anchor
        }
        let lookup = visibleMessageLookup
        guard !isRestoringTail else { return }
        guard !session.followsTranscriptTail else { return }
        let rememberedAnchor = rememberedScrollAnchor()
        let anchorIndex = lookup.transcriptIndex(for: anchor)
        let anchorIndexChanged = rememberedAnchor == anchor && latestRememberedScrollAnchorIndex != anchorIndex
        guard anchorChanged || rememberedAnchor != anchor || anchorIndexChanged else { return }
        if !Self.shouldRememberVisibleAnchor(
            anchor,
            rememberedAnchor: rememberedAnchor,
            restoredRememberedAnchor: restoredRememberedAnchor,
            visibleMessageIds: lookup.ids,
            isBackfillingOlderMessages: transcript.isBackfillingOlderMessages
        ) {
            return
        }
        onRememberScrollAnchor(anchor, anchorIndex, false)
        latestRememberedScrollAnchorIndex = anchorIndex
        restoredRememberedAnchor = anchor
    }

    private func handleModernRowFrame(id: String, frame: CGRect) {
        let lookup = visibleMessageLookup
        modernRowFrames = modernRowFrames.filter { lookup.contains($0.key) }
        if lookup.contains(id), frame.height > 0, frame.maxY > 0 {
            modernRowFrames[id] = frame
        } else {
            modernRowFrames.removeValue(forKey: id)
        }
        guard let anchor = Self.topVisibleAnchorID(in: modernRowFrames) else { return }
        let anchorChanged = latestTopVisibleAnchor.value != anchor
        if anchorChanged {
            latestTopVisibleAnchor.value = anchor
        }
        guard !isRestoringTail else { return }
        guard !session.followsTranscriptTail else { return }
        guard !transcript.isBackfillingOlderMessages else { return }
        let rememberedAnchor = rememberedScrollAnchor()
        let anchorIndex = lookup.transcriptIndex(for: anchor)
        let anchorIndexChanged = rememberedAnchor == anchor && latestRememberedScrollAnchorIndex != anchorIndex
        guard anchorChanged || rememberedAnchor != anchor || anchorIndexChanged else { return }
        onRememberScrollAnchor(anchor, anchorIndex, false)
        latestRememberedScrollAnchorIndex = anchorIndex
        restoredRememberedAnchor = anchor
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
        guard !isRestoringTail else { return }
        guard transcript.visibleTailBound < transcript.messages.count else { return }
        let now = Date()
        guard now.timeIntervalSince(lastTailStepAt) > headStepDebounceInterval else { return }
        lastTailStepAt = now
        let anchorId = Self.anchorForTailForwardPreservation(
            latestTopVisibleAnchor: latestTopVisibleAnchor.value,
            lookup: lookup
        )
        let anchorIndex = lookup.transcriptIndex(for: anchorId)
        isRestoringTail = true
        transcript.stepTailForward(preserving: anchorIndex)
        let updatedRows = Self.visibleRows(
            messages: transcript.messages,
            visibleHead: transcript.visibleHead,
            visibleTail: transcript.visibleTailBound,
            stableId: { transcript.stableId(for: $0) }
        )
        let updatedLookup = Self.visibleMessageLookup(rows: updatedRows.map { row in
            (index: row.index, stableId: row.stableId)
        })
        let scrollTargetId = updatedLookup.contains(anchorId) ? anchorId : updatedLookup.firstStableId
        DispatchQueue.main.async {
            if let scrollTargetId {
                proxy.scrollTo(scrollTargetId, anchor: .top)
            }
            DispatchQueue.main.async {
                isRestoringTail = false
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
                value: [id: rowGeometry.frame(in: .named(scrollSpaceName))]
            )
        }
    }

    @available(macOS 15, *)
    private func modernRowFrameReporter(id: String) -> some View {
        Color.clear.onGeometryChange(for: CGRect.self) { rowGeometry in
            rowGeometry.frame(in: .named(scrollSpaceName))
        } action: { frame in
            handleModernRowFrame(id: id, frame: frame)
        }
    }

    private var visibleMessageLookup: VisibleMessageLookup {
        Self.visibleMessageLookup(rows: visibleRows.map { row in
            (index: row.index, stableId: row.stableId)
        })
    }

    private var topPaginationSentinel: some View {
        GeometryReader { headGeom in
            Color.clear.preference(
                key: ACPHeadFramePreferenceKey.self,
                value: headGeom.frame(in: .named(scrollSpaceName))
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
        followsTranscriptTail: Bool
    ) -> Bool {
        guard followsTranscriptTail else { return false }
        guard newContentHeight > previousContentHeight + ACPScrollDirectionClassifier.upwardEpsilon else {
            return false
        }
        let distanceFromBottom = max(0, newContentHeight - viewportHeight - newMinY)
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

    nonisolated static func shouldRunScheduledTailScroll(followsTranscriptTail: Bool) -> Bool {
        followsTranscriptTail
    }

    nonisolated static func shouldScheduleTailScroll(hasPendingTailScroll: Bool) -> Bool {
        !hasPendingTailScroll
    }

    nonisolated static func shouldRestoreTailAfterViewportWidthChange(
        previousWidth: CGFloat,
        newWidth: CGFloat,
        followsTranscriptTail: Bool
    ) -> Bool {
        guard followsTranscriptTail else { return false }
        return abs(newWidth - previousWidth) > 0.5
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
        headFrame = frame
        guard transcript.visibleHead > 0 else { return }
        guard frame.minY < headStepScrollThreshold, frame.maxY > 0 else { return }
        let now = Date()
        guard now.timeIntervalSince(lastHeadStepAt) > headStepDebounceInterval else { return }
        lastHeadStepAt = now
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
        // Tail-follow pause/resume — reuse the shared classifier so the rules
        // match the legacy observer exactly.
        let currentEventType = NSApp.currentEvent?.type
        let isUserDriven = ACPUserScrollEvent.isUserDriven(currentEventType)
        let isHeadPaginationDriven = ACPUserScrollEvent.isHeadPaginationDriven(
            currentEventType,
            previousMinY: previousMinY,
            newMinY: newMinY,
            isScrollbarTrackHit: ACPUserScrollEvent.isScrollbarTrackMouseDown(NSApp.currentEvent)
        )
        let decision = ACPScrollDirectionClassifier.decide(
            previousOffsetY: previousMinY,
            newOffsetY: newMinY,
            viewportHeight: viewportHeight,
            contentHeight: contentHeight,
            isRestoring: isRestoringTail,
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
                    isRestoring: isRestoringTail,
                    previousMinY: previousMinY,
                    newMinY: newMinY,
                    visibleTail: transcript.visibleTailBound,
                    messageCount: transcript.messages.count
                )
            )
        case .noChange: break
        }
        if Self.shouldRestoreTailAfterContentGrowth(
            previousContentHeight: previousContentHeight,
            newContentHeight: contentHeight,
            viewportHeight: viewportHeight,
            newMinY: newMinY,
            followsTranscriptTail: session.followsTranscriptTail
        ) {
            scheduleTailScroll(
                proxy: proxy,
                animated: Self.shouldAnimateTailScroll(
                    trigger: .contentGrowth,
                    streamingState: session.transcript.streamingState
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
            isRestoring: isRestoringTail,
            isHeadPaginationDriven: isHeadPaginationDriven,
            newMinY: newMinY,
            threshold: headStepScrollThreshold
        ) else { return }
        let now = Date()
        guard now.timeIntervalSince(lastHeadStepAt) > headStepDebounceInterval else { return }
        lastHeadStepAt = now
        stepHeadBackPreservingScroll(proxy: proxy)
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
        isRestoringTail = true
        transcript.stepHeadBack()
        DispatchQueue.main.async {
            if let anchorId {
                proxy.scrollTo(anchorId, anchor: .top)
            }
            DispatchQueue.main.async { isRestoringTail = false }
        }
    }

    @ViewBuilder
    private func visibleRow(_ visibleRow: VisibleRow) -> some View {
        if transcript.messages.indices.contains(visibleRow.index) {
            let message = transcript.messages[visibleRow.index]
            row(for: message, stableId: visibleRow.stableId)
                .background(rowFrameReporter(id: visibleRow.stableId))
        } else {
            EmptyView()
        }
    }

    @ViewBuilder
    private func row(for m: ACPMessage, stableId: String) -> some View {
        switch m {
        case .user(_, _, let text, let attachments, let delegatedSource):
            ACPMessageGutter(copySource: .text(text)) {
                UserMessageRow(
                    text: text,
                    attachments: attachments,
                    isDelegated: delegatedSource != nil,
                    contentMaxWidth: contentMaxWidth,
                    typography: typography
                )
            }
        case .agent(_, _, let buf):
            ACPMessageGutter(copySource: .streaming(buf)) {
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

    static func markdownCacheMessageId(for message: ACPMessage) -> String {
        message.stableId
    }
}

private final class ACPWeakScrollViewRef {
    weak var scrollView: NSScrollView?
}

private final class ACPMutableScrollAnchor {
    var value: String?
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
private struct ACPScrollProbe: Equatable {
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
            ACPUserScrollEvent.isUserDriven(NSApp.currentEvent?.type)
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
