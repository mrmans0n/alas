import SwiftUI
import UniformTypeIdentifiers

/// Read and drive the selected peer through forwarded gateway frames only.
/// Rows and pending requests render with the same cards the local ACP
/// transcript uses, so a mirrored session reads like a native tab.
struct NativePeerSessionView: View {
    @Bindable var client: NativePeerSessions
    var typography: ACPChatTypography = .default
    var collapsesFinishedToolCalls = false
    var dictationLocale = ""
    var onSelectDictationLocale: (String) -> Void = { _ in }
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
                            typography: typography, contentMaxWidth: contentMaxWidth,
                            dictationLocale: dictationLocale, onSelectDictationLocale: onSelectDictationLocale
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

/// Its own view so draft edits re-render only the composer, not the
/// transcript beside it.
private struct NativePeerComposer: View {
    @Bindable var client: NativePeerSessions
    let transcript: NativePeerTranscript
    let typography: ACPChatTypography
    let contentMaxWidth: CGFloat
    let dictationLocale: String
    let onSelectDictationLocale: (String) -> Void
    @Environment(\.theme) private var theme
    @FocusState private var composerFocused: Bool
    @State private var selection: TextSelection?
    @StateObject private var slashPicker = ACPSlashPickerModel(suggestions: [])
    /// UTF-16 offset of the `/` the open picker completes; nil when closed.
    @State private var slashTokenStart: Int?
    /// UTF-16 offset of the `@` the open mention picker completes.
    @State private var mentionTokenStart: Int?
    /// The `@` query to ask the host about, debounced by `.task(id:)`.
    @State private var mentionQuery: String?
    @State private var mentionHighlight = 0
    @State private var notice: String?
    @StateObject private var dictation = ACPDictationService(engine: ACPSpeechDictationEngine())
    @State private var installedDictationLocales: [String] = []
    /// The open volatile dictation span (UTF-16); nil when none is open.
    @State private var dictationSpan: NSRange?
    /// The draft as dictation last left it. Any other draft while a span is
    /// open is a manual edit.
    @State private var dictatedDraft: String?

    private var online: Bool { client.selectedPeer?.state.carriesSessions == true }
    private var canDrive: Bool { online && transcript.canDrive }
    private var config: RemoteSessionConfig? { transcript.config }
    private var chipState: ACPChipState? { config.map(NativePeerComposerState.chipState(from:)) }
    private var sessionOpen: Bool { online && transcript.epoch != nil && !transcript.isClosed }
    private var acceptsImages: Bool { config?.acceptsImages == true }
    private var hasContent: Bool {
        !client.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !client.attachments.isEmpty
    }
    private var queueCount: Int { RemoteQueueProjection.visibleCount(transcript.queue) }
    private var action: ComposerAction {
        composerAction(
            streamingState: NativePeerComposerState.streamingState(transcript.streamingState),
            hasText: hasContent, agentState: .ready,
            hasCancellableBackgroundWork: transcript.hasCancellableBackgroundWork)
    }

    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 0)
            HStack {
                Spacer(minLength: 0)
                VStack(spacing: 6) {
                    if slashTokenStart != nil { slashPickerList }
                    if mentionTokenStart != nil, !client.mentionCandidates.isEmpty { mentionPickerList }
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
        .onChange(of: client.draft) { _, draft in
            reconcileSlashPicker()
            reconcileMentionPicker()
            // As in the local composer, a manual edit mid-utterance stops
            // dictation: the engine's next correction would otherwise land
            // as a fresh span and duplicate the partial text.
            if dictationSpan != nil, draft != dictatedDraft {
                dictationSpan = nil
                dictation.stop()
            }
        }
        .onChange(of: selection) { _, _ in
            reconcileSlashPicker()
            reconcileMentionPicker()
        }
        .onChange(of: client.mentionCandidates) { _, _ in mentionHighlight = 0 }
        .task(id: mentionQuery) {
            // A closed picker answers at once; a keystroke waits briefly so
            // typing a path doesn't send a search per character.
            if mentionQuery != nil { try? await Task.sleep(for: .milliseconds(120)) }
            guard !Task.isCancelled else { return }
            client.searchMentions(mentionQuery)
        }
        .onChange(of: config?.availableCommands) { _, _ in reconcileSlashPicker() }
        .onChange(of: composerFocused) { _, focused in
            if !focused {
                slashTokenStart = nil
                closeMentionPicker()
            }
        }
        .onAppear {
            dictation.onTranscriptUpdate = { applyDictation($0, isFinal: $1) }
            dictation.onStop = { dictationSpan = nil }
            dictation.onNotice = { showNotice($0) }
            dictation.preferredLocaleIdentifier = dictationLocale
        }
        .onDisappear { dictation.stop() }
        .task { installedDictationLocales = await dictation.installedLocaleIdentifiers() }
        .onChange(of: dictationLocale) { _, locale in
            dictation.stop()
            dictation.preferredLocaleIdentifier = locale
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
            if let error = client.deliveryError ?? notice {
                Text(error)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(theme.color("del"))
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            if !client.attachments.isEmpty { attachmentStrip }
            ZStack(alignment: .topLeading) {
                if client.draft.isEmpty {
                    Text(sessionOpen ? "Message the peer session" : "Peer session unavailable")
                        .font(typography.swiftUIFont(size: typography.paragraphSize))
                        .foregroundStyle(theme.color("fg-faint"))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .allowsHitTesting(false)
                }
                TextEditor(text: $client.draft, selection: $selection)
                    .font(typography.swiftUIFont(size: typography.paragraphSize))
                    .foregroundStyle(theme.color("fg"))
                    .scrollContentBackground(.hidden)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 6)
                    .focused($composerFocused)
                    .disabled(!sessionOpen)
                    .accessibilityLabel("Message peer session")
                    .onKeyPress(keys: [.upArrow, .downArrow, .return, .tab, .escape]) { press in
                        let mention = handleMentionKey(press)
                        return mention == .handled ? mention : handleSlashKey(press)
                    }
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
                if let usage = config?.usage { contextUsageButton(usage) }
                if dictation.state != .unavailable {
                    ACPDictationMicButton(
                        dictation: dictation, installedLocales: installedDictationLocales,
                        selectedLocale: dictationLocale, onSelectLocale: onSelectDictationLocale)
                    .disabled(!sessionOpen)
                }
                if acceptsImages { attachButton }
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
                            send(primarySubmitIntent(
                                for: action,
                                optionPressed: NSApp.currentEvent?.modifierFlags.contains(.option) == true) ?? .auto)
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
                .disabled(!sessionOpen)
                .background {
                    // Cmd+Return submits only; it must never reach Stop, which
                    // the primary button shows while a turn runs on an empty draft.
                    Button("") {
                        guard sessionOpen, !client.isPromptPending,
                              let intent = primarySubmitIntent(for: action, optionPressed: false)
                        else { return }
                        send(intent)
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
        .dropDestination(for: URL.self) { urls, _ in
            guard acceptsImages, sessionOpen else { return false }
            attachImages(at: urls)
            return true
        }
    }

    /// Dictation stops first, so no late transcript lands in the cleared draft.
    private func send(_ intent: ACPSubmitIntent) {
        dictation.stop()
        client.sendPrompt(intent: intent)
    }

    // MARK: - Dictation

    /// The selection as UTF-16, or the end of the draft when there is none.
    private var selectedRange: NSRange {
        let draft = client.draft
        guard case .selection(let range)? = selection?.indices, range.upperBound <= draft.endIndex else {
            return NSRange(location: (draft as NSString).length, length: 0)
        }
        return NSRange(range, in: draft)
    }

    private func applyDictation(_ transcript: String, isFinal: Bool) {
        guard sessionOpen else { return dictation.stop() }
        let edit = NativePeerComposerState.applyingDictation(
            transcript, isFinal: isFinal, to: client.draft, span: dictationSpan, selection: selectedRange)
        dictationSpan = edit.span
        dictatedDraft = edit.text
        client.draft = edit.text
        selection = TextSelection(insertionPoint: String.Index(utf16Offset: edit.caret, in: edit.text))
    }

    // MARK: - Slash commands

    private var slashPickerList: some View {
        ACPSlashPickerView(model: slashPicker) { pick($0) }
            .frame(height: min(CGFloat(slashPicker.filtered.count) * 26 + 8, 220))
            .padding(4)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(theme.color("line"), lineWidth: 0.5))
    }

    /// The caret's UTF-16 offset while it is a plain insertion point.
    private var caret: Int? {
        guard case .selection(let range)? = selection?.indices, range.isEmpty,
              range.upperBound <= client.draft.endIndex else { return nil }
        return range.upperBound.utf16Offset(in: client.draft)
    }

    /// Opens, filters or closes the picker for the `/` token at the caret,
    /// the way the local composer's text view does.
    private func reconcileSlashPicker() {
        let suggestions = NativePeerComposerState.slashSuggestions(from: config)
        guard sessionOpen, composerFocused, !suggestions.isEmpty, let caret,
              let token = ACPSlashCommand.activeToken(in: client.draft as NSString, caret: caret)
        else {
            slashTokenStart = nil
            return
        }
        if slashTokenStart == nil || slashPicker.allSuggestions != suggestions {
            slashPicker.updateSuggestions(suggestions)
        }
        slashPicker.setQuery(token.query)
        slashTokenStart = slashPicker.filtered.isEmpty ? nil : token.start
    }

    private func handleSlashKey(_ press: KeyPress) -> KeyPress.Result {
        guard slashTokenStart != nil else { return .ignored }
        switch press.key {
        case .upArrow: slashPicker.moveUp()
        case .downArrow: slashPicker.moveDown()
        case .escape: slashTokenStart = nil
        default:
            // Cmd+Return sends and Shift+Return adds a line, even with the picker open.
            guard press.modifiers.isDisjoint(with: [.command, .shift]), let suggestion = slashPicker.selected() else { return .ignored }
            pick(suggestion)
        }
        return .handled
    }

    private func pick(_ suggestion: ACPPromptSuggestion) {
        guard let start = slashTokenStart, let caret else { return }
        let completed = NativePeerComposerState.completingToken(
            suggestion.command, in: client.draft, tokenStart: start, caret: caret)
        slashTokenStart = nil
        client.draft = completed.text
        selection = TextSelection(insertionPoint: String.Index(utf16Offset: completed.caret, in: completed.text))
    }

    // MARK: - Mentions

    private var mentionPickerList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(spacing: 0) {
                    ForEach(Array(client.mentionCandidates.enumerated()), id: \.element) { index, mention in
                        mentionRow(mention, highlighted: index == mentionHighlight)
                            .id(index)
                            .contentShape(Rectangle())
                            .onTapGesture { pickMention(mention) }
                    }
                }
            }
            .onChange(of: mentionHighlight) { _, index in proxy.scrollTo(index) }
        }
        .opacity(mentionRowsAreCurrent ? 1 : 0.55)
        .frame(height: min(CGFloat(client.mentionCandidates.count) * 26 + 8, 220))
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
              let token = NativePeerComposerState.activeMentionToken(in: client.draft as NSString, caret: caret)
        else { return closeMentionPicker() }
        mentionTokenStart = token.start
        mentionQuery = token.query
    }

    private func closeMentionPicker() {
        mentionTokenStart = nil
        mentionQuery = nil
    }

    private func handleMentionKey(_ press: KeyPress) -> KeyPress.Result {
        let candidates = client.mentionCandidates
        guard mentionTokenStart != nil, !candidates.isEmpty else { return .ignored }
        switch press.key {
        case .upArrow: mentionHighlight = max(0, mentionHighlight - 1)
        case .downArrow: mentionHighlight = min(candidates.count - 1, mentionHighlight + 1)
        case .escape: closeMentionPicker()
        default:
            // Cmd+Return sends and Shift+Return adds a line, even with the picker open.
            guard press.modifiers.isDisjoint(with: [.command, .shift]) else { return .ignored }
            pickMention(candidates[min(mentionHighlight, candidates.count - 1)])
        }
        return .handled
    }

    /// Rows answering an older query stay up, dimmed, until the host
    /// answers this one, and can't be picked meanwhile.
    private var mentionRowsAreCurrent: Bool { client.mentionCandidatesQuery == mentionQuery }

    private func pickMention(_ mention: RemoteMention) {
        guard mentionRowsAreCurrent, let start = mentionTokenStart, let caret else { return }
        let completed = NativePeerComposerState.completingToken(
            "@" + mention.name, in: client.draft, tokenStart: start, caret: caret)
        closeMentionPicker()
        client.addMention(mention)
        client.draft = completed.text
        selection = TextSelection(insertionPoint: String.Index(utf16Offset: completed.caret, in: completed.text))
    }

    // MARK: - Attachments

    private var attachButton: some View {
        Button(action: presentImagePicker) {
            Image(systemName: "photo")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(theme.color("fg-muted"))
                .frame(width: 28, height: 24)
                .background(RoundedRectangle(cornerRadius: 6).fill(theme.color("bg-3").opacity(0.7)))
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(theme.color("line"), lineWidth: 0.75))
        }
        .buttonStyle(.plain)
        .disabled(!sessionOpen)
        .accessibilityLabel("Attach image")
        .help("Attach an image")
    }

    private var attachmentStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(client.attachments) { attachment in
                    ZStack(alignment: .topTrailing) {
                        Group {
                            if let image = NSImage(data: attachment.data) {
                                Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
                            } else {
                                Image(systemName: "photo").foregroundStyle(theme.color("fg-muted"))
                            }
                        }
                        .frame(width: 44, height: 44)
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                        .help(attachment.name ?? "Image")
                        Button { client.removeAttachment(attachment.id) } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: 12))
                                .foregroundStyle(theme.color("fg"), theme.color("bg-3"))
                        }
                        .buttonStyle(.plain)
                        .offset(x: 4, y: -4)
                        .accessibilityLabel("Remove attachment")
                    }
                }
            }
            .padding(.top, 4)
            .padding(.horizontal, 4)
        }
    }

    private func presentImagePicker() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.png, .jpeg, .gif, .webP]
        panel.begin { response in
            guard response == .OK else { return }
            attachImages(at: panel.urls)
        }
    }

    private func attachImages(at urls: [URL]) {
        var refusal: String?
        for url in urls where url.isFileURL {
            // Sizes first: a file the remaining count or byte budget can't
            // take is refused without being read.
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            if let tooBig = NativePeerComposerState.attachmentSizeRefusal(
                size, stagedSizes: client.attachments.map(\.data.count)) {
                refusal = tooBig
                continue
            }
            guard let data = try? Data(contentsOf: url) else { continue }
            refusal = client.addAttachment(data, name: url.lastPathComponent) ?? refusal
        }
        showNotice(refusal)
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
