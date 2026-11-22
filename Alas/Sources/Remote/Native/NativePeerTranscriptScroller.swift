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
    var onQuote: (String) -> Void = { _ in }
    /// Opens the restore preview for a user row's checkpoint; nil hides the action.
    var onRestoreCheckpoint: ((CheckpointID) -> Void)? = nil

    var imageReader: ACPTranscriptImageReader? = nil
    var visualActions: ACPVisualAidActions = .readOnly
    var visualForm: (ACPVisualAid) -> ACPUserInputFormState? = { _ in nil }
    var visualStatus: (UUID) -> ACPVisualAidSendStatus = { _ in ACPVisualAidSendStatus() }
    /// The agent's commands, chipped at the start of user messages.
    var commands: [ACPPromptSuggestion] = []
    /// Looks up the `#N`/`!N` references user messages name, through the peer.
    var upstreamReferences: ACPUpstreamReferenceStore? = nil
    /// Opens a skill command's file and shows `/ship`'s state, for command chips.
    /// Only user messages get it: its no-op `perform` must not show a prompt card's action.
    var promptCardContext: ACPPromptCardContext? = nil
    /// The session's worktree on its host, so tool-call patches list worktree-relative paths.
    var worktreeRoot: String? = nil

    @Environment(\.theme) private var theme
    @Environment(\.openURL) private var openURL
    @Environment(\.designScale) private var designScale

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
        private var fold: (key: FoldKey, rows: [ACPTranscriptRenderRow], items: [ACPTranscriptFoldItem])?

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

        private func renderRows(host: NativePeerTranscriptScroller) -> (rows: [ACPTranscriptRenderRow], items: [ACPTranscriptFoldItem]) {
            let transcript = host.transcript
            let key = FoldKey(
                generation: transcript.messagesGeneration,
                isTurnActive: transcript.streamingState != "idle",
                enabled: host.collapsesFinishedToolCalls,
                expansion: expansionSeeds.generation
            )
            if let fold, fold.key == key { return (fold.rows, fold.items) }
            if fold?.key.generation != key.generation {
                rowCache.sync(transcript.messages)
            }
            let items = rowCache.foldItems(for: transcript.messages)
            let rows = NativePeerTranscriptFold.renderRows(
                messages: transcript.messages,
                items: items,
                isTurnActive: key.isTurnActive,
                enabled: key.enabled,
                isExpanded: { [expansionSeeds] in expansionSeeds.isExpanded($0) },
                memberLimit: { [expansionSeeds] in expansionSeeds.memberLimit($0) }
            )
            fold = (key, rows, items)
            return (rows, items)
        }

        func specs(host: NativePeerTranscriptScroller) -> [ACPTranscriptRowSpec] {
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
                                    .font(host.designScale.metaFont)
                                    .foregroundStyle(host.theme.color("fg-muted"))
                            }
                            .opacity(isFetching ? 1 : 0)
                            .frame(maxWidth: .infinity, minHeight: 26)
                        }
                    }
                ))
            }

            let (rows, items) = renderRows(host: host)
            let messages = host.transcript.messages
            let currentTurnUserIndex = items.lastIndex(of: .user) ?? 0
            let isTurnActive = host.transcript.streamingState != "idle"
            let isPlanActive = host.transcript.streamingState == "sending"
                || host.transcript.streamingState == "streaming"
            for renderRow in rows {
                let indices: [Int]
                switch renderRow {
                case .message(let row):
                    specs.append(messageSpec(
                        messages[row.index], inGroup: false,
                        isPlanActive: isPlanActive && row.index >= currentTurnUserIndex, host: host))
                    indices = [row.index]
                case .toolCallGroupMember(let row, _):
                    specs.append(messageSpec(
                        messages[row.index], inGroup: true,
                        isPlanActive: isPlanActive && row.index >= currentTurnUserIndex, host: host))
                    indices = [row.index]
                case .toolCallGroup(let group), .toolCallGroupHeader(let group):
                    specs.append(groupHeaderSpec(group, items: items, host: host))
                    indices = group.members.map(\.index)
                }
                let hasLiveTool = indices.contains { index in
                    guard case .toolCall(let call) = items[index] else { return false }
                    return call.status == "pending" || call.status == "in_progress"
                }
                if hasLiveTool || (isTurnActive && indices.contains { $0 >= currentTurnUserIndex }) {
                    specs[specs.count - 1].parksWhenReleased = false
                }
                // A finished turn's file changes follow its answer, as in a local session.
                if case .message(let row) = renderRow,
                   let changes = turnChanges(answerIndex: row.index, messages: messages, isTurnActive: isTurnActive, host: host) {
                    specs.append(ACPTranscriptRowSpec(
                        id: "__turn_changes__" + row.stableId,
                        equalityToken: Self.token(changes, host: host),
                        build: { Self.wrap(host: host) { ACPTurnChangesCard(changes: changes, caption: nil, onOpenDiff: nil) } }
                    ))
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

        /// The files live on the peer, so the card lists them without opening diffs.
        private func turnChanges(
            answerIndex: Int, messages: [RemoteWireMessage], isTurnActive: Bool, host: NativePeerTranscriptScroller
        ) -> ACPTurnChanges? {
            guard messages.indices.contains(answerIndex), messages[answerIndex].kind == "agent" else { return nil }
            let rowCache = rowCache
            return ACPTurnChanges.forAnswer(at: answerIndex, count: messages.count, isTurnActive: isTurnActive) { index in
                let message = messages[index]
                // A hidden row is transparent, as in the fold.
                guard message.isHidden != true else { return .other }
                switch rowCache.row(for: message) {
                case .user: return .user
                case .agent: return .agent
                case .fileEdit(let edit): return .fileEdit(.init(path: edit.path, added: edit.added, removed: edit.removed))
                case .toolCall(let call): return .toolCallEdits(ACPTurnChanges.written(by: call, worktreeRoot: host.worktreeRoot))
                default: return .other
                }
            }
        }

        private struct MessageTokenInputs: Equatable {
            let row: NativePeerRow
            let inGroup: Bool
            let isPlanActive: Bool
            let typography: ACPChatTypography
            let offersRestore: Bool
            let commands: [ACPPromptSuggestion]
        }

        private func messageSpec(
            _ message: RemoteWireMessage, inGroup: Bool, isPlanActive: Bool, host: NativePeerTranscriptScroller
        ) -> ACPTranscriptRowSpec {
            let row = rowCache.row(for: message)
            // Parking a visual would retain its WebKit page after it leaves the mount band.
            let parksWhenReleased = if case .visualAid = row { false } else { true }
            let isPlanActive = if case .plan = row { isPlanActive } else { false }
            // A thought renders from its streaming buffer, which republishes
            // on its own; rebuilding the row per chunk would only re-measure.
            let tokenRow: NativePeerRow = if case .thought = row { .thought("") } else { row }
            let rowCache = rowCache
            let stableId = message.stableId
            return ACPTranscriptRowSpec(
                id: stableId,
                equalityToken: Self.token(
                    MessageTokenInputs(
                        row: tokenRow, inGroup: inGroup, isPlanActive: isPlanActive, typography: host.typography,
                        offersRestore: host.onRestoreCheckpoint != nil, commands: host.commands),
                    host: host
                ),
                build: {
                    Self.wrap(host: host) {
                        let content = NativePeerRowView(
                            row: row, stableId: stableId, rowCache: rowCache,
                            contentMaxWidth: host.contentMaxWidth, typography: host.typography,
                            isPlanActive: isPlanActive, onQuote: host.onQuote,
                            onRestoreCheckpoint: host.onRestoreCheckpoint, commands: host.commands,
                            promptCardContext: host.promptCardContext,
                            visualActions: host.visualActions, visualForm: host.visualForm, visualStatus: host.visualStatus
                        )
                        if inGroup {
                            ACPToolCallGroupMemberRow { content }
                        } else {
                            content
                        }
                    }
                },
                parksWhenReleased: parksWhenReleased
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
            _ group: ACPTranscriptToolCallGroup, items: [ACPTranscriptFoldItem], host: NativePeerTranscriptScroller
        ) -> ACPTranscriptRowSpec {
            let summary = ACPToolCallGroupSummary(
                toolCalls: RemoteTranscriptFold.summaryToolCalls(of: group, items: items),
                kind: group.kind, isLive: group.isLive
            )
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
            let designScale: DesignScale
            let contentMaxWidth: CGFloat
            let imageReaderID: String?
            let base: Base
        }

        /// Hosted rows capture their environment at build time. Refresh them
        /// when a peer's image-serving capability becomes available too.
        private static func token<T: Equatable>(_ base: T, host: NativePeerTranscriptScroller) -> ACPRowEqualityToken {
            ACPRowEqualityToken(ThemedToken(theme: host.theme, designScale: host.designScale, contentMaxWidth: host.contentMaxWidth, imageReaderID: host.imageReader?.id, base: base))
        }

        /// Each row lives in its own `NSHostingView`, outside the SwiftUI
        /// tree, so the column framing and environment are applied per row.
        private static func wrap<Content: View>(
            host: NativePeerTranscriptScroller, @ViewBuilder _ content: () -> Content
        ) -> AnyView {
            AnyView(
                content()
                    .frame(maxWidth: host.contentMaxWidth, alignment: .leading)
                    .padding(.horizontal, ACPChatLayout.transcriptRowInset)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .environment(\.theme, host.theme)
                    .environment(\.designScale, host.designScale)
                    .environment(\.openURL, host.openURL)
                    .environment(\.acpTranscriptImageReader, host.imageReader)
                    .environment(\.acpUpstreamReferenceStore, host.upstreamReferences)
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
    let isPlanActive: Bool
    var onQuote: (String) -> Void = { _ in }
    var onRestoreCheckpoint: ((CheckpointID) -> Void)? = nil
    /// The agent's commands, chipped at the start of a user message.
    var commands: [ACPPromptSuggestion] = []
    var promptCardContext: ACPPromptCardContext? = nil
    @Environment(\.acpUpstreamReferenceStore) private var upstreamReferences

    var visualActions: ACPVisualAidActions = .readOnly
    var visualForm: (ACPVisualAid) -> ACPUserInputFormState? = { _ in nil }
    var visualStatus: (UUID) -> ACPVisualAidSendStatus = { _ in ACPVisualAidSendStatus() }
    @State private var showsVisualPreview = false

    static func promptCard(_ json: String) -> ACPPromptCard? {
        try? JSONDecoder().decode(ACPPromptCard.self, from: Data(json.utf8))
    }

    var body: some View {
        switch row {
        case .user(let text, _, _, let card?, _, _) where Self.promptCard(card) != nil:
            // A turn Alas sent, as the local transcript shows it.
            PromptCardRow(card: Self.promptCard(card)!, text: text, contentMaxWidth: contentMaxWidth, typography: typography)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contextMenu { messageMenu(text, checkpointID: nil) }
        case .user(let text, let checkpointID, let images, _, let mentions, let pastedSpans):
            HStack {
                Spacer(minLength: 40)
                VStack(alignment: .trailing, spacing: 4) {
                    if !images.isEmpty {
                        HStack(spacing: 6) {
                            // Same image attached twice shares a uri.
                            ForEach(Array(images.enumerated()), id: \.offset) { _, image in
                                NativePeerImageThumbnail(image: image)
                            }
                        }
                    }
                    if !mentions.isEmpty {
                        HStack(spacing: 4) {
                            ForEach(Array(mentions.enumerated()), id: \.offset) { _, mention in
                                mentionBadge(mention)
                            }
                        }
                    }
                    if let upstreamReferences {
                        // Only typed text, as in a local row.
                        ACPUserReferenceSummary(
                            text: ACPPastedTextContents(text: text, spans: pastedSpans)?.typedText ?? text,
                            store: upstreamReferences)
                    }
                    if !text.isEmpty {
                        let symbols = Self.symbolAttachments(mentions)
                        ACPUserMessageText(
                            text: text, attachments: symbols, pastedSpans: pastedSpans, typography: typography,
                            commands: .fixed(commands), chipsAbsolutePaths: false,
                            symbolMentions: ACPTranscriptSymbolMentions(attachments: symbols, root: nil))
                            .acpUserBubble()
                            .environment(\.acpPromptCardContext, promptCardContext)
                    }
                }
                .frame(maxWidth: contentMaxWidth * 0.75, alignment: .trailing)
            }
            .frame(maxWidth: .infinity)
            .contextMenu { messageMenu(text, checkpointID: checkpointID) }
        case .agent(let text):
            ACPMarkdownText(
                raw: text,
                cache: rowCache.markdownCache(for: stableId),
                typography: typography
            )
            .frame(maxWidth: .infinity, alignment: .leading)
            .contextMenu { messageMenu(text, checkpointID: nil) }
        case .thought(let text):
            ACPThoughtView(buffer: rowCache.thoughtBuffer(for: stableId, seed: text))
        case .toolCall(let call):
            ACPToolCallCard(toolCall: call, messageCreatedAt: nil)
        case .fileEdit(let edit):
            // The edited file lives on the peer, so there is no local diff
            // to open; the card still shows the inline hunk.
            ACPFileEditCard(edit: edit, onOpenDiff: nil)
        case .plan(let items):
            ACPPlanChecklist(items: items, isTurnActive: isPlanActive)
        case .planDocument(let document):
            // The plan file lives on the peer, so there is nothing to open.
            if let display = document.display {
                ACPPlanDocumentCard(
                    display: display, cache: rowCache.markdownCache(for: stableId), typography: typography)
            }
        case .visualAid(let visual):
            ACPVisualAidCard(
                visual: visual, form: visualForm(visual), sendStatus: visualStatus(visual.id),
                actions: actionsForVisual, typography: typography
            )
            .sheet(isPresented: $showsVisualPreview) {
                ACPVisualAidCard(
                    visual: visual, form: visualForm(visual), sendStatus: visualStatus(visual.id),
                    actions: actionsForVisual, fillsHeight: true, typography: typography
                )
                .frame(minWidth: 640, minHeight: 480)
                .toolbar { Button("Done") { showsVisualPreview = false } }
            }
        case .questionAnswer(let answer):
            ACPQuestionAnswerCard(answer: answer)
        case .outcomeCard(let card):
            PromptCardRow(card: ACPPromptCard(card), text: "", contentMaxWidth: contentMaxWidth, typography: typography)
                .frame(maxWidth: .infinity, alignment: .leading)
        case .failureIncident(let incident):
            ACPFailureIncidentCard(
                incident: ACPFailureIncident(record: .init(remote: incident), endedTurn: incident.endedTurn),
                actions: .readOnly)
        case .systemNotice(let text):
            ACPSystemNoticeView(text: text)
        }
    }
    private var actionsForVisual: ACPVisualAidActions {
        var actions = visualActions
        actions.popOut = { _ in showsVisualPreview = true }
        actions.popOutLabel = "Expand visual"
        return actions
    }

    /// A sent mention, badged as a local row badges its attachment. The peer
    /// keeps the files, so a symbol badge has no preview.
    @ViewBuilder
    private func mentionBadge(_ mention: RemoteUserMention) -> some View {
        if let symbol = mention.symbol, let target = Self.symbolTarget(symbol) {
            ACPSymbolBadge(target: target, snapshot: symbol.snapshot, root: nil, typography: typography)
        } else {
            FileChip(path: mention.name, lines: nil,
                     iconSystemName: mention.kind == RemoteMention.session ? "bubble.left.and.bubble.right" : "at")
        }
    }

    static func symbolTarget(_ symbol: RemoteSymbolMention) -> ACPSymbolReference.Target? {
        guard let kind = SymbolKind(rawValue: symbol.kind) else { return nil }
        return ACPSymbolReference.Target(path: symbol.path, name: symbol.name, kind: kind, container: symbol.container,
                                         lineRange: symbol.lineRange, includeCode: symbol.includesCode)
    }

    /// The symbol mentions as the attachments a local row has, so the text chips their `@` labels.
    static func symbolAttachments(_ mentions: [RemoteUserMention]) -> [ACPMessage.Attachment] {
        mentions.compactMap { mention in
            guard let symbol = mention.symbol, let target = symbolTarget(symbol) else { return nil }
            return ACPMessage.Attachment(uri: ACPSymbolReference.uri(for: target), name: mention.name, symbol: symbol.snapshot)
        }
    }

    @ViewBuilder
    private func messageMenu(_ text: String, checkpointID: CheckpointID?) -> some View {
        // Ordered as ACPMessageActionsMenu.make orders the local row's menu.
        if let checkpointID, let onRestoreCheckpoint {
            Button("Restore files to before this request") { onRestoreCheckpoint(checkpointID) }
            Divider()
        }
        Button("Copy") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
        }
        if ACPMessageQuote.canQuote(text) {
            Button("Quote") { onQuote(text) }
        }
    }
}

/// A prompt's image, read from the peer that holds the file. Its `🖼` label
/// stands in until the bytes load, and stays when the peer can't serve them.
private struct NativePeerImageThumbnail: View {
    let image: RemoteWireMessage.Image
    @Environment(\.acpTranscriptImageReader) private var reader
    @Environment(\.designScale) private var scale

    private var title: String { image.name ?? "Image" }

    var body: some View {
        let reader = reader
        let uri = image.uri
        ACPCachedThumbnail(
            cacheKey: "\(reader?.id ?? "none"):\(uri)",
            loadImage: { await reader?.read(uri).flatMap(NSImage.init(data:)) }
        ) { loaded in
            Button {
                ACPImagePreview.shared.show(loaded, title: title)
            } label: {
                Image(nsImage: loaded)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: 96, height: 96)
                    .clipShape(RoundedRectangle(cornerRadius: scale.radius.medium))
                    .overlay(RoundedRectangle(cornerRadius: scale.radius.medium)
                        .strokeBorder(.primary.opacity(0.15), lineWidth: 0.5))
            }
            .buttonStyle(.plain)
            .contentShape(Rectangle())
            .help(title)
        } placeholder: {
            Text("🖼 \(title)")
                .acpUserBubble()
        }
    }
}
