import SwiftUI
import UniformTypeIdentifiers

/// Read and drive the selected peer through forwarded gateway frames only.
/// Rows and pending requests render with the same cards the local ACP
/// transcript uses, so a mirrored session reads like a native tab.
struct NativePeerSessionView: View {
    @Bindable var client: NativePeerSessions
    var typography: ACPChatTypography = .default
    var collapsesFinishedToolCalls = false
    var sendOnEnter = true
    var dictationPreferences = ACPDictationPreferences()
    var onChangeDictationPreferences: (ACPDictationPreferences) -> Void = { _ in }
    @StateObject private var composerActions = ACPComposerActions()
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
                            client: client, transcript: transcript, actions: composerActions,
                            composer: client.composerState(for: transcript.sessionId),
                            typography: typography, contentMaxWidth: contentMaxWidth,
                            sendOnEnter: sendOnEnter, dictationPreferences: dictationPreferences,
                            onChangeDictationPreferences: onChangeDictationPreferences
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
            fetchOlder: { _ = client.fetchOlder() },
            onQuote: { composerActions.quote($0) },
            onRestoreCheckpoint: servesCheckpoints ? { client.requestCheckpointRestore($0) } : nil
        )
    }

    private var servesCheckpoints: Bool {
        guard let serverId = client.selectedPeer?.serverId else { return false }
        return client.hosts?.servesCheckpoints(serverId: serverId) == true
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
        let position: Int
        let canRemove: Bool
        let canEdit: Bool
        let online: Bool
        let reorder: Bool
        let targets: NativePeerComposerState.MoveTargets?
    }

    /// "Up next" rows mirror the host queue. Hosts that serve reordering get
    /// the local row's move, promote and drag; removal follows `canRemove`.
    private func queueRows(_ transcript: NativePeerTranscript, contentMaxWidth: CGFloat) -> [NativePeerTranscriptExtraRow] {
        let client = client
        let online = online
        let typography = typography
        let items = transcript.queue.compactMap(NativePeerComposerState.queuedPrompt)
            .filter { ACPTranscriptQueuePolicy.shouldRenderQueueBubble($0) }
        guard !items.isEmpty else { return [] }
        let wireById = Dictionary(
            transcript.queue.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let canClear = online
            && NativePeerComposerState.canClear(items.compactMap { wireById[$0.id.uuidString] })
        let reorder = transcript.config?.supportsQueueReorder == true
        let moveTargets = reorder ? NativePeerComposerState.moveTargets(transcript.queue) : [:]
        var rows: [NativePeerTranscriptExtraRow] = [NativePeerTranscriptExtraRow(
            id: "__peer_queue_header__",
            token: ACPRowEqualityToken([items.count, canClear ? 1 : 0]),
            content: {
                AnyView(ACPQueueHeader(count: items.count, canClear: canClear, onClear: { client.queueClear() }))
            })]
        for (index, item) in items.enumerated() {
            let id = item.id.uuidString
            let wire = wireById[id]
            let canRemove = wire?.canRemove ?? true
            let canEdit = wire.map(NativePeerComposerState.canEdit) ?? true
            let targets = moveTargets[id]
            rows.append(NativePeerTranscriptExtraRow(
                id: "__peer_queue_\(id)",
                token: ACPRowEqualityToken(QueueRowToken(
                    item: item, position: index + 1, canRemove: canRemove, canEdit: canEdit,
                    online: online, reorder: reorder, targets: targets)),
                content: {
                    AnyView(ACPQueueItemRow(
                        item: item, position: index + 1, contentMaxWidth: contentMaxWidth,
                        typography: typography,
                        canMoveUp: targets?.up != nil, canMoveDown: targets?.down != nil,
                        isHeldByUsageLimit: false,
                        allowsReordering: reorder, canRemove: canRemove, canEdit: canEdit,
                        onPromote: { client.queuePromote(id) }, onSendNow: { client.queueForceSend(id) },
                        onEdit: { client.queueEdit(id) }, onRemove: { client.queueRemove(id) },
                        onRetry: { client.queueRetry(id) },
                        onMoveUp: { targets?.up.map { client.queueMove(id, to: $0) } },
                        onMoveDown: { targets?.down.map { client.queueMove(id, to: $0) } })
                    .dropDestination(for: String.self) { dropped, _ in
                        // Only queue rows drag queue ids; the host refuses
                        // any move the local queue would.
                        guard reorder, let source = dropped.first, source != id,
                              moveTargets[source] != nil else { return false }
                        client.queueMove(source, to: id)
                        return true
                    }
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

/// The host's shepherd pill for the session, read-only: the local pill's
/// look without its popover. A badge this Mac doesn't know shows nothing.
private struct NativePeerShepherdPill: View {
    let shepherd: HostSessionShepherd
    @Environment(\.theme) private var theme

    var body: some View {
        if let badge = shepherd.badgeState {
            HStack(spacing: 5) {
                Image(systemName: badge.symbolName)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(badge.color(theme: theme))
                if let number = shepherd.number {
                    Text(number)
                        .font(.system(size: 11, weight: .semibold, design: .monospaced))
                }
            }
            .foregroundStyle(theme.color("fg-dim"))
            .lineLimit(1)
            .padding(.horizontal, 7)
            .frame(height: 22)
            .background(theme.color("bg-3").opacity(0.5))
            .clipShape(RoundedRectangle(cornerRadius: 5))
            .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(theme.color("line"), lineWidth: 0.5))
            .aiBeam(isActive: badge.isActive, cornerRadius: 5)
            .help(shepherd.tooltip)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Shepherd")
            .accessibilityValue(shepherd.tooltip)
        }
    }
}

/// Its own view so draft edits re-render only the composer, not the
/// transcript beside it.
private struct NativePeerComposer: View {
    @Bindable var client: NativePeerSessions
    let transcript: NativePeerTranscript
    let actions: ACPComposerActions
    @ObservedObject var composer: ACPComposerState
    let typography: ACPChatTypography
    let contentMaxWidth: CGFloat
    let sendOnEnter: Bool
    let dictationPreferences: ACPDictationPreferences
    let onChangeDictationPreferences: (ACPDictationPreferences) -> Void
    @Environment(\.theme) private var theme
    @State private var composerFocused = false
    @StateObject private var dropRouter = ACPComposerDropRouter()
    /// UTF-16 offset of the `@` the open mention picker completes.
    @State private var mentionTokenStart: Int?
    /// The `@` query to ask the host about, debounced by `.task(id:)`.
    @State private var mentionQuery: String?
    @State private var mentionHighlight = 0
    @State private var mentionScope: MentionScope = .all
    @State private var notice: String?
    @StateObject private var dictation = ACPDictationService(engine: ACPSpeechDictationEngine())
    private var online: Bool { client.selectedPeer?.state.carriesSessions == true }
    private var canDrive: Bool { online && transcript.canDrive }
    private var editorContext: NativePeerComposerState.EditorContext {
        .init(client: client, sessionId: transcript.sessionId)
    }
    private var config: RemoteSessionConfig? { editorContext.config }
    private var chipState: ACPChipState? { config.map(NativePeerComposerState.chipState(from:)) }
    private var sessionOpen: Bool { editorContext.isOpen }
    private var acceptsImages: Bool { config?.acceptsImages == true }
    private var hasContent: Bool {
        composer.draft.hasContent
    }
    private var queueCount: Int { RemoteQueueProjection.visibleCount(transcript.queue) }
    private var action: ComposerAction {
        composerAction(
            streamingState: NativePeerComposerState.streamingState(transcript.streamingState),
            hasText: hasContent, agentState: .ready, queueByDefault: sendOnEnter,
            hasCancellableBackgroundWork: transcript.hasCancellableBackgroundWork)
    }

    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 0)
            HStack {
                Spacer(minLength: 0)
                VStack(spacing: 6) {
                    if mentionTokenStart != nil { mentionPickerList }
                    composerPill
                }
                .frame(maxWidth: contentMaxWidth)
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
        .onChange(of: client.draft) { _, _ in syncExternalDraft() }
        .onChange(of: client.mentionCandidates) { _, _ in mentionHighlight = 0 }
        .onChange(of: mentionScope) { _, _ in mentionHighlight = 0 }
        .task(id: mentionQuery) {
            // A closed picker answers at once; a keystroke waits briefly so
            // typing a path doesn't send a search per character.
            if mentionQuery != nil { try? await Task.sleep(for: .milliseconds(120)) }
            guard !Task.isCancelled, client.selectedSessionId == transcript.sessionId else { return }
            client.searchMentions(mentionQuery)
        }
        .onChange(of: composerFocused) { _, focused in
            if !focused {
                closeMentionPicker()
            }
        }
        .onAppear {
            syncExternalDraft()
            dictation.onTranscriptUpdate = { actions.applyDictationTranscript?($0, $1) }
            dictation.onStop = { actions.cancelDictationRegion?() }
            dictation.onNotice = { showNotice($0) }
            dictation.preferences = dictationPreferences
        }
        .onDisappear { dictation.stop() }
        .onChange(of: dictationPreferences) { _, preferences in
            dictation.stop()
            dictation.preferences = preferences
        }
        .onChange(of: dictation.state) { _, state in
            if case .failed(let message) = state { showNotice(message) }
        }
        .onChange(of: sessionOpen) { _, open in
            if !open { dictation.stop() }
        }
    }

    private var composerPill: some View {
        VStack(spacing: 6) {
            if let error = NativePeerSessions.composerMessage(
                deliveryError: client.deliveryError, notice: notice, agentIssue: config?.agentIssue) {
                Text(error)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(theme.color("del"))
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            ACPInputField(
                streamingState: NativePeerComposerState.streamingState(transcript.streamingState),
                canSteerRunningTurn: config?.supportsSteering == true,
                promptSuggestions: NativePeerComposerState.slashSuggestions(from: config),
                composer: composer,
                worktreeRoot: FileManager.default.temporaryDirectory.appendingPathComponent("peer-composer"),
                actions: actions, dropRouter: dropRouter,
                isFocused: $composerFocused, focusRequest: 0,
                sendOnEnter: sendOnEnter, typography: typography,
                onDraftChange: { draft in
                    composer.replaceDraft(draft)
                    guard client.selectedSessionId == transcript.sessionId else { return }
                    client.draft = draft.plainText
                    reconcileMentionPicker()
                },
                onDraftClear: {},
                onStopDictation: { dictation.stop() },
                onSubmit: { _, attachments, intent, _, completion in
                    submit(attachments: attachments, intent: intent, completion: completion)
                },
                onImageError: { showNotice($0.userMessage) },
                filesProvider: { [] },
                usesExternalMentionPicker: true,
                acceptsImages: acceptsImages,
                onEditorSelectionChange: { reconcileMentionPicker() },
                onEditorKeyDown: handleMentionKey,
                onDictationShortcut: { dictation.handleShortcut($0) }
            )
            .disabled(!sessionOpen)
            .accessibilityLabel("Message peer session")
            .frame(minHeight: 44, maxHeight: 140)

            ViewThatFits(in: .horizontal) {
                toolbar(showShortcuts: true)
                toolbar(showShortcuts: false)
                compactToolbar
            }
            .padding(.horizontal, 2)
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
        .acpComposerPill(focused: composerFocused)
    }

    private func syncExternalDraft() {
        guard client.selectedSessionId == transcript.sessionId else { return }
        // The client also receives Queue Edit restores while the editor is unmounted.
        // Its draft observer keeps this same rich state synchronized.
        reconcileMentionPicker()
    }

    private func send(_ intent: ACPSubmitIntent) {
        actions.submitWithIntent?(intent)
    }

    private func submit(
        attachments: [ACPMessage.Attachment], intent: ACPSubmitIntent,
        completion: @escaping ACPComposerSubmitCompletion
    ) -> Bool {
        guard sessionOpen, !client.isPromptPending, let peerId = client.selectedPeer?.serverId else { return false }
        var images: [NativePeerAttachment] = []
        var mentions: [RemoteMention] = []
        for attachment in attachments {
            if let mimeType = attachment.mimeType, mimeType.hasPrefix("image/") {
                guard acceptsImages, let url = URL(string: attachment.uri), url.isFileURL,
                      let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize else {
                    showNotice("This image is unavailable. Remove it or attach it again.")
                    return false
                }
                if let refusal = NativePeerComposerState.attachmentSizeRefusal(size, stagedSizes: images.map { $0.data.count }) {
                    showNotice(refusal)
                    return false
                }
                guard let data = try? Data(contentsOf: url), ACPImageStaging.sniffMIME(data) != nil else {
                    showNotice("This image is unavailable. Remove it or attach it again.")
                    return false
                }
                images.append(.init(name: attachment.name, mimeType: mimeType, data: data))
            } else {
                guard config?.supportsMentions == true,
                      let mention = NativePeerComposerState.mention(from: attachment.uri, peerId: peerId) else {
                    showNotice("Choose this mention from the selected peer's picker before sending.")
                    return false
                }
                if !mentions.contains(where: { $0.kind == mention.kind && $0.value == mention.value }) {
                    mentions.append(mention)
                }
            }
        }
        guard mentions.count <= RemoteSessionGateway.maxMentionCount else {
            showNotice(NativePeerComposerState.tooManyMentions)
            return false
        }
        dictation.stop()
        return client.sendComposerPrompt(images: images, mentions: mentions, intent: intent, completion: completion)
    }

    // MARK: - Mentions

    private var caret: Int? {
        guard let snapshot = actions.selectionSnapshot?(), snapshot.range.length == 0 else { return nil }
        return snapshot.range.location
    }

    private var offeredMentionScopes: [MentionScope] {
        MentionScope.offered(symbols: false, sessions: true)
    }

    private var scopedMentionCandidates: [RemoteMention] {
        client.mentionCandidates.filter { mention in
            switch mentionScope {
            case .all: true
            case .files: mention.kind == RemoteMention.file
            case .symbols: mention.kind == RemoteMention.symbol
            case .sessions: mention.kind == RemoteMention.session
            }
        }
    }

    private var mentionPickerList: some View {
        VStack(spacing: 4) {
            HStack(spacing: 4) {
                ForEach(offeredMentionScopes) { scope in
                    Button { mentionScope = scope } label: {
                        Text(scope.title)
                            .font(.system(size: 10.5, weight: .medium))
                            .padding(.horizontal, 7).padding(.vertical, 2)
                            .background(mentionScope == scope ? theme.color("accent").opacity(0.22) : theme.color("bg-2"))
                            .foregroundStyle(mentionScope == scope ? theme.color("accent") : theme.color("fg-faint"))
                            .clipShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .focusable(false)
                }
                Spacer(minLength: 0)
            }
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(Array(scopedMentionCandidates.enumerated()), id: \.element) { index, mention in
                            mentionRow(mention, highlighted: index == mentionHighlight)
                                .id(index)
                                .contentShape(Rectangle())
                                .onTapGesture { pickMention(mention) }
                        }
                        if scopedMentionCandidates.isEmpty {
                            Text(mentionRowsAreCurrent ? "No matches" : "Searching…")
                                .font(.system(size: 12))
                                .foregroundStyle(theme.color("fg-faint"))
                                .padding(6)
                        }
                    }
                }
                .onChange(of: mentionHighlight) { _, index in proxy.scrollTo(index) }
            }
            .opacity(mentionRowsAreCurrent ? 1 : 0.55)
            .frame(height: min(CGFloat(max(1, scopedMentionCandidates.count)) * 26 + 8, 220))
        }
        .padding(4)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(theme.color("line"), lineWidth: 0.5))
    }

    private func mentionRow(_ mention: RemoteMention, highlighted: Bool) -> some View {
        HStack(spacing: 8) {
            Image(systemName: NativePeerComposerState.mentionIconName(mention))
                .font(.system(size: 11))
                .foregroundStyle(theme.color("fg-muted"))
                .frame(width: 16)
            Text(mention.name)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(theme.color("fg"))
                .lineLimit(1)
            if let detail = mention.detail {
                Text(detail)
                    .font(.system(size: 11))
                    .foregroundStyle(theme.color("fg-faint"))
                    .lineLimit(1)
                    .truncationMode(.head)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8)
        .frame(height: 26)
        .background(RoundedRectangle(cornerRadius: 6).fill(highlighted ? theme.color("accent").opacity(0.18) : .clear))
    }

    /// Opens, re-queries or closes the picker for the `@` token at the caret.
    private func reconcileMentionPicker() {
        guard sessionOpen, composerFocused, config?.supportsMentions == true, let caret,
              let token = NativePeerComposerState.activeMentionToken(in: (actions.selectionSnapshot?()?.text ?? "") as NSString, caret: caret)
        else { return closeMentionPicker() }
        // Opening asks at once with the bare query, which refreshes the
        // host's file listing; the typed query follows after the debounce.
        if mentionTokenStart == nil { client.searchMentions("") }
        mentionTokenStart = token.start
        mentionQuery = token.query
    }

    private func closeMentionPicker() {
        mentionTokenStart = nil
        mentionQuery = nil
    }

    private func handleMentionKey(_ event: NSEvent) -> Bool {
        guard mentionTokenStart != nil else { return false }
        let modifiers = event.modifierFlags.intersection([.shift, .control, .option, .command])
        if modifiers == .command, let character = event.charactersIgnoringModifiers,
           let number = Int(character), offeredMentionScopes.indices.contains(number - 1) {
            mentionScope = offeredMentionScopes[number - 1]
            return true
        }
        guard let key = MentionPickerKey(keyCode: event.keyCode, modifiers: event.modifierFlags) else { return false }
        let candidates = scopedMentionCandidates
        switch key {
        case .up: mentionHighlight = max(0, mentionHighlight - 1)
        case .down: mentionHighlight = min(max(0, candidates.count - 1), mentionHighlight + 1)
        case .cancel:
            dictation.stop()
            closeMentionPicker()
        case .nextScope: mentionScope = mentionScope.cycled(by: 1, in: offeredMentionScopes)
        case .previousScope: mentionScope = mentionScope.cycled(by: -1, in: offeredMentionScopes)
        case .insert(let includeCode):
            if !candidates.isEmpty {
                pickMention(candidates[min(mentionHighlight, candidates.count - 1)], includeCode: includeCode)
            }
        }
        return true
    }

    /// Rows answering an older query stay up, dimmed, until the host
    /// answers this one, and can't be picked meanwhile.
    private var mentionRowsAreCurrent: Bool { client.mentionCandidatesQuery == mentionQuery }

    private func pickMention(_ candidate: RemoteMention, includeCode: Bool = false) {
        guard mentionRowsAreCurrent, let start = mentionTokenStart,
              let peerId = client.selectedPeer?.serverId else { return }
        let count = composer.draft.segments.filter { if case .mention = $0 { true } else { false } }.count
        guard count < RemoteSessionGateway.maxMentionCount else {
            showNotice(NativePeerComposerState.tooManyMentions)
            return
        }
        var mention = candidate
        if mention.kind == RemoteMention.symbol,
           var target = ACPSymbolReference.target(fromURI: mention.value) {
            target.includeCode = includeCode
            mention = RemoteMention(kind: mention.kind, value: ACPSymbolReference.uri(for: target),
                                    name: mention.name, detail: mention.detail)
        }
        _ = actions.insertMention?(mention.name, NativePeerComposerState.mentionURI(mention, peerId: peerId), start)
        closeMentionPicker()
    }

    private var attachButton: some View {
        Button { actions.presentImagePicker?() } label: {
            Image(systemName: "photo")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(theme.color("fg-muted"))
                .frame(width: 28, height: 24)
        }
        .buttonStyle(.plain)
        .disabled(!sessionOpen)
        .accessibilityLabel("Attach image")
        .help("Attach an image")
    }

    private func showNotice(_ message: String?) {
        notice = message
        guard let message else { return }
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(4))
            if notice == message { notice = nil }
        }
    }

    // MARK: - Toolbar

    private func contextUsageButton(_ usage: RemoteUsage) -> some View {
        let local = NativePeerComposerState.contextUsage(from: usage)
        return ACPContextUsageButton(usage: local.usage, modelName: usage.modelName,
                                     lastTurnQuota: local.lastTurn, sessionQuotaTotal: local.cumulative)
    }

    /// Same width ladder as the local composer: every chip with the shortcut
    /// hint, then without it, then the model chip plus an Options popover.
    private func toolbar(showShortcuts: Bool) -> some View {
        HStack(spacing: 8) {
            if showsTakeOver {
                takeOverButton
            } else if canDrive, showShortcuts {
                shortcutHint
            }
            Spacer(minLength: 0)
            if let shepherd = client.selectedShepherd { NativePeerShepherdPill(shepherd: shepherd) }
            if let usage = config?.usage { contextUsageButton(usage) }
            if dictation.state != .unavailable { micButton }
            if acceptsImages { attachButton }
            if let chipState, let config {
                chipRow(chipState: chipState, config: config)
            }
            actionButton
        }
    }

    private var compactToolbar: some View {
        HStack(spacing: 8) {
            if showsTakeOver { takeOverButton }
            if let shepherd = client.selectedShepherd { NativePeerShepherdPill(shepherd: shepherd) }
            if let usage = config?.usage { contextUsageButton(usage) }
            if dictation.state != .unavailable { micButton }
            if acceptsImages { attachButton }
            Spacer(minLength: 0)
            if let chipState, let config {
                Group {
                    if let model = chipState.models {
                        chips(chipState: chipState, config: config).modelChip(model)
                            .frame(maxWidth: 160, alignment: .trailing)
                    }
                    ACPComposerOptionsButton(
                        chips: chips(chipState: chipState, config: config),
                        autoRun: autoRun(chipState: chipState, config: config)
                    )
                }
                .disabled(!sessionOpen)
            }
            actionButton
        }
    }

    private var micButton: some View {
        ACPDictationMicButton(
            dictation: dictation, preferences: dictationPreferences,
            onChangePreferences: onChangeDictationPreferences)
        .disabled(!sessionOpen)
    }

    private var showsTakeOver: Bool {
        online && transcript.epoch != nil && !transcript.isClosed && !transcript.canDrive
    }

    private var takeOverButton: some View {
        Button("Take over") { client.takeOver() }
            .buttonStyle(PeerChipButtonStyle(theme: theme))
            .fixedSize()
    }

    private var actionButton: some View {
        ACPComposerActionButton(
            action: action,
            onPrimary: {
                switch action {
                case .stop: client.stopSelected()
                default:
                    guard !client.isPromptPending else { return }
                    send(primarySubmitIntent(
                        for: action,
                        optionPressed: NSApp.currentEvent?.modifierFlags.contains(.option) == true,
                        queueByDefault: sendOnEnter) ?? .auto)
                }
            },
            onMenu: { item in
                switch item {
                case .queue:
                    guard !client.isPromptPending else { return }
                    send(.auto)
                case .steer:
                    guard !client.isPromptPending else { return }
                    send(.steer)
                case .stop: client.stopSelected()
                }
            },
            onSchedule: { _ in },
            queueBadgeCount: queueCount,
            nativeSteering: config?.supportsSteering == true,
            showsSchedule: false
        )
        .fixedSize(horizontal: true, vertical: false)
        .layoutPriority(1)
        .disabled(!sessionOpen)
    }

    private func chips(chipState: ACPChipState, config: RemoteSessionConfig) -> ACPComposerChips {
        ACPComposerChips(
            theme: theme, chipState: chipState,
            configOptions: NativePeerComposerState.configOptions(from: config),
            onSelect: { client.selectChip($0, itemId: $1) },
            onConfigValue: { client.setConfigValue(configId: $0, value: $1) })
    }

    private func autoRun(chipState: ACPChipState, config: RemoteSessionConfig) -> ACPComposerOptionsButton.AutoRun {
        let isEnabled = config.autoRunEnabled == true
        return .init(
            isEnabled: isEnabled,
            isDisabled: chipState.autoRun == .ignored || !sessionOpen,
            help: chipState.autoRun == .ignored
                ? "Auto-run has no effect — this agent doesn't request permissions"
                : (isEnabled
                    ? "Auto-run is ON — agent runs tools without asking"
                    : "Click to skip permission prompts"),
            toggle: { client.toggleAutoRun() })
    }

    @ViewBuilder
    private func chipRow(chipState: ACPChipState, config: RemoteSessionConfig) -> some View {
        let chips = chips(chipState: chipState, config: config)
        let autoRun = autoRun(chipState: chipState, config: config)
        HStack(spacing: 8) {
            chips.fastModeToggle()
            ACPAutoRunToggle(isEnabled: autoRun.isEnabled, isDisabled: autoRun.isDisabled,
                             help: autoRun.help, onToggle: autoRun.toggle)
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
            Text("⏎")
                .font(.system(size: 10, design: .monospaced))
                .fontWeight(.semibold)
                .foregroundStyle(theme.color("fg"))
            Text(sendOnEnter ? "send" : "steer")
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
