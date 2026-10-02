import AppKit
import SwiftUI

/// Sends a question from the card. Returns whether it was accepted;
/// `completion` reports whether an accepted question was delivered.
typealias ACPSideQuestionAsk = (
    _ text: String,
    _ completion: @escaping @MainActor (Bool) -> Void
) -> Bool

/// Floating card above the composer that shows a `/btw` side question and
/// its answer. The answer comes from a hidden, read-only fork and never
/// enters the parent's transcript.
struct ACPSideQuestionCard: View {
    let entry: ACPSideQuestion
    /// Nil until the side session exists.
    let side: ACPSession?
    let policy: ACPPermissionPolicy?
    let typography: ACPChatTypography
    let onAsk: ACPSideQuestionAsk
    let onDismiss: () -> Void
    let onInsert: (String) -> Void
    let onKeep: () -> Void
    /// Retries or drops a follow-up whose send failed in the side queue.
    let onRetryQueued: (UUID) -> Void
    let onRemoveQueued: (UUID) -> Void

    var body: some View {
        if let side {
            SessionCard(
                entry: entry,
                side: side,
                transcript: side.transcript,
                policy: policy,
                typography: typography,
                onAsk: onAsk,
                onDismiss: onDismiss,
                onInsert: onInsert,
                onKeep: onKeep,
                onRetryQueued: onRetryQueued,
                onRemoveQueued: onRemoveQueued
            )
        } else {
            ACPSideQuestionCardChrome(
                question: entry.question,
                phase: ACPSideQuestionPhase.resolve(
                    question: entry.question,
                    creationError: entry.error,
                    hasSession: false,
                    sessionError: nil,
                    isTurnActive: false,
                    hasOutput: false
                ),
                modelName: nil,
                answer: nil,
                hasContent: false,
                // Retry after a failure; not while the question is starting.
                canAsk: entry.question.isEmpty || entry.error != nil,
                onAsk: onAsk,
                onDismiss: onDismiss,
                onInsert: onInsert,
                onKeep: nil
            ) { EmptyView() }
        }
    }

    private struct SessionCard: View {
        let entry: ACPSideQuestion
        @ObservedObject var side: ACPSession
        @ObservedObject var transcript: ACPTranscript
        let policy: ACPPermissionPolicy?
        let typography: ACPChatTypography
        let onAsk: ACPSideQuestionAsk
        let onDismiss: () -> Void
        let onInsert: (String) -> Void
        let onKeep: () -> Void
        let onRetryQueued: (UUID) -> Void
        let onRemoveQueued: (UUID) -> Void

        @Environment(\.theme) private var theme

        /// Messages after the ones inherited from the parent.
        private var ownMessages: ArraySlice<ACPMessage> {
            transcript.messages.dropFirst(side.forkRecord?.inheritedMessageCount ?? 0)
        }

        private var latestTurn: ArraySlice<ACPMessage> {
            let own = ownMessages
            guard let lastPrompt = own.lastIndex(where: { if case .user = $0 { true } else { false } }) else {
                return own
            }
            return own[lastPrompt...]
        }

        private var earlierQuestions: [String] {
            let own = ownMessages
            let latestStart = latestTurn.startIndex
            return own[own.startIndex..<latestStart].compactMap {
                if case .user(_, _, let text, _, _) = $0 { text } else { nil }
            }
        }

        private var failureReason: String? {
            if case .failed(let reason) = side.agentState { reason } else { nil }
        }

        private var latestAnswer: String {
            latestTurn.compactMap { if case .agent(_, _, let buffer) = $0 { buffer.value } else { nil } }
                .joined(separator: "\n\n")
        }

        var body: some View {
            let phase = ACPSideQuestionPhase.resolve(
                question: entry.question,
                creationError: entry.error,
                hasSession: true,
                sessionError: side.lastError ?? failureReason,
                isTurnActive: transcript.streamingState != .idle,
                hasOutput: latestTurn.dropFirst().contains {
                    if case .user = $0 { false } else { true }
                }
            )
            ACPSideQuestionCardChrome(
                question: entry.question,
                phase: phase,
                modelName: side.currentModelDisplayName,
                answer: latestAnswer.isEmpty ? nil : latestAnswer,
                hasContent: !ownMessages.isEmpty || !side.readOnlyBlockedTools.isEmpty,
                // A follow-up before the first question is sent would run first.
                canAsk: entry.isSubmitted,
                onAsk: onAsk,
                onDismiss: onDismiss,
                onInsert: onInsert,
                // Offered once the question was sent; see `promoteSideQuestion`.
                onKeep: entry.isSubmitted ? onKeep : nil
            ) {
                VStack(alignment: .leading, spacing: 6) {
                    // The first question is the header; later ones collapse
                    // to a line each, and only the latest turn is expanded.
                    ForEach(Array(earlierQuestions.dropFirst().enumerated()), id: \.offset) { _, question in
                        followUpLine(question)
                    }
                    ForEach(Array(latestTurn.enumerated()), id: \.offset) { index, message in
                        row(message, isFirstOfTurn: index == 0)
                    }
                    ForEach(Array(side.readOnlyBlockedTools.enumerated()), id: \.offset) { _, title in
                        blockedNotice(title)
                    }
                    // A failed queued follow-up blocks the ones behind it.
                    ForEach(side.queue.filter { $0.lastError != nil }) { item in
                        failedFollowUp(item)
                    }
                    if transcript.pendingPermission != nil, let policy {
                        ACPPermissionPrompt(
                            session: side,
                            policy: policy,
                            scopeKey: Self.scopeKey(for: transcript.pendingPermission)
                        )
                    }
                }
            }
        }

        @ViewBuilder
        private func row(_ message: ACPMessage, isFirstOfTurn: Bool) -> some View {
            switch message {
            case .user(_, _, let text, _, _):
                // The question that opened the card is already the header.
                if !(isFirstOfTurn && earlierQuestions.isEmpty) {
                    followUpLine(text)
                }
            case .agent(_, _, let buffer):
                AgentText(buffer: buffer, typography: typography)
            case .toolCall(let call):
                Text(call.title)
                    .font(.system(size: 11))
                    .foregroundStyle(theme.color("fg-faint"))
                    .lineLimit(1)
            default:
                EmptyView()
            }
        }

        private func followUpLine(_ text: String) -> some View {
            Text("↳ \(text)")
                .font(.system(size: 11.5))
                .foregroundStyle(theme.color("fg-muted"))
                .lineLimit(2)
        }

        private func failedFollowUp(_ item: QueuedPrompt) -> some View {
            VStack(alignment: .leading, spacing: 4) {
                Text("Couldn't send “\(ACPQueueItemRow.textPreview(of: item.blocks))”: \(item.lastError ?? "")")
                    .font(.system(size: 11.5))
                    .foregroundStyle(theme.color("del"))
                    .lineLimit(3)
                HStack(spacing: 6) {
                    Button("Retry") { onRetryQueued(item.id) }.controlSize(.small)
                    Button("Remove") { onRemoveQueued(item.id) }.controlSize(.small)
                }
            }
        }

        private func blockedNotice(_ title: String) -> some View {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Image(systemName: "nosign")
                    .foregroundStyle(theme.color("del"))
                Text("Blocked \(title). Side questions are read-only.")
                    .foregroundStyle(theme.color("fg-muted"))
            }
            .font(.system(size: 11.5))
        }

        private static func scopeKey(for pending: ACPSession.PendingPermission?) -> String {
            guard let pending else { return "" }
            return "tool:\(pending.params.toolCall.title ?? pending.params.toolCall.toolCallId)"
        }
    }

    private struct AgentText: View {
        @ObservedObject var buffer: StreamingText
        let typography: ACPChatTypography

        var body: some View {
            ACPMarkdownText(raw: buffer.value, typography: typography)
                .textSelection(.enabled)
        }
    }
}

/// Header, scrolling body, and follow-up footer shared by every card state.
private struct ACPSideQuestionCardChrome<Content: View>: View {
    let question: String
    let phase: ACPSideQuestionPhase
    let modelName: String?
    /// The latest answer, for Copy and Insert; nil until there is one.
    let answer: String?
    let hasContent: Bool
    let canAsk: Bool
    let onAsk: ACPSideQuestionAsk
    let onDismiss: () -> Void
    let onInsert: (String) -> Void
    let onKeep: (() -> Void)?
    @ViewBuilder let content: () -> Content

    @State private var isCollapsed = false
    @State private var followUp = ""
    @FocusState private var fieldFocused: Bool
    @Environment(\.theme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            if !isCollapsed {
                body(for: phase)
                footer
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(theme.color("bg-1"))
                .overlay(RoundedRectangle(cornerRadius: 12).fill(theme.color("warn").opacity(0.06)))
        )
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(theme.color("warn").opacity(0.45)))
        .shadow(color: .black.opacity(0.35), radius: 14, y: 6)
        .background {
            // ⌘. collapses the card from anywhere in the tab.
            Button("") { isCollapsed.toggle() }
                .keyboardShortcut(".", modifiers: .command)
                .hidden()
        }
        .onAppear { fieldFocused = phase == .composing }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Text("/btw")
                .font(.system(size: 11.5, weight: .bold, design: .monospaced))
                .foregroundStyle(theme.color("warn"))
            Text(question.isEmpty ? "Side question" : question)
                .font(.system(size: 12))
                .foregroundStyle(theme.color(question.isEmpty ? "fg-faint" : "fg"))
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 8)
            Text("read-only")
                .font(.system(size: 10.5))
                .foregroundStyle(theme.color("fg-muted"))
                .padding(.horizontal, 6)
                .padding(.vertical, 1)
                .overlay(Capsule().strokeBorder(theme.color("line")))
            status
            Button { isCollapsed.toggle() } label: {
                Image(systemName: isCollapsed ? "chevron.up" : "chevron.down")
            }
            .buttonStyle(.plain)
            .help("Collapse (⌘.)")
            Button(action: onDismiss) { Image(systemName: "xmark") }
                .buttonStyle(.plain)
                .help("Discard side question (Esc)")
        }
        .font(.system(size: 11))
        .foregroundStyle(theme.color("fg-muted"))
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .contentShape(Rectangle())
        .onTapGesture { isCollapsed.toggle() }
    }

    @ViewBuilder
    private var status: some View {
        switch phase {
        case .starting, .streaming:
            ProgressView().controlSize(.mini)
        case .answered:
            if let modelName { Text(modelName).lineLimit(1) }
        case .composing, .failed:
            EmptyView()
        }
    }

    @ViewBuilder
    private func body(for phase: ACPSideQuestionPhase) -> some View {
        Divider().overlay(theme.color("warn").opacity(0.2))
        switch phase {
        case .composing:
            EmptyView()
        case .starting where !hasContent:
            Text("Forking the session…")
                .font(.system(size: 12))
                .foregroundStyle(theme.color("fg-muted"))
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
        case .failed(let message):
            Text(message)
                .font(.system(size: 12))
                .foregroundStyle(theme.color("del"))
                .textSelection(.enabled)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
        default:
            ScrollView {
                content()
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
            }
            .frame(maxHeight: 220)
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var footer: some View {
        HStack(spacing: 6) {
            TextField(phase == .composing ? "Ask a side question…" : "Ask a follow-up…", text: $followUp)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 12))
                .focused($fieldFocused)
                .disabled(!canAsk)
                .onSubmit(submit)
                .onExitCommand(perform: onDismiss)
            if let answer {
                Button("Copy") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(answer, forType: .string)
                }
                .controlSize(.small)
                Button("Insert into composer") { onInsert(answer) }.controlSize(.small)
            }
            if let onKeep, phase != .composing {
                Button("Keep as session", action: onKeep).controlSize(.small)
            }
        }
        .padding(8)
    }

    private func submit() {
        let text = followUp.trimmingCharacters(in: .whitespacesAndNewlines)
        guard canAsk, !text.isEmpty else { return }
        // Keep the text when the side session can't take it, so it can be
        // sent again.
        let accepted = onAsk(text) { delivered in
            if !delivered, followUp.isEmpty { followUp = text }
        }
        if accepted { followUp = "" }
    }
}
