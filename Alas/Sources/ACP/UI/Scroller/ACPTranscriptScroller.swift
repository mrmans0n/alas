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
        /// Set when a head step has been requested and cleared by the next
        /// `update(host:)`. See `handleScroll`'s head-step block.
        private var pendingHeadStep = false
        /// Global message index selected by a logical scrollbar release that
        /// still lies in tail-first hydration's unmaterialized prefix.
        private var pendingLogicalTargetGlobalIndex: Int?
        /// Stable id to align at the viewport top after its bounded window
        /// has been reconciled into the AppKit tiling map.
        private var pendingLogicalTargetId: String?
        private var isPendingLogicalResolutionScheduled = false
        /// Memoizes the window-sliced row list + its id → message-index
        /// lookup, keyed on (messages generation, window bounds) — the same
        /// cache the legacy list uses. `rememberCurrentAnchor` runs on every
        /// non-programmatic scroll tick while browsing history, i.e. at
        /// display refresh rate over a window that can hold thousands of
        /// rows; rebuilding that array per tick just to map one anchor id to
        /// its message index is O(window) work in exactly the state where
        /// scrolling must stay smooth.
        private let visibleRowsCache = ACPVisibleRowsCache()

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
            scroller.onContentWidthChange = { [weak self] in
                self?.reconcileForContentWidthChange()
            }
            scroller.onViewportHeightChange = { [weak self] in
                self?.reconcileForViewportHeightChange()
            }
            scroller.onLogicalScrollCommit = { [weak self] value in
                self?.commitLogicalScroll(value: value)
            }
            update(host: host)
        }

        /// Re-runs `update(host:)` against the retained host when the
        /// scroller's own AppKit layout pass reports a content-width change
        /// with no accompanying SwiftUI model update — see
        /// `ACPTranscriptScrollerView.onContentWidthChange`'s doc comment.
        /// This closes the gap where `attach()`'s first `update(host:)`
        /// always runs at `contentWidth == 0` (the scroller starts at
        /// `frame: .zero`), which `reconciler.apply` defers on: without
        /// this, a fully hydrated but otherwise idle transcript could stay
        /// empty until some UNRELATED SwiftUI update happened to call
        /// `updateNSView` again. The same gap could also leave row
        /// measurements stale after a resize with no model update.
        ///
        /// Guarded by `reconciler.isApplyingSpecs`, which is true for the
        /// ENTIRE duration of `apply()` — every mutation it makes (document
        /// height, prepend/removal offset compensation, and the per-row
        /// `addSubview`/`.frame` assignments `layoutMountedRows()` performs
        /// while mounting rows) is covered, not just the scroller's own
        /// programmatic scroll/height adjustments (`performProgrammatic`'s
        /// narrower `programmaticAdjustmentDepth`, which only brackets
        /// `setScrollY`/`setDocumentHeight`/`applyPrepend`). If any of
        /// `apply()`'s mutations were to re-trigger AppKit's layout pass on
        /// the scroll view itself, the reentrant call would land here
        /// mid-`apply()`, before `orderedIds`/`specsById` finish being
        /// rewritten — recursing into `update(host:)` at that point would
        /// call `apply()` again against inconsistent reconciler state.
        /// `isApplyingSpecs` is therefore the guard that matters here, not
        /// the scroller's programmatic-adjustment counter (which doesn't
        /// span the whole call and so wouldn't catch a layout storm
        /// triggered by the row-mounting mutations specifically).
        ///
        /// In practice `ACPTranscriptScrollerView.setFrameSize` only marks
        /// `needsLayout` when the SCROLL VIEW's own outer frame changes —
        /// `apply()`'s mutations only ever touch the document view's frame
        /// and its row subviews, several levels down, which does not bubble
        /// `needsLayout` back up in this plain (non-Auto-Layout) view tree —
        /// so this reentrant path is not expected to fire under normal
        /// (overlay-scroller) conditions. The guard exists to make that
        /// true by construction rather than by accident of AppKit's
        /// internals, and covers even a legacy (non-overlay) scroller style
        /// where showing/hiding the vertical scroller in response to a
        /// document-height change could, in principle, force a width
        /// recompute.
        private func reconcileForContentWidthChange() {
            guard let host, let reconciler, !reconciler.isApplyingSpecs else { return }
            update(host: host)
        }

        /// Re-runs the reconciler's mount/relayout pass — NOT a full
        /// `update(host:)` — when the scroller's own AppKit layout pass
        /// reports a viewport-HEIGHT change with no accompanying width
        /// change; see `ACPTranscriptScrollerView.onViewportHeightChange`'s
        /// doc comment for why the scroller only fires this hook on a
        /// height-only change.
        ///
        /// This is deliberately the cheap response, unlike
        /// `reconcileForContentWidthChange`: the mount band
        /// (`ACPTranscriptScrollerReconciler.performLayoutPass`) is derived
        /// from `scroller.viewportHeight`, so growing or shrinking the
        /// window without a width change reveals or hides mountable rows
        /// that nothing else would recompute — but a height change never
        /// invalidates any row's MEASURED content (nothing reflows
        /// vertically because the viewport got taller or shorter). Routing
        /// this through `update(host:)`/`reconciler.apply` instead would
        /// rebuild the whole row-spec list and re-run the (cheap but O(n))
        /// unchanged-token diff on every vertical resize tick — exactly the
        /// per-tick cost the width-settle debounce exists to keep off of
        /// live resizes, just for the wrong dimension.
        ///
        /// Guarded by `reconciler.isApplyingSpecs` for the same reason
        /// `reconcileForContentWidthChange` is: it spans the ENTIRE
        /// `apply()` call, including the row-mounting mutations
        /// `layoutMountedRows()` itself performs, whereas the scroller's own
        /// `programmaticAdjustmentDepth` only brackets its narrower
        /// scroll/height primitives (see `reconcileForContentWidthChange`'s
        /// doc comment for the full argument).
        private func reconcileForViewportHeightChange() {
            guard let reconciler, !reconciler.isApplyingSpecs else { return }
            // Re-tiling alone is not enough while following the tail. A
            // height-only resize leaves `contentHeight` untouched but moves
            // the maximum legal offset: shrinking the viewport pushes the
            // bottom further down, so the unchanged `scrollY` stays legal
            // while no longer sitting at the end. Without this the newest
            // content drifts below the viewport, with tail-follow still
            // reporting true, until some unrelated model update calls
            // `apply()` and re-pins as a side effect. The legacy path's
            // height-change handler scrolls to the tail for the same reason.
            if reconciler.followsTail {
                scroller?.scrollToBottom()
            }
            reconciler.layoutMountedRows()
            syncLogicalScrollerMetrics()
        }

        func update(host: ACPTranscriptScroller) {
            self.host = host
            schedulePendingLogicalTargetResolutionIfPossible()
            // Re-apply unconditionally: `reconciler.apply` itself early-
            // returns and records nothing for a non-positive width (host
            // view not yet laid out), so skipping this call based on any
            // "already applied" memo would leave the transcript permanently
            // empty once a real width does arrive.
            guard let reconciler, let scroller else { return }
            let specs = Self.rowSpecs(host: host)
            hasNonSyntheticRow = specs.contains {
                !$0.id.hasPrefix(ACPTranscriptScrollerReconciler.syntheticIdPrefix)
            }
            reconciler.apply(
                specs: specs,
                contentWidth: scroller.contentView.bounds.width,
                followsTail: host.session.followsTranscriptTail
            )
            // This update carries whatever `visibleHead` currently is, so a
            // head step requested since the last one has now been applied
            // (or, at width 0, will be re-requested by the next scroll tick).
            pendingHeadStep = false
            restoreInitialPositionIfNeeded()
            alignPendingLogicalTargetIfPossible()
            syncLogicalScrollerMetrics()
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

        /// Folds `host.theme` and `host.contentMaxWidth` into an equality
        /// token so a live theme switch or column-width change forces every
        /// mounted row to rebuild — and thus re-run `wrapRow`'s
        /// `.environment(\.theme, host.theme)` and `.frame(maxWidth:
        /// host.contentMaxWidth, ...)` with the NEW values — instead of
        /// leaving already-mounted rows on the old palette/width until some
        /// other part of their content happens to change. `wrapRow` bakes
        /// both values into the built view at construction time for EVERY
        /// row that goes through it (every synthetic spec below, plus
        /// message rows); without this, `ACPTranscriptRowHostingPool.view(
        /// for:)` only rebuilds a row when its token changes, so a bare
        /// theme switch or window resize (no other content change) would
        /// never be observed by already-mounted rows. Message rows already
        /// fold `contentMaxWidth` a second time via `equalityKey`'s own
        /// field — harmless duplication, not a correctness issue.
        /// `host.typography` is deliberately NOT folded in here: unlike
        /// `contentMaxWidth`, `wrapRow` never reads it, and most synthetic
        /// rows below never capture it either, so folding it generically
        /// would rebuild rows that don't use it on every typography change.
        /// Specs whose build closures do capture it (the queue bubble) fold
        /// it into their own token explicitly instead.
        private static func token<T: Equatable>(_ base: T, host: ACPTranscriptScroller) -> ACPRowEqualityToken {
            ACPRowEqualityToken(ThemedToken(theme: host.theme, contentMaxWidth: host.contentMaxWidth, base: base))
        }

        private struct ThemedToken<Base: Equatable>: Equatable {
            let theme: Theme
            let contentMaxWidth: CGFloat
            let base: Base
        }

        /// See the queue-bubble spec below: folds the rendering/behavior
        /// inputs its build closure captures beyond what `token(_:host:)`
        /// already covers generically (theme, contentMaxWidth).
        private struct QueueBubbleTokenInputs: Equatable {
            let item: QueuedPrompt
            let idx: Int
            let typography: ACPChatTypography
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

        /// Beyond `fork` (and theme/contentMaxWidth folded by
        /// `token(_:host:)`), the fork divider's build closure also derives
        /// `sourceAgentName` by CALLING `host.agentDisplayName(fork
        /// .sourceAgentID)` — a resolved `String`, not the closure itself,
        /// baked into the built view at construction time. Unlike a direct
        /// host property (`contentMaxWidth`, `typography`), this value isn't
        /// anywhere in `fork` or `host`'s stored properties for `token(_:
        /// host:)` to pick up automatically: a live rename of the source
        /// agent's display name — with the `fork` record and every other
        /// input unchanged — must still be folded in explicitly, or the
        /// pool's token comparison stays equal and an already-mounted
        /// divider keeps showing the stale name forever.
        private struct ForkDividerTokenInputs: Equatable {
            let fork: ACPSessionForkRecord
            let sourceAgentDisplayName: String
        }

        /// Verbatim port of the fork divider inserted right after the fork
        /// boundary row in the legacy VStack (ACPMessageList.swift:179-191).
        static func forkDividerSpec(
            host: ACPTranscriptScroller,
            fork: ACPSessionForkRecord
        ) -> ACPTranscriptRowSpec {
            ACPTranscriptRowSpec(
                id: "__fork_divider__",
                equalityToken: token(
                    ForkDividerTokenInputs(
                        fork: fork,
                        sourceAgentDisplayName: host.agentDisplayName(fork.sourceAgentID)
                    ),
                    host: host
                ),
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
                    },
                    // `ACPUserInputPrompt` holds live `@State`/`@FocusState`
                    // form data (see `ACPTranscriptRowSpec.keepsMountedOffscreen`).
                    // Scrolling this prompt out of the mount band must not
                    // destroy its hosting view — that would silently discard
                    // whatever the user has already typed.
                    keepsMountedOffscreen: true
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
                    // Beyond `item` (and theme/contentMaxWidth folded by
                    // `token(_:host:)`), this row's build closure also
                    // captures `host.typography` (passed straight into
                    // `ACPQueuedBubble`) and `idx` (captured by the
                    // `.dropDestination` handler below as the reorder
                    // target). Both must be in the token: a typography
                    // change would otherwise leave the mounted bubble
                    // measured with stale text metrics, and a stale `idx`
                    // after the queue reorders would send a subsequent drag
                    // on this retained bubble to the wrong slot.
                    equalityToken: token(
                        QueueBubbleTokenInputs(item: item, idx: idx, typography: host.typography),
                        host: host
                    ),
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
            // covered by that trailing call, but `isApplyingSpecs` is false
            // at those sites too, so this same guard still lets their
            // `onScroll` callback run `layoutMountedRows()` normally — no
            // explicit call is needed at either site.
            guard !isProgrammatic else {
                if !reconciler.isApplyingSpecs {
                    reconciler.layoutMountedRows()
                }
                syncLogicalScrollerMetrics()
                return
            }

            // A wheel/trackpad move after a logical release is newer user
            // intent. Do not let a queued jump into not-yet-materialized
            // history revive when a later backfill makes its target
            // available and teleport the viewport away from this position.
            pendingLogicalTargetGlobalIndex = nil
            pendingLogicalTargetId = nil

            // This tick is the user moving the viewport, not us. Two things
            // follow from that: a row that vanished from an earlier update is
            // no longer worth restoring to if it comes back (see
            // `PendingAnchorRestore`), and an update landing in the next
            // moment must not re-pin the tail out from under the gesture (see
            // `repinsToTail(followsTail:wasFollowingTail:)`).
            reconciler.invalidatePendingAnchorRestore()
            reconciler.noteUserScroll()

            let event = NSApp.currentEvent
            let eventIsFresh = ACPUserScrollEvent.isFresh(
                eventTimestamp: event?.timestamp,
                now: ProcessInfo.processInfo.systemUptime
            )
            let currentEventType = eventIsFresh ? event?.type : nil
            // Classifies whether to PAUSE tail-follow, and nothing else — the
            // pagination decisions below are geometric (see
            // `shouldStepHeadBack`). Mirrors
            // `ACPMessageList.handleScrollGeometry`: a click on the scrollbar
            // track arrives as a plain `.leftMouseDown`, which
            // `ACPUserScrollEvent.isUserDriven` alone rejects (a bare click
            // can't be told apart from clicking a transcript control by event
            // type). Widen to `isHeadPaginationDriven`, which additionally
            // accepts that click when it actually hit the scrollbar track AND
            // the geometry genuinely moved upward, so a track click pauses
            // tail-follow the same as a trackpad gesture or scroller-knob
            // drag would — without misclassifying clicks on transcript
            // controls (which aren't scrollbar hits) as scrolling.
            //
            // `scroller.isUserScrollActive` is what makes this reachable at
            // all. The event-based test alone answers false for ~97-99% of
            // scroll ticks under responsive scrolling (the same measurement
            // `shouldStepHeadBack` documents), so the pause it gates almost
            // never fired: a reader who scrolled up out of the tail kept
            // `followsTranscriptTail` set, and once their gesture ended —
            // and with it the suppression window in
            // `ACPTranscriptScrollerReconciler.repinsToTail` — the next
            // update pinned them straight back to the bottom. The scroll
            // view's own live-scroll notifications are posted only for
            // genuine user scrolling and never for a programmatic
            // `setBoundsOrigin`, so they identify the gesture where the event
            // stream cannot. The event test is kept alongside because it
            // additionally covers input that never opens a live-scroll
            // session (a scrollbar-track click, magnify, swipe).
            let isHeadPaginationDriven = scroller.isUserScrollActive
                || ACPUserScrollEvent.isHeadPaginationDriven(
                    currentEventType,
                    previousMinY: previousY,
                    newMinY: newY,
                    isScrollbarTrackHit: ACPUserScrollEvent.isScrollbarTrackMouseDown(eventIsFresh ? event : nil)
                )

            let decision = ACPScrollDirectionClassifier.decide(
                previousOffsetY: previousY,
                newOffsetY: newY,
                viewportHeight: viewportHeight,
                contentHeight: contentHeight,
                isRestoring: false,
                isUserDriven: isHeadPaginationDriven
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

            // Deliberately after the classification above. Mounting a newly
            // exposed row can synchronously invalidate its intrinsic size,
            // which lands in `remeasureRow` and re-pins to the bottom while
            // the reconciler still believes tail-follow is on. Pausing
            // first means that belief is already correct by the time any
            // row is mounted.
            if !reconciler.isApplyingSpecs {
                reconciler.layoutMountedRows()
            }

            let threshold = ACPTranscriptScroller.headStepThreshold(viewportHeight: viewportHeight)
            if ACPTranscriptScroller.shouldStepHeadBack(
                visibleHead: host.transcript.visibleHead,
                scrollY: newY, threshold: threshold,
                hasPendingHeadStep: pendingHeadStep
            ) {
                // `stepHeadBack` mutates `visibleHead` synchronously, but the
                // rows it exposes — and the compensating prepend that keeps
                // them from shoving the reading position down — only arrive
                // on the NEXT SwiftUI update. Until then every scroll tick
                // still sees a positive `visibleHead` and a `scrollY` under
                // threshold, so without this latch one flick near the head
                // queues several steps that land together as a single
                // 60-150 row insertion measured in one synchronous pass.
                pendingHeadStep = true
                host.transcript.stepHeadBack()
            }
            if ACPTranscriptScroller.shouldStepTailForward(
                visibleTail: host.transcript.visibleTailBound,
                messageCount: host.transcript.messages.count,
                distanceFromBottom: scroller.distanceFromBottom,
                threshold: threshold,
                previousScrollY: previousY, newScrollY: newY
            ) {
                host.transcript.stepTailForward(preserving: nil)
            }

            if !host.session.followsTranscriptTail {
                rememberCurrentAnchor()
            }
            syncLogicalScrollerMetrics()
        }

        private func commitLogicalScroll(value: Double) {
            guard let host, let scroller, host.transcript.logicalMessageCount > 0 else { return }
            if value >= 1 - Double.ulpOfOne {
                pendingLogicalTargetGlobalIndex = nil
                pendingLogicalTargetId = nil
                host.session.followsTranscriptTail = true
                reconciler?.setFollowsTail(true)
                host.transcript.resetWindowToTail()
                host.onRememberScrollAnchor(nil, nil, true)
                update(host: host)
                scroller.scrollToBottom()
                syncLogicalScrollerMetrics()
                return
            }

            if host.session.followsTranscriptTail {
                pauseTailFollow()
            } else {
                reconciler?.setFollowsTail(false)
                host.transcript.freezeVisibleTail()
            }
            let target = ACPTranscriptLogicalScrollModel.targetGlobalIndex(
                value: value,
                totalCount: host.transcript.logicalMessageCount,
                viewportHeight: scroller.viewportHeight
            )
            pendingLogicalTargetGlobalIndex = target
            if resolvePendingLogicalTargetIfPossible() {
                update(host: host)
            } else {
                syncLogicalScrollerMetrics()
            }
        }

        /// Returns true when the pending global target is materialized and a
        /// bounded local window has been selected for the next reconcile.
        @discardableResult
        private func resolvePendingLogicalTargetIfPossible() -> Bool {
            guard let host, let target = pendingLogicalTargetGlobalIndex else { return false }
            let count = host.transcript.logicalMessageCount
            guard count > 0 else {
                pendingLogicalTargetGlobalIndex = nil
                return false
            }
            let clampedTarget = min(max(0, target), count - 1)
            pendingLogicalTargetGlobalIndex = clampedTarget
            guard let localIndex = host.transcript.localIndex(forGlobalIndex: clampedTarget) else {
                return false
            }
            pendingLogicalTargetGlobalIndex = nil
            pendingLogicalTargetId = host.transcript.stableId(
                for: host.transcript.messages[localIndex]
            )
            host.transcript.setVisibleWindow(around: localIndex)
            return true
        }

        /// `update(host:)` is called from `updateNSView`; selecting a new
        /// published render window synchronously inside that boundary would
        /// mutate SwiftUI-observed state during view reconciliation. Once
        /// backfill makes a queued target available, resolve it on the next
        /// main-actor turn instead.
        private func schedulePendingLogicalTargetResolutionIfPossible() {
            guard !isPendingLogicalResolutionScheduled,
                  let host,
                  let target = pendingLogicalTargetGlobalIndex,
                  host.transcript.localIndex(forGlobalIndex: target) != nil
            else { return }
            isPendingLogicalResolutionScheduled = true
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.isPendingLogicalResolutionScheduled = false
                guard let host = self.host,
                      self.resolvePendingLogicalTargetIfPossible()
                else { return }
                self.update(host: host)
            }
        }

        private func alignPendingLogicalTargetIfPossible() {
            guard let id = pendingLogicalTargetId,
                  let row = tiling.row(withId: id),
                  let scroller
            else { return }
            scroller.setScrollY(row.minY)
            pendingLogicalTargetId = nil
            rememberCurrentAnchor()
        }

        private func syncLogicalScrollerMetrics() {
            guard let host, let scroller else { return }
            let topGlobalIndex = pendingLogicalTargetGlobalIndex
                ?? currentTopGlobalMessageIndex()
                ?? host.transcript.globalIndex(forLocalIndex: host.transcript.visibleHead)
                ?? 0
            scroller.setLogicalScrollerMetrics(ACPTranscriptLogicalScrollModel.metrics(
                totalCount: host.transcript.logicalMessageCount,
                viewportHeight: scroller.viewportHeight,
                topGlobalIndex: topGlobalIndex,
                isAtTail: host.session.followsTranscriptTail
            ))
        }

        private func currentTopGlobalMessageIndex() -> Int? {
            guard let host, let scroller,
                  let anchorId = tiling.nearestNonSyntheticRowId(
                      to: scroller.scrollY,
                      syntheticIdPrefix: ACPTranscriptScrollerReconciler.syntheticIdPrefix
                  )
            else { return nil }
            let lookup = visibleRowsCache.lookup(
                generation: host.transcript.messagesGeneration,
                head: host.transcript.visibleHead,
                tail: host.transcript.visibleTailBound,
                build: {
                    ACPMessageList.visibleRows(
                        messages: host.transcript.messages,
                        visibleHead: host.transcript.visibleHead,
                        visibleTail: host.transcript.visibleTailBound,
                        stableId: { host.transcript.stableId(for: $0) }
                    )
                }
            )
            guard let localIndex = lookup.transcriptIndex(for: anchorId) else { return nil }
            return host.transcript.globalIndex(forLocalIndex: localIndex)
        }

        private func pauseTailFollow() {
            guard let host, host.session.followsTranscriptTail else { return }
            host.session.followsTranscriptTail = false
            // Mirror the pause into the reconciler now rather than waiting
            // for the `apply()` one update later. Between those two points
            // the scroll handler mounts newly exposed rows, and a row whose
            // intrinsic size invalidates on mount would otherwise re-pin
            // this user to the bottom — see `remeasureRow`'s doc comment.
            reconciler?.setFollowsTail(false)
            host.transcript.freezeVisibleTail()
            rememberCurrentAnchor()
        }

        private func resumeTailFollow() {
            guard let host, !host.session.followsTranscriptTail else { return }
            host.session.followsTranscriptTail = true
            reconciler?.setFollowsTail(true)
            host.transcript.resetWindowToTail()
            host.onRememberScrollAnchor(nil, nil, true)
            scroller?.scrollToBottom()
        }

        private func rememberCurrentAnchor() {
            guard let host, let scroller else { return }
            // Finds the nearest real message rather than discarding the
            // update when a synthetic row is on top. Both directions matter:
            // scrolling to the head of a paginated transcript puts the
            // pagination spinner on top, and stopping inside the synthetic
            // tail (queued prompts, composer spacer) has nothing but
            // synthetic rows below. Recording nothing in either case pauses
            // tail-follow with no anchor at all, and restoration reads a
            // missing anchor as "go to the bottom" — undoing the very scroll
            // that caused it.
            guard let anchorId = tiling.nearestNonSyntheticRowId(
                to: scroller.scrollY,
                syntheticIdPrefix: ACPTranscriptScrollerReconciler.syntheticIdPrefix
            ) else { return }
            // O(1) per tick: the row list is rebuilt only when the window
            // itself changes, and the id → index map is derived once per
            // rebuild. Same rows, same builder, same lookup the legacy list
            // uses.
            let lookup = visibleRowsCache.lookup(
                generation: host.transcript.messagesGeneration,
                head: host.transcript.visibleHead,
                tail: host.transcript.visibleTailBound,
                build: {
                    ACPMessageList.visibleRows(
                        messages: host.transcript.messages,
                        visibleHead: host.transcript.visibleHead,
                        visibleTail: host.transcript.visibleTailBound,
                        stableId: { host.transcript.stableId(for: $0) }
                    )
                }
            )
            let globalIndex = lookup.transcriptIndex(for: anchorId)
                .flatMap { host.transcript.globalIndex(forLocalIndex: $0) }
            host.onRememberScrollAnchor(anchorId, globalIndex, false)
        }

        /// Runs once per Coordinator lifetime, but only actually latches
        /// (`didRestoreInitialPosition = true`) once the outcome is
        /// definite. `__composer_spacer__` and other synthetic rows are
        /// unconditionally present in `rowSpecs`, so `tiling.rowCount > 0`
        /// alone is true on the very first `apply()` even with zero
        /// messages — gating on `hasNonSyntheticRow` too avoids latching
        /// before there's any real content to restore a position within.
        /// Both checks are required: `hasNonSyntheticRow` alone is not
        /// enough, because `makeNSView` builds the scroller at `frame:
        /// .zero` and `attach` calls `update(host:)` immediately, so the
        /// very first `update` always runs with `contentWidth == 0` — a
        /// width `reconciler.apply` deliberately defers on, leaving the
        /// tiling map empty even though `hasNonSyntheticRow` is already
        /// true from the spec list. Without also requiring
        /// `tiling.rowCount > 0`, a non-tail-following session with no
        /// remembered anchor would hit the "nothing to restore" branch
        /// below on that width-0 pass, latch, and call `scrollToBottom()`
        /// on an empty (zero-height) document — a no-op — permanently
        /// skipping the real restore once actual rows exist.
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
                  hasNonSyntheticRow, tiling.rowCount > 0
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

        #if DEBUG
        /// Re-measures every mounted row, reproducing what streaming content
        /// does continuously (`acp-thought:`/`tc-*` rows invalidating their
        /// intrinsic size). This is the path that used to yank a scrolled-away
        /// reader back to the bottom.
        func remeasureMountedRowsForTesting() {
            guard let reconciler else { return }
            for id in reconciler.mountedRowIdsForTesting {
                reconciler.remeasureRow(id: id)
            }
        }

        var mountedRowCountForTesting: Int {
            reconciler?.mountedRowIdsForTesting.count ?? 0
        }

        var pendingLogicalTargetGlobalIndexForTesting: Int? {
            pendingLogicalTargetGlobalIndex
        }

        var topVisibleMessageIdForTesting: String? {
            guard let scroller else { return nil }
            return tiling.nearestNonSyntheticRowId(
                to: scroller.scrollY,
                syntheticIdPrefix: ACPTranscriptScrollerReconciler.syntheticIdPrefix
            )
        }
        #endif
    }
}

extension ACPTranscriptScroller {
    nonisolated static func headStepThreshold(viewportHeight: CGFloat) -> CGFloat {
        max(1500, viewportHeight * 2)
    }

    /// `hasPendingHeadStep` is the caller's latch for "a step was already
    /// requested and its compensating update hasn't landed yet" — see the
    /// call site in `Coordinator.handleScroll`.
    ///
    /// Deliberately NOT gated on `ACPUserScrollEvent.isUserDriven`, unlike the
    /// tail-follow pause decision next to it. `NSApp.currentEvent` is only the
    /// scroll event while the bounds change is happening inside event
    /// dispatch, and with `NSScrollView`'s responsive scrolling most of them
    /// are not: measured against the live app, 1176 of 1209 scroll ticks
    /// during ordinary trackpad paging (97%) classified as NOT user-driven.
    /// Gating pagination on that flag meant reaching the top of the render
    /// window and then waiting — a second or more — for a tick to coincide
    /// with a recognizable fresh event before older messages loaded at all.
    ///
    /// The gate is right for PAUSING tail-follow, where a false positive
    /// stops the follow mid-stream and is user-visible (see
    /// `ACPUserScrollEvent`'s doc comment), and it stays there. It buys
    /// nothing here: the worst a false positive can do is widen the render
    /// window slightly early, which is the direction this wants to err in
    /// anyway. What actually bounds the work is geometry — a step only fires
    /// while the viewport is within `threshold` of the window's top, and each
    /// step's compensation pushes the offset back down by the height it
    /// grafted in, so the window stops growing as soon as there is
    /// `threshold`-worth of loaded history above the viewport. The legacy
    /// path paginated from a geometry sentinel coming into view
    /// (`ACPMessageList.handleHeadFramePreference`) for the same reason.
    nonisolated static func shouldStepHeadBack(
        visibleHead: Int, scrollY: CGFloat, threshold: CGFloat,
        hasPendingHeadStep: Bool = false
    ) -> Bool {
        visibleHead > 0 && scrollY < threshold && !hasPendingHeadStep
    }

    /// Mirrors `ACPMessageList.shouldStepTailForwardFromBottomGeometry`: a
    /// bounds change within the bottom threshold only pages the hidden tail
    /// while the viewport is actually moving DOWN through the document (in
    /// this flipped, top-down coordinate space, that means `newScrollY`
    /// increasing past `previousScrollY`). Without this, browsing upward
    /// while near the bottom threshold — e.g. a non-tail-following session
    /// with hidden newer messages — would advance `visibleTail` and
    /// synchronously measure another chunk of rows on every tick, which is
    /// exactly the unnecessary synchronous work this scroller exists to
    /// avoid. `previousScrollY` is `nil` only before the first reported
    /// scroll offset, in which case direction is unknown and paging is
    /// withheld.
    ///
    /// Like `shouldStepHeadBack`, this is not gated on
    /// `ACPUserScrollEvent.isUserDriven` — see that method's doc comment for
    /// why the flag is close to useless under responsive scrolling. The
    /// downward-movement requirement below is the intent signal here, and it
    /// is a geometric one: a viewport that is not moving down through the
    /// document does not page in newer messages, whatever the event stream
    /// happened to look like.
    nonisolated static func shouldStepTailForward(
        visibleTail: Int, messageCount: Int, distanceFromBottom: CGFloat,
        threshold: CGFloat,
        previousScrollY: CGFloat?, newScrollY: CGFloat
    ) -> Bool {
        guard visibleTail < messageCount, distanceFromBottom < threshold,
              let previousScrollY
        else { return false }
        return newScrollY > previousScrollY + ACPScrollDirectionClassifier.upwardEpsilon
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
