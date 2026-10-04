import SwiftUI

/// Read and drive the selected peer through forwarded gateway frames only.
/// Rows and pending requests render with the same cards the local ACP
/// transcript uses, so a mirrored session reads like a native tab.
struct NativePeerSessionView: View {
    @Bindable var client: NativePeerSessions
    let agentLookup: (String) -> AgentDefinition?
    var typography: ACPChatTypography = .default
    var collapsesFinishedToolCalls = false
    @Environment(\.theme) private var theme
    @Environment(\.openURL) private var openURL

    private var online: Bool { client.selectedPeer?.state.carriesSessions == true }
    private var canDrive: Bool { online && client.transcript?.canDrive == true }
    private var sessionKey: String { client.selectedSessionId ?? "peer-transcript" }

    private var selectedAgentID: String? {
        guard let agentID = client.selectedRow?.agentId,
              !agentID.isEmpty, agentID != "none"
        else { return nil }
        return agentID
    }

    private var selectedAgent: AgentDefinition? {
        guard let selectedAgentID else { return nil }
        return agentLookup(selectedAgentID) ?? AgentBuiltins.entry(id: selectedAgentID)
    }

    private var selectedAgentAccessibilityLabel: String {
        "Agent: \(selectedAgent?.displayName ?? selectedAgentID ?? "Unknown")"
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            if let transcript = client.transcript {
                GeometryReader { proxy in
                    let contentMaxWidth = ACPChatLayout.contentMaxWidth(forChatColumnWidth: proxy.size.width)
                    ZStack(alignment: .bottom) {
                        transcriptList(transcript, contentMaxWidth: contentMaxWidth)
                        NativePeerComposer(
                            client: client, transcript: transcript,
                            typography: typography, contentMaxWidth: contentMaxWidth
                        )
                    }
                    .frame(width: proxy.size.width, height: proxy.size.height)
                }
                .id(sessionKey)
            } else {
                ContentUnavailableView("No peer session selected", systemImage: "desktopcomputer")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(
            LinearGradient(
                colors: [theme.color("bg-1"), theme.color("bg-0")],
                startPoint: .top, endPoint: .bottom
            )
        )
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .center, spacing: 10) {
            Image(systemName: "desktopcomputer")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(theme.color("fg-muted"))
            VStack(alignment: .leading, spacing: 2) {
                Text(client.selectedRow?.title ?? "Peer session")
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(theme.color("fg"))
                    .lineLimit(1)
                HStack(alignment: .center, spacing: 5) {
                    Text([client.selectedPeer?.name, client.selectedRow?.worktree?.projectName,
                          client.selectedRow?.worktree?.worktreeName,
                          client.selectedRow?.worktree?.branch]
                        .compactMap { $0 }.joined(separator: " · "))
                        .font(.system(size: 11))
                        .foregroundStyle(theme.color("fg-muted"))
                        .lineLimit(1)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    selectedAgentLogo
                }
            }
            Spacer(minLength: 8)
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
        .background(theme.color("bg-1").opacity(0.7))
        .overlay(alignment: .bottom) {
            Rectangle().fill(theme.color("line")).frame(height: 0.5)
        }
    }

    @ViewBuilder
    private var selectedAgentLogo: some View {
        if let selectedAgent {
            AgentLogoView(agent: selectedAgent, size: 13)
                .accessibilityLabel(selectedAgentAccessibilityLabel)
        } else if selectedAgentID != nil {
            Image(systemName: "sparkles")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(theme.color("fg-muted"))
                .frame(width: 13, height: 13)
                .accessibilityLabel(selectedAgentAccessibilityLabel)
        }
    }

    // MARK: - Transcript

    private func transcriptList(_ transcript: NativePeerTranscript, contentMaxWidth: CGFloat) -> some View {
        NativePeerTranscriptScroller(
            transcript: transcript,
            contentMaxWidth: contentMaxWidth,
            typography: typography,
            collapsesFinishedToolCalls: collapsesFinishedToolCalls,
            canFetchOlder: online && transcript.olderPageBeforeIndex != nil,
            isFetchingOlder: client.isFetchingOlderMessages,
            leadingRows: leadingRows(transcript),
            trailingRows: pendingRequestRows(transcript),
            fetchOlder: { _ = client.fetchOlder() }
        )
    }

    private func leadingRows(_ transcript: NativePeerTranscript) -> [NativePeerTranscriptExtraRow] {
        guard !online || transcript.isClosed else { return [] }
        let client = client
        return [NativePeerTranscriptExtraRow(
            id: "__peer_unavailable__",
            token: ACPRowEqualityToken(true),
            content: { AnyView(NativePeerUnavailableBanner { client.clearSelection() }) }
        )]
    }

    // MARK: - Pending requests

    /// Identity for a pending request's prompt. Includes that kind's request
    /// generation because consecutive requests can reuse a wire id, and a
    /// reused `.id` would carry the previous request's form state.
    private func requestKey(
        _ kind: NativePeerTranscript.PendingRequestKind,
        _ requestId: Any,
        in transcript: NativePeerTranscript
    ) -> String {
        "\(sessionKey):\(kind):\(transcript.requestGeneration(for: kind)):\(requestId)"
    }

    private struct PendingRequestToken<Payload: Equatable>: Equatable {
        let key: String
        let payload: Payload
        let canDrive: Bool
    }

    /// Pending requests trail the messages. Their prompts hold in-progress
    /// form state, so they stay mounted while scrolled out of view, and each
    /// request gets its own row id so a new request never inherits a form.
    private func pendingRequestRows(_ transcript: NativePeerTranscript) -> [NativePeerTranscriptExtraRow] {
        let client = client
        let canDrive = canDrive
        let openURL = openURL
        var rows: [NativePeerTranscriptExtraRow] = []
        if let request = transcript.pendingPermission {
            let key = requestKey(.permission, request.requestId, in: transcript)
            rows.append(NativePeerTranscriptExtraRow(
                id: "__peer_\(key)",
                token: ACPRowEqualityToken(PendingRequestToken(key: key, payload: request, canDrive: canDrive)),
                content: {
                    AnyView(ACPPermissionCard(content: .init(payload: request)) { option in
                        client.decidePermission(requestId: request.requestId, optionId: option.optionId)
                    }
                    .disabled(!canDrive))
                }
            ))
        }
        if let request = transcript.pendingPlan {
            let key = requestKey(.plan, request.requestId, in: transcript)
            rows.append(NativePeerTranscriptExtraRow(
                id: "__peer_\(key)",
                token: ACPRowEqualityToken(PendingRequestToken(key: key, payload: request, canDrive: canDrive)),
                keepsMountedOffscreen: true,
                content: {
                    AnyView(ACPPlanApprovalPrompt(plan: NativePeerRequestBridge.planParams(request)) { response in
                        let reply = NativePeerRequestBridge.planReply(response)
                        client.respondToPlan(requestId: request.requestId, action: reply.action, reason: reply.reason)
                    }
                    .disabled(!canDrive))
                }
            ))
        }
        if let request = transcript.pendingQuestion {
            let key = requestKey(.question, request.requestId, in: transcript)
            rows.append(NativePeerTranscriptExtraRow(
                id: "__peer_\(key)",
                token: ACPRowEqualityToken(PendingRequestToken(key: key, payload: request, canDrive: canDrive)),
                keepsMountedOffscreen: true,
                content: {
                    AnyView(ACPUserInputPrompt(
                        request: NativePeerRequestBridge.userInputRequest(question: request),
                        onRespond: { _, action in
                            guard let answers = NativePeerRequestBridge.questionAnswers(for: action, question: request)
                            else { return }
                            client.answerQuestion(requestId: request.requestId, answers: answers)
                        },
                        onOpenURL: { _ in false },
                        showsDismissActions: false
                    )
                    .disabled(!canDrive))
                }
            ))
        }
        if let request = transcript.pendingElicitation {
            let key = requestKey(.elicitation, request.requestId, in: transcript)
            let input = NativePeerRequestBridge.userInputRequest(elicitation: request)
            rows.append(NativePeerTranscriptExtraRow(
                id: "__peer_\(key)",
                token: ACPRowEqualityToken(PendingRequestToken(key: key, payload: request, canDrive: canDrive)),
                keepsMountedOffscreen: input != nil,
                content: {
                    if let input {
                        AnyView(ACPUserInputPrompt(
                            request: input,
                            onRespond: { _, action in
                                let reply = NativePeerRequestBridge.elicitationReply(for: action)
                                client.respondToElicitation(
                                    requestId: request.requestId, action: reply.action, content: reply.content
                                )
                            },
                            onOpenURL: { _ in
                                await Self.openElicitationURL(request.requestId, client: client, openURL: openURL)
                            }
                        )
                        .disabled(!canDrive))
                    } else {
                        AnyView(NativePeerUnsupportedElicitation(request: request, client: client)
                            .disabled(!canDrive))
                    }
                }
            ))
        }
        return rows
    }

    private static func openElicitationURL(
        _ requestId: String, client: NativePeerSessions, openURL: OpenURLAction
    ) async -> Bool {
        await withCheckedContinuation { continuation in
            client.openElicitationURL(requestId: requestId, openURL: { url, finish in
                openURL(url) { accepted in
                    Task { @MainActor in finish(accepted) }
                }
            }, completion: { didOpen in
                continuation.resume(returning: didOpen)
            })
        }
    }
}

/// Explains why a peer session stopped responding and offers a way back.
private struct NativePeerUnavailableBanner: View {
    let onReturn: () -> Void
    @Environment(\.theme) private var theme

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "wifi.slash")
                .foregroundStyle(theme.color("warn"))
            Text("This peer session is unavailable. Your draft is preserved until you close it.")
                .font(.system(size: 12))
                .foregroundStyle(theme.color("fg"))
            Spacer(minLength: 8)
            Button("Return", action: onReturn)
                .buttonStyle(PeerChipButtonStyle(theme: theme))
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(theme.color("warn").opacity(0.10))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(theme.color("warn").opacity(0.3), lineWidth: 0.5)
        )
    }
}

/// A request the local prompt cannot render (unknown mode, bad URL)
/// still needs a way out, or the peer stays parked on it.
private struct NativePeerUnsupportedElicitation: View {
    let request: RemoteElicitationPayload
    let client: NativePeerSessions
    @Environment(\.theme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("This request cannot be shown here.")
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundStyle(theme.color("fg"))
            Text(request.message)
                .font(.system(size: 12))
                .foregroundStyle(theme.color("fg-muted"))
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                Button("Decline") {
                    client.respondToElicitation(requestId: request.requestId, action: "decline")
                }
                Button("Cancel", role: .cancel) {
                    client.respondToElicitation(requestId: request.requestId, action: "cancel")
                }
            }
            .buttonStyle(PeerChipButtonStyle(theme: theme))
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(theme.color("bg-1").opacity(0.96))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(theme.color("accent").opacity(0.55), lineWidth: 1)
        )
    }
}

/// Its own view so draft edits re-render only the composer, not the
/// transcript beside it.
private struct NativePeerComposer: View {
    @Bindable var client: NativePeerSessions
    let transcript: NativePeerTranscript
    let typography: ACPChatTypography
    let contentMaxWidth: CGFloat
    @Environment(\.theme) private var theme
    @FocusState private var composerFocused: Bool

    private var online: Bool { client.selectedPeer?.state.carriesSessions == true }
    private var canDrive: Bool { online && transcript.canDrive }

    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 0)
            HStack {
                Spacer(minLength: 0)
                composerPill.frame(maxWidth: contentMaxWidth)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 24)
            .padding(.top, 28)
            .padding(.bottom, 16)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            LinearGradient(
                stops: [
                    .init(color: .clear, location: 0.0),
                    .init(color: .clear, location: 0.55),
                    .init(color: theme.color("bg-1").opacity(0.55), location: 1.0),
                ],
                startPoint: .top, endPoint: .bottom
            )
            .allowsHitTesting(false)
        )
    }

    private var composerPill: some View {
        let canSend = canDrive && !client.isPromptPending
            && !client.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        return VStack(spacing: 6) {
            if let error = client.deliveryError {
                Text(error)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(theme.color("del"))
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            ZStack(alignment: .topLeading) {
                if client.draft.isEmpty {
                    Text(canDrive ? "Message the peer session" : "Read only until you take over")
                        .font(typography.swiftUIFont(size: typography.paragraphSize))
                        .foregroundStyle(theme.color("fg-faint"))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .allowsHitTesting(false)
                }
                TextEditor(text: $client.draft)
                    .font(typography.swiftUIFont(size: typography.paragraphSize))
                    .foregroundStyle(theme.color("fg"))
                    .scrollContentBackground(.hidden)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 6)
                    .focused($composerFocused)
                    .disabled(!canDrive)
                    .accessibilityLabel("Message peer session")
            }
            .frame(minHeight: 44, maxHeight: 140)

            HStack(spacing: 8) {
                if online, transcript.epoch != nil, !transcript.isClosed, !transcript.canDrive {
                    Button("Take over") { client.takeOver() }
                        .buttonStyle(PeerChipButtonStyle(theme: theme))
                } else if canDrive {
                    shortcutHint
                }
                Spacer(minLength: 0)
                if NativePeerSessionControls.showsStop(for: transcript.streamingState,
                                                       hasCancellableBackgroundWork: transcript.hasCancellableBackgroundWork) {
                    ACPComposerActionButton(
                        action: .stop,
                        onPrimary: { client.stopSelected() },
                        onMenu: { _ in },
                        onSchedule: { _ in },
                        queueBadgeCount: 0
                    )
                    .disabled(!online || transcript.isClosed)
                }
                Button {
                    client.sendPrompt()
                } label: {
                    HStack(spacing: 5) {
                        Text("Send")
                            .font(.system(size: 11.5, weight: .semibold))
                        Image(systemName: "arrow.up")
                            .font(.system(size: 10, weight: .bold))
                    }
                    .foregroundStyle(theme.color("bg-0"))
                    .padding(.horizontal, 11)
                    .frame(height: ACPComposerActionButtonMetrics.capsuleHeight)
                    .background(
                        RoundedRectangle(cornerRadius: ACPComposerActionButtonMetrics.cornerRadius)
                            .fill(theme.color("accent").opacity(canSend ? 1 : 0.35))
                    )
                }
                .buttonStyle(.plain)
                .disabled(!canSend)
                .keyboardShortcut(.return, modifiers: .command)
                .help("Send (⌘⏎)")
            }
            .padding(.horizontal, 2)
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
        .acpComposerPill(focused: composerFocused)
    }

    private var shortcutHint: some View {
        HStack(spacing: 6) {
            Text("⌘⏎")
                .font(.system(size: 10, design: .monospaced))
                .fontWeight(.semibold)
                .foregroundStyle(theme.color("fg"))
            Text("send")
                .font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(theme.color("fg-muted"))
        }
        .fixedSize(horizontal: true, vertical: false)
    }
}

/// The small neutral chip the composer toolbar uses for secondary actions.
private struct PeerChipButtonStyle: ButtonStyle {
    let theme: Theme

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 11.5, weight: .medium))
            .foregroundStyle(theme.color("fg"))
            .padding(.horizontal, 10)
            .frame(height: 26)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(theme.color("bg-3").opacity(configuration.isPressed ? 1 : 0.7))
            )
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(theme.color("line"), lineWidth: 0.75))
    }
}

enum NativePeerSessionControls {
    static func showsStop(for streamingState: String, hasCancellableBackgroundWork: Bool = false) -> Bool {
        streamingState != "idle" || hasCancellableBackgroundWork
    }
}
