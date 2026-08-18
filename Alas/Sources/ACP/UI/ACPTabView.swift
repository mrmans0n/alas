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
    var onStartupRecoveryReady: () -> Void = {}

    var body: some View {
        if let manager = state.acpManager(for: worktree) {
            ACPManagedTabView(
                sessionId: sessionId,
                state: state,
                worktree: worktree,
                onStartupRecoveryReady: onStartupRecoveryReady,
                manager: manager
            )
        } else {
            unavailable
        }
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
    let onStartupRecoveryReady: () -> Void
    @ObservedObject var manager: ACPSessionManager

    var body: some View {
        if let session = manager.placeholderSession(id: sessionId) {
            ACPSessionView(
                sessionId: sessionId,
                state: state,
                worktree: worktree,
                manager: manager,
                session: session,
                onStartupRecoveryReady: onStartupRecoveryReady,
                transcript: session.transcript
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
    let manager: ACPSessionManager
    @ObservedObject var session: ACPSession
    let onStartupRecoveryReady: () -> Void
    /// Observed so the body re-evaluates when pending user action arrives.
    /// `scopeKey(for:)` reads the permission value through this and passes
    /// it down to `ACPMessageList`; otherwise the message list gets a stale
    /// `""` scope and persisted allow/reject_always decisions land under the
    /// wrong key.
    @ObservedObject var transcript: ACPTranscript
    @State private var updateState: AdapterUpdateState?
    @State private var dismissedLatest: String?
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
                    worktree: worktree
                )
                adapterBanner()
                contextRestoreBanner()
                if isMirror {
                    mirrorBanner()
                }
                if let err = session.lastError {
                    errorBanner(err)
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
        .task(id: sessionId) {
            await hydrateAndAttach()
            onStartupRecoveryReady()
        }
        .onExitCommand {
            handleEscape()
        }
    }

    /// Esc cancels the in-flight request. Idempotent — safe to press
    /// when nothing's streaming.
    private func handleEscape() {
        guard session.transcript.streamingState == .streaming || session.transcript.streamingState == .sending
              || session.transcript.streamingState == .awaitingPermission
              || session.transcript.streamingState == .awaitingInput
              || !session.transcript.pendingUserInputs.isEmpty
        else { return }
        Task {
            if let runner = manager.runners[sessionId] {
                await runner.userCancel()
            }
        }
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
            chatSurface(contentMaxWidth: chatContentMaxWidth)
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

        provider.loadDataRepresentation(
            forTypeIdentifier: UTType.alasDropPayload.identifier
        ) { data, _ in
            guard let data else { return }
            Task { @MainActor in
                _ = composerDropRouter.insert(
                    encoded: data,
                    enabled: !manager.isMirror(sessionId: sessionId)
                )
            }
        }
        return true
    }

    private func chatSurface(contentMaxWidth: CGFloat) -> some View {
        ZStack(alignment: .bottom) {
            if showsPreSessionUserInput {
                messageList(contentMaxWidth: contentMaxWidth)
                    .transition(.opacity)
            } else if let phase = firstRunConnectingPhase {
                introStateAndComposer(contentMaxWidth: contentMaxWidth) {
                    ACPFirstRunConnectingView(
                        agentDisplayName: state.agent(id: session.agentId)?.displayName ?? session.agentId,
                        phase: phase,
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
                        agentDisplayName: state.agent(id: session.agentId)?.displayName ?? session.agentId
                    )
                } else {
                    messageList(contentMaxWidth: contentMaxWidth)
                        .transition(.opacity)
                }

                composerView(
                    placement: composerPlacement,
                    contentMaxWidth: contentMaxWidth,
                    typography: chatTypography
                )

                if let undo = session.steerUndo, !undo.snapshot.isEmpty {
                    VStack {
                        Spacer()
                        ACPSteerUndoToast(
                            discardedCount: undo.snapshot.count,
                            onUndo: { manager.runners[sessionId]?.steerUndo() },
                            onDismiss: { session.steerUndo = nil }
                        )
                        .id(undo.id)
                        .padding(.bottom, 200)
                    }
                    .frame(maxWidth: .infinity)
                    .transition(.opacity)
                }
            }
        }
    }

    private func messageList(contentMaxWidth: CGFloat) -> ACPMessageList {
        ACPMessageList(
            session: session,
            transcript: session.transcript,
            contentMaxWidth: contentMaxWidth,
            typography: chatTypography,
            onOpenDiff: { relativePath in
                state.openDiffTab(forFileInWorktree: worktree, relativePath: relativePath)
            },
            onOpenTranscriptLink: { url in
                state.routeTranscriptOpenURL(url, worktreeId: worktree.id)
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
                // Pull the queued prompt back into the composer for editing,
                // appended after any text the user has already typed so
                // nothing is clobbered. `takeForEditing` removes the item and
                // returns its draft ONLY if it's still `.pending`; a `.sending`
                // item returns nil and is left in flight, so it can't be
                // duplicated.
                guard let restored = session.takeForEditing(id: item.id) else { return }
                manager.persistComposerDraft(
                    session.composerDraft.appending(restored), for: session)
                manager.persistQueue(for: session)
                manager.runners[sessionId]?.flushQueueIfIdle()
            },
            onQueueForceSend: { id in
                guard ACPTranscriptQueuePolicy.allowsQueueMutation(isMirror: isMirror) else { return }
                manager.runners[sessionId]?.forceSendQueuedItem(id: id)
            },
            onQueueRemove: { id in
                guard ACPTranscriptQueuePolicy.allowsQueueMutation(isMirror: isMirror) else { return }
                session.removeFromQueue(id: id)
                manager.persistQueue(for: session)
                manager.runners[sessionId]?.flushQueueIfIdle()
            },
            onQueueRetry: { id in
                guard ACPTranscriptQueuePolicy.allowsQueueMutation(isMirror: isMirror) else { return }
                guard let idx = session.queue.firstIndex(where: { $0.id == id }) else { return }
                session.queue[idx].lastError = nil
                manager.persistQueue(for: session)
                manager.runners[sessionId]?.flushQueueIfIdle()
            },
            onQueueReorder: { src, dst in
                guard ACPTranscriptQueuePolicy.allowsQueueMutation(isMirror: isMirror) else { return }
                session.moveInQueue(from: src, to: dst)
                manager.persistQueue(for: session)
                manager.runners[sessionId]?.flushQueueIfIdle()
            },
            onQueueClearAll: {
                guard ACPTranscriptQueuePolicy.allowsQueueMutation(isMirror: isMirror) else { return }
                session.clearPendingQueue()
                manager.persistQueue(for: session)
                manager.runners[sessionId]?.flushQueueIfIdle()
            },
            onRetryContextRecovery: {
                _ = manager.sendTranscriptAsContext(
                    sessionId: sessionId,
                    agentName: state.agent(id: session.agentId)?.displayName
                )
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
            forkTargets: state.acpForkTargets(sourceAgentID: session.agentId),
            onQuote: { message in
                composerActions.quote(message)
            },
            onFork: { boundary, targetAgentID in
                state.forkACPSession(
                    worktree: worktree,
                    sourceSessionID: sessionId,
                    boundary: boundary,
                    targetAgentID: targetAgentID
                )
            },
            onOpenForkSource: { sourceSessionID in
                Task {
                    await state.openExistingACPSession(sessionId: sourceSessionID)
                }
            },
            agentDisplayName: { agentID in
                state.agent(id: agentID)?.displayName ?? agentID
            }
        )
    }

    private func introStateAndComposer<Intro: View>(
        contentMaxWidth: CGFloat,
        @ViewBuilder intro: () -> Intro
    ) -> some View {
        VStack(spacing: 0) {
            intro()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
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
            agentLookup: { state.agent(id: $0) },
            sendOnEnter: state.config.harness.acpSendOnEnter,
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
            }
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
            var suspendedRevision: Int = -1
            let accepted = manager.submit(
                sessionId: sessionId,
                text: text,
                attachments: attachments,
                intent: intent,
                draft: draft
            ) { succeeded in
                if suspendedRevision >= 0 {
                    if succeeded {
                        manager.purgeSuspendedComposerDraft(
                            for: session,
                            suspendedRevision: suspendedRevision
                        )
                    } else {
                        manager.reinstateSuspendedComposerDraft(
                            draft,
                            for: session,
                            suspendedRevision: suspendedRevision
                        )
                    }
                }
                onPromptFinished(succeeded)
            }
            if accepted {
                suspendedRevision = manager.suspendComposerDraftForSubmission(
                    draft, for: session
                )
            }
            return accepted
        }
        .disabled(isMirror)
        .opacity(isMirror ? 0.5 : 1)
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
            let dismissedSetup = ACPSetupNudgeDismissal.isDismissed(
                state.config.harness.dismissedACPSetupNudges,
                key: adapterUpdateKey
            )
            let decision = ACPAdapterUpdateBannerDecider.decide(
                setupState: session.setupState,
                updateState: updateState,
                dismissedLatest: dismissedLatest)

            switch decision {
            case .showInstall where !dismissedSetup:
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
                _ = try await state.openACPAuthTerminalTabPreparingRemoteZmxIfNeeded(for: worktree, command: command) {
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

    private func installAdapter() async throws {
        try await state.acpAdapterInstallCoordinator.install(
            target: adapterTarget,
            agentID: session.agentId
        )
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
    /// and, on success, attach the runner. Used by both the initial
    /// `.task(id:)` and the failure banner's Retry button so a successful
    /// retry doesn't leave the session unattached with a disabled composer.
    private func hydrateAndAttach() async {
        await manager.hydrateIfNeeded(id: sessionId)
        if case .failed = session.hydrationState { return }
        let freshlyCreated = manager.runners[sessionId] == nil
            && ACPSessionAttachFreshness.isFresh(
                restoredFromPersistence: session.restoredFromPersistence,
                remoteSessionId: session.remoteSessionId
            )
        await manager.attach(to: sessionId, freshlyCreated: freshlyCreated)
        await refreshAdapterUpdateState()
    }

    /// After attach: if the adapter is ready and has an npm package, ask the
    /// store for its cached update state (or compute it on cache miss).
    /// Silent on failure.
    private func refreshAdapterUpdateState() async {
        guard case .ready = session.setupState else { return }
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
                Task { await hydrateAndAttach() }
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

    private func errorBanner(_ err: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(theme.color("del"))
            Text(err)
                .font(.system(size: 12))
                .textSelection(.enabled)
                .foregroundStyle(theme.color("fg"))
            Spacer()
            Button {
                session.lastError = nil
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 10))
                    .foregroundStyle(theme.color("fg-faint"))
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(theme.color("del").opacity(0.10))
        .overlay(alignment: .bottom) {
            Rectangle().fill(theme.color("del").opacity(0.3)).frame(height: 0.5)
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
