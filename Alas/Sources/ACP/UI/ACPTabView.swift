import SwiftUI

struct ACPTabView: View {
    let sessionId: ACPSession.ID
    let state: AppState
    let worktree: Worktree

    var body: some View {
        if let manager = state.acpManager(for: worktree),
           let session = manager.openSession(id: sessionId) {
            ACPSessionView(
                sessionId: sessionId,
                state: state,
                worktree: worktree,
                manager: manager,
                session: session,
                transcript: session.transcript
            )
        } else {
            VStack {
                Spacer()
                Text("ACP session unavailable").foregroundStyle(.secondary)
                Spacer()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
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
    /// Observed so the body re-evaluates when `pendingPermission`
    /// arrives — `scopeKey(for:)` reads through this and the value
    /// is passed down to `ACPMessageList`; otherwise the message
    /// list gets a stale `""` scope and persisted allow/reject_always
    /// decisions land under the wrong key.
    @ObservedObject var transcript: ACPTranscript
    @Environment(\.theme) private var theme

    var body: some View {
        VStack(spacing: 0) {
            ACPToolbar(
                session: session,
                manager: manager,
                agentLookup: { state.agent(id: $0) },
                state: state,
                worktree: worktree
            )
            if case .needsSetup(let reason) = session.setupState,
               !state.config.harness.dismissedACPSetupNudges.contains(session.agentId) {
                if let installer = ACPInstallerRegistry.installer(for: session.agentId) {
                    ACPSetupNudgeBanner(
                        agentID: session.agentId,
                        agentDisplayName: AgentBuiltins.entry(id: session.agentId)?.displayName ?? session.agentId,
                        installer: installer,
                        onDismiss: { dismissNudge() },
                        onInstalled: { await reattach() }
                    )
                } else {
                    setupReasonBanner(reason: reason)
                }
            }
            if let err = session.lastError {
                errorBanner(err)
            }
            transcriptAndComposer
        }
        .task(id: sessionId) {
            let freshlyCreated = manager.runners[sessionId] == nil && session.transcript.messages.isEmpty
            await manager.attach(to: sessionId, freshlyCreated: freshlyCreated)
        }
        .focusable()
        .onKeyPress(.escape) {
            handleEscape()
            return .handled
        }
    }

    /// Esc cancels the in-flight request. Idempotent — safe to press
    /// when nothing's streaming.
    private func handleEscape() {
        guard session.transcript.streamingState == .streaming || session.transcript.streamingState == .sending
              || session.transcript.streamingState == .awaitingPermission
        else { return }
        Task {
            if let runner = manager.runners[sessionId] {
                await runner.userCancel()
            }
        }
    }

    /// True when we're actively spawning + initialising the agent on a
    /// fresh open. Don't show the empty transcript or "agent not yet
    /// attached" warning during this — render a skeleton instead.
    private var isConnecting: Bool {
        guard manager.runners[sessionId] == nil else { return false }
        if case .needsSetup = session.setupState { return false }
        if session.lastError != nil { return false }
        if session.disconnected { return false }
        return session.transcript.messages.isEmpty
    }

    private var transcriptAndComposer: some View {
        ZStack(alignment: .bottom) {
            if isConnecting {
                ACPConnectingPlaceholder(
                    agentDisplayName: state.agent(id: session.agentId)?.displayName ?? session.agentId
                )
            } else {
                ACPMessageList(
                    session: session,
                    transcript: session.transcript,
                    onOpenDiff: { relativePath in
                        state.openDiffTab(forFileInWorktree: worktree, relativePath: relativePath)
                    },
                    // Use the runner's policy (where the agent's continuation
                    // lives) — otherwise the user's click can't resolve the
                    // pending permission request.
                    policy: manager.runners[sessionId]?.policy,
                    scopeKey: scopeKey(for: session.transcript.pendingPermission),
                    onQueueEdit: { item in
                        // Inline editor is a future enhancement (see plan §4.4).
                        // For v1, clicking the pencil removes the item from
                        // the queue so the user can re-type in the composer.
                        session.removeFromQueue(id: item.id)
                        manager.persistQueue(for: session)
                        // Discarding the head can unblock a successor
                        // that was waiting behind a `lastError` head.
                        manager.runners[sessionId]?.flushQueueIfIdle()
                    },
                    onQueueRemove: { id in
                        session.removeFromQueue(id: id)
                        manager.persistQueue(for: session)
                        manager.runners[sessionId]?.flushQueueIfIdle()
                    },
                    onQueueRetry: { id in
                        guard let idx = session.queue.firstIndex(where: { $0.id == id }) else { return }
                        session.queue[idx].lastError = nil
                        manager.persistQueue(for: session)
                        manager.runners[sessionId]?.flushQueueIfIdle()
                    },
                    onQueueReorder: { src, dst in
                        session.moveInQueue(from: src, to: dst)
                        manager.persistQueue(for: session)
                        // Reordering can move a clean prompt to the head
                        // where it can finally drain.
                        manager.runners[sessionId]?.flushQueueIfIdle()
                    },
                    onQueueClearAll: {
                        session.clearPendingQueue()
                        manager.persistQueue(for: session)
                        // No-op if the queue is now empty, but if a
                        // `.sending` head survives the clear and the
                        // user re-enqueues, the next idle drain still
                        // needs to fire from this path.
                        manager.runners[sessionId]?.flushQueueIfIdle()
                    }
                )
            }

            ACPComposer(
                session: session,
                manager: manager,
                worktreeRoot: worktree.path,
                agentLookup: { state.agent(id: $0) },
                sendOnEnter: state.config.harness.acpSendOnEnter
            ) { text, attachments, intent, draft, onPromptFinished -> Bool in
                guard session.attached, !session.disconnected,
                      let runner = manager.runners[sessionId] else { return false }
                // `intent` is already resolved by the composer for keyboard
                // submits; the toolbar send button bypasses the keyboard
                // inversion and supplies its own intent directly. No
                // further resolution here.
                let draftRevision = session.composerDraftRevision
                runner.send(text: text, attachments: attachments, intent: intent) { succeeded in
                    if succeeded {
                        manager.clearComposerDraft(
                            for: session,
                            ifCurrentDraftEquals: draft,
                            revision: draftRevision
                        )
                    } else {
                        manager.persistComposerDraft(
                            draft,
                            for: session,
                            ifCurrentDraftEquals: draft,
                            revision: draftRevision
                        )
                    }
                    onPromptFinished(succeeded)
                }
                return true
            }

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

    private func scopeKey(for pending: ACPSession.PendingPermission?) -> String {
        guard let p = pending else { return "" }
        return "tool:\(p.params.toolCall.title ?? p.params.toolCall.toolCallId)"
    }

    private func reattach() async {
        // Drop any half-attached connection state, clear the prior error,
        // then re-run attach with `freshlyCreated:` matching whether we have
        // any messages yet (mirrors initial-mount logic).
        await manager.detach(sessionId: sessionId)
        session.lastError = nil
        session.setupState = .checking
        let freshlyCreated = session.transcript.messages.isEmpty
        await manager.attach(to: sessionId, freshlyCreated: freshlyCreated)
    }

    private func dismissNudge() {
        var dismissed = state.config.harness.dismissedACPSetupNudges
        if !dismissed.contains(session.agentId) {
            dismissed.append(session.agentId)
            state.config.harness.dismissedACPSetupNudges = dismissed
            _ = state.saveConfig()
        }
    }

    private func setupReasonBanner(reason: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "info.circle").foregroundStyle(theme.color("fg-faint"))
            Text(reason).font(.system(size: 12)).foregroundStyle(theme.color("fg-muted"))
            Spacer()
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(theme.color("bg-1").opacity(0.6))
        .overlay(alignment: .bottom) {
            Rectangle().fill(theme.color("line")).frame(height: 0.5)
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
