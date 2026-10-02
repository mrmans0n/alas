import AppKit
import SwiftUI

/// A row the host adds around the peer's messages (the unavailable banner,
/// pending requests). The scroller frames it into the chat column and
/// re-applies the environment, like every other hosted row.
struct NativePeerTranscriptExtraRow {
    /// Must start with `ACPTranscriptScrollerReconciler.syntheticIdPrefix`
    /// so scroll anchoring skips it.
    let id: String
    let token: ACPRowEqualityToken
    var keepsMountedOffscreen = false
    let content: () -> AnyView
}

/// The peer transcript on the local transcript's AppKit scroller: rows are
/// measured once and tiled, older pages graft in above the reader with
/// synchronous offset compensation, and tail-follow only pauses for real
/// user scrolling. Thinking and tool calls fold like the local transcript.
struct NativePeerTranscriptScroller: NSViewRepresentable {
    let transcript: NativePeerTranscript
    let contentMaxWidth: CGFloat
    let typography: ACPChatTypography
    let collapsesFinishedToolCalls: Bool
    /// Whether an older page exists and can be requested right now.
    let canFetchOlder: Bool
    let isFetchingOlder: Bool
    let leadingRows: [NativePeerTranscriptExtraRow]
    let trailingRows: [NativePeerTranscriptExtraRow]
    let fetchOlder: () -> Void

    @Environment(\.theme) private var theme
    @Environment(\.openURL) private var openURL

    static let composerSpacerHeight: CGFloat = 220

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> MinimapContainerView<ACPTranscriptScrollerView> {
        let scroller = ACPTranscriptScrollerView(frame: .zero)
        context.coordinator.attach(scroller: scroller, host: self)
        return MinimapContainerView(scrollView: scroller)
    }

    func updateNSView(_ nsView: MinimapContainerView<ACPTranscriptScrollerView>, context: Context) {
        context.coordinator.update(host: self)
    }

    @MainActor
    final class Coordinator {
        private var scroller: ACPTranscriptScrollerView?
        private var reconciler: ACPTranscriptScrollerReconciler?
        private let tiling = ACPTranscriptTilingController()
        private let pool = ACPTranscriptRowHostingPool()
        private let rowCache = NativePeerRowCache()
        /// Keyed by stable ids, which the peer derives from position; a new
        /// epoch can hand the same ids to different messages, so it starts
        /// a fresh store.
        private var expansionSeeds = ACPToolCallGroupExpansionSeeds()
        private var host: NativePeerTranscriptScroller?
        private var followsTail = true
        private var epoch: Int?
        private var isFetchScheduled = false
        /// Fires once a gesture's tail-pin suppression has expired, so an
        /// update that landed inside it cannot strand a following reader
        /// above the newest row.
        private let scrollSettleTimer = DebounceTimer(
            interval: ACPTranscriptScrollerReconciler.userScrollSuppressionWindow
        )

        init() {
            scrollSettleTimer.onFire = { [weak self] in
                MainActor.assumeIsolated { self?.settleUserScroll() }
            }
        }

        private struct FoldKey: Equatable {
            let generation: UInt64
            let isTurnActive: Bool
            let enabled: Bool
            let expansion: UInt64
        }
        private var fold: (key: FoldKey, rows: [ACPTranscriptRenderRow], proxies: [ACPMessage])?

        func attach(scroller: ACPTranscriptScrollerView, host: NativePeerTranscriptScroller) {
            self.scroller = scroller
            let reconciler = ACPTranscriptScrollerReconciler(tiling: tiling, pool: pool, scroller: scroller)
            // A bundle's id follows its first member, so a page revealing an
            // earlier member re-keys it; remap the reader's anchor to it.
            reconciler.resolveStaleRowId = { [weak self] staleId in
                guard let self, let host = self.host, let fold = self.fold else { return nil }
                guard let resolution = ACPTranscriptScroller.Coordinator.resolveStaleRowId(
                    staleId, lookup: ACPTranscriptVisibleRowLookup(rows: fold.rows),
                    groupingEnabled: host.collapsesFinishedToolCalls
                ) else { return nil }
                return (resolution.rowId, resolution.assumeHeadGrowth)
            }
            self.reconciler = reconciler
            observeExpansionSeeds()
            scroller.onScroll = { [weak self] previousY, newY, viewportHeight, contentHeight, isProgrammatic in
                self?.handleScroll(
                    previousY: previousY, newY: newY,
                    viewportHeight: viewportHeight, contentHeight: contentHeight,
                    isProgrammatic: isProgrammatic
                )
            }
            // The scroller routes its knob and track through this callback
            // instead of AppKit's default action. With no logical history
            // range installed, its value spans the physical document.
            scroller.onLogicalScrollCommit = { [weak self] value in
                self?.commitScrollbar(value: value)
            }
            scroller.onContentWidthChange = { [weak self] in
                guard let self, let host = self.host, self.reconciler?.isApplyingSpecs == false else { return }
                self.update(host: host)
            }
            scroller.onViewportHeightChange = { [weak self] in
                guard let self, let reconciler = self.reconciler, !reconciler.isApplyingSpecs else { return }
                if reconciler.followsTail { self.scroller?.scrollToBottom() }
                reconciler.layoutMountedRows()
            }
            update(host: host)
        }

        func update(host: NativePeerTranscriptScroller) {
            self.host = host
            guard let scroller, let reconciler else { return }
            if host.transcript.epoch != epoch {
                // A fresh snapshot replaces the window; start from its tail.
                epoch = host.transcript.epoch
                followsTail = true
                expansionSeeds = ACPToolCallGroupExpansionSeeds()
                observeExpansionSeeds()
                fold = nil
                // Ids come from message position, so a new epoch can reuse an
                // id for a different message: never revive a view across epochs.
                pool.purgeParked()
            }
            reconciler.apply(
                specs: specs(host: host),
                contentWidth: scroller.contentView.bounds.width,
                followsTail: followsTail
            )
            scheduleFetchOlderIfNeeded()
        }

        private func observeExpansionSeeds() {
            expansionSeeds.onChange = { [weak self] in
                guard let self, let host = self.host else { return }
                self.update(host: host)
            }
        }

        // MARK: Rows

        private func renderRows(host: NativePeerTranscriptScroller) -> (rows: [ACPTranscriptRenderRow], proxies: [ACPMessage]) {
            let transcript = host.transcript
            let key = FoldKey(
                generation: transcript.messagesGeneration,
                isTurnActive: transcript.streamingState != "idle",
                enabled: host.collapsesFinishedToolCalls,
                expansion: expansionSeeds.generation
            )
            if let fold, fold.key == key { return (fold.rows, fold.proxies) }
            if fold?.key.generation != key.generation {
                rowCache.sync(transcript.messages)
            }
            let proxies = rowCache.proxies(for: transcript.messages)
            let rows = NativePeerTranscriptFold.renderRows(
                messages: transcript.messages,
                proxies: proxies,
                isTurnActive: key.isTurnActive,
                enabled: key.enabled,
                isExpanded: { [expansionSeeds] in expansionSeeds.isExpanded($0) },
                memberLimit: { [expansionSeeds] in expansionSeeds.memberLimit($0) }
            )
            fold = (key, rows, proxies)
            return (rows, proxies)
        }

        private func specs(host: NativePeerTranscriptScroller) -> [ACPTranscriptRowSpec] {
            var specs: [ACPTranscriptRowSpec] = host.leadingRows.map { extraSpec($0, host: host) }
            if host.canFetchOlder || host.isFetchingOlder {
                let isFetching = host.isFetchingOlder
                specs.append(ACPTranscriptRowSpec(
                    id: "__top_pagination__",
                    equalityToken: Self.token(isFetching, host: host),
                    build: {
                        Self.wrap(host: host) {
                            HStack(spacing: 6) {
                                ProgressView().controlSize(.small)
                                Text("Loading earlier messages…")
                                    .font(.system(size: 11))
                                    .foregroundStyle(host.theme.color("fg-muted"))
                            }
                            .opacity(isFetching ? 1 : 0)
                            .frame(maxWidth: .infinity, minHeight: 26)
                        }
                    }
                ))
            }

            let (rows, proxies) = renderRows(host: host)
            let messages = host.transcript.messages
            let currentTurnUserIndex = proxies.lastIndex {
                if case .user = $0 { return true }
                return false
            } ?? 0
            let isTurnActive = host.transcript.streamingState != "idle"
            for renderRow in rows {
                let indices: [Int]
                switch renderRow {
                case .message(let row):
                    specs.append(messageSpec(messages[row.index], inGroup: false, host: host))
                    indices = [row.index]
                case .toolCallGroupMember(let row, _):
                    specs.append(messageSpec(messages[row.index], inGroup: true, host: host))
                    indices = [row.index]
                case .toolCallGroup(let group), .toolCallGroupHeader(let group):
                    specs.append(groupHeaderSpec(group, proxies: proxies, host: host))
                    indices = group.members.map(\.index)
                }
                let hasLiveTool = indices.contains { index in
                    guard case .toolCall(let call) = proxies[index] else { return false }
                    return call.status == "pending" || call.status == "in_progress"
                }
                if hasLiveTool || (isTurnActive && indices.contains { $0 >= currentTurnUserIndex }) {
                    specs[specs.count - 1].parksWhenReleased = false
                }
            }

            specs.append(contentsOf: host.trailingRows.map { extraSpec($0, host: host) })
            specs.append(ACPTranscriptRowSpec(
                id: "__composer_spacer__",
                equalityToken: ACPRowEqualityToken(NativePeerTranscriptScroller.composerSpacerHeight),
                build: { AnyView(Color.clear.frame(height: NativePeerTranscriptScroller.composerSpacerHeight)) }
            ))
            return specs
        }

        private struct MessageTokenInputs: Equatable {
            let row: NativePeerRow
            let inGroup: Bool
            let typography: ACPChatTypography
        }

        private func messageSpec(
            _ message: RemoteWireMessage, inGroup: Bool, host: NativePeerTranscriptScroller
        ) -> ACPTranscriptRowSpec {
            let row = rowCache.row(for: message)
            // A thought renders from its streaming buffer, which republishes
            // on its own; rebuilding the row per chunk would only re-measure.
            let tokenRow: NativePeerRow = if case .thought = row { .thought("") } else { row }
            let rowCache = rowCache
            let stableId = message.stableId
            return ACPTranscriptRowSpec(
                id: stableId,
                equalityToken: Self.token(
                    MessageTokenInputs(row: tokenRow, inGroup: inGroup, typography: host.typography),
                    host: host
                ),
                build: {
                    Self.wrap(host: host) {
                        let content = NativePeerRowView(
                            row: row, stableId: stableId, rowCache: rowCache,
                            contentMaxWidth: host.contentMaxWidth, typography: host.typography
                        )
                        if inGroup {
                            ACPToolCallGroupMemberRow { content }
                        } else {
                            content
                        }
                    }
                }
            )
        }

        private struct GroupTokenInputs: Equatable {
            let summary: ACPToolCallGroupSummary
            let expanded: Bool
            let hiddenMemberCount: Int
            let memberStableIds: [String]
        }

        /// Mirrors the local transcript's bundle header: one row id whether
        /// collapsed or expanded, with members tiled as sibling rows.
        private func groupHeaderSpec(
            _ group: ACPTranscriptToolCallGroup, proxies: [ACPMessage], host: NativePeerTranscriptScroller
        ) -> ACPTranscriptRowSpec {
            let toolCalls: [ACPMessage.ToolCall] = group.members.compactMap {
                guard case .toolCall(let call) = proxies[$0.index] else { return nil }
                return call
            }
            let summary = ACPToolCallGroupSummary(toolCalls: toolCalls, kind: group.kind, isLive: group.isLive)
            let memberStableIds = group.members.map(\.stableId)
            expansionSeeds.syncLineage(members: memberStableIds)
            expansionSeeds.syncCollapsed(members: memberStableIds)
            let expanded = expansionSeeds.isExpanded(group)
            let hiddenMemberCount = expanded
                ? max(0, memberStableIds.count - (expansionSeeds.memberLimit(group) ?? memberStableIds.count))
                : 0
            return ACPTranscriptRowSpec(
                id: group.id,
                equalityToken: Self.token(
                    GroupTokenInputs(
                        summary: summary, expanded: expanded,
                        hiddenMemberCount: hiddenMemberCount, memberStableIds: memberStableIds
                    ),
                    host: host
                ),
                build: {
                    Self.wrap(host: host) {
                        ACPToolCallGroupHeaderRow(
                            summary: summary,
                            expanded: expanded,
                            hiddenMemberCount: hiddenMemberCount,
                            // Through the coordinator, not a captured store: a
                            // new epoch swaps the store under a mounted header.
                            onToggle: { [weak self] in
                                self?.expansionSeeds.setExpanded($0, members: memberStableIds)
                            }
                        )
                    }
                }
            )
        }

        private func extraSpec(_ row: NativePeerTranscriptExtraRow, host: NativePeerTranscriptScroller) -> ACPTranscriptRowSpec {
            ACPTranscriptRowSpec(
                id: row.id,
                equalityToken: Self.token(ErasedToken(token: row.token), host: host),
                build: { Self.wrap(host: host) { row.content() } },
                keepsMountedOffscreen: row.keepsMountedOffscreen
            )
        }

        private struct ErasedToken: Equatable {
            let token: ACPRowEqualityToken
            static func == (lhs: Self, rhs: Self) -> Bool { lhs.token.isEqual(to: rhs.token) }
        }

        private struct ThemedToken<Base: Equatable>: Equatable {
            let theme: Theme
            let contentMaxWidth: CGFloat
            let base: Base
        }

        /// Hosted rows bake the theme and column width in at build time, so
        /// both belong in every token.
        private static func token<T: Equatable>(_ base: T, host: NativePeerTranscriptScroller) -> ACPRowEqualityToken {
            ACPRowEqualityToken(ThemedToken(theme: host.theme, contentMaxWidth: host.contentMaxWidth, base: base))
        }

        /// Each row lives in its own `NSHostingView`, outside the SwiftUI
        /// tree, so the column framing and environment are applied per row.
        private static func wrap<Content: View>(
            host: NativePeerTranscriptScroller, @ViewBuilder _ content: () -> Content
        ) -> AnyView {
            AnyView(
                content()
                    .frame(maxWidth: host.contentMaxWidth, alignment: .leading)
                    .padding(.horizontal, 28 + ACPMessageGutterLayout.laneWidth)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .environment(\.theme, host.theme)
                    .environment(\.openURL, host.openURL)
            )
        }

        // MARK: Scrolling

        private func handleScroll(
            previousY: CGFloat?, newY: CGFloat,
            viewportHeight: CGFloat, contentHeight: CGFloat,
            isProgrammatic: Bool
        ) {
            guard let scroller, let reconciler else { return }
            if isProgrammatic || reconciler.isApplyingSpecs {
                if !reconciler.isApplyingSpecs { reconciler.layoutMountedRowsForScroll() }
                return
            }

            let event = NSApp.currentEvent
            let eventIsFresh = ACPUserScrollEvent.isFresh(
                eventTimestamp: event?.timestamp,
                now: ProcessInfo.processInfo.systemUptime
            )
            let currentEventType = eventIsFresh ? event?.type : nil
            let isScrollbarTrackHit = ACPUserScrollEvent.isScrollbarTrackMouseDown(eventIsFresh ? event : nil)
            let isUserDriven = scroller.isUserScrollActive
                || ACPUserScrollEvent.isHeadPaginationDriven(
                    currentEventType,
                    previousMinY: previousY,
                    newMinY: newY,
                    isScrollbarTrackHit: isScrollbarTrackHit
                )
            let hasUserScrollInput = scroller.isUserScrollActive
                || ACPUserScrollEvent.isScrollInput(currentEventType, isScrollbarTrackHit: isScrollbarTrackHit)

            guard hasUserScrollInput else {
                // Layout, not intent: keep a following viewport on the tail.
                if followsTail { scroller.scrollToBottom() }
                reconciler.layoutMountedRowsForScroll()
                return
            }

            reconciler.invalidatePendingAnchorRestore()
            reconciler.noteUserScroll()
            scrollSettleTimer.poke()
            switch ACPScrollDirectionClassifier.decide(
                previousOffsetY: previousY,
                newOffsetY: newY,
                viewportHeight: viewportHeight,
                contentHeight: contentHeight,
                isRestoring: false,
                isUserDriven: isUserDriven
            ) {
            case .userScrolledUp where followsTail:
                // Mirror into the reconciler before mounting newly exposed
                // rows, or a row resizing on mount re-pins the reader.
                followsTail = false
                reconciler.setFollowsTail(false)
            case .userAtBottom where !followsTail:
                followsTail = true
                reconciler.setFollowsTail(true)
            default:
                break
            }
            reconciler.layoutMountedRowsForScroll()
            scheduleFetchOlderIfNeeded()
        }

        private func commitScrollbar(value: Double) {
            guard let scroller, let reconciler else { return }
            let atTail = value >= 1 - Double.ulpOfOne
            followsTail = atTail
            reconciler.setFollowsTail(atTail)
            reconciler.invalidatePendingAnchorRestore()
            reconciler.noteUserScroll()
            scrollSettleTimer.poke()
            let maxY = max(0, scroller.contentHeight - scroller.viewportHeight)
            scroller.setScrollY(maxY * CGFloat(min(max(value, 0), 1)))
            reconciler.layoutMountedRowsForScroll()
            scheduleFetchOlderIfNeeded()
        }

        private func settleUserScroll() {
            guard let scroller, let host else { return }
            guard !scroller.isUserScrollActive else {
                scrollSettleTimer.poke()
                return
            }
            if followsTail { update(host: host) }
        }

        /// Requests the previous page once the reader is within the same
        /// distance of the top that the local transcript pages at, so older
        /// rows are usually in place before the reader reaches them. Runs
        /// asynchronously because it mutates observed state and can be
        /// reached from a SwiftUI update.
        private func scheduleFetchOlderIfNeeded() {
            guard let host, let scroller, host.canFetchOlder, !host.isFetchingOlder,
                  !isFetchScheduled, tiling.rowCount > 0,
                  scroller.scrollY < ACPTranscriptScroller.headStepThreshold(viewportHeight: scroller.viewportHeight)
            else { return }
            isFetchScheduled = true
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.isFetchScheduled = false
                self.host?.fetchOlder()
            }
        }
    }
}

/// One peer message, rendered with the local transcript's cards.
private struct NativePeerRowView: View {
    let row: NativePeerRow
    let stableId: String
    let rowCache: NativePeerRowCache
    let contentMaxWidth: CGFloat
    let typography: ACPChatTypography

    var body: some View {
        switch row {
        case .user(let text):
            HStack {
                Spacer(minLength: 40)
                ACPMarkdownText(raw: text, typography: typography)
                    .acpUserBubble()
                    .frame(maxWidth: contentMaxWidth * 0.75, alignment: .trailing)
            }
            .frame(maxWidth: .infinity)
        case .agent(let text):
            ACPMarkdownText(
                raw: text,
                cache: rowCache.markdownCache(for: stableId),
                typography: typography
            )
            .frame(maxWidth: .infinity, alignment: .leading)
        case .thought(let text):
            ACPThoughtView(buffer: rowCache.thoughtBuffer(for: stableId, seed: text))
        case .toolCall(let call):
            ACPToolCallCard(toolCall: call, messageCreatedAt: nil)
        case .fileEdit(let edit):
            // The edited file lives on the peer, so there is no local diff
            // to open; the card still shows the inline hunk.
            ACPFileEditCard(edit: edit, onOpenDiff: nil)
        case .plan(let items):
            ACPPlanChecklist(items: items)
        case .systemNotice(let text):
            ACPSystemNoticeView(text: text)
        }
    }
}
