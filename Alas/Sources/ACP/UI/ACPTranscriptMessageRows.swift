import SwiftUI

// MARK: - User bubble (right-aligned)

struct UserMessageRow: View {
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

struct AgentMessageRow: View {
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

/// Codex `commentary`-phase prose: the narration the model writes before and
/// between tool calls, as opposed to its final answer. It is ordinary
/// user-facing markdown, so it renders exactly like `AgentMessageRow` — the
/// left bar and "Working…" label only mark it as narration, mirroring the
/// affordance `ACPThoughtView` uses for reasoning.
struct ACPCommentaryRow: View {
    let messageId: String
    let transcript: ACPTranscript
    @ObservedObject var buffer: StreamingText
    let typography: ACPChatTypography
    @Environment(\.theme) private var theme

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Rectangle()
                .fill(theme.color("bg-4"))
                .frame(width: 1.5)
                .padding(.vertical, 2)
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 7) {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 11))
                        .foregroundStyle(theme.color("fg-faint"))
                    Text("Working…")
                        .font(.system(size: 11))
                        .foregroundStyle(theme.color("fg-faint"))
                }
                AgentMessageRow(
                    messageId: messageId,
                    transcript: transcript,
                    buffer: buffer,
                    typography: typography
                )
            }
        }
    }
}
