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
struct ACPTranscriptRowContent: View, Equatable {
    // Compared (render-relevant values):
    let stableId: String
    let messageIndex: Int
    let message: ACPMessage
    let messagePhase: ACPMessagePhase?
    let contentMaxWidth: CGFloat
    let typography: ACPChatTypography
    let trustedImageRoot: URL?
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
    var onQuote: (String) -> Void = { _ in }
    let onFork: (ACPForkMessageBoundary, String) -> Void

    static func == (lhs: Self, rhs: Self) -> Bool {
        guard lhs.messagePhase == rhs.messagePhase else { return false }
        return equalityKey(
            stableId: lhs.stableId, message: lhs.message,
            messagePhase: lhs.messagePhase,
            contentMaxWidth: lhs.contentMaxWidth, typography: lhs.typography,
            trustedImageRoot: lhs.trustedImageRoot,
            isForkEligible: lhs.isForkEligible, forkTargets: lhs.forkTargets
        )
        == equalityKey(
            stableId: rhs.stableId, message: rhs.message,
            messagePhase: rhs.messagePhase,
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
        messagePhase: ACPMessagePhase? = nil,
        contentMaxWidth: CGFloat,
        typography: ACPChatTypography,
        trustedImageRoot: URL?,
        isForkEligible: Bool = false,
        forkTargets: [ACPSessionForkTarget] = []
    ) -> EqualityKey {
        EqualityKey(
            stableId: stableId, message: message,
            messagePhase: messagePhase ?? presentationPhase(of: message),
            contentMaxWidth: contentMaxWidth,
            typography: typography, trustedImageRoot: trustedImageRoot,
            isForkEligible: isForkEligible, forkTargets: forkTargets
        )
    }

    struct EqualityKey: Equatable {
        let stableId: String
        let message: ACPMessage
        let messagePhase: ACPMessagePhase?
        let contentMaxWidth: CGFloat
        let typography: ACPChatTypography
        let trustedImageRoot: URL?
        let isForkEligible: Bool
        let forkTargets: [ACPSessionForkTarget]
    }

    static func presentationPhase(of message: ACPMessage) -> ACPMessagePhase? {
        guard case .agent(_, _, let buffer) = message else { return nil }
        return buffer.phase
    }

    var body: some View {
        switch message {
        case .user(_, _, let text, let attachments, let delegatedSource):
            ACPMessageGutter(
                copySource: .text(text),
                forkBoundary: forkBoundary(kind: .user),
                forkTargets: forkTargets,
                onQuote: onQuote,
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
                onQuote: onQuote,
                onFork: onFork
            ) {
                if buf.phase == .commentary {
                    ACPCommentaryRow(buffer: buf)
                } else {
                    AgentMessageRow(
                        messageId: stableId,
                        transcript: transcript,
                        buffer: buf,
                        typography: typography
                    )
                }
            }
        case .thought(_, _, let buf):
            ACPThoughtView(buffer: buf)
        case .toolCall(let tc):
            if let compaction = ACPContextCompaction(toolCall: tc) {
                ACPContextCompactionView(compaction: compaction)
            } else {
                ACPToolCallCard(
                    toolCall: tc,
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
