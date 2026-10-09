import SwiftUI

/// Read and drive the selected peer through forwarded gateway frames only.
/// Rows and pending requests render with the same cards the local ACP
/// transcript uses, so a mirrored session reads like a native tab.
struct NativePeerSessionView: View {
    @Bindable var client: NativePeerSessions
    var typography: ACPChatTypography = .default
    var collapsesFinishedToolCalls = false
    @Environment(\.theme) private var theme
    @Environment(\.openURL) private var openURL

    private var online: Bool { client.selectedPeer?.state.carriesSessions == true }
    private var canDrive: Bool { online && client.transcript?.canDrive == true }
    private var sessionKey: String { client.selectedSessionId ?? "peer-transcript" }

    var body: some View {
        VStack(spacing: 0) {
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
            trailingRows: queueRows(transcript, contentMaxWidth: contentMaxWidth) + pendingRequestRows(transcript),
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

    // MARK: - Queue

    private struct QueueRowToken: Equatable {
        let item: QueuedPrompt
        let canRemove: Bool
        let online: Bool
    }

    /// "Up next" rows mirror the host queue. The host owns ordering, so the
    /// rows offer no reordering; removal follows the host's `canRemove`.
    private func queueRows(_ transcript: NativePeerTranscript, contentMaxWidth: CGFloat) -> [NativePeerTranscriptExtraRow] {
        let client = client
        let online = online
        let typography = typography
        let items = transcript.queue.compactMap(NativePeerComposerState.queuedPrompt)
            .filter { ACPTranscriptQueuePolicy.shouldRenderQueueBubble($0) }
        guard !items.isEmpty else { return [] }
        let canRemoveById = Dictionary(
            transcript.queue.map { ($0.id, $0.canRemove ?? true) }, uniquingKeysWith: { first, _ in first })
        var rows: [NativePeerTranscriptExtraRow] = [NativePeerTranscriptExtraRow(
            id: "__peer_queue_header__",
            token: ACPRowEqualityToken([items.count, online ? 1 : 0]),
            content: {
                AnyView(ACPQueueHeader(count: items.count, canClear: online, onClear: { client.queueClear() }))
            })]
        for (index, item) in items.enumerated() {
            let id = item.id.uuidString
            let canRemove = canRemoveById[id] ?? true
            rows.append(NativePeerTranscriptExtraRow(
                id: "__peer_queue_\(id)",
                token: ACPRowEqualityToken(QueueRowToken(item: item, canRemove: canRemove, online: online)),
                content: {
                    AnyView(ACPQueueItemRow(
                        item: item, position: index + 1, contentMaxWidth: contentMaxWidth,
                        typography: typography, canMoveUp: false, canMoveDown: false,
                        isHeldByUsageLimit: false,
                        allowsReordering: false, canRemove: canRemove,
                        onPromote: {}, onSendNow: { client.queueForceSend(id) },
                        onEdit: { client.queueEdit(id) }, onRemove: { client.queueRemove(id) },
                        onRetry: { client.queueRetry(id) }, onMoveUp: {}, onMoveDown: {})
                    .disabled(!online))
                }))
        }
        return rows
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
    private var config: RemoteSessionConfig? { transcript.config }
    private var chipState: ACPChipState? { config.map(NativePeerComposerState.chipState(from:)) }
    private var sessionOpen: Bool { online && transcript.epoch != nil && !transcript.isClosed }
    private var hasText: Bool { !client.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    private var queueCount: Int { RemoteQueueProjection.visibleCount(transcript.queue) }
    private var action: ComposerAction {
        composerAction(
            streamingState: NativePeerComposerState.streamingState(transcript.streamingState),
            hasText: hasText, agentState: .ready,
            hasCancellableBackgroundWork: transcript.hasCancellableBackgroundWork)
    }

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
        VStack(spacing: 6) {
            if let error = client.deliveryError {
                Text(error)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(theme.color("del"))
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            ZStack(alignment: .topLeading) {
                if client.draft.isEmpty {
                    Text(sessionOpen ? "Message the peer session" : "Peer session unavailable")
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
                    .disabled(!sessionOpen)
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
                if let chipState, let config {
                    chipRow(chipState: chipState, config: config)
                }
                ACPComposerActionButton(
                    action: action,
                    onPrimary: {
                        switch action {
                        case .stop: client.stopSelected()
                        default:
                            guard !client.isPromptPending else { return }
                            client.sendPrompt(intent: primarySubmitIntent(
                                for: action,
                                optionPressed: NSApp.currentEvent?.modifierFlags.contains(.option) == true) ?? .auto)
                        }
                    },
                    onMenu: { item in
                        switch item {
                        case .queue:
                            guard !client.isPromptPending else { return }
                            client.sendPrompt(intent: .auto)
                        case .steer:
                            guard !client.isPromptPending else { return }
                            client.sendPrompt(intent: .steer)
                        case .stop: client.stopSelected()
                        }
                    },
                    onSchedule: { _ in },
                    queueBadgeCount: queueCount,
                    nativeSteering: config?.supportsSteering == true,
                    showsSchedule: false
                )
                .disabled(!sessionOpen)
                .background {
                    // Cmd+Return submits only; it must never reach Stop, which
                    // the primary button shows while a turn runs on an empty draft.
                    Button("") {
                        guard sessionOpen, !client.isPromptPending,
                              let intent = primarySubmitIntent(for: action, optionPressed: false)
                        else { return }
                        client.sendPrompt(intent: intent)
                    }
                    .keyboardShortcut(.return, modifiers: .command)
                    .frame(width: 0, height: 0)
                    .opacity(0)
                    .accessibilityHidden(true)
                }
            }
            .padding(.horizontal, 2)
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
        .acpComposerPill(focused: composerFocused)
    }

    @ViewBuilder
    private func chipRow(chipState: ACPChipState, config: RemoteSessionConfig) -> some View {
        let chips = ACPComposerChips(
            theme: theme, chipState: chipState,
            configOptions: NativePeerComposerState.configOptions(from: config),
            onSelect: { client.selectChip($0, itemId: $1) },
            onConfigValue: { client.setConfigValue(configId: $0, value: $1) })
        HStack(spacing: 8) {
            chips.fastModeToggle()
            ACPAutoRunToggle(
                isEnabled: config.autoRunEnabled == true,
                isDisabled: chipState.autoRun == .ignored || !sessionOpen,
                help: chipState.autoRun == .ignored
                    ? "Auto-run has no effect — this agent doesn't request permissions"
                    : (config.autoRunEnabled == true
                        ? "Auto-run is ON — agent runs tools without asking"
                        : "Click to skip permission prompts"),
                onToggle: { client.toggleAutoRun() })
            if let thinking = chipState.thinking {
                chips.thinkingChip(thinking).fixedSize(horizontal: true, vertical: false)
            }
            ForEach(chips.parameterChips) { chips.parameterChip($0).fixedSize(horizontal: true, vertical: false) }
            ForEach(chips.booleanConfigOptions) {
                chips.booleanConfigToggle($0).fixedSize(horizontal: true, vertical: false)
            }
            if let mode = chipState.mode {
                chips.modeChip(mode).fixedSize(horizontal: true, vertical: false)
            }
            if let model = chipState.models {
                chips.modelChip(model).fixedSize(horizontal: true, vertical: false)
            }
        }
        .disabled(!sessionOpen)
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
