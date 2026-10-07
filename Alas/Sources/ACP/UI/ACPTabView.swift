import AppKit
import SwiftUI
import UniformTypeIdentifiers

enum ACPSessionAttachFreshness {
    static func isFresh(restoredFromPersistence: Bool, remoteSessionId: String?) -> Bool {
        !restoredFromPersistence && (remoteSessionId?.isEmpty ?? true)
    }
}

struct ACPTabView: View {
    let sessionId: ACPSession.ID
    let state: AppState
    let worktree: Worktree
    var owner: SessionOwnerID? = nil
    var onOpenPreview: (() -> Void)? = nil
    var onStartupRecoveryReady: () -> Void = {}
    var nextPromptOffer: String? = nil
    var takeNextPromptOffer: () -> String? = { nil }
    var dismissNextPromptOffer: () -> Void = {}
    var onNextPromptStateChange: (NextPromptEligibilitySnapshot.Environment) -> Void = { _ in }
    var nextPromptInputBlocked: () -> Bool = { false }

    var body: some View {
        Group {
            if let manager = managerForOwnerBoundary {
                ACPManagedTabView(
                    sessionId: sessionId,
                    state: state,
                    worktree: worktree,
                    owner: owner,
                    onOpenPreview: onOpenPreview,
                    onStartupRecoveryReady: onStartupRecoveryReady,
                    manager: manager,
                    nextPromptOffer: nextPromptOffer,
                    takeNextPromptOffer: takeNextPromptOffer,
                    dismissNextPromptOffer: dismissNextPromptOffer,
                    onNextPromptStateChange: onNextPromptStateChange,
                    nextPromptInputBlocked: nextPromptInputBlocked
                )
            } else {
                unavailable
            }
        }
        .task(id: agentAvailabilityTaskKey) {
            if let checkout = selectedWorkspaceCheckout {
                await state.loadAgentAvailability(
                    worktreePath: URL(fileURLWithPath: checkout.rootPath),
                    executionTarget: checkout.executionLocation.agentExecutionTarget
                )
            } else {
                await state.loadAgentAvailability(for: worktree)
            }
        }
    }

    private var agentAvailabilityTaskKey: String {
        if let checkout = selectedWorkspaceCheckout {
            let root = URL(fileURLWithPath: checkout.rootPath)
            let generation = state.agentAvailabilityGeneration(
                worktreePath: root,
                executionTarget: checkout.executionLocation.agentExecutionTarget
            )
            return "\(checkout.executionLocation.identityComponent)\u{0000}\(root.path)\u{0000}\(generation)"
        }
        return "\(worktree.path.path):\(state.agentAvailabilityGeneration(for: worktree))"
    }

    private var selectedWorkspaceCheckout: WorkspaceCheckout? {
        state.workspaceCheckout(for: owner)
    }

    private var managerForOwnerBoundary: ACPSessionManager? {
        if let owner {
            return state.acpManager(for: owner)
        }
        return state.acpManager(for: worktree)
    }

    private var unavailable: some View {
        VStack {
            Spacer()
            Text("ACP session unavailable").foregroundStyle(.secondary)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct ACPManagedTabView: View {
    let sessionId: ACPSession.ID
    let state: AppState
    let worktree: Worktree
    let owner: SessionOwnerID?
    let onOpenPreview: (() -> Void)?
    let onStartupRecoveryReady: () -> Void
    @ObservedObject var manager: ACPSessionManager
    var nextPromptOffer: String? = nil
    var takeNextPromptOffer: () -> String? = { nil }
    var dismissNextPromptOffer: () -> Void = {}
    var onNextPromptStateChange: (NextPromptEligibilitySnapshot.Environment) -> Void = { _ in }
    var nextPromptInputBlocked: () -> Bool = { false }

    var body: some View {
        if let session = manager.placeholderSession(id: sessionId) {
            ACPSessionView(
                sessionId: sessionId,
                state: state,
                worktree: worktree,
                owner: owner,
                onOpenPreview: onOpenPreview,
                manager: manager,
                session: session,
                onStartupRecoveryReady: onStartupRecoveryReady,
                transcript: session.transcript,
                nextPromptOffer: nextPromptOffer,
                takeNextPromptOffer: takeNextPromptOffer,
                dismissNextPromptOffer: dismissNextPromptOffer,
                onNextPromptStateChange: onNextPromptStateChange,
                nextPromptInputBlocked: nextPromptInputBlocked
            )
            // Refcount this tab's hold on the cached `ACPSession`. When the
            // tab is dismissed (worktree switch, tab close, window close)
            // and no other UI surface still retains the same id, the manager
            // evicts it from `sessions` so its transcript + markdown caches
            // can be reclaimed. Reopening rehydrates from SQLite.
            .onAppear {
                manager.retainSession(id: sessionId)
                manager.markSessionVisible(id: sessionId)
            }
            .onDisappear {
                manager.unmarkSessionVisible(id: sessionId)
                manager.releaseSession(id: sessionId)
            }
        } else {
            if manager.isKnownMissingSession(id: sessionId) {
                VStack {
                    Spacer()
                    Text("ACP session unavailable").foregroundStyle(.secondary)
                    Spacer()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .task {
                    onStartupRecoveryReady()
                }
            } else {
                ProgressView()
                    .controlSize(.small)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .task {
                        _ = manager.placeholderSession(id: sessionId)
                    }
            }
        }
    }
}

/// Single-column Flow layout (no history sidebar). Transcript scrolls full
/// width; composer floats over the bottom with heavy blur. Setup nudge
/// and lastError banner sit between toolbar and transcript.
private struct ACPSessionView: View {
    let sessionId: ACPSession.ID
    let state: AppState
    let worktree: Worktree
    let owner: SessionOwnerID?
    let onOpenPreview: (() -> Void)?
    let manager: ACPSessionManager
    @ObservedObject var session: ACPSession
    let onStartupRecoveryReady: () -> Void
    /// Observed so the body re-evaluates when pending user action arrives.
    /// `scopeKey(for:)` reads the permission value through this and passes
    /// it down to `ACPMessageList`; otherwise the message list gets a stale
    /// `""` scope and persisted allow/reject_always decisions land under the
    /// wrong key.
    @ObservedObject var transcript: ACPTranscript
    var nextPromptOffer: String? = nil
    var takeNextPromptOffer: () -> String? = { nil }
    var dismissNextPromptOffer: () -> Void = {}
    var onNextPromptStateChange: (NextPromptEligibilitySnapshot.Environment) -> Void = { _ in }
    var nextPromptInputBlocked: () -> Bool = { false }
    @State private var pendingComposerDrops = 0
    @State private var updateState: AdapterUpdateState?
    @State private var dismissedLatest: String?
    /// Update state of the agent CLI itself when Alas detected it on PATH
    /// instead of installing it (omp, opencode, the pi CLI under pi-acp).
    @State private var agentUpdateState: AdapterUpdateState?
    @State private var agentDismissedLatest: String?
    @State private var agentUpdateOwner: ACPDetectedAgentOwner?
    @Environment(\.theme) private var theme
    @State private var composerFocusRequest: Int = 0
    @StateObject private var composerDropRouter = ACPComposerDropRouter()
    @StateObject private var composerActions = ACPComposerActions()

    private var adapterTarget: ACPAdapterTarget {
        guard let host = RemoteHostRegistry.shared.host(forPath: worktree.path.path) else {
            return .local
        }
        return .ssh(host: host)
    }

    private var adapterUpdateKey: ACPAdapterUpdateKey {
        ACPAdapterUpdateKey(target: adapterTarget, agentID: session.agentId)
    }

    private var adapterTargetHost: String? {
        guard case .ssh(let host) = adapterTarget else { return nil }
        return host
    }

    var body: some View {
        VStack(spacing: 0) {
            if ACPFirstRunConnectingPolicy.showsChrome(firstRunConnecting: isFirstRunConnecting) {
                ACPToolbar(
                    session: session,
                    manager: manager,
                    agentLookup: { state.agent(id: $0) },
                    state: state,
                    worktree: worktree,
                    sessionSummaryCoordinator: state.sessionSummaryCoordinator,
                    sessionSummariesRequested: sessionSummariesRequested,
                    sessionSummariesRuntimeEnabled: state.sessionSummariesRuntimeEnabled,
                    localTextSupported: state.localTextSupported,
                    localTextModelState: state.localTextModelState,
                    owner: owner,
                    onOpenPreview: onOpenPreview
                )
                adapterBanner()
                repoMCPTrustBanner()
                contextRestoreBanner()
                if let retry = session.retryStatus {
                    retryBanner(retry)
                }
                if let limit = session.usageLimit {
                    usageLimitBanner(limit, resumeAt: session.usageLimitResumeItem?.scheduledAt)
                }
                if manager.showsTakeoverBanner(sessionId: sessionId) {
                    mirrorBanner()
                }
                if let err = session.lastError {
                    errorBanner(err)
                } else if case .failed(let reason) = session.agentState,
                          showsGenericFailureBanner {
                    errorBanner(reason, dismissible: false)
                }
                if case .failed(let msg) = session.hydrationState {
                    hydrationFailureBanner(message: msg)
                }
            }
            transcriptAndComposer
        }
        .onChange(of: isFirstRunConnecting) { oldValue, newValue in
            composerFocusRequest = ACPComposerFocusPolicy.focusRequest(
                current: composerFocusRequest,
                oldFirstRunConnecting: oldValue,
                newFirstRunConnecting: newValue,
                composerReady: composerCanAcceptInput
            )
        }
        .onAppear {
            applySessionSummaryBinding(
                ACPSessionSummaryBindingPolicy.action(from: nil, to: sessionSummaryBindingInput)
            )
        }
        .onChange(of: sessionSummaryBindingInput) { previous, current in
            applySessionSummaryBinding(
                ACPSessionSummaryBindingPolicy.action(from: previous, to: current)
            )
        }
        .task(id: sessionId) {
            await hydrateAndAttach()
            onStartupRecoveryReady()
            // Optional and possibly slow (`brew outdated`); never gate startup
            // recovery on it.
            await refreshAdapterUpdateState()
        }
        .onExitCommand {
            handleEscape()
        }
    }

    private var sessionSummariesRequested: Bool {
        state.config.sessionSummariesEnabled && !state.sessionSummaryDisableSavePending
    }

    private var sessionSummaryBindingInput: ACPSessionSummaryBindingPolicy.Input {
        .init(
            requested: sessionSummariesRequested,
            supported: state.localTextSupported,
            incarnation: session.incarnation
        )
    }

    private func applySessionSummaryBinding(_ action: ACPSessionSummaryBindingPolicy.Action) {
        switch action {
        case .none:
            break
        case .bind:
            state.sessionSummaryCoordinator.bind(to: session)
        case .teardown:
            state.sessionSummaryCoordinator.teardown()
        }
    }

    /// Esc cancels the in-flight request. Idempotent — safe to press
    /// when nothing's streaming.
    private func handleEscape() {
        // An open side question goes first: Esc discards it, and only the
        // next Esc cancels the main turn.
        if manager.sideQuestions[sessionId] != nil {
            Task { await manager.dismissSideQuestion(parentID: sessionId) }
            return
        }
        guard session.transcript.streamingState == .streaming || session.transcript.streamingState == .sending
              || session.transcript.streamingState == .awaitingPermission
              || session.transcript.streamingState == .awaitingInput
              || !session.transcript.pendingUserInputs.isEmpty
              || session.hasCancellableBackgroundWork
        else { return }
        Task {
            if let runner = manager.runners[sessionId] {
                await runner.userCancel()
            }
        }
    }

    private func sideQuestionSlot(contentMaxWidth: CGFloat) -> some View {
        ACPSideQuestionSlot(
            manager: manager,
            parentID: sessionId,
            typography: chatTypography,
            onInsert: insertSideAnswer,
            onKeep: {
                state.keepACPSideQuestion(worktree: worktree, owner: owner, parentID: sessionId)
            }
        )
        .frame(maxWidth: contentMaxWidth)
        .padding(.horizontal, 20)
    }

    private func insertSideAnswer(_ answer: String) {
        var draft = session.composerDraft
        let separator = draft.isEmpty ? "" : "\n\n"
        draft.segments.append(.text(separator + answer))
        manager.persistComposerDraft(draft, for: session)
        composerFocusRequest += 1
    }

    private func insertStarterPrompt(_ starter: ACPStarterPrompt) {
        let next = starter.applying(to: session.composerDraft)
        manager.persistComposerDraft(next, for: session)
        composerFocusRequest += 1
    }

    /// True when we're actively spawning + initialising the agent on a
    /// fresh open. Don't show the empty transcript or "agent not yet
    /// attached" warning during this — render a skeleton instead.
    private var isConnecting: Bool {
        if session.hydrationState == .loading { return true }
        guard manager.runners[sessionId] == nil else { return false }
        if case .needsSetup = session.setupState { return false }
        if case .setupError = session.setupState { return false }
        if case .needsAuth = session.setupState { return false }
        if session.lastError != nil { return false }
        if session.agentState == .disconnected { return false }
        return session.transcript.messages.isEmpty
    }

    private var firstRunConnectingPhase: ACPFirstRunConnectingPhase? {
        ACPFirstRunConnectingPolicy.phase(for: session)
    }

    private var isFirstRunConnecting: Bool {
        firstRunConnectingPhase != nil
    }

    private var showsPreSessionUserInput: Bool {
        (isFirstRunConnecting || isConnecting)
            && (!session.transcript.pendingUserInputs.isEmpty
                || !session.transcript.urlElicitationWaits.isEmpty)
    }

    private var isNewEmptySession: Bool {
        ACPNewChatEmptyStatePolicy.isVisible(for: session)
    }

    private var isMirror: Bool { manager.isMirror(sessionId: sessionId) }
    private var mirrorIsBusy: Bool { manager.mirrorIsBusy(sessionId: sessionId) }

    private var composerCanAcceptInput: Bool {
        guard !isMirror else { return false }
        guard session.hydrationState == .ready else { return false }
        guard case .ready = session.setupState else { return false }
        guard case .ready = session.agentState else { return false }
        return true
    }

    private var composerPlacement: ACPComposerPlacement {
        ACPFirstRunConnectingPolicy.composerPlacement(
            firstRunConnecting: isFirstRunConnecting,
            newEmptySession: isNewEmptySession
        )
    }

    private var emptyStateAnimation: Animation {
        .spring(response: 0.32, dampingFraction: 0.86)
    }

    private var chatTypography: ACPChatTypography {
        ACPChatTypography(
            fontFamily: state.config.agents.chatFontFamily,
            fontSize: state.config.agents.chatFontSize
        )
    }

    private var transcriptAndComposer: some View {
        GeometryReader { chatProxy in
            let chatContentMaxWidth = ACPChatLayout.contentMaxWidth(
                forChatColumnWidth: chatProxy.size.width
            )
            let showMinimap = ACPTranscriptScrollerView.shouldShowMinimap(
                preferred: state.config.harness.acpShowMinimap,
                availableWidth: chatProxy.size.width
            )
            chatSurface(
                contentMaxWidth: chatContentMaxWidth,
                showMinimap: showMinimap
            )
                .frame(width: chatProxy.size.width, height: chatProxy.size.height)
                .animation(emptyStateAnimation, value: isNewEmptySession)
                .animation(emptyStateAnimation, value: isFirstRunConnecting)
                .onDrop(of: [.alasDropPayload], isTargeted: nil, perform: handleDrop)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        guard !isMirror,
              composerDropRouter.isAttached,
              let provider = providers.first(where: {
                  $0.hasItemConformingToTypeIdentifier(UTType.alasDropPayload.identifier)
              })
        else { return false }

        dismissNextPromptOffer()
        pendingComposerDrops += 1
        provider.loadDataRepresentation(
            forTypeIdentifier: UTType.alasDropPayload.identifier
        ) { data, _ in
            Task { @MainActor in
                defer { pendingComposerDrops -= 1 }
                guard let data else { return }
                _ = composerDropRouter.insert(
                    encoded: data,
                    enabled: !manager.isMirror(sessionId: sessionId)
                )
            }
        }
        return true
    }

    private func chatSurface(
        contentMaxWidth: CGFloat,
        showMinimap: Bool
    ) -> some View {
        ZStack(alignment: .bottom) {
            if showsPreSessionUserInput {
                messageList(contentMaxWidth: contentMaxWidth, showMinimap: showMinimap)
                    .transition(.opacity)
            } else if let phase = firstRunConnectingPhase {
                introStateAndComposer(contentMaxWidth: contentMaxWidth) {
                    ACPFirstRunConnectingView(
                        agentDisplayName: state.agent(id: session.agentId)?.displayName ?? session.agentId,
                        phase: phase,
                        connectionStartedAt: session.connectionAttemptStartedAt,
                        reconnectAvailable: !isMirror,
                        restartInProgress: session.connectionRestartInProgress,
                        onRestart: {
                            guard !isMirror else { return }
                            Task { await manager.reconnectNow(to: sessionId) }
                        },
                        bottomInset: 0
                    )
                }
            } else if isNewEmptySession {
                introStateAndComposer(contentMaxWidth: contentMaxWidth) {
                    ACPNewChatEmptyStateView(
                        agentDisplayName: state.agent(id: session.agentId)?.displayName ?? session.agentId,
                        bottomInset: 0,
                        onStarterPrompt: insertStarterPrompt
                    )
                    .transition(
                        .opacity.combined(with: .move(edge: .top))
                    )
                }
            } else {
                if isConnecting {
                    ACPConnectingPlaceholder(
                        agentDisplayName: state.agent(id: session.agentId)?.displayName ?? session.agentId,
                        connectionStartedAt: session.connectionAttemptStartedAt,
                        reconnectAvailable: !isMirror,
                        restartInProgress: session.connectionRestartInProgress,
                        onRestart: {
                            guard !isMirror else { return }
                            Task { await manager.reconnectNow(to: sessionId) }
                        }
                    )
                } else {
                    messageList(contentMaxWidth: contentMaxWidth, showMinimap: showMinimap)
                        .transition(.opacity)
                }

                VStack(spacing: 8) {
                    sideQuestionSlot(contentMaxWidth: contentMaxWidth)
                    composerView(
                        placement: composerPlacement,
                        contentMaxWidth: contentMaxWidth,
                        typography: chatTypography
                    )
                }
                .padding(.trailing, showMinimap && !isConnecting ? MinimapView.width : 0)
            }
        }
    }

    private func messageList(contentMaxWidth: CGFloat, showMinimap: Bool) -> ACPMessageList {
        ACPMessageList(
            session: session,
            transcript: session.transcript,
            contentMaxWidth: contentMaxWidth,
            typography: chatTypography,
            onOpenDiff: { relativePath in
                state.openDiffTab(forFileInWorktree: worktree, relativePath: relativePath)
            },
            onOpenTranscriptLink: { url in
                if let target = ACPSymbolReference.target(fromURI: url.absoluteString) {
                    // Symbol mentions are off in workspace checkouts: a link's
                    // path is relative to the checkout root, not the focused member.
                    guard !isWorkspaceCheckoutOwner else { return true }
                    state.openFile(
                        relativePath: target.path,
                        worktreeId: worktree.id,
                        revealLine: target.lineRange.lowerBound,
                        revealEndLine: target.lineRange.upperBound,
                        revealCharacter: 0
                    )
                    return true
                }
                switch state.transcriptLinkRoute(url, worktreeId: worktree.id) {
                case .opened, .ignored:
                    return true
                case .systemOpen(let fileURL):
                    // Claimed either way: the destination this came from is
                    // a schemeless path (`/Users/me/notes.md` parses as a
                    // relative URL), and handing that to the default action
                    // only ever yields paramErr -50. The resolved `file:`
                    // URL is the sole form the system can act on.
                    _ = NSWorkspace.shared.open(fileURL)
                    return true
                case .unhandled:
                    return false
                }
            },
            // Use the runner's policy (where the agent's continuation
            // lives) so the user's click can resolve the pending permission
            // request.
            policy: manager.runners[sessionId]?.policy,
            trustedImageRoot: worktree.path,
            scopeKey: scopeKey(for: session.transcript.pendingPermission),
            onUserInputResponse: { token, action in
                manager.respondToUserInput(for: sessionId, token: token, action: action)
            },
            onPlanResponse: { requestId, response in
                manager.respondToPlan(for: sessionId, requestId: requestId, response)
            },
            onOpenElicitationURL: { token in
                await manager.openElicitationURL(for: sessionId, token: token)
            },
            onDismissElicitationURLWait: { elicitationId in
                manager.dismissElicitationURLWait(
                    for: sessionId,
                    elicitationId: elicitationId
                )
            },
            // Every queue callback below re-reads `isMirror` when it fires
            // rather than being swapped for a no-op up front: the AppKit
            // scroller retains a mounted queue row's closures until that
            // row's equality token changes, and the token cannot cover
            // callback identity. See
            // `ACPTranscriptQueuePolicy.allowsQueueMutation`.
            onQueueEdit: { item in
                guard ACPTranscriptQueuePolicy.allowsQueueMutation(isMirror: isMirror) else { return }
                // Return the pending item to the composer without losing its
                // structured draft. The manager also releases any model/mode
                // selection waiting for this queued item to dispatch.
                Task { @MainActor in
                    await manager.queueEditIntoComposer(for: sessionId, itemId: item.id)
                }
            },
            onQueueForceSend: { id in
                guard ACPTranscriptQueuePolicy.allowsQueueMutation(isMirror: isMirror) else { return }
                Task { await manager.queueForceSend(for: sessionId, itemId: id) }
            },
            onQueuePromote: { id in
                // Non-interrupting reorder: never touches an in-flight
                // turn, so unlike `onQueueForceSend` this runs synchronously
                // against the local session rather than through the
                // manager's writer-lease/reattach dance.
                guard ACPTranscriptQueuePolicy.allowsQueueMutation(isMirror: isMirror) else { return }
                guard session.forceQueueItem(id: id) else { return }
                manager.persistQueue(for: session)
                manager.runners[sessionId]?.flushQueueIfIdle()
            },
            onQueueRemove: { id in
                guard ACPTranscriptQueuePolicy.allowsQueueMutation(isMirror: isMirror) else { return }
                Task { @MainActor in
                    await manager.queueRemove(for: sessionId, itemId: id)
                }
            },
            onQueueRetry: { id in
                guard ACPTranscriptQueuePolicy.allowsQueueMutation(isMirror: isMirror) else { return }
                Task { await manager.queueRetry(for: sessionId, itemId: id) }
            },
            onQueueReorder: { src, dst in
                guard ACPTranscriptQueuePolicy.allowsQueueMutation(isMirror: isMirror) else { return }
                session.moveInQueue(from: src, to: dst)
                manager.persistQueue(for: session)
                manager.runners[sessionId]?.flushQueueIfIdle()
            },
            onQueueClearAll: {
                guard ACPTranscriptQueuePolicy.allowsQueueMutation(isMirror: isMirror) else { return }
                Task { @MainActor in
                    await manager.queueClear(for: sessionId)
                }
            },
            onRetryContextRecovery: {
                _ = manager.sendTranscriptAsContext(
                    sessionId: sessionId,
                    agentName: state.agent(id: session.agentId)?.displayName
                )
            },
            reconnectAvailable: !isMirror,
            onReconnect: {
                guard !isMirror else { return }
                Task { await manager.reconnectNow(to: sessionId) }
            },
            rememberedScrollAnchor: {
                manager.rememberedTranscriptScrollAnchor(for: sessionId)
            },
            onRememberScrollAnchor: { anchor, index, followsTail in
                manager.rememberTranscriptScrollAnchor(
                    sessionId: sessionId,
                    anchorMessageId: anchor,
                    anchorMessageIndex: index,
                    followsTail: followsTail
                )
            },
            onLoadFullToolCallContent: { toolCallId in
                await manager.reloadFullToolCallContent(
                    sessionId: sessionId, toolCallId: toolCallId)
            },
            forkTargets: state.acpForkTargets(
                sourceAgentID: session.agentId,
                worktreePath: acpForkTargetWorktreePath,
                executionTarget: acpForkTargetExecutionTarget
            ),
            onQuote: { message in
                composerActions.quote(message)
            },
            onFork: { boundary, targetAgentID in
                if let owner {
                    state.forkACPSession(
                        owner: owner,
                        sourceSessionID: sessionId,
                        boundary: boundary,
                        targetAgentID: targetAgentID
                    )
                } else {
                    state.forkACPSession(
                        worktree: worktree,
                        sourceSessionID: sessionId,
                        boundary: boundary,
                        targetAgentID: targetAgentID
                    )
                }
            },
            onRestoreCheckpoint: { checkpointID in
                guard let pane = state.rightPaneStore.activeState(worktreeId: worktree.id) else {
                    session.lastError = "Checkpoint restore is unavailable for this worktree."
                    return
                }
                Task {
                    await pane.previewCheckpointRestore(id: checkpointID)
                    if let error = pane.lastCheckpointError {
                        session.lastError = error
                    }
                }
            },
            messageMenuItems: { [isWorkspaceCheckoutOwner] in
                // Plugins run per project, so a workspace checkout's sessions have none.
                guard !isWorkspaceCheckoutOwner else { return [] }
                return state.pluginCommands(.messageMenu, projectID: worktree.projectId).map { item in
                    ACPMessageMenuItem(title: item.command.title, icon: item.command.icon) { markdown in
                        state.runPluginCommand(item, slot: .messageMenu, worktreeID: worktree.id, detail: sessionId, text: markdown)
                    }
                }
            },
            // Nil in a mirror so the row never draws a Cancel the reader
            // cannot use. The closure ALSO re-reads `isMirror` when it
            // fires, for the same reason the queue callbacks above do: a
            // mounted row keeps its closures until its equality token
            // changes, and that token cannot cover callback identity.
            onCancelSubagent: isMirror ? nil : { subagentSessionId in
                guard !isMirror else { return }
                Task { await manager.cancelSubagent(for: sessionId, subagentSessionId: subagentSessionId) }
            },
            onOpenForkSource: { sourceSessionID in
                Task {
                    if let owner {
                        await state.openExistingACPSession(sessionId: sourceSessionID, owner: owner)
                    } else {
                        await state.openExistingACPSession(sessionId: sourceSessionID)
                    }
                }
            },
            agentDisplayName: { agentID in
                state.agent(id: agentID)?.displayName ?? agentID
            },
            showMinimap: showMinimap,
            collapsesFinishedToolCalls: state.config.harness.acpCollapseFinishedToolCalls,
            upstreamReferences: manager.upstreamReferences.store(for: worktree.path),
            visualAidActions: ACPVisualAidActions(
                answer: { visualId, answer in
                    await manager.answerVisualAid(id: visualId, answer: answer, in: sessionId)
                },
                popOut: { _ in }
            )
        )
    }

    private func introStateAndComposer<Intro: View>(
        contentMaxWidth: CGFloat,
        @ViewBuilder intro: () -> Intro
    ) -> some View {
        VStack(spacing: 0) {
            intro()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            // `/btw` can be the first thing asked in a new session.
            sideQuestionSlot(contentMaxWidth: contentMaxWidth)
                .padding(.bottom, 8)
            composerView(
                placement: .inFlow,
                contentMaxWidth: contentMaxWidth,
                typography: chatTypography
            )
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func composerView(
        placement: ACPComposerPlacement,
        contentMaxWidth: CGFloat = ACPChatLayout.defaultContentMaxWidth,
        typography: ACPChatTypography? = nil
    ) -> some View {
        ACPComposer(
            session: session,
            manager: manager,
            worktreeRoot: worktree.path,
            sendOnEnter: state.config.harness.acpSendOnEnter,
            dictationLocale: state.config.harness.acpDictationLocale,
            onSelectDictationLocale: { [state] identifier in
                state.config.harness.acpDictationLocale = identifier
                state.saveConfig()
            },
            focusRequest: composerFocusRequest,
            dropRouter: composerDropRouter,
            placement: placement,
            contentMaxWidth: contentMaxWidth,
            typography: typography ?? chatTypography,
            actions: composerActions,
            filesProvider: { [state, worktree] in
                await state.fileIndex.invalidate(forWorktreePath: worktree.path)
                async let entries = try? state.fileIndex.entries(forWorktreePath: worktree.path)
                guard let entries = await entries else { return [] }
                let root = worktree.path
                var result: [URL] = []
                var dirEntries: [(path: String, isDirectory: Bool)] = []
                for entry in entries {
                    let url = root.appendingPathComponent(entry.relativePath)
                    guard (try? url.checkResourceIsReachable()) ?? false else { continue }
                    let isDir = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
                    if isDir {
                        // Untracked directory or submodule gitlink; expand
                        // it so its files and subdirectories show too.
                        let sub = MentionFuzzy.collectFiles(under: url, limit: 5000)
                        result.append(contentsOf: sub)
                    } else {
                        result.append(url)
                    }
                    dirEntries.append((entry.relativePath, isDir))
                }
                // `git ls-files` lists files only - reconstruct every
                // directory (tracked dirs and submodules included) so
                // they are pickable in the @ menu, flagged for the
                // folder icon.
                result += MentionFuzzy.pickerDirectories(forEntries: dirEntries, root: root)
                return result
            },
            sessionMentions: isWorkspaceCheckoutOwner ? nil : sessionMentions,
            // A checkout's runner resolves symbol paths against the checkout
            // root, but `worktree` is the focused member repo.
            symbolMentions: isWorkspaceCheckoutOwner ? nil : symbolMentions,
            nextPromptOffer: nextPromptOffer,
            takeNextPromptOffer: takeNextPromptOffer,
            dismissNextPromptOffer: dismissNextPromptOffer,
            onNextPromptStateChange: onNextPromptStateChange,
            nextPromptInputBlocked: { nextPromptInputBlocked() || pendingComposerDrops > 0 || !composerCanAcceptInput },
            pluginPrompts: pluginPrompts.map(\.suggestion),
            contextProviders: isWorkspaceCheckoutOwner ? [] : state.pluginContextProviders(projectID: worktree.projectId)
        ) { text, attachments, intent, draft, onPromptFinished -> Bool in
            // `intent` is already resolved by the composer for keyboard
            // submits; the toolbar send button bypasses the keyboard
            // inversion and supplies its own intent directly. No
            // further resolution here.
            //
            // The eager in-memory clear happens AFTER `manager.submit`
            // returns but BEFORE the completion closure can run (the
            // submit's completion is always dispatched via a Task,
            // so it runs on a later main-actor tick). The
            // suspendedRevision captured below identifies the post-
            // clear state - if the user has typed a new draft by the
            // time the completion fires, the conditional checks in
            // purge/reinstate skip and the new draft survives.
            // `/btw` never reaches the main session: it opens a side question.
            switch ACPSideQuestionSubmitRoute.resolve(
                text: text,
                hasAttachments: !attachments.isEmpty,
                intent: intent,
                isAvailable: !isMirror && !session.readOnlyRestricted
            ) {
            case .passThrough:
                break
            case .refuse(let reason):
                session.lastError = reason
                return false
            case .ask(let question):
                // Complete the composer's submission like a sent prompt, so
                // its persisted draft is cleared and `/btw …` doesn't come
                // back. Deferred: the composer records the pending submit
                // only after this handler returns.
                Task { @MainActor in onPromptFinished(true) }
                Task { @MainActor in
                    if question.isEmpty {
                        await manager.composeSideQuestion(parentID: sessionId)
                    } else {
                        _ = try? await manager.startSideQuestion(parentID: sessionId, question: question)
                    }
                }
                return true
            }
            // A plugin's slash prompt is expanded by its plugin into the draft, so the user sees what would go out.
            if !isMirror, !session.readOnlyRestricted, let match = PluginPromptItem.match(text, in: pluginPrompts) {
                guard attachments.isEmpty else {
                    session.lastError = "/\(match.item.prompt.name) doesn't take attachments. Remove them to expand it."
                    return false
                }
                let revision = session.composerDraftRevision
                Task { @MainActor in
                    switch await state.expandPluginPrompt(
                        match.item, projectID: worktree.projectId, args: match.args, session: sessionId) {
                    case .text(let expanded):
                        // Only over the draft it came from: someone who kept typing keeps their text.
                        guard session.composerDraftRevision == revision else { return }
                        manager.persistComposerDraft(ACPComposerDraft(segments: [.text(expanded)]), for: session)
                    case .failed(let reason):
                        session.lastError = reason
                    case .busy:
                        break
                    }
                }
                return false
            }
            let suspendedRevision = ACPSuspendedRevisionBox()
            let accepted = manager.submit(
                sessionId: sessionId,
                text: text,
                attachments: attachments,
                intent: intent,
                draft: draft
            ) { succeeded in
                if suspendedRevision.value >= 0 {
                    if succeeded {
                        manager.purgeSuspendedComposerDraft(
                            for: session,
                            suspendedRevision: suspendedRevision.value
                        )
                    } else {
                        manager.reinstateSuspendedComposerDraft(
                            draft,
                            for: session,
                            suspendedRevision: suspendedRevision.value
                        )
                    }
                }
                onPromptFinished(succeeded)
            }
            if accepted {
                suspendedRevision.value = manager.suspendComposerDraftForSubmission(
                    draft, for: session
                )
            }
            return accepted
        }
        .disabled(isMirror)
        .opacity(isMirror ? 0.5 : 1)
    }

    @ViewBuilder
    private func repoMCPTrustBanner() -> some View {
        // Workspace-checkout sessions plan their attachments from frozen
        // descriptors and never gain repo servers, so a trust decision made
        // here could not join the displayed session while still affecting
        // ordinary live sessions later.
        if !isWorkspaceCheckoutOwner,
           let project = state.projects.first(where: { $0.id == worktree.projectId }) {
            let decision = state.repoMCPTrustDecision(
                worktreeRoot: worktree.path,
                project: project
            )
            if decision.isVisible {
                RepoMCPTrustBanner(
                    pendingServers: decision.pendingServers,
                    approvalQueue: state.repoHookApprovalQueue,
                    onApproveAll: {
                        state.approveRepoMCPServers(projectId: project.id, servers: decision.pendingServers)
                    },
                    onDeclineAll: {
                        state.declineRepoMCPServers(projectId: project.id, servers: decision.pendingServers)
                    },
                    onApproveServer: { server in
                        state.approveRepoMCPServers(projectId: project.id, servers: [server])
                    },
                    onDeclineServer: { server in
                        state.declineRepoMCPServers(projectId: project.id, servers: [server])
                    }
                )
            }
        }
    }

    /// Slash prompts of the plugins running in this session's project; plugins run per project, so a workspace
    /// checkout has none.
    private var pluginPrompts: [PluginPromptItem] {
        isWorkspaceCheckoutOwner ? [] : state.pluginPrompts(projectID: worktree.projectId)
    }

    private var isWorkspaceCheckoutOwner: Bool {
        guard case .workspaceCheckout = owner else { return false }
        return true
    }

    /// Other sessions of this project, attachable from the composer.
    private var sessionMentions: ACPSessionMentionSource {
        ACPSessionMentionSource(
            candidates: { [state, worktree, sessionId] in
                await state.acpSessionMentionCandidates(projectId: worktree.projectId, excluding: sessionId)
            },
            candidate: { [state, worktree, sessionId] id in
                guard id != sessionId, let candidate = await state.acpSessionMentionCandidate(sessionId: id),
                      candidate.projectId == worktree.projectId
                else { return nil }
                return candidate
            }
        )
    }

    private var symbolMentions: ACPSymbolMentionSource {
        let root = worktree.path
        let fileIndex = state.fileIndex
        let symbolIndex = state.symbolIndex
        var index: (@MainActor () async -> AsyncStream<WorktreeSymbolIndex.Snapshot>)?
        if !root.isRemoteAlasPath {
            index = {
                // Fresh listing on every open, like the file provider does;
                // nil on a failed enumeration: the index replays its cache.
                await symbolIndex.updates(root: root) {
                    await fileIndex.invalidate(forWorktreePath: root)
                    return (try? await fileIndex.entries(forWorktreePath: root))?.map(\.relativePath)
                }
            }
        }
        return ACPSymbolMentionSource(
            index: index,
            fileSymbols: { fileQuery in
                // From FileIndex paths, not the picker's file list: that list
                // drops remote entries, and drill-down is remote's only route.
                // Each step can be slow (enumeration, a remote read, parsing),
                // and a newer keystroke or the closed picker cancels this one.
                let entries = (try? await fileIndex.entries(forWorktreePath: root)) ?? []
                guard !Task.isCancelled else { return [] }
                let urls = entries.map { root.appendingPathComponent($0.relativePath) }
                guard let best = MentionFuzzy.rank(files: urls, query: fileQuery, limit: 1, relativeTo: root).first,
                      !Task.isCancelled
                else { return [] }
                let relativePath = String(best.path.dropFirst(root.path.count + 1))
                guard let source = await SymbolSource.read(root: root, relativePath: relativePath),
                      !Task.isCancelled
                else { return [] }
                return SymbolExtractor.symbols(in: source, relativePath: relativePath)
            }
        )
    }

    private var isSetupNudgeDismissed: Bool {
        ACPSetupNudgeDismissal.isDismissed(
            state.config.harness.dismissedACPSetupNudges,
            key: adapterUpdateKey
        )
    }

    private var showsGenericFailureBanner: Bool {
        ACPAdapterUpdateBannerDecider.showsGenericFailure(
            setupState: session.setupState,
            setupNudgeDismissed: isSetupNudgeDismissed
        )
    }

    @ViewBuilder
    private func adapterBanner() -> some View {
        if case .needsAuth(let methods, let reason) = session.setupState {
            ACPAuthNudgeBanner(
                agentDisplayName: state.agent(id: session.agentId)?.displayName
                    ?? AgentBuiltins.entry(id: session.agentId)?.displayName
                    ?? session.agentId,
                methods: methods,
                reason: reason,
                onSignIn: { method in launchAuth(method) },
                onReconnect: { Task { await reattachAndRefreshAdapterUpdateState() } }
            )
        } else {
            let decision = ACPAdapterUpdateBannerDecider.decide(
                setupState: session.setupState,
                updateState: updateState,
                dismissedLatest: dismissedLatest,
                agentUpdateState: agentUpdateState,
                agentDismissedLatest: agentDismissedLatest)

            switch decision {
            case .showInstall where !isSetupNudgeDismissed:
                if ACPManagedAdapterDescriptor.descriptor(for: session.agentId) != nil {
                    ACPSetupNudgeBanner(
                        agentID: session.agentId,
                        agentDisplayName: AgentBuiltins.entry(id: session.agentId)?.displayName ?? session.agentId,
                        targetHost: adapterTargetHost,
                        mode: .install,
                        onDismiss: { dismissNudge() },
                        install: { try await installAdapter() },
                        onInstalled: { await reattachAfterAdapterChange() }
                    )
                } else if case .needsSetup(let reason) = session.setupState {
                    setupReasonBanner(reason: reason)
                }
            case .none:
                if case .setupError(let reason) = session.setupState {
                    setupReasonBanner(reason: reason) {
                        Task { await reattachAndRefreshAdapterUpdateState() }
                    }
                } else {
                    EmptyView()
                }
            case .showUpdate(let current, let latest):
                if ACPManagedAdapterDescriptor.descriptor(for: session.agentId) != nil {
                    ACPSetupNudgeBanner(
                        agentID: session.agentId,
                        agentDisplayName: AgentBuiltins.entry(id: session.agentId)?.displayName ?? session.agentId,
                        targetHost: adapterTargetHost,
                        mode: .update(current: current, latest: latest),
                        onDismiss: { dismissUpdate(latest: latest) },
                        install: { try await installAdapter() },
                        onInstalled: { await reattachAfterAdapterChange() }
                    )
                }
            case .showAgentUpdate(let current, let latest):
                if let owner = agentUpdateOwner {
                    ACPSetupNudgeBanner(
                        agentID: session.agentId,
                        agentDisplayName: AgentBuiltins.entry(id: session.agentId)?.displayName ?? session.agentId,
                        mode: .agentUpdate(current: current, latest: latest, manager: owner.managerName),
                        onDismiss: { dismissAgentUpdate(latest: latest, owner: owner) },
                        install: {
                            try await state.acpAdapterInstallCoordinator.updateDetectedAgent(
                                agentID: session.agentId,
                                owner: owner)
                        },
                        onInstalled: { await reattachAfterAgentUpdate(owner: owner) }
                    )
                }
            default:
                EmptyView()
            }
        }
    }

    @ViewBuilder
    private func mirrorBanner() -> some View {
        HStack(spacing: 6) {
            if mirrorIsBusy {
                ProgressView().controlSize(.small)
                Text("Working in another window — read-only")
            } else {
                Image(systemName: "eye")
                Text("Open in another window — read-only")
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(alignment: .trailing) {
            Button("Take over here") {
                Task { await manager.takeOver(sessionId: sessionId) }
            }
                .controlSize(.small)
                .padding(.trailing, 12)
        }
        .padding(.horizontal, 12).padding(.vertical, 6)
        .background(.quaternary)
    }

    @ViewBuilder
    private func contextRestoreBanner() -> some View {
        if session.contextRecoveryStatus == nil, let warning = session.contextRestoreWarning {
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.arrow.triangle.2.circlepath")
                    .foregroundStyle(theme.color("warn"))
                Text(warning.message)
                    .font(.system(size: 12))
                    .foregroundStyle(theme.color("fg"))
                Spacer()
                if warning.canSendTranscript {
                    Button("Send transcript as context") {
                        _ = manager.sendTranscriptAsContext(
                            sessionId: sessionId,
                            agentName: state.agent(id: session.agentId)?.displayName
                        )
                    }
                    .buttonStyle(.borderless)
                    .disabled(
                        session.agentState != .ready
                            || session.transcript.streamingState != .idle
                            || manager.runners[sessionId] == nil
                    )
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(theme.color("bg-1").opacity(0.7))
            .overlay(alignment: .bottom) {
                Rectangle().fill(theme.color("line")).frame(height: 0.5)
            }
        }
    }

    private func scopeKey(for pending: ACPSession.PendingPermission?) -> String {
        guard let p = pending else { return "" }
        return "tool:\(p.params.toolCall.title ?? p.params.toolCall.toolCallId)"
    }

    private func reattach() async {
        guard await !state.checkpointACPAdmissionDisabledAfterDiscovery(owner: owner, fallbackWorktree: worktree) else {
            session.lastError = AppState.checkpointRecoveryBlocksACPMessage
            return
        }
        // Drop any half-attached connection state, clear the prior error,
        // then re-run attach with the session's persisted-origin state.
        await manager.detach(sessionId: sessionId)
        session.lastError = nil
        session.setupState = .checking
        let freshlyCreated = ACPSessionAttachFreshness.isFresh(
            restoredFromPersistence: session.restoredFromPersistence,
            remoteSessionId: session.remoteSessionId
        )
        await manager.attach(to: sessionId, freshlyCreated: freshlyCreated)
    }

    private func launchAuth(_ method: ACPInitializeResult.ACPAuthMethod) {
        guard let spec = ACPLaunchCatalog.spec(for: session.agentId),
              let command = ACPAuthTerminalCommand.resolve(
                method: method,
                launchSpec: spec
              )
        else {
            session.lastError = "Failed to launch auth terminal: unsupported sign-in method."
            return
        }
        Task { @MainActor in
            do {
                _ = try await state.openACPAuthTerminalTabPreparingRemoteZmxIfNeeded(
                    for: worktree,
                    acpSessionId: sessionId,
                    command: command
                ) {
                    Task { @MainActor in
                        session.pendingAuthMethodId = method.id
                        await reattachAndRefreshAdapterUpdateState()
                    }
                }
            } catch {
                session.lastError = "Failed to launch auth terminal: \(error.localizedDescription)"
            }
        }
    }

    private func dismissNudge() {
        var dismissed = state.config.harness.dismissedACPSetupNudges
        let key = adapterUpdateKey
        if !ACPSetupNudgeDismissal.isDismissed(dismissed, key: key) {
            dismissed.append(ACPSetupNudgeDismissal.storageKey(for: key))
            state.config.harness.dismissedACPSetupNudges = dismissed
            _ = state.saveConfig()
        }
    }

    private func dismissUpdate(latest: String) {
        let key = adapterUpdateKey
        Task {
            await state.acpAdapterUpdateStore.dismiss(key: key, latest: latest)
            await MainActor.run { dismissedLatest = latest }
        }
    }

    private func dismissAgentUpdate(latest: String, owner: ACPDetectedAgentOwner) {
        let key = ACPAdapterUpdateKey.detectedCLI(agentID: session.agentId, owner: owner)
        Task {
            await state.acpAdapterUpdateStore.dismiss(key: key, latest: latest)
            await MainActor.run { agentDismissedLatest = latest }
        }
    }

    private func installAdapter() async throws {
        try await state.acpAdapterInstallCoordinator.install(
            target: adapterTarget,
            agentID: session.agentId
        )
    }

    private var acpForkTargetWorktreePath: URL {
        if let checkout = state.workspaceCheckout(for: owner) {
            return URL(fileURLWithPath: checkout.rootPath)
        }
        return worktree.path
    }

    private var acpForkTargetExecutionTarget: AgentExecutionTarget {
        if let checkout = state.workspaceCheckout(for: owner) {
            return checkout.executionLocation.agentExecutionTarget
        }
        return state.agentExecutionTarget(for: worktree)
    }

    private func reattachAfterAdapterChange() async {
        await state.acpAdapterUpdateStore.clear(key: adapterUpdateKey)
        await MainActor.run {
            updateState = nil
            dismissedLatest = nil
        }
        await reattach()
        await refreshAdapterUpdateState()
    }

    private func reattachAfterAgentUpdate(owner: ACPDetectedAgentOwner) async {
        await state.acpAdapterUpdateStore.clear(key: .detectedCLI(agentID: session.agentId, owner: owner))
        await MainActor.run {
            agentUpdateState = nil
            agentDismissedLatest = nil
        }
        await reattach()
        await refreshAdapterUpdateState()
    }

    private func reattachAndRefreshAdapterUpdateState() async {
        await reattach()
        await refreshAdapterUpdateState()
    }

    private func setupReasonBanner(
        reason: String,
        onRetry: (() -> Void)? = nil
    ) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "info.circle").foregroundStyle(theme.color("fg-faint"))
            Text(reason).font(.system(size: 12)).foregroundStyle(theme.color("fg-muted"))
            Spacer()
            if let onRetry {
                Button("Retry", action: onRetry)
                    .buttonStyle(.borderless)
                    .controlSize(.small)
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(theme.color("bg-1").opacity(0.6))
        .overlay(alignment: .bottom) {
            Rectangle().fill(theme.color("line")).frame(height: 0.5)
        }
    }

    /// Drive a session from `.loading` through `.ready` (or `.failed`)
    /// and, on success, attach the runner. Callers refresh update state
    /// afterwards. Used by both the initial
    /// `.task(id:)` and the failure banner's Retry button so a successful
    /// retry doesn't leave the session unattached with a disabled composer.
    private func hydrateAndAttach() async {
        await manager.hydrateIfNeeded(id: sessionId)
        if case .failed = session.hydrationState { return }
        guard await !state.checkpointACPAdmissionDisabledAfterDiscovery(owner: owner, fallbackWorktree: worktree) else {
            session.lastError = AppState.checkpointRecoveryBlocksACPMessage
            return
        }
        let freshlyCreated = manager.runners[sessionId] == nil
            && ACPSessionAttachFreshness.isFresh(
                restoredFromPersistence: session.restoredFromPersistence,
                remoteSessionId: session.remoteSessionId
            )
        await manager.attach(to: sessionId, freshlyCreated: freshlyCreated)
    }

    /// After attach: if the adapter is ready, ask the store for the cached
    /// update state of its npm package and of a detected agent CLI (or
    /// compute them on cache miss). Silent on failure.
    private func refreshAdapterUpdateState() async {
        guard case .ready = session.setupState else { return }
        await refreshManagedAdapterUpdateState()
        await refreshDetectedAgentUpdateState()
    }

    private func refreshDetectedAgentUpdateState() async {
        guard ACPDetectedAgentUpdater.runsLocally(
                adapterTarget: adapterTarget,
                checkoutLocation: state.workspaceCheckout(for: owner)?.executionLocation),
              let binary = ACPDetectedAgentUpdater.binaryName(
                agentID: session.agentId,
                binaryOverride: state.agent(id: session.agentId)?.binaryOverride)
        else { return }
        let owner = await Task.detached { ACPDetectedAgentUpdater.owner(ofBinary: binary) }.value
        guard let owner else {
            agentUpdateOwner = nil
            agentUpdateState = nil
            return
        }

        let store = state.acpAdapterUpdateStore
        let key = ACPAdapterUpdateKey.detectedCLI(agentID: session.agentId, owner: owner)
        let result = await store.checkOrCompute(key: key) {
            await ACPDetectedAgentUpdater().check(owner: owner)
        }
        var dismissed: String? = nil
        if case .available(_, let latest) = result,
           await store.isDismissed(key: key, latest: latest) {
            dismissed = latest
        }

        await MainActor.run {
            self.agentUpdateOwner = owner
            self.agentUpdateState = result
            self.agentDismissedLatest = dismissed
        }
    }

    private func refreshManagedAdapterUpdateState() async {
        guard let spec = ACPLaunchCatalog.spec(for: session.agentId),
              let pkg = spec.npmPackageName
        else { return }

        let store = state.acpAdapterUpdateStore
        let checker = ACPAdapterVersionChecker()
        let key = adapterUpdateKey
        let result = await store.checkOrCompute(key: key) {
            switch key.target {
            case .local:
                return await checker.check(packageName: pkg)
            case .ssh(let host):
                guard let descriptor = ACPManagedAdapterDescriptor.descriptor(for: key.agentID) else {
                    return .unknown
                }
                return await checker.check(host: host, descriptor: descriptor)
            }
        }
        var dismissed: String? = nil
        if case .available(_, let latest) = result,
           await store.isDismissed(key: key, latest: latest) {
            dismissed = latest
        }

        await MainActor.run {
            self.updateState = result
            self.dismissedLatest = dismissed
        }
    }

    private func hydrationFailureBanner(message: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(theme.color("del"))
            Text("Failed to load session history: \(message)")
                .font(.system(size: 12))
                .foregroundStyle(theme.color("fg"))
                .textSelection(.enabled)
            Spacer()
            Button("Retry") {
                session.hydrationState = .loading
                // Mirror the initial `.task(id:)` so a successful retry
                // continues into `attach`. Without this, the runner stays
                // nil and the composer can't send.
                Task {
                    await hydrateAndAttach()
                    await refreshAdapterUpdateState()
                }
            }
            .buttonStyle(.plain)
            .font(.system(size: 11, weight: .medium))
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(theme.color("del").opacity(0.18))
            .clipShape(Capsule())
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(theme.color("del").opacity(0.10))
        .overlay(alignment: .bottom) {
            Rectangle().fill(theme.color("del").opacity(0.3)).frame(height: 0.5)
        }
    }

    private func errorBanner(_ err: String, dismissible: Bool = true) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(theme.color("del"))
            Text(err)
                .font(.system(size: 12))
                .textSelection(.enabled)
                .foregroundStyle(theme.color("fg"))
            Spacer()
            if case .failed = session.agentState,
               session.connectionRecoveryState == nil,
               !isMirror {
                Button("Try again") { Task { await manager.reconnectNow(to: sessionId) } }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .tint(theme.color("accent"))
                    .disabled(session.connectionRestartInProgress)
            }
            if dismissible {
                Button {
                    session.lastError = nil
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 10))
                        .foregroundStyle(theme.color("fg-faint"))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(theme.color("del").opacity(0.10))
        .overlay(alignment: .bottom) {
            Rectangle().fill(theme.color("del").opacity(0.3)).frame(height: 0.5)
        }
    }

    private func usageLimitBanner(_ limit: ACPUsageLimit, resumeAt: Date?) -> some View {
        func time(_ date: Date) -> String { date.formatted(ACPUsageLimit.resetTimeFormat(for: date)) }
        let detail: String = if let resumeAt {
            if let resetsAt = limit.resetsAt {
                "resets \(time(resetsAt)) · resuming automatically"
            } else {
                "checking again at \(time(resumeAt))"
            }
        } else if let resetsAt = limit.resetsAt {
            "resets \(time(resetsAt))"
        } else {
            ""
        }
        return HStack(spacing: 8) {
            Image(systemName: "clock.badge.exclamationmark")
                .foregroundStyle(theme.color("warn"))
            Text(detail.isEmpty ? "Usage limit reached" : "Usage limit reached · \(detail)")
                .font(.system(size: 12))
                .textSelection(.enabled)
                .foregroundStyle(theme.color("fg"))
            Spacer()
            if !isMirror {
                Button("Resume now") { Task { await manager.usageLimitResumeNow(for: sessionId) } }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .tint(theme.color("accent"))
                if resumeAt != nil {
                    Button("Cancel auto-resume") { Task { await manager.usageLimitCancelAutoResume(for: sessionId) } }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                }
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(theme.color("warn").opacity(0.10))
        .overlay(alignment: .bottom) {
            Rectangle().fill(theme.color("warn").opacity(0.3)).frame(height: 0.5)
        }
    }

    private func retryBanner(_ retry: ACPRetryStatus) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "arrow.trianglehead.2.clockwise.rotate.90")
                .foregroundStyle(theme.color("warn"))
            Text(retry.detail.map { "Retrying — \($0)" } ?? "Retrying")
                .font(.system(size: 12))
                .textSelection(.enabled)
                .foregroundStyle(theme.color("fg"))
            Spacer()
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(theme.color("warn").opacity(0.10))
        .overlay(alignment: .bottom) {
            Rectangle().fill(theme.color("warn").opacity(0.3)).frame(height: 0.5)
        }
    }
}

enum ACPSetupNudgeDismissal {
    static func storageKey(for key: ACPAdapterUpdateKey) -> String {
        key.storageKey
    }

    static func isDismissed(_ values: [String], key: ACPAdapterUpdateKey) -> Bool {
        if values.contains(storageKey(for: key)) { return true }
        // Existing agent-only values predate target identity and therefore
        // retain their old behavior only for local ACP sessions.
        return key.target == .local && values.contains(key.agentID)
    }
}

/// `submit`'s completion deliberately observes a revision assigned *after*
/// `submit` returns, so the value cannot be a captured `let`. The completion is
/// `@MainActor` and so is the assignment, so main-actor isolation is enough to
/// make the box safe to capture — no lock required.
@MainActor
private final class ACPSuspendedRevisionBox {
    var value: Int = -1
}

/// Hosts the parent's `/btw` card, if any. Observes the manager so the card
/// appears, updates, and goes away with the side question.
private struct ACPSideQuestionSlot: View {
    @ObservedObject var manager: ACPSessionManager
    let parentID: ACPSession.ID
    let typography: ACPChatTypography
    let onInsert: (String) -> Void
    let onKeep: () -> Void

    var body: some View {
        if let entry = manager.sideQuestions[parentID] {
            let side = entry.sessionID.flatMap { manager.liveSession(for: $0) }
            ACPSideQuestionCard(
                entry: entry,
                side: side,
                enforcesReadOnly: manager.liveSession(for: parentID).map {
                    ACPSideQuestionSupportPolicy.enforcesReadOnly(agentId: $0.agentId)
                } ?? true,
                policy: { side.flatMap { manager.permissionPolicy(for: $0.id) } },
                typography: typography,
                onAsk: { text, completion in
                    if let side {
                        let accepted = manager.submit(
                            sessionId: side.id,
                            text: text,
                            attachments: [],
                            intent: .auto,
                            onCompleted: completion
                        )
                        // The card shows the session's last prompt error as a
                        // failure; a new turn supersedes it.
                        if accepted { side.lastError = nil }
                        return accepted
                    }
                    Task { _ = try? await manager.startSideQuestion(parentID: parentID, question: text) }
                    return true
                },
                onDismiss: {
                    Task { await manager.dismissSideQuestion(parentID: parentID) }
                },
                onInsert: onInsert,
                onKeep: onKeep,
                onRetryQueued: { itemID in
                    guard let side else { return }
                    side.lastError = nil
                    Task { await manager.queueRetry(for: side.id, itemId: itemID) }
                },
                onRemoveQueued: { itemID in
                    guard let side else { return }
                    Task { await manager.queueRemove(for: side.id, itemId: itemID) }
                },
                onCancelTurn: {
                    guard let side, let runner = manager.runners[side.id] else { return }
                    Task { await runner.userCancel() }
                },
                inputActions: ACPSideQuestionInputActions(
                    onUserInput: { token, action in
                        guard let side else { return }
                        manager.respondToUserInput(for: side.id, token: token, action: action)
                    },
                    onPlan: { requestId, response in
                        guard let side else { return }
                        manager.respondToPlan(for: side.id, requestId: requestId, response)
                    },
                    onOpenURL: { token in
                        guard let side else { return false }
                        return await manager.openElicitationURL(for: side.id, token: token)
                    },
                    onDismissURLWait: { elicitationId in
                        guard let side else { return }
                        manager.dismissElicitationURLWait(for: side.id, elicitationId: elicitationId)
                    }
                )
            )
            .id(entry.id)
            .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }
}
