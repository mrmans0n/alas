import SwiftUI

// MARK: - User bubble (right-aligned)

struct UserMessageRow: View {
    let text: String
    let attachments: [ACPMessage.Attachment]
    let contentMaxWidth: CGFloat
    let typography: ACPChatTypography
    let session: ACPSession
    let chipsAbsolutePaths: Bool
    @Environment(\.theme) private var theme
    @Environment(\.acpUpstreamReferenceStore) private var upstreamReferences
    var body: some View {
        HStack {
            Spacer(minLength: 40)
            VStack(alignment: .trailing, spacing: 4) {
                let visibleAttachments = attachments.filter { !$0.isCheckpointReference }
                if !visibleAttachments.isEmpty {
                    let images = visibleAttachments.filter { ($0.mimeType?.hasPrefix("image/")) == true }
                    let others = visibleAttachments.filter { ($0.mimeType?.hasPrefix("image/")) != true }
                    if !images.isEmpty {
                        HStack(spacing: 6) {
                            // Key by index, not uri: content-addressed staging
                            // means the same image attached twice shares a uri,
                            // and duplicate ForEach ids collapse the row.
                            ForEach(Array(images.enumerated()), id: \.offset) { index, a in
                                if let url = URL(string: a.uri) {
                                    ACPImageThumbnail(
                                        fileURL: url,
                                        index: images.count > 1 ? index + 1 : nil
                                    )
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
                if let upstreamReferences {
                    ACPUserReferenceSummary(text: text, store: upstreamReferences)
                }
                ACPUserMessageText(
                    text: text,
                    attachments: attachments,
                    typography: typography,
                    session: session,
                    chipsAbsolutePaths: chipsAbsolutePaths
                )
                .acpUserBubble()
            }
            .frame(maxWidth: contentMaxWidth * 0.75, alignment: .trailing)
        }
        .frame(maxWidth: .infinity)
    }
}

private struct ACPUserReferenceSummary: View {
    let text: String
    @ObservedObject var store: ACPUpstreamReferenceStore
    @Environment(\.theme) private var theme

    var body: some View {
        Group {
            if let host = store.hostKind {
                let references = ACPUpstreamReferenceChip.summaryReferences(in: text, host: host, theme: theme)
                if !references.isEmpty {
                    VStack(alignment: .trailing, spacing: 4) {
                        ForEach(references, id: \.self) { reference in
                            ACPUserReferenceSummaryItem(reference: reference, store: store)
                        }
                    }
                }
            }
        }
    }
}

private struct ACPUserReferenceSummaryItem: View {
    let reference: CodeHostReference
    @ObservedObject var store: ACPUpstreamReferenceStore
    @State private var isHovering = false
    @State private var showsCard = false
    @Environment(\.openURL) private var openURL
    @Environment(\.theme) private var theme

    var body: some View {
        let model = ACPUpstreamReferenceCardModel.make(
            reference: reference, entry: store.entry(for: reference), now: Date()
        )
        Button {
            if let url = store.url(for: reference) { openURL(url) }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: model.kind == .issue ? "smallcircle.filled.circle" : "arrow.triangle.pull")
                    .foregroundStyle(Color(nsColor: ACPUpstreamReferenceChipStyle.tint(for: model.kind)))
                Text(reference.spelling)
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                if let title = model.title {
                    Text(title)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                if let badge = model.badge {
                    Text(badge.label)
                        .foregroundStyle(Color(nsColor: badge.color))
                }
            }
            .font(.system(size: 11))
            .foregroundStyle(theme.color("fg-muted"))
            .padding(.horizontal, 7)
            .padding(.vertical, 4)
            .background(theme.color("bg-2").opacity(0.8), in: RoundedRectangle(cornerRadius: 6))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(store.url(for: reference) == nil)
        .onAppear { store.ensureLoaded(reference) }
        .onHover { isHovering = $0 }
        .onDisappear {
            isHovering = false
            showsCard = false
        }
        .task(id: isHovering) {
            guard isHovering else {
                showsCard = false
                return
            }
            try? await Task.sleep(for: .seconds(ACPImageChipHoverController.hoverDelay))
            if !Task.isCancelled { showsCard = true }
        }
        .popover(isPresented: $showsCard, arrowEdge: .bottom) {
            ACPUpstreamReferenceHoverCard(reference: reference, store: store)
        }
    }
}

/// The accent bubble that wraps a user's prompt. Shared with the mirrored
/// peer transcript so a forwarded prompt reads exactly like a local one.
struct ACPUserBubbleChrome: ViewModifier {
    @Environment(\.theme) private var theme

    private var shape: UnevenRoundedRectangle {
        UnevenRoundedRectangle(
            cornerRadii: .init(topLeading: 12, bottomLeading: 12, bottomTrailing: 4, topTrailing: 12)
        )
    }

    func body(content: Content) -> some View {
        content
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
            .clipShape(shape)
            .overlay(shape.strokeBorder(theme.color("accent").opacity(0.5), lineWidth: 0.5))
            .shadow(color: .black.opacity(0.2), radius: 8, y: 2)
    }
}

extension View {
    func acpUserBubble() -> some View {
        modifier(ACPUserBubbleChrome())
    }
}

// MARK: - Delegated prompt (incoming bubble)

/// A prompt Alas delivered on another session's behalf: a child's report to
/// its parent, or a parent's (or mission's) prompt to a child. Nobody typed
/// it here, so it renders as an incoming bubble (the user bubble mirrored to
/// the left, in neutral slate) with the sender captioned above it. Long
/// prompts fold to a few lines until expanded.
struct DelegatedPromptRow: View {
    let text: String
    let label: String
    let isFromChild: Bool
    let contentMaxWidth: CGFloat
    let typography: ACPChatTypography
    /// Local like `ACPThoughtView.expanded`: a rebuilt row folds again.
    @State private var isExpanded = false
    @Environment(\.theme) private var theme

    nonisolated static let foldLineThreshold = 12
    nonisolated static let foldCharacterThreshold = 900
    private static let foldedVisibleLines: CGFloat = 8

    /// The raw line count when `text` is long enough to fold, else nil.
    /// Decided from the text alone: measuring the rendered height would
    /// write state from a geometry callback, which live-locks the transcript.
    nonisolated static func foldedLineCount(for text: String) -> Int? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let lineCount = trimmed.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline).count
        guard lineCount > foldLineThreshold || trimmed.count > foldCharacterThreshold else { return nil }
        return lineCount
    }

    var body: some View {
        let foldedLineCount = Self.foldedLineCount(for: text)
        let isFolded = foldedLineCount != nil && !isExpanded
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 6) {
                    Image(systemName: isFromChild ? "arrow.turn.down.left" : "arrow.turn.down.right")
                        .font(.system(size: 11))
                    Text(label)
                        .font(.system(size: 11, weight: .medium))
                }
                .foregroundStyle(theme.color("fg-faint"))
                .padding(.leading, 4)
                VStack(alignment: .leading, spacing: 6) {
                    ACPMarkdownText(raw: text, typography: typography.flatteningHeadings())
                        .frame(maxHeight: isFolded ? foldedHeight : nil, alignment: .top)
                        .clipped()
                        .contentShape(Rectangle())
                        .mask(foldMask(isFolded: isFolded))
                    if let foldedLineCount {
                        foldToggle(lineCount: foldedLineCount)
                    }
                }
                .padding(.vertical, 9)
                .padding(.horizontal, 13)
                .background(
                    LinearGradient(
                        colors: [theme.color("bg-3"), theme.color("bg-2")],
                        startPoint: .top, endPoint: .bottom
                    )
                )
                .clipShape(bubbleShape)
                .overlay(bubbleShape.strokeBorder(theme.color("bg-5"), lineWidth: 0.5))
                .shadow(color: .black.opacity(0.2), radius: 8, y: 2)
            }
            .frame(maxWidth: contentMaxWidth * 0.84, alignment: .leading)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// The user bubble's shape mirrored: the tail corner is bottom-leading.
    private var bubbleShape: UnevenRoundedRectangle {
        UnevenRoundedRectangle(
            cornerRadii: .init(topLeading: 12, bottomLeading: 4, bottomTrailing: 12, topTrailing: 12)
        )
    }

    private var foldedHeight: CGFloat {
        let font = typography.appKitFont(size: typography.paragraphSize)
        return ceil((font.ascender - font.descender + font.leading) * Self.foldedVisibleLines)
    }

    /// Fades the last lines of a folded prompt; fully opaque otherwise.
    private func foldMask(isFolded: Bool) -> LinearGradient {
        LinearGradient(
            stops: [
                .init(color: .black, location: isFolded ? 0.6 : 1),
                .init(color: isFolded ? .clear : .black, location: 1)
            ],
            startPoint: .top, endPoint: .bottom
        )
    }

    private func foldToggle(lineCount: Int) -> some View {
        Button { isExpanded.toggle() } label: {
            HStack(spacing: 5) {
                Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                    .font(.system(size: 9, weight: .semibold))
                Text(isExpanded ? "Collapse" : "Show full prompt · \(lineCount) lines")
            }
            .font(.system(size: 11.5))
            .foregroundStyle(theme.color("fg-dim"))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
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
    /// Whether the agent is still writing this narration — see
    /// `ACPThoughtView.isLive`.
    var isLive: Bool = false
    @Environment(\.theme) private var theme

    var body: some View {
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
