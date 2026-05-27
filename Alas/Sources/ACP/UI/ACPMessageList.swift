import SwiftUI

struct ACPMessageList: View {
    @ObservedObject var session: ACPSession
    let onOpenDiff: (String) -> Void
    let policy: ACPPermissionPolicy?
    let scopeKey: String
    @Environment(\.theme) private var theme

    /// Height of an invisible spacer at the tail of the VStack. The
    /// composer pill plus its outer padding occupies roughly this much
    /// vertical space, so by scrolling THAT element to the viewport
    /// bottom we guarantee the streaming caret / last message sits
    /// above the composer instead of behind it.
    private let composerSpacerHeight: CGFloat = 220

    /// Cheap signature of the entire transcript. SwiftUI re-evaluates when
    /// any cell mutates (e.g. an agent_message_chunk merging into the
    /// trailing message) so the scroll-to-bottom hook fires for streaming
    /// edits in addition to brand-new rows.
    private var scrollSignature: Int {
        var hasher = Hasher()
        hasher.combine(session.messages.count)
        if let last = session.messages.last {
            hasher.combine(last.kind)
            switch last {
            case .agent(let t), .thought(let t), .systemNotice(let t):
                hasher.combine(t.count)
            case .toolCall(let tc):
                hasher.combine(tc.status)
                hasher.combine(tc.content.count)
            case .fileEdit(let e):
                hasher.combine(e.added); hasher.combine(e.removed)
            case .plan(let items):
                hasher.combine(items.count)
                for it in items { hasher.combine(it.status) }
            case .user(let t, _):
                hasher.combine(t.count)
            }
        }
        return hasher.finalize()
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    ForEach(Array(session.messages.enumerated()), id: \.offset) { idx, message in
                        row(for: message).id(idx)
                    }
                    if session.pendingPermission != nil, let policy = policy {
                        ACPPermissionPrompt(session: session, policy: policy, scopeKey: scopeKey)
                            .id("__pending_perm__")
                    }
                    if session.streamingState == .streaming {
                        StreamingCaret().frame(width: 8, height: 14)
                            .id("__streaming_caret__")
                    }
                    // Invisible tail spacer that the auto-scroll pins to
                    // the viewport bottom; this guarantees the streaming
                    // caret / last message sits above the composer pill.
                    Color.clear
                        .frame(height: composerSpacerHeight)
                        .id("__composer_spacer__")
                }
                .frame(maxWidth: 720, alignment: .leading)
                .padding(.horizontal, 28)
                .padding(.top, 24)
                .frame(maxWidth: .infinity, alignment: .center)
            }
            .onChange(of: scrollSignature) { _, _ in
                withAnimation(.easeOut(duration: 0.12)) {
                    proxy.scrollTo("__composer_spacer__", anchor: .bottom)
                }
            }
            .onChange(of: session.streamingState) { _, new in
                if new == .streaming || new == .sending {
                    withAnimation(.easeOut(duration: 0.12)) {
                        proxy.scrollTo("__composer_spacer__", anchor: .bottom)
                    }
                }
            }
        }
        .background(
            LinearGradient(
                colors: [theme.color("bg-1"), theme.color("bg-0")],
                startPoint: .top, endPoint: .bottom
            )
        )
    }

    @ViewBuilder
    private func row(for m: ACPMessage) -> some View {
        switch m {
        case .user(let text, let attachments):
            UserMessageRow(text: text, attachments: attachments)
        case .agent(let text):
            AgentMessageRow(text: text)
        case .thought(let text):
            ACPThoughtView(text: text)
        case .toolCall(let tc):
            ACPToolCallCard(toolCall: tc)
        case .fileEdit(let edit):
            ACPFileEditCard(edit: edit, onOpenDiff: { onOpenDiff(edit.path) })
        case .plan(let items):
            ACPPlanCard(items: items)
        case .systemNotice(let text):
            ACPSystemNoticeView(text: text)
        }
    }
}

// MARK: - User bubble (right-aligned)

private struct UserMessageRow: View {
    let text: String
    let attachments: [ACPMessage.Attachment]
    @Environment(\.theme) private var theme

    var body: some View {
        HStack {
            Spacer(minLength: 40)
            VStack(alignment: .trailing, spacing: 4) {
                if !attachments.isEmpty {
                    HStack(spacing: 4) {
                        ForEach(attachments, id: \.uri) { a in
                            FileChip(path: a.name ?? a.uri, lines: nil, iconSystemName: "at")
                        }
                    }
                }
                ACPMarkdownText(raw: text)
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
            .frame(maxWidth: 540, alignment: .trailing)
        }
        .frame(maxWidth: .infinity)
    }
}

// MARK: - Agent prose (markdown-rendered, full-width)

private struct AgentMessageRow: View {
    let text: String
    var body: some View {
        ACPMarkdownText(raw: text)
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
