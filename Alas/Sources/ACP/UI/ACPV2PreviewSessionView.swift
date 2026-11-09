import SwiftUI

/// Explicit preview UI. The standard composer's queue and tool actions are absent.
struct ACPV2PreviewSessionView: View {
    @Environment(\.designScale) private var scale
    @ObservedObject var session: ACPSession
    @ObservedObject var manager: ACPSessionManager
    let worktree: Worktree
    let agentDisplayName: (String) -> String
    let typography: ACPChatTypography
    let onNewStandardSession: () -> Void
    @Environment(\.theme) private var theme
    @State private var draft = ""
    @State private var sending = false
    @State private var error: String?
    @State private var confirmsEnd = false
    @State private var endsRemainingProcess = false

    private var presentation: ACPV2PreviewPresentation { manager.v2PreviewPresentation(for: session.id) }
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: scale.space[1]) {
                    Text(session.runtimeKind == .v2FreshPreview ? "ACP v2 preview" : "Saved session unavailable")
                        .font(.headline)
                    Text(statusText).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if presentation.canEnd {
                    Button("End preview session") { endsRemainingProcess = false
                    confirmsEnd = true }
                } else if manager.v2PreviewCanEndRemainingProcess(for: session.id) {
                    Button("End remaining preview process") { endsRemainingProcess = true
                    confirmsEnd = true }
                }
                Button("New standard session", action: onNewStandardSession)
            }
            .padding(scale.space[3])
            if presentation.viewOnly {
                Text("Conversation may be incomplete. This saved display cannot resume or answer old requests.")
                    .font(.callout).foregroundStyle(.secondary).padding(.horizontal, scale.space[3]).padding(.bottom, scale.space[2])
            }
            if let message = error ?? session.lastError {
                Text(message).foregroundStyle(theme.color("warn")).textSelection(.enabled)
                    .padding(.horizontal, scale.space[3]).padding(.bottom, scale.space[2])
            }
            if case .failed(let message) = session.hydrationState {
                Text(message).foregroundStyle(theme.color("warn")).padding(scale.space[3])
            }
            transcript
            if !manager.v2PreviewPermissions(for: session.id).isEmpty {
                ScrollView {
                    VStack(spacing: scale.space[2]) {
                        ForEach(manager.v2PreviewPermissions(for: session.id)) { item in permission(item) }
                    }.padding(scale.space[3])
                }.frame(maxHeight: 300)
            }
            if !presentation.viewOnly {
                VStack(alignment: .leading, spacing: scale.space[2]) {
                    TextEditor(text: $draft)
                        .font(.system(size: typography.baseSize))
                        .frame(minHeight: 54, maxHeight: 120)
                        .scrollContentBackground(.hidden)
                        .padding(scale.space[2])
                        .overlay(RoundedRectangle(cornerRadius: scale.radius.medium).stroke(theme.color("line")))
                        .accessibilityLabel("Preview message, plain text only")
                    HStack {
                        Text("Text only. Send after the current turn ends.").font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Button("Send", action: send)
                            .keyboardShortcut(.return, modifiers: .command)
                            .disabled(!presentation.canSend || sending || draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }.padding(scale.space[3])
            }
        }
        .background(theme.color("bg-0"))
        .task(id: session.id) { await manager.hydrateIfNeeded(id: session.id) }
        .onAppear { draft = session.composerDraft.plainText }
        .onChange(of: draft) { _, text in
            manager.persistComposerDraft(.init(segments: [.text(text)]), for: session)
        }
        .onChange(of: session.composerDraftRevision) { _, _ in
            let value = session.composerDraft.plainText
            if value != draft { draft = value }
        }
        .onExitCommand {} // Escape never interrupts or ends a preview process.
        .confirmationDialog(endsRemainingProcess ? "End remaining preview process?" : "End preview session?", isPresented: $confirmsEnd) {
            Button("End preview session", role: .destructive) {
                Task {
                    do {
                        if endsRemainingProcess { try await manager.endRemainingV2PreviewProcess(for: session.id) }
                        else { try await manager.endV2PreviewSession(for: session.id) }
                    } catch { self.error = error.localizedDescription }
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This ends the adapter process. The preview cannot resume.")
        }
    }

    private var statusText: String {
        switch presentation.status {
        case .starting, .idle: "Starting"
        case .ending: "Ending"
        case .ended: "Ended · view only"
        case .interrupted: "Interrupted · view only"
        case .failed: "Unavailable · view only"
        case .none: "Saved display · view only"
        case .ready:
            switch presentation.foreground {
            case .idle: "Ready"
            case .running: "Running"
            case .requiresAction: "Waiting for permission"
            case .unknown, .unrecognized: "Observation unavailable"
            }
        }
    }

    @ViewBuilder
    private func permission(_ item: ACPV2PreviewPermissionItem) -> some View {
        switch item.phase {
        case .awaitingDecision, .sending:
            VStack(alignment: .leading, spacing: scale.space[2]) {
                ACPPermissionCard(content: .init(permission: item.permission, existingToolCall: matchingTool(item), worktreeRoot: worktree.path.path),
                    onChoose: { choice in decide(item, optionID: choice.optionId) },
                    statusText: item.phase == .sending ? "Sending choice" : nil)
                    .disabled(item.phase != .awaitingDecision || presentation.status != .ready)
                if item.phase == .awaitingDecision {
                    Button("Cancel request") { decide(item, optionID: nil) }
                        .disabled(presentation.status != .ready)
                }
            }
        case .unavailable:
            Text("Permission no longer available: \(item.permission.title)").font(.callout).foregroundStyle(.secondary)
        case .uncertain:
            Text("The reply to \"\(item.permission.title)\" could not be confirmed. It will not be retried.")
                .font(.callout).foregroundStyle(.secondary)
        }
    }
    private func matchingTool(_ item: ACPV2PreviewPermissionItem) -> ACPMessage.ToolCall? {
        guard let id = item.permission.subject?.toolCallUpdate?.toolCallID else { return nil }
        return session.transcript.messages.compactMap { message in
            if case .toolCall(let tool) = message, tool.toolCallId.utf8.elementsEqual(id.utf8) { return tool }
            return nil
        }.first
    }
    private func decide(_ item: ACPV2PreviewPermissionItem, optionID: String?) {
        error = nil
        Task {
            do { _ = try await manager.respondToV2PreviewPermission(for: session.id, itemID: item.id, optionID: optionID) }
            catch { self.error = error.localizedDescription }
        }
    }
    private func send() {
        guard presentation.canSend, !sending else { return }
        let text = draft
        sending = true
        error = nil
        Task {
            defer { sending = false }
            do {
                let result = try await manager.sendV2PreviewText(for: session.id, text: text)
                if case .accepted = result.recovery, draft == text {
                    draft = ""
                    manager.persistComposerDraft(.empty, for: session)
                }
            } catch { self.error = error.localizedDescription }
        }
    }

    private var transcript: some View {
        ACPMessageList(session: session, transcript: session.transcript, contentMaxWidth: 760, typography: typography,
            onOpenDiff: { _ in }, onOpenTranscriptLink: { _ in false }, policy: nil, trustedImageRoot: worktree.path,
            scopeKey: "preview:\(session.id)", onUserInputResponse: { _, _ in }, onPlanResponse: { _, _ in },
            onOpenElicitationURL: { _ in false }, onDismissElicitationURLWait: { _ in }, onQueueEdit: { _ in },
            onQueueForceSend: { _ in }, onQueuePromote: { _ in }, onQueueRemove: { _ in }, onQueueRetry: { _ in },
            onQueueReorder: { _, _ in }, onQueueClearAll: {}, onRetryContextRecovery: {}, reconnectAvailable: false,
            onReconnect: {}, rememberedScrollAnchor: { manager.rememberedTranscriptScrollAnchor(for: session.id) },
            onRememberScrollAnchor: { anchor, index, follows in manager.rememberTranscriptScrollAnchor(sessionId: session.id, anchorMessageId: anchor, anchorMessageIndex: index, followsTail: follows) },
            onLoadFullToolCallContent: { _ in nil }, forkTargets: [], onQuote: { quote in
                guard !presentation.viewOnly else { return }
                draft += (draft.isEmpty ? "" : "\n\n") + quote
            }, onFork: { _, _ in }, onCancelSubagent: nil, onOpenSubagentLink: nil,
            onOpenForkSource: { _ in }, agentDisplayName: agentDisplayName)
    }
}
