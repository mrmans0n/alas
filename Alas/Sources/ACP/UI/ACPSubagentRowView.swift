import SwiftUI

/// Per-row-INSTANCE identity for the child transcript's `ForEach`.
///
/// Unlike `ACPMessage.stableIdentityKey` (content-addressed — the same
/// `messageId` always maps to the same key, which is exactly what replay
/// reconciliation needs to locate a row to update), this always distinguishes
/// two separate rows even when they share a `messageId`, since a child's
/// replay reconciliation deliberately keeps two turns that reuse an id as
/// two rows (see `applyReplayedUserChunk`). Built from each case's own
/// per-instance id (or `toolCallId`, the one case without a UUID), which
/// `resetTextRow`/in-place merges preserve across replay reconciliation, and
/// which a genuinely new row (append or `insertRecovered`) always mints
/// fresh — so it stays both unique per row and stable across the array
/// shifts a mid-transcript insertion causes.
private extension ACPMessage {
    var rowViewIdentity: AnyHashable {
        switch self {
        case .user(let id, _, _, _, _): id
        case .agent(let id, _, _): id
        case .thought(let id, _, _): id
        case .fileEdit(let id, _): id
        case .plan(let id, _): id
        case .systemNotice(let id, _): id
        case .toolCall(let toolCall): toolCall.toolCallId
        }
    }
}

/// A native subagent in the parent transcript: one collapsible row showing
/// the child's name, task and live state, expanding to its transcript
/// inline.
///
/// The child transcript is rendered nested rather than tiled as sibling
/// rows (the way an expanded tool-call bundle is). A bundle's members are
/// the parent's own messages, so the scroller needs real per-message rows
/// for them; a child session's messages are not parent rows at all, and
/// giving them transcript indices would corrupt every anchor, fork
/// boundary and window calculation that maps an index to a parent message.
struct ACPSubagentRowView: View {
    let descriptor: ACPSubagentRowDescriptor
    /// The live child transcript. Nil while the run has not been restored
    /// (a mirror snapshot, or a row from a session whose child rows were
    /// pruned) — the header still renders from the persisted descriptor.
    @ObservedObject var run: ACPSubagentRun
    let typography: ACPChatTypography
    let trustedImageRoot: URL?
    var onCancel: (() -> Void)?

    @State private var expanded = false
    @Environment(\.theme) private var theme

    private var state: ACPSubagentState { run.state }

    var body: some View {
        ACPToolCallGroupLane {
            VStack(alignment: .leading, spacing: 8) {
                header
                if let lastError = run.lastError, state == .failed {
                    // Often the only explanation a failed child leaves
                    // behind, especially one that produced no output of
                    // its own — dropping it would make the failure
                    // permanently unexplained.
                    Text(lastError)
                        .font(.system(size: 10.5))
                        .foregroundStyle(theme.color("fg-faint"))
                        .lineLimit(3)
                        .padding(.leading, 17)
                }
                if expanded {
                    childTranscript
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var header: some View {
        HStack(spacing: 7) {
            Button {
                expanded.toggle()
            } label: {
                HStack(spacing: 7) {
                    Image(systemName: "person.2")
                        .font(.system(size: 10))
                        .foregroundStyle(theme.color("fg-faint"))
                    Text(run.displayName)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(theme.color("fg-muted"))
                    Text(ACPSubagentRowPolicy.stateLabel(for: state))
                        .font(.system(size: 10))
                        .foregroundStyle(theme.color("fg-faint"))
                    if let summary = ACPSubagentRowPolicy.summary(
                        task: run.task,
                        messageCount: run.messages.count
                    ) {
                        Text(summary)
                            .font(.system(size: 11))
                            .foregroundStyle(theme.color("fg-faint"))
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                    if ACPSubagentRowPolicy.showsSpinner(state: state) {
                        Spinner(lineWidth: 1.5, duration: 0.7).frame(width: 11, height: 11)
                    }
                    Image(systemName: "chevron.down")
                        .font(.system(size: 9))
                        .foregroundStyle(theme.color("fg-faint"))
                        .rotationEffect(.degrees(expanded ? 180 : 0))
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(ACPSubagentRowPolicy.disclosureLabel(
                expanded: expanded,
                messageCount: run.messages.count))
            Spacer(minLength: 6)
            if let onCancel, ACPSubagentRowPolicy.showsCancel(
                state: state,
                capabilities: run.capabilities
            ) {
                Button("Cancel", action: onCancel)
                    .buttonStyle(.plain)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(theme.color("fg-faint"))
                    .accessibilityLabel("Cancel subagent")
            }
        }
    }

    @ViewBuilder
    private var childTranscript: some View {
        if run.messages.isEmpty {
            Text(state.isTerminal ? "No output." : "Waiting for output…")
                .font(.system(size: 11))
                .foregroundStyle(theme.color("fg-faint"))
        } else {
            VStack(alignment: .leading, spacing: 10) {
                // Keyed by each row's own per-instance identity, not its
                // array offset — replay recovery can insert a missing row
                // in the middle of an already-expanded transcript, shifting
                // every later message's offset by one. Keying by offset
                // would let SwiftUI reuse each shifted row's view identity
                // (and therefore its local state, like an
                // `ACPToolCallCard`'s `expanded` flag) for what is now a
                // DIFFERENT message. NOT `stableIdentityKey`: two child
                // turns can legitimately reuse the same `messageId` (see
                // `applyReplayedUserChunk`), which would give both rows the
                // same key and reintroduce the identity collision this
                // fix exists to prevent.
                // A child has no `streamingState`; its run state is the
                // equivalent gate, and the trailing narration is live for
                // as long as the child is still working.
                let liveIndex = run.isRunning
                    ? ACPNarrationLiveness.liveIndex(
                        messages: run.messages,
                        isStreaming: true,
                        lastContentTouchIndex: run.lastContentTouchIndex)
                    : nil
                ForEach(Array(run.messages.enumerated()), id: \.element.rowViewIdentity) { index, message in
                    ACPSubagentMessageRow(
                        stableId: "\(descriptor.subagentSessionId)#\(message.stableId)",
                        message: message,
                        typography: typography,
                        trustedImageRoot: trustedImageRoot,
                        isLiveNarration: index == liveIndex)
                }
            }
            .padding(.leading, 2)
        }
    }
}

/// One row of a child transcript. Reuses the parent's row views so a
/// child's tool calls, thoughts and prose are rendered by exactly the same
/// code, minus the affordances that only make sense on a parent message
/// (fork, quote, checkpoint restore, timestamps gutter).
private struct ACPSubagentMessageRow: View {
    let stableId: String
    let message: ACPMessage
    let typography: ACPChatTypography
    let trustedImageRoot: URL?
    let isLiveNarration: Bool
    @Environment(\.theme) private var theme

    var body: some View {
        switch message {
        case .agent(_, _, let buffer):
            ACPSubagentTextRow(buffer: buffer, typography: typography, isLive: isLiveNarration)
        case .thought(_, _, let buffer):
            ACPThoughtView(buffer: buffer, isLive: isLiveNarration)
        case .user(_, _, let text, let attachments, _):
            ACPSubagentPromptRow(text: text, attachments: attachments)
        case .toolCall(let toolCall):
            ACPToolCallCard(toolCall: toolCall, trustedImageRoot: trustedImageRoot)
        case .fileEdit(_, let edit):
            ACPFileEditCard(edit: edit, onOpenDiff: { _ in })
        case .plan(_, let items):
            ACPPlanChecklist(items: items)
        case .systemNotice(_, let text):
            ACPSystemNoticeView(text: text)
        }
    }
}

/// The prompt handed to a child. Compact by design — no bubble, no
/// gutter — but it must still show what the child was given: an
/// attachment-only prompt is a real shape (a screenshot with no words),
/// and it would otherwise render as an empty row.
private struct ACPSubagentPromptRow: View {
    let text: String
    let attachments: [ACPMessage.Attachment]
    @Environment(\.theme) private var theme

    private var visibleAttachments: [ACPMessage.Attachment] {
        attachments.filter { !$0.isCheckpointReference }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            let images = visibleAttachments.filter { ($0.mimeType?.hasPrefix("image/")) == true }
            let others = visibleAttachments.filter { ($0.mimeType?.hasPrefix("image/")) != true }
            if !images.isEmpty {
                HStack(spacing: 6) {
                    // Keyed by index, not uri: the same image attached
                    // twice shares a uri and duplicate ids collapse the row.
                    ForEach(Array(images.enumerated()), id: \.offset) { index, attachment in
                        if let url = URL(string: attachment.uri) {
                            ACPImageThumbnail(
                                fileURL: url,
                                index: images.count > 1 ? index + 1 : nil)
                        }
                    }
                }
            }
            if !others.isEmpty {
                HStack(spacing: 4) {
                    ForEach(others, id: \.uri) { attachment in
                        FileChip(
                            path: attachment.name ?? attachment.uri,
                            lines: nil,
                            iconSystemName: "at")
                    }
                }
            }
            if !text.isEmpty {
                Text(text)
                    .font(.system(size: 11))
                    .foregroundStyle(theme.color("fg-faint"))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// A child's prose. Rendered without the parent's markdown block cache:
/// the cache is keyed per parent message and a child row has no entry of
/// its own, so it renders straight from the buffer.
/// Not `private`: measured directly by `ACPNarrationShimmerTests`, same
/// reasoning as `ACPToolCallGroupHeaderRow`/`ACPToolCallGroupLane`.
struct ACPSubagentTextRow: View {
    @ObservedObject var buffer: StreamingText
    let typography: ACPChatTypography
    /// Whether this is the row the child is currently writing into —
    /// meaningful only for `.commentary` (see below), passed through
    /// regardless since the buffer's own phase is what decides.
    var isLive: Bool = false
    @Environment(\.theme) private var theme

    var body: some View {
        if buffer.phase == .commentary {
            // Mirrors the parent transcript's `ACPCommentaryRow` — same
            // "Working…" affordance and shimmer, minus the gutter (fork,
            // quote, checkpoint) that only makes sense on a parent message.
            HStack(alignment: .top, spacing: 12) {
                Rectangle()
                    .fill(theme.color("bg-4"))
                    .frame(width: 1.5)
                    .acpNarrationShimmer(isActive: isLive, axis: .vertical)
                    .padding(.vertical, 2)
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 7) {
                        Image(systemName: "hammer")
                            .font(.system(size: 11))
                            .foregroundStyle(theme.color("fg-faint"))
                        Text("Working…")
                            .font(.system(size: 11))
                            .foregroundStyle(theme.color("fg-faint"))
                    }
                    .acpNarrationShimmer(isActive: isLive)
                    ACPMarkdownText(raw: buffer.value, typography: typography)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        } else {
            ACPMarkdownText(raw: buffer.value, typography: typography)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
