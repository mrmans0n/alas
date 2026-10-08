import SwiftUI

/// A single transcript row's content, extracted from `ACPMessageList.body` so
/// it can be gated with `.equatable()`. A full-list body re-eval (from a
/// scroll/geometry pass) used to re-diff every visible row's deep modifier
/// tree even when nothing about the row had changed — the dominant cost in
/// the live-lock sample (`ModifiedViewList.applyNodes`,
/// `LazySubviewPlacements.placeSubviews`). Gating on the render-relevant
/// values below lets SwiftUI skip re-diffing a row's subtree entirely when
/// they're unchanged. See docs/plans/2026-07-17-acp-transcript-livelock-fix.md
/// (Task 7) for the stale-closure audit backing the excluded fields below.
// `==` is only invoked by SwiftUI view diffing via `.equatable()`/`EquatableView`,
// which runs on the main actor; the only other caller is the `@MainActor` test
// suite. The `equalityKey(...)` seam exists precisely so background callers
// never reach `==`.
struct ACPTranscriptRowContent: View, @preconcurrency Equatable {
    // Compared (render-relevant values):
    let stableId: String
    let messageIndex: Int
    let message: ACPMessage
    let messageCreatedAt: Date?
    let messagePhase: ACPMessagePhase?
    let contentMaxWidth: CGFloat
    var availableRowContentWidth: CGFloat?
    var availableTrailingGutterWidth: CGFloat?
    let typography: ACPChatTypography
    let trustedImageRoot: URL?
    /// Whether this row is the narration the agent is writing into right
    /// now (`ACPNarrationLiveness`). Compared, so the row re-renders when
    /// it stops being the live tail — otherwise a finished "Thinking…"
    /// would keep shimmering until some unrelated field of its message
    /// happened to change.
    var isLiveNarration: Bool = false
    // Excluded from equality — reference-stable for the session's lifetime
    // (`transcript`/`session` are `let` properties on `ACPSession`, never
    // reassigned), or closures whose behavior only depends on already-compared
    // data:
    // - `onOpenDiff` / `onQuote` / queue callbacks capture stable host references
    //   (`state`, `worktree`, `manager`, `sessionId`) wired once by
    //   `ACPTabView`, not per-render-varying state.
    // - `onLoadFullToolCallContent` is only ever invoked when
    //   `tc.isContentTruncated` is true; that flag is intentionally excluded
    //   from `ACPMessage.ToolCall`'s own `==`/`hash` (a row must stay equal
    //   across the in-memory truncation boundary), but `truncateForOffWindow`
    //   only fires on messages that are, at that same moment, leaving the
    //   render window (`ACPTranscript.trimHiddenMessage`) — so the flag never
    //   flips on a message that remains part of an already-rendered,
    //   gate-compared row. Leaving the transcript spec window drops its parked
    //   view too, so re-entering that window builds with the current
    //   `isContentTruncated` value. Scrolling within the window can reuse it.
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
    var onQuote: (String) -> Void = { _ in }
    let onFork: (ACPForkMessageBoundary, String) -> Void
    var onRestoreCheckpoint: (CheckpointID) -> Void = { _ in }
    /// Plugin commands for the "…" menu, read when it opens.
    var messageMenuItems: () -> [ACPMessageMenuItem] = { [] }
    /// Cancels one native subagent by child session id. Nil when the host
    /// can't cancel (read-only mirror), which also hides the action.
    var onCancelSubagent: ((String) -> Void)?
    /// Resolved caption for a delegated prompt's bubble. Compared, because
    /// it folds in the sender's agent display name, which lives outside
    /// `message`.
    var delegatedLabel: String? = nil
    /// Not compared, like the other callbacks. `canAnswer` is a closure the
    /// card re-reads (and re-reads when `changes` fires), so a mounted row
    /// follows writer ownership without a new value reaching this struct.
    var visualAidActions: ACPVisualAidActions = .readOnly

    static func == (lhs: Self, rhs: Self) -> Bool {
        guard lhs.messagePhase == rhs.messagePhase else { return false }
        return equalityKey(
            stableId: lhs.stableId, message: lhs.message,
            messageCreatedAt: lhs.messageCreatedAt,
            messagePhase: lhs.messagePhase,
            contentMaxWidth: lhs.contentMaxWidth,
            availableRowContentWidth: lhs.availableRowContentWidth ?? lhs.contentMaxWidth,
            availableTrailingGutterWidth: lhs.availableTrailingGutterWidth ?? .infinity,
            typography: lhs.typography,
            trustedImageRoot: lhs.trustedImageRoot,
            isForkEligible: lhs.isForkEligible, forkTargets: lhs.forkTargets,
            isLiveNarration: lhs.isLiveNarration,
            delegatedLabel: lhs.delegatedLabel
        )
        == equalityKey(
            stableId: rhs.stableId, message: rhs.message,
            messageCreatedAt: rhs.messageCreatedAt,
            messagePhase: rhs.messagePhase,
            contentMaxWidth: rhs.contentMaxWidth,
            availableRowContentWidth: rhs.availableRowContentWidth ?? rhs.contentMaxWidth,
            availableTrailingGutterWidth: rhs.availableTrailingGutterWidth ?? .infinity,
            typography: rhs.typography,
            trustedImageRoot: rhs.trustedImageRoot,
            isForkEligible: rhs.isForkEligible, forkTargets: rhs.forkTargets,
            isLiveNarration: rhs.isLiveNarration,
            delegatedLabel: rhs.delegatedLabel
        )
    }

    /// Exposed so equality can be exercised in tests without constructing
    /// (and rendering) a `View`.
    static func equalityKey(
        stableId: String,
        message: ACPMessage,
        messageCreatedAt: Date? = nil,
        messagePhase: ACPMessagePhase? = nil,
        contentMaxWidth: CGFloat,
        availableRowContentWidth: CGFloat? = nil,
        availableTrailingGutterWidth: CGFloat? = nil,
        typography: ACPChatTypography,
        trustedImageRoot: URL?,
        isForkEligible: Bool = false,
        forkTargets: [ACPSessionForkTarget] = [],
        isLiveNarration: Bool = false,
        delegatedLabel: String? = nil
    ) -> EqualityKey {
        EqualityKey(
            stableId: stableId, message: message,
            symbolSnapshots: symbolSnapshots(in: message),
            messageCreatedAt: messageCreatedAt,
            messagePhase: messagePhase ?? presentationPhase(of: message),
            contentMaxWidth: contentMaxWidth,
            availableRowContentWidth: availableRowContentWidth ?? contentMaxWidth,
            availableTrailingGutterWidth: availableTrailingGutterWidth ?? .infinity,
            typography: typography, trustedImageRoot: trustedImageRoot,
            isForkEligible: isForkEligible, forkTargets: forkTargets,
            isLiveNarration: isLiveNarration,
            delegatedLabel: delegatedLabel
        )
    }

    struct EqualityKey: Equatable {
        let stableId: String
        let message: ACPMessage
        /// `Attachment.==` leaves out `symbol` so an echoed copy still
        /// reconciles, but the chip's label and click target read it, and
        /// it changes in place once the prompt is sent.
        let symbolSnapshots: [ACPSymbolSnapshot?]
        let messageCreatedAt: Date?
        let messagePhase: ACPMessagePhase?
        let contentMaxWidth: CGFloat
        let availableRowContentWidth: CGFloat
        let availableTrailingGutterWidth: CGFloat
        let typography: ACPChatTypography
        let trustedImageRoot: URL?
        let isForkEligible: Bool
        let forkTargets: [ACPSessionForkTarget]
        let isLiveNarration: Bool
        let delegatedLabel: String?
    }

    static func presentationPhase(of message: ACPMessage) -> ACPMessagePhase? {
        guard case .agent(_, _, let buffer) = message else { return nil }
        return buffer.phase
    }

    /// Empty unless an attachment carries a snapshot, so ordinary rows
    /// don't allocate.
    static func symbolSnapshots(in message: ACPMessage) -> [ACPSymbolSnapshot?] {
        guard case .user(_, _, _, let attachments, _, _) = message,
              attachments.contains(where: { $0.symbol != nil })
        else { return [] }
        return attachments.map(\.symbol)
    }

    static func checkpointID(in message: ACPMessage) -> CheckpointID? {
        guard case .user(_, _, _, let attachments, _, _) = message else { return nil }
        for attachment in attachments {
            if let checkpointID = attachment.checkpointID { return checkpointID }
        }
        return nil
    }

    static func showsInlineTimestamp(
        availableRowContentWidth: CGFloat,
        availableTrailingGutterWidth: CGFloat
    ) -> Bool {
        availableRowContentWidth >= ACPMessageGutterLayout.inlineTimestampMinimumContentWidth
            && availableTrailingGutterWidth >= ACPMessageGutterLayout.inlineTimestampTrailingExtent
    }

    /// Where symbol previews read files. A workspace checkout's symbol paths
    /// are relative to the checkout root, which this row does not have, so a
    /// preview there would read the wrong repository: it gets none.
    private var symbolPreviewRoot: URL? {
        if case .workspaceCheckout = session.owner { return nil }
        return trustedImageRoot
    }

    var body: some View {
        switch message {
        case .user(_, _, let text, let attachments, let delegatedSource, let pastedSpans):
            ACPMessageGutter(
                copySource: .text(text),
                messageCreatedAt: messageCreatedAt,
                showsInlineTimestamp: Self.showsInlineTimestamp(
                    availableRowContentWidth: availableRowContentWidth ?? contentMaxWidth,
                    availableTrailingGutterWidth: availableTrailingGutterWidth ?? .infinity
                ),
                forkBoundary: forkBoundary(kind: .user),
                forkTargets: forkTargets,
                onQuote: onQuote,
                onFork: onFork,
                checkpointID: Self.checkpointID(in: message),
                onRestoreCheckpoint: onRestoreCheckpoint,
                messageMenuItems: messageMenuItems
            ) {
                if let delegatedSource {
                    DelegatedPromptRow(
                        text: text,
                        label: delegatedLabel
                            ?? ACPDelegatedPromptSource.transcriptLabel(for: delegatedSource, agentDisplayName: { $0 }),
                        isFromChild: delegatedSource.isFromChild,
                        contentMaxWidth: contentMaxWidth,
                        typography: typography
                    )
                } else {
                    UserMessageRow(
                        text: text,
                        attachments: attachments,
                        symbolSnapshots: Self.symbolSnapshots(in: message),
                        pastedSpans: pastedSpans,
                        contentMaxWidth: contentMaxWidth,
                        typography: typography,
                        session: session,
                        chipsAbsolutePaths: !(trustedImageRoot?.isRemoteAlasPath ?? false),
                        worktreeRoot: symbolPreviewRoot
                    )
                }
            }
        case .agent(_, _, let buf):
            ACPMessageGutter(
                copySource: .streaming(buf),
                messageCreatedAt: messageCreatedAt,
                showsInlineTimestamp: Self.showsInlineTimestamp(
                    availableRowContentWidth: availableRowContentWidth ?? contentMaxWidth,
                    availableTrailingGutterWidth: availableTrailingGutterWidth ?? .infinity
                ),
                forkBoundary: forkBoundary(kind: .agent),
                forkTargets: forkTargets,
                onQuote: onQuote,
                onFork: onFork,
                checkpointID: nil,
                onRestoreCheckpoint: onRestoreCheckpoint,
                messageMenuItems: messageMenuItems
            ) {
                if buf.phase == .commentary {
                    ACPCommentaryRow(
                        messageId: stableId,
                        transcript: transcript,
                        buffer: buf,
                        typography: typography,
                        isLive: isLiveNarration
                    )
                } else {
                    AgentMessageRow(
                        messageId: stableId,
                        transcript: transcript,
                        buffer: buf,
                        typography: typography
                    )
                }
            }
            .environment(\.acpTrustedImageRoot, trustedImageRoot)
        case .thought(_, _, let buf):
            ACPThoughtView(buffer: buf, isLive: isLiveNarration)
        case .toolCall(let tc):
            if let compaction = ACPContextCompaction(toolCall: tc) {
                ACPContextCompactionView(compaction: compaction)
            } else if let task = ACPBackgroundTask(toolCall: tc) {
                if task.showInTranscript {
                    ACPBackgroundTaskTranscriptRow(task: task)
                }
            } else if let descriptor = ACPSubagentRowDescriptor(toolCall: tc),
                      let run = session.subagentRun(descriptor.subagentSessionId) {
                ACPSubagentRowView(
                    descriptor: descriptor,
                    run: run,
                    typography: typography,
                    trustedImageRoot: trustedImageRoot,
                    symbolPreviewRoot: symbolPreviewRoot,
                    onCancel: onCancelSubagent.map { cancel in
                        { cancel(descriptor.subagentSessionId) }
                    })
                    // A child's terminal-backed tool calls are served by the
                    // same host as the parent's — terminals belong to the
                    // connection, not to the session that asked for one — so
                    // the expanded child card needs it in the environment
                    // exactly like the ordinary tool-call path below.
                    .environment(\.acpTerminalHost, session.terminalHost)
                    .environment(\.acpTrustedImageRoot, trustedImageRoot)
            } else {
                ACPToolCallCard(
                    toolCall: tc,
                    messageCreatedAt: messageCreatedAt,
                    trustedImageRoot: trustedImageRoot,
                    loadFullContent: tc.isContentTruncated ? onLoadFullToolCallContent : nil)
                    .environment(\.acpTerminalHost, session.terminalHost)
            }
        case .fileEdit(_, let edit):
            ACPFileEditCard(edit: edit, onOpenDiff: onOpenDiff)
        case .plan:
            EmptyView()
        case .systemNotice(_, let text):
            ACPSystemNoticeView(text: text)
        case .visualAid(let visual):
            ACPVisualAidCard(
                visual: visual, form: session.visualAidForm(for: visual),
                sendStatus: session.visualAidSendStatus(for: visual.id), actions: visualAidActions)
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
