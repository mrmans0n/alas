import SwiftUI

/// Read and drive the selected peer through forwarded gateway frames only.
/// Rows and pending requests render with the same cards the local ACP
/// transcript uses, so a mirrored session reads like a native tab.
struct NativePeerSessionView: View {
    @Bindable var client: NativePeerSessions
    var typography: ACPChatTypography = .default
    @Environment(\.theme) private var theme
    @Environment(\.openURL) private var openURL
    @State private var rowCache = NativePeerRowCache()
    @State private var followsTranscriptTail = true
    @FocusState private var composerFocused: Bool

    private var online: Bool { client.selectedPeer?.state.carriesSessions == true }
    private var canDrive: Bool { online && client.transcript?.canDrive == true }
    private var sessionKey: String { client.selectedSessionId ?? "peer-transcript" }

    var body: some View {
        VStack(spacing: 0) {
            header
            if let transcript = client.transcript {
                GeometryReader { proxy in
                    let contentMaxWidth = ACPChatLayout.contentMaxWidth(forChatColumnWidth: proxy.size.width)
                    ZStack(alignment: .bottom) {
                        transcriptList(transcript, contentMaxWidth: contentMaxWidth)
                        composer(transcript, contentMaxWidth: contentMaxWidth)
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
                Text([client.selectedPeer?.name, client.selectedRow?.worktree?.projectName,
                      client.selectedRow?.worktree?.worktreeName,
                      client.selectedRow?.worktree?.branch]
                    .compactMap { $0 }.joined(separator: " · "))
                    .font(.system(size: 11))
                    .foregroundStyle(theme.color("fg-muted"))
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
        .background(theme.color("bg-1").opacity(0.7))
        .overlay(alignment: .bottom) {
            Rectangle().fill(theme.color("line")).frame(height: 0.5)
        }
    }

    // MARK: - Transcript

    private func transcriptList(_ transcript: NativePeerTranscript, contentMaxWidth: CGFloat) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    if !online || transcript.isClosed {
                        unavailableBanner.modifier(PeerRowFrame(contentMaxWidth: contentMaxWidth))
                    }
                    if transcript.olderPageBeforeIndex != nil && online {
                        HStack {
                            Spacer()
                            Button {
                                client.fetchOlder()
                            } label: {
                                Label("Load older messages", systemImage: "arrow.up.circle")
                            }
                            .buttonStyle(PeerChipButtonStyle(theme: theme))
                            Spacer()
                        }
                    }
                    ForEach(transcript.messages, id: \.stableId) { message in
                        row(message, contentMaxWidth: contentMaxWidth)
                            .modifier(PeerRowFrame(contentMaxWidth: contentMaxWidth))
                    }
                    pendingRequests(transcript)
                        .modifier(PeerRowFrame(contentMaxWidth: contentMaxWidth))
                    Color.clear
                        .frame(height: Self.composerSpacerHeight)
                        .id(NativePeerTranscriptScrollPolicy.tailAnchorID)
                }
                .padding(.top, 20)
            }
            .onAppear {
                proxy.scrollTo(NativePeerTranscriptScrollPolicy.tailAnchorID, anchor: .bottom)
            }
            .onChange(of: transcript) { _, _ in
                guard followsTranscriptTail else { return }
                proxy.scrollTo(NativePeerTranscriptScrollPolicy.tailAnchorID, anchor: .bottom)
            }
            .onScrollGeometryChange(for: Bool.self) { geometry in
                let distanceFromBottom = geometry.contentSize.height - geometry.contentOffset.y
                    - geometry.containerSize.height
                return NativePeerTranscriptScrollPolicy.shouldFollow(
                    distanceFromBottom: distanceFromBottom
                )
            } action: { _, shouldFollow in
                followsTranscriptTail = shouldFollow
            }
        }
        .onChange(of: transcript.messages, initial: true) { _, messages in
            rowCache.sync(messages)
        }
    }

    /// `scrollTo` targets this view, so the spacer must be the target itself;
    /// padding after a one-point target leaves the last row under the composer.
    private static let composerSpacerHeight: CGFloat = 220

    @ViewBuilder
    private func row(_ message: RemoteWireMessage, contentMaxWidth: CGFloat) -> some View {
        switch NativePeerRow(message: message) {
        case .user(let text):
            HStack {
                Spacer(minLength: 40)
                ACPMarkdownText(raw: text, typography: typography)
                    .acpUserBubble()
                    .frame(maxWidth: contentMaxWidth * 0.75, alignment: .trailing)
            }
            .frame(maxWidth: .infinity)
        case .agent(let text):
            ACPMarkdownText(
                raw: text,
                cache: rowCache.markdownCache(for: message.stableId),
                typography: typography
            )
            .frame(maxWidth: .infinity, alignment: .leading)
        case .thought(let text):
            ACPThoughtView(buffer: rowCache.thoughtBuffer(for: message.stableId, seed: text))
        case .toolCall(let call):
            ACPToolCallCard(toolCall: call, messageCreatedAt: nil)
        case .fileEdit(let edit):
            // The edited file lives on the peer, so there is no local diff
            // to open; the card still shows the inline hunk.
            ACPFileEditCard(edit: edit, onOpenDiff: nil)
        case .plan(let items):
            ACPPlanChecklist(items: items)
        case .systemNotice(let text):
            ACPSystemNoticeView(text: text)
        }
    }

    private var unavailableBanner: some View {
        HStack(spacing: 8) {
            Image(systemName: "wifi.slash")
                .foregroundStyle(theme.color("warn"))
            Text("This peer session is unavailable. Your draft is preserved until you close it.")
                .font(.system(size: 12))
                .foregroundStyle(theme.color("fg"))
            Spacer(minLength: 8)
            Button("Return") { client.clearSelection() }
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

    @ViewBuilder
    private func pendingRequests(_ transcript: NativePeerTranscript) -> some View {
        if let request = transcript.pendingPermission {
            ACPPermissionCard(content: .init(payload: request)) { option in
                client.decidePermission(requestId: request.requestId, optionId: option.optionId)
            }
            .disabled(!canDrive)
        }
        if let request = transcript.pendingPlan {
            ACPPlanApprovalPrompt(plan: NativePeerRequestBridge.planParams(request)) { response in
                let reply = NativePeerRequestBridge.planReply(response)
                client.respondToPlan(requestId: request.requestId, action: reply.action, reason: reply.reason)
            }
            .id(requestKey(.plan, request.requestId, in: transcript))
            .disabled(!canDrive)
        }
        if let request = transcript.pendingQuestion {
            ACPUserInputPrompt(
                request: NativePeerRequestBridge.userInputRequest(question: request),
                onRespond: { _, action in
                    guard let answers = NativePeerRequestBridge.questionAnswers(for: action, question: request)
                    else { return }
                    client.answerQuestion(requestId: request.requestId, answers: answers)
                },
                onOpenURL: { _ in false },
                showsDismissActions: false
            )
            .id(requestKey(.question, request.requestId, in: transcript))
            .disabled(!canDrive)
        }
        if let request = transcript.pendingElicitation {
            if let input = NativePeerRequestBridge.userInputRequest(elicitation: request) {
                ACPUserInputPrompt(
                    request: input,
                    onRespond: { _, action in
                        let reply = NativePeerRequestBridge.elicitationReply(for: action)
                        client.respondToElicitation(
                            requestId: request.requestId, action: reply.action, content: reply.content
                        )
                    },
                    onOpenURL: { _ in await openElicitationURL(request.requestId) }
                )
                .id(requestKey(.elicitation, request.requestId, in: transcript))
                .disabled(!canDrive)
            } else {
                unsupportedElicitation(request)
                    .disabled(!canDrive)
            }
        }
    }

    /// A request the local prompt cannot render (unknown mode, bad URL)
    /// still needs a way out, or the peer stays parked on it.
    private func unsupportedElicitation(_ request: RemoteElicitationPayload) -> some View {
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

    private func openElicitationURL(_ requestId: String) async -> Bool {
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

    // MARK: - Composer

    private func composer(_ transcript: NativePeerTranscript, contentMaxWidth: CGFloat) -> some View {
        VStack(spacing: 0) {
            Spacer(minLength: 0)
            HStack {
                Spacer(minLength: 0)
                composerPill(transcript).frame(maxWidth: contentMaxWidth)
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

    private func composerPill(_ transcript: NativePeerTranscript) -> some View {
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
                if NativePeerSessionControls.showsStop(for: transcript.streamingState) {
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

/// Centers a row at the chat column width with the same side padding the
/// local transcript scroller applies, so mirrored rows line up with the
/// composer pill.
private struct PeerRowFrame: ViewModifier {
    let contentMaxWidth: CGFloat

    func body(content: Content) -> some View {
        content
            .frame(maxWidth: contentMaxWidth, alignment: .leading)
            .padding(.horizontal, 28 + ACPMessageGutterLayout.laneWidth)
            .frame(maxWidth: .infinity, alignment: .center)
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
    static func showsStop(for streamingState: String) -> Bool {
        streamingState != "idle"
    }
}

enum NativePeerTranscriptScrollPolicy {
    static let tailAnchorID = "native-peer-transcript-tail"
    private static let bottomTolerance: CGFloat = 72

    static func shouldFollow(distanceFromBottom: CGFloat) -> Bool {
        distanceFromBottom <= bottomTolerance
    }
}
