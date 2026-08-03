import AppKit
import SwiftUI

/// AppKit-backed transcript scroller (feature-flagged replacement for the
/// SwiftUI ScrollView in ACPMessageList). SwiftUI remains the reconciliation
/// driver: every updateNSView builds the ordered row-spec list from the
/// transcript's render window and hands it to the reconciler; AppKit owns
/// scrolling, tiling, and offset compensation.
struct ACPTranscriptScroller: NSViewRepresentable {
    @ObservedObject var session: ACPSession
    @ObservedObject var transcript: ACPTranscript
    let contentMaxWidth: CGFloat
    let typography: ACPChatTypography
    let trustedImageRoot: URL?
    let onOpenDiff: (String) -> Void
    let onLoadFullToolCallContent: (String) async -> String?
    let forkTargets: [ACPSessionForkTarget]
    let onFork: (ACPForkMessageBoundary, String) -> Void
    let rememberedScrollAnchor: () -> String?
    let onRememberScrollAnchor: (String?, Int?, Bool) -> Void
    // Remaining ACPMessageList host inputs (ACPMessageList.swift:5-36),
    // carried through with identical names/types so Task 11 can pass this
    // struct's init the same arguments it already builds for ACPMessageList.
    let onOpenTranscriptLink: (URL) -> Bool
    let policy: ACPPermissionPolicy?
    let scopeKey: String
    let onUserInputResponse: (UUID, ACPUserInputAction) -> Void
    let onOpenElicitationURL: (UUID) async -> Bool
    let onDismissElicitationURLWait: (String) -> Void
    let onQueueEdit: (QueuedPrompt) -> Void
    let onQueueForceSend: (UUID) -> Void
    let onQueueRemove: (UUID) -> Void
    let onQueueRetry: (UUID) -> Void
    let onQueueReorder: (Int, Int) -> Void
    let onQueueClearAll: () -> Void
    let onRetryContextRecovery: () -> Void
    let onOpenForkSource: (String) -> Void
    let agentDisplayName: (String) -> String

    /// Ambient theme at the point this representable sits in the SwiftUI
    /// tree. Individual rows are hosted in their own, otherwise-disconnected
    /// `NSHostingView`s (see `ACPTranscriptRowHostingPool`), so SwiftUI's
    /// normal environment inheritance — which would carry `\.theme` down
    /// from `RootView`'s `.environment(\.theme, ...)` for free in the legacy
    /// single-ScrollView tree — does not reach them automatically. Every row
    /// spec re-applies this value explicitly (see `wrapRow`).
    @Environment(\.theme) private var theme

    /// Mirrors `ACPMessageList.openTranscriptURLAction`: routes markdown
    /// link taps inside message rows back through the host callback.
    private var openTranscriptURLAction: OpenURLAction {
        OpenURLAction { url in
            onOpenTranscriptLink(url) ? .handled : .systemAction
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> ACPTranscriptScrollerView {
        let scroller = ACPTranscriptScrollerView(frame: .zero)
        context.coordinator.attach(scroller: scroller, host: self)
        return scroller
    }

    func updateNSView(_ nsView: ACPTranscriptScrollerView, context: Context) {
        context.coordinator.update(host: self)
    }

    @MainActor
    final class Coordinator {
        // The Coordinator is the sole strong owner of both `scroller` and
        // `reconciler`. `reconciler` holds `unowned let scroller`: nothing
        // outside this Coordinator keeps `reconciler` alive (its callback
        // closures capture `self` weakly, never `scroller` directly), so
        // when the Coordinator is deallocated both references are released
        // together and the unowned pointer is never dereferenced after
        // `scroller` is gone. SwiftUI's own strong reference to the NSView
        // it placed in the AppKit hierarchy only extends `scroller`'s
        // lifetime further, which cannot violate the invariant.
        private var scroller: ACPTranscriptScrollerView?
        private var reconciler: ACPTranscriptScrollerReconciler?
        private let tiling = ACPTranscriptTilingController()
        private let pool = ACPTranscriptRowHostingPool()
        private var host: ACPTranscriptScroller?
        private var didRestoreInitialPosition = false
        /// Whether the most recently built spec list contained at least one
        /// non-synthetic (message) row id — i.e. an id not prefixed `__`.
        /// See `restoreInitialPositionIfNeeded`'s doc comment.
        private var hasNonSyntheticRow = false

        static let composerSpacerHeight: CGFloat = 220

        func attach(scroller: ACPTranscriptScrollerView, host: ACPTranscriptScroller) {
            self.scroller = scroller
            self.reconciler = ACPTranscriptScrollerReconciler(
                tiling: tiling, pool: pool, scroller: scroller
            )
            scroller.onScroll = { [weak self] previousY, newY, viewportH, contentH, isProgrammatic in
                self?.handleScroll(
                    previousY: previousY, newY: newY,
                    viewportHeight: viewportH, contentHeight: contentH,
                    isProgrammatic: isProgrammatic
                )
            }
            update(host: host)
        }

        func update(host: ACPTranscriptScroller) {
            self.host = host
            // Re-apply unconditionally: `reconciler.apply` itself early-
            // returns and records nothing for a non-positive width (host
            // view not yet laid out), so skipping this call based on any
            // "already applied" memo would leave the transcript permanently
            // empty once a real width does arrive.
            guard let reconciler, let scroller else { return }
            let specs = Self.rowSpecs(host: host)
            hasNonSyntheticRow = specs.contains { !$0.id.hasPrefix("__") }
            reconciler.apply(
                specs: specs,
                contentWidth: scroller.contentView.bounds.width,
                followsTail: host.session.followsTranscriptTail
            )
            restoreInitialPositionIfNeeded()
        }

        // MARK: row specs

        /// Wraps a row's content with the layout and environment values that
        /// would otherwise reach it "for free" as a child of the legacy
        /// VStack. In the legacy list, `.frame(maxWidth: contentMaxWidth,
        /// alignment: .leading).padding(.horizontal: 28 +
        /// laneWidth).frame(maxWidth: .infinity, alignment: .center)` sits
        /// on the WHOLE VStack (ACPMessageList.swift:267-270), constraining
        /// every child — including synthetic rows — into one centered
        /// content column. `\.theme` and `\.openURL` are likewise set once
        /// at that same root. Each row here is instead hosted in its own,
        /// independently-created `NSHostingView` (see
        /// `ACPTranscriptRowHostingPool`), which SwiftUI's layout/environment
        /// propagation does not reach automatically — so both the column
        /// framing and the environment values must be re-applied per row.
        private static func wrapRow<Content: View>(
            host: ACPTranscriptScroller,
            @ViewBuilder _ content: () -> Content
        ) -> AnyView {
            AnyView(
                content()
                    .frame(maxWidth: host.contentMaxWidth, alignment: .leading)
                    .padding(.horizontal, 28 + ACPMessageGutterLayout.laneWidth)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .environment(\.theme, host.theme)
                    .environment(\.openURL, host.openTranscriptURLAction)
            )
        }

        /// Folds `host.theme` into an equality token so a live theme switch
        /// forces every mounted row to rebuild — and thus re-run `wrapRow`'s
        /// `.environment(\.theme, host.theme)` with the NEW value — instead
        /// of leaving already-mounted rows on the old palette until some
        /// other part of their content happens to change. `wrapRow` bakes
        /// `host.theme` into the built view at construction time; without
        /// this, `ACPTranscriptRowHostingPool.view(for:)` only rebuilds a
        /// row when its token changes, so a bare theme switch (no other
        /// content change) would never be observed by already-mounted rows.
        private static func token<T: Equatable>(_ base: T, host: ACPTranscriptScroller) -> ACPRowEqualityToken {
            ACPRowEqualityToken(ThemedToken(theme: host.theme, base: base))
        }

        private struct ThemedToken<Base: Equatable>: Equatable {
            let theme: Theme
            let base: Base
        }

        /// Message rows from the render window + synthetic tail rows, in the
        /// same order the legacy VStack rendered them.
        static func rowSpecs(host: ACPTranscriptScroller) -> [ACPTranscriptRowSpec] {
            let transcript = host.transcript
            var specs: [ACPTranscriptRowSpec] = []

            if transcript.isBackfillingOlderMessages || transcript.visibleHead > 0 {
                specs.append(ACPTranscriptRowSpec(
                    id: "__top_pagination__",
                    equalityToken: token(transcript.isBackfillingOlderMessages, host: host),
                    build: {
                        wrapRow(host: host) {
                            Spinner(lineWidth: 1.5)
                                .frame(width: 14, height: 14)
                                .frame(maxWidth: .infinity, alignment: .center)
                                .opacity(transcript.isBackfillingOlderMessages ? 1 : 0)
                        }
                    }
                ))
            }

            let rows = ACPMessageList.visibleRows(
                messages: transcript.messages,
                visibleHead: transcript.visibleHead,
                visibleTail: transcript.visibleTailBound,
                stableId: { transcript.stableId(for: $0) }
            )
            for row in rows where transcript.messages.indices.contains(row.index) {
                let message = transcript.messages[row.index]
                let rowToken = token(ACPTranscriptRowContent.equalityKey(
                    stableId: row.stableId, message: message,
                    contentMaxWidth: host.contentMaxWidth, typography: host.typography,
                    trustedImageRoot: host.trustedImageRoot,
                    isForkEligible: host.session.canForkMessage(at: row.index),
                    forkTargets: host.forkTargets
                ), host: host)
                specs.append(ACPTranscriptRowSpec(
                    id: row.stableId,
                    equalityToken: rowToken,
                    build: { wrapRow(host: host) { Self.messageRow(host: host, row: row, message: message) } }
                ))
                // Fork divider follows its boundary row, as in the legacy list.
                if let fork = host.session.forkRecord,
                   fork.phase == .ready,
                   row.index == fork.inheritedMessageCount - 1,
                   fork.mechanism != nil {
                    specs.append(Self.forkDividerSpec(host: host, fork: fork))
                }
            }

            specs.append(contentsOf: Self.syntheticTailSpecs(host: host))
            return specs
        }

        static func messageRow(
            host: ACPTranscriptScroller,
            row: ACPMessageList.VisibleRow,
            message: ACPMessage
        ) -> some View {
            ACPTranscriptRowContent(
                stableId: row.stableId,
                messageIndex: row.index,
                message: message,
                contentMaxWidth: host.contentMaxWidth,
                typography: host.typography,
                trustedImageRoot: host.trustedImageRoot,
                transcript: host.transcript,
                session: host.session,
                onOpenDiff: host.onOpenDiff,
                onLoadFullToolCallContent: host.onLoadFullToolCallContent,
                isForkEligible: host.session.canForkMessage(at: row.index),
                forkTargets: host.forkTargets,
                onFork: host.onFork
            )
            // Column framing (max width / horizontal padding / centering)
            // is applied uniformly to every row by `wrapRow`, not here —
            // see its doc comment.
        }

        /// Verbatim port of the fork divider inserted right after the fork
        /// boundary row in the legacy VStack (ACPMessageList.swift:179-191).
        static func forkDividerSpec(
            host: ACPTranscriptScroller,
            fork: ACPSessionForkRecord
        ) -> ACPTranscriptRowSpec {
            ACPTranscriptRowSpec(
                id: "__fork_divider__",
                equalityToken: token(fork, host: host),
                build: {
                    wrapRow(host: host) {
                        Group {
                            if let mechanism = fork.mechanism {
                                ACPSessionForkDivider(
                                    presentation: .init(
                                        sourceAgentName: host.agentDisplayName(fork.sourceAgentID),
                                        mechanism: mechanism
                                    ),
                                    onOpenSource: { host.onOpenForkSource(fork.sourceSessionID) }
                                )
                            }
                        }
                    }
                }
            )
        }

        /// Verbatim ports of the trailing elements of the legacy VStack
        /// (ACPMessageList.swift:199-265): pending permission prompt,
        /// pending user-input prompt, URL-elicitation waits, streaming
        /// caret, queue header, queued bubbles, context-recovery row, and
        /// the invisible composer spacer. Same ids the legacy list used.
        /// Equality tokens carry the same values `scrollSignature` hashed
        /// for each element.
        static func syntheticTailSpecs(host: ACPTranscriptScroller) -> [ACPTranscriptRowSpec] {
            let transcript = host.transcript
            let session = host.session
            var specs: [ACPTranscriptRowSpec] = []

            if transcript.pendingPermission != nil, let policy = host.policy {
                let pendingPermission = transcript.pendingPermission
                specs.append(ACPTranscriptRowSpec(
                    id: "__pending_perm__",
                    equalityToken: token(pendingPermission, host: host),
                    build: {
                        wrapRow(host: host) {
                            ACPPermissionPrompt(session: session, policy: policy, scopeKey: host.scopeKey)
                        }
                    }
                ))
            }

            if let request = transcript.pendingUserInputs.first {
                specs.append(ACPTranscriptRowSpec(
                    id: "__pending_user_input_\(request.id)",
                    equalityToken: token(request.id, host: host),
                    build: {
                        wrapRow(host: host) {
                            ACPUserInputPrompt(
                                request: request,
                                onRespond: host.onUserInputResponse,
                                onOpenURL: host.onOpenElicitationURL
                            )
                        }
                    }
                ))
            }

            for wait in transcript.urlElicitationWaits {
                specs.append(ACPTranscriptRowSpec(
                    id: "__elicitation_wait_\(wait.id)",
                    equalityToken: token(wait, host: host),
                    build: {
                        wrapRow(host: host) {
                            ACPURLElicitationWaitView(
                                wait: wait,
                                onOpenAgain: { NSWorkspace.shared.open($0) },
                                onDismiss: host.onDismissElicitationURLWait
                            )
                        }
                    }
                ))
            }

            if transcript.streamingState == .streaming {
                specs.append(ACPTranscriptRowSpec(
                    id: "__streaming_caret__",
                    equalityToken: token(transcript.streamingState, host: host),
                    build: {
                        wrapRow(host: host) {
                            StreamingCaret().frame(width: 8, height: 14)
                        }
                    }
                ))
            }

            let queueHeaderCount = ACPMessageList.queueHeaderCount(statuses: session.queue.map(\.status))
            if queueHeaderCount > 1 {
                specs.append(ACPTranscriptRowSpec(
                    id: "__queue_header__",
                    equalityToken: token(queueHeaderCount, host: host),
                    build: {
                        wrapRow(host: host) {
                            ACPQueueHeader(count: queueHeaderCount, onClear: host.onQueueClearAll)
                        }
                    }
                ))
            }

            for (idx, item) in session.queue.enumerated()
            where ACPMessageList.shouldRenderQueueBubble(status: item.status) {
                specs.append(ACPTranscriptRowSpec(
                    id: "__queue_\(item.id)",
                    equalityToken: token(item, host: host),
                    build: {
                        wrapRow(host: host) {
                            ACPQueuedBubble(
                                item: item,
                                contentMaxWidth: host.contentMaxWidth,
                                typography: host.typography,
                                onForceSend: { host.onQueueForceSend(item.id) },
                                onEdit: { host.onQueueEdit(item) },
                                onRemove: { host.onQueueRemove(item.id) },
                                onRetry: { host.onQueueRetry(item.id) }
                            )
                            .dropDestination(for: String.self) { items, _ in
                                guard let s = items.first,
                                      let uuid = UUID(uuidString: s),
                                      let src = session.queue.firstIndex(where: { $0.id == uuid })
                                else { return false }
                                guard ACPMessageList.canDropQueuedItem(
                                    sourceStatus: session.queue[src].status,
                                    targetStatus: item.status
                                ) else { return false }
                                host.onQueueReorder(src, idx)
                                return true
                            }
                        }
                    }
                ))
            }

            if let status = session.contextRecoveryStatus {
                specs.append(ACPTranscriptRowSpec(
                    id: "__context_recovery__",
                    equalityToken: token(status, host: host),
                    build: {
                        wrapRow(host: host) {
                            ContextRecoveryRow(status: status, onRetry: host.onRetryContextRecovery)
                        }
                    }
                ))
            }

            // Invisible tail spacer the tail-follow scroll pins to the
            // viewport bottom; guarantees the streaming caret / last
            // message sits above the composer pill. Its content is a
            // fixed-height `Color.clear` that reads neither theme nor
            // openURL, so — unlike every other row — a constant equality
            // token is correct here: nothing about it ever needs to rebuild.
            // Still routed through `wrapRow` for the same column framing
            // every other row gets, matching the legacy VStack where this
            // spacer was a plain child of the same constrained stack.
            specs.append(ACPTranscriptRowSpec(
                id: "__composer_spacer__",
                equalityToken: ACPRowEqualityToken(true),
                build: {
                    wrapRow(host: host) {
                        Color.clear.frame(height: composerSpacerHeight)
                    }
                }
            ))

            return specs
        }

        // MARK: scroll handling

        private func handleScroll(
            previousY: CGFloat?, newY: CGFloat,
            viewportHeight: CGFloat, contentHeight: CGFloat,
            isProgrammatic: Bool
        ) {
            guard let host, let scroller, let reconciler else { return }
            // `apply()` issues its own programmatic scrolls synchronously
            // (`applyPrepend`, `scrollToBottom`) while `specsById`/
            // `orderedIds` are mid-mutation; running a layout pass here
            // against that stale state would mount views from the previous
            // update instead of the one `apply()` is still installing.
            // `apply()`'s own trailing `layoutMountedRows()` call covers
            // this once it's safe — see `isApplyingSpecs`'s doc comment.
            // Other programmatic scrolls that happen OUTSIDE of `apply()`
            // (`resumeTailFollow`, `restoreInitialPositionIfNeeded`) are not
            // covered by that trailing call, so they invoke
            // `layoutMountedRows()` explicitly themselves.
            if !reconciler.isApplyingSpecs {
                reconciler.layoutMountedRows()
            }
            guard !isProgrammatic else { return }

            let event = NSApp.currentEvent
            let eventIsFresh = ACPUserScrollEvent.isFresh(
                eventTimestamp: event?.timestamp,
                now: ProcessInfo.processInfo.systemUptime
            )
            let isUserDriven = eventIsFresh && ACPUserScrollEvent.isUserDriven(event?.type)

            let decision = ACPScrollDirectionClassifier.decide(
                previousOffsetY: previousY,
                newOffsetY: newY,
                viewportHeight: viewportHeight,
                contentHeight: contentHeight,
                isRestoring: false,
                isUserDriven: isUserDriven
            )
            switch decision {
            case .userScrolledUp:
                pauseTailFollow()
            case .userAtBottom:
                if host.transcript.visibleTailBound >= host.transcript.messages.count {
                    resumeTailFollow()
                }
            case .noChange:
                break
            }

            let threshold = ACPTranscriptScroller.headStepThreshold(viewportHeight: viewportHeight)
            if ACPTranscriptScroller.shouldStepHeadBack(
                visibleHead: host.transcript.visibleHead,
                scrollY: newY, isUserDriven: isUserDriven, threshold: threshold
            ) {
                host.transcript.stepHeadBack(boundTail: false)
                // SwiftUI observes visibleHead; updateNSView re-runs and the
                // reconciler prepends with compensation in that same pass.
            }
            if ACPTranscriptScroller.shouldStepTailForward(
                visibleTail: host.transcript.visibleTailBound,
                messageCount: host.transcript.messages.count,
                distanceFromBottom: scroller.distanceFromBottom,
                isUserDriven: isUserDriven, threshold: threshold
            ) {
                host.transcript.stepTailForward(preserving: nil, boundHead: false)
            }

            if !host.session.followsTranscriptTail {
                rememberCurrentAnchor()
            }
        }

        private func pauseTailFollow() {
            guard let host, host.session.followsTranscriptTail else { return }
            host.session.followsTranscriptTail = false
            host.transcript.freezeVisibleTail()
            rememberCurrentAnchor()
        }

        private func resumeTailFollow() {
            guard let host, !host.session.followsTranscriptTail else { return }
            host.session.followsTranscriptTail = true
            host.transcript.resetWindowToTail()
            host.onRememberScrollAnchor(nil, nil, true)
            scroller?.scrollToBottom()
        }

        private func rememberCurrentAnchor() {
            guard let host, let scroller else { return }
            guard let anchorId = tiling.topVisibleRowId(viewportMinY: scroller.scrollY),
                  !anchorId.hasPrefix("__")   // synthetic rows are not anchors
            else { return }
            let rows = ACPMessageList.visibleRows(
                messages: host.transcript.messages,
                visibleHead: host.transcript.visibleHead,
                visibleTail: host.transcript.visibleTailBound,
                stableId: { host.transcript.stableId(for: $0) }
            )
            let index = rows.first(where: { $0.stableId == anchorId })?.index
            host.onRememberScrollAnchor(anchorId, index, false)
        }

        /// Runs once per Coordinator lifetime, but only actually latches
        /// (`didRestoreInitialPosition = true`) once the outcome is
        /// definite. `__composer_spacer__` and other synthetic rows are
        /// unconditionally present in `rowSpecs`, so `tiling.rowCount > 0`
        /// alone is true on the very first `apply()` even with zero
        /// messages — gating on `hasNonSyntheticRow` instead avoids latching
        /// before there's any real content to restore a position within.
        /// Beyond that: tail-follow and "no remembered anchor" are definite
        /// outcomes (latch immediately); a remembered anchor that isn't yet
        /// in the tiling map (e.g. the render window hasn't reached it yet)
        /// is NOT definite — don't latch, so the next `update(host:)` (which
        /// runs on every relevant transcript/session change, mirroring the
        /// legacy path's retries on appear / viewport change / scroll
        /// signature / visibleHead) gets another chance to resolve it,
        /// instead of permanently falling back to `scrollToBottom()`.
        private func restoreInitialPositionIfNeeded() {
            guard !didRestoreInitialPosition, let host, let scroller,
                  hasNonSyntheticRow
            else { return }
            if host.session.followsTranscriptTail {
                didRestoreInitialPosition = true
                scroller.scrollToBottom()
                return
            }
            guard let anchor = host.rememberedScrollAnchor() else {
                // Nothing to restore — this is a definite final state.
                didRestoreInitialPosition = true
                scroller.scrollToBottom()
                return
            }
            guard let row = tiling.row(withId: anchor) else {
                // Anchor exists but isn't resolvable yet; retry later
                // instead of latching onto a wrong fallback.
                return
            }
            didRestoreInitialPosition = true
            scroller.setScrollY(row.minY)
        }
    }
}

extension ACPTranscriptScroller {
    nonisolated static func headStepThreshold(viewportHeight: CGFloat) -> CGFloat {
        max(1500, viewportHeight * 2)
    }

    nonisolated static func shouldStepHeadBack(
        visibleHead: Int, scrollY: CGFloat, isUserDriven: Bool, threshold: CGFloat
    ) -> Bool {
        visibleHead > 0 && isUserDriven && scrollY < threshold
    }

    nonisolated static func shouldStepTailForward(
        visibleTail: Int, messageCount: Int, distanceFromBottom: CGFloat,
        isUserDriven: Bool, threshold: CGFloat
    ) -> Bool {
        visibleTail < messageCount && isUserDriven && distanceFromBottom < threshold
    }
}

// MARK: - Synthetic row content

/// Verbatim port of `ACPMessageList.StreamingCaret` (private to that file).
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

/// Verbatim port of `ACPMessageList.contextRecoveryRow(_:)` +
/// `contextRecoveryText(_:)` (private to that file).
private struct ContextRecoveryRow: View {
    let status: ACPSession.ContextRecoveryStatus
    let onRetry: () -> Void
    @Environment(\.theme) private var theme

    var body: some View {
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

            Text(Self.text(for: status))
                .font(.system(size: 12))
                .foregroundStyle(theme.color("fg-muted"))

            if case .failed = status {
                Button("Retry") {
                    onRetry()
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

    private static func text(for status: ACPSession.ContextRecoveryStatus) -> String {
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
}
