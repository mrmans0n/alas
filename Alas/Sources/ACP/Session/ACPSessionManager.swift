import Foundation

@MainActor
final class ACPSessionManager: ObservableObject {
    let worktreeId: String
    let worktreePath: String
    let store: ACPSessionStore
    /// Called by each runner's write handler to check whether the target path
    /// has an open, dirty editor buffer. `nil` disables the check (no notices).
    let onDirtyCheck: ((String) -> Bool)?
    /// Read the in-memory editor contents for the absolute `path` when an
    /// open dirty buffer exists. Returns nil for clean/un-opened files;
    /// the runner falls back to disk in that case. Lets agent reads see
    /// the user's unsaved edits rather than stale disk bytes.
    let onLiveBufferRead: ((String) -> String?)?
    @Published private(set) var sessions: [ACPSession.ID: ACPSession] = [:]
    @Published private(set) var recent: [ACPSessionRow] = []
    private(set) var runners: [ACPSession.ID: ACPSessionRunner] = [:]
    /// Per-session debounced write tasks for `composer_drafts`. The
    /// in-memory `session.composerDraft` updates on every keystroke;
    /// the SQLite write only fires after a brief idle (or a forced
    /// flush on submit / delete). Cancelled and re-scheduled on each
    /// further keystroke so a typing burst produces one write.
    private var pendingDraftWrites: [ACPSession.ID: Task<Void, Never>] = [:]
    private static let draftDebounceNanos: UInt64 = 300_000_000

    init(worktreeId: String, worktreePath: String, store: ACPSessionStore,
         onDirtyCheck: ((String) -> Bool)? = nil,
         onLiveBufferRead: ((String) -> String?)? = nil)
    {
        self.worktreeId = worktreeId
        self.worktreePath = worktreePath
        self.store = store
        self.onDirtyCheck = onDirtyCheck
        self.onLiveBufferRead = onLiveBufferRead
        self.recent = (try? store.recentSessions()) ?? []
    }

    func createSession(agentId: String) -> ACPSession {
        let id = UUID().uuidString
        let now = Int64(Date().timeIntervalSince1970)
        let row = ACPSessionRow(
            id: id, agentId: agentId, title: "New session",
            currentModel: nil, currentMode: nil, autoRun: false,
            createdAt: now, updatedAt: now, lastOpenedAt: now, archived: false)
        try? store.upsertSession(row)
        let session = ACPSession(id: id, agentId: agentId, worktreeId: worktreeId, title: row.title)
        sessions[id] = session
        refreshRecent()
        return session
    }

    func openSession(id: ACPSession.ID) -> ACPSession? {
        if let s = sessions[id] { return s }
        guard let row = try? store.loadSession(id: id) else { return nil }
        let session = ACPSession(id: row.id, agentId: row.agentId, worktreeId: worktreeId, title: row.title)
        // Restore transcript
        if let stored = try? store.loadMessages(sessionId: id) {
            for m in stored {
                if let decoded = try? ACPMessageCodec.decode(kind: m.kind, payload: m.payload) {
                    session.transcript.messages.append(decoded)
                }
            }
        }
        // Restore queue
        if let queue = try? store.loadQueue(sessionId: id) {
            session.restoreQueue(queue)
        }
        session.currentModel = row.currentModel
        session.currentMode = row.currentMode
        session.autoRunEnabled = row.autoRun
        if let loadedDraft = try? store.loadComposerDraft(sessionId: id) {
            session.replaceComposerDraft(loadedDraft)
        }
        sessions[id] = session
        try? store.upsertSession(touch(row))
        refreshRecent()
        return session
    }

    func closeSession(id: ACPSession.ID) {
        // Flush any pending draft write before dropping the in-memory
        // session reference — otherwise a tab-switch-while-typing
        // window can lose the last ~300ms of input.
        flushPendingDraftWrite(for: id)
        sessions[id] = nil
    }

    func deleteSession(id: ACPSession.ID) {
        cancelPendingDraftWrite(for: id)
        sessions[id] = nil
        try? store.deleteSession(id: id)
        refreshRecent()
    }

    func setArchived(id: ACPSession.ID, archived: Bool) {
        try? store.setArchived(id: id, archived: archived)
        refreshRecent()
    }

    /// Persist a fresh trailing chunk of messages (`from..<session.transcript.messages.count`)
    /// to the store. Used by code paths that mutate the session outside the
    /// runner's update loop (composer fallback when no runner is attached
    /// yet, or any direct manager call) so the messages survive a reload.
    func persistTrailingMessages(_ session: ACPSession, fromIndex from: Int) {
        let now = Int64(Date().timeIntervalSince1970)
        let messages = session.transcript.messages
        guard from < messages.count else { return }
        for i in from..<messages.count {
            let m = messages[i]
            guard let payload = try? ACPMessageCodec.encode(m) else { continue }
            let id = "msg-\(session.id)-\(i)"
            try? store.appendMessage(
                sessionId: session.id, id: id, kind: m.kind,
                seq: Int64(i), payload: payload, createdAt: now)
        }
    }

    /// Persist a session-level change (model/mode/title/autoRun) and bump updated_at.
    func persist(_ s: ACPSession) {
        guard let row = try? store.loadSession(id: s.id) else { return }
        let now = Int64(Date().timeIntervalSince1970)
        try? store.upsertSession(.init(
            id: row.id, agentId: row.agentId, title: s.title,
            currentModel: s.currentModel, currentMode: s.currentMode,
            autoRun: s.autoRunEnabled,
            createdAt: row.createdAt, updatedAt: now,
            lastOpenedAt: row.lastOpenedAt, archived: row.archived))
        refreshRecent()
    }

    func persistComposerDraft(_ draft: ACPComposerDraft, for session: ACPSession) {
        // In-memory state updates instantly so cross-tab restore is live.
        // The SQLite write is debounced so a typing burst produces at
        // most one upsert per ~300ms instead of one per keystroke.
        session.replaceComposerDraft(draft)
        scheduleDraftPersistence(for: session.id)
    }

    func clearComposerDraft(for session: ACPSession) {
        session.replaceComposerDraft(.empty)
        cancelPendingDraftWrite(for: session.id)
        try? store.deleteComposerDraft(sessionId: session.id)
    }

    private func scheduleDraftPersistence(for sessionId: ACPSession.ID) {
        pendingDraftWrites[sessionId]?.cancel()
        pendingDraftWrites[sessionId] = Task { [weak self] in
            try? await Task.sleep(nanoseconds: Self.draftDebounceNanos)
            guard !Task.isCancelled else { return }
            await self?.flushPendingDraftWrite(for: sessionId)
        }
    }

    private func flushPendingDraftWrite(for sessionId: ACPSession.ID) {
        pendingDraftWrites[sessionId] = nil
        // Write the LATEST in-memory state, not whatever was captured at
        // schedule time — additional keystrokes may have come in during
        // the debounce window.
        guard let session = sessions[sessionId] else { return }
        let draft = session.composerDraft
        if draft.isEmpty {
            try? store.deleteComposerDraft(sessionId: sessionId)
        } else {
            let now = Int64(Date().timeIntervalSince1970)
            try? store.upsertComposerDraft(sessionId: sessionId, draft: draft, updatedAt: now)
        }
    }

    private func cancelPendingDraftWrite(for sessionId: ACPSession.ID) {
        pendingDraftWrites[sessionId]?.cancel()
        pendingDraftWrites[sessionId] = nil
    }

    /// Flush every pending debounced draft write synchronously. Hook for
    /// app-termination, scene resign, or tests that need a deterministic
    /// post-write read.
    func flushPendingDraftWrites() {
        for sessionId in Array(pendingDraftWrites.keys) {
            flushPendingDraftWrite(for: sessionId)
        }
    }

    /// Flush the debounced draft write for one session. Hook for the
    /// tab-close path (single session goes away while the worktree's
    /// manager stays alive).
    func flushPendingDraftWrite(forSession sessionId: ACPSession.ID) {
        flushPendingDraftWrite(for: sessionId)
    }

    /// Persist the in-memory queue to SQLite. The runner has the same
    /// `persistQueue` method, but UI actions on a session that has no
    /// runner yet (setup nudge, launch failure) must still reach the
    /// store directly — otherwise removing or clearing queue items
    /// only mutates the cached `ACPSession`, and the supposedly-removed
    /// prompts reappear on relaunch.
    func persistQueue(for session: ACPSession) {
        try? store.upsertQueue(sessionId: session.id, items: session.queue)
    }

    func clearComposerDraft(
        for session: ACPSession,
        ifCurrentDraftEquals expected: ACPComposerDraft,
        revision expectedRevision: Int
    ) {
        guard session.composerDraft == expected,
              session.composerDraftRevision == expectedRevision
        else { return }
        clearComposerDraft(for: session)
    }

    func persistComposerDraft(
        _ draft: ACPComposerDraft,
        for session: ACPSession,
        ifCurrentDraftEquals expected: ACPComposerDraft,
        revision expectedRevision: Int
    ) {
        guard session.composerDraft == expected,
              session.composerDraftRevision == expectedRevision
        else { return }
        persistComposerDraft(draft, for: session)
    }

    func refreshRecent() {
        recent = (try? store.recentSessions()) ?? []
    }

    private func touch(_ row: ACPSessionRow) -> ACPSessionRow {
        var r = row
        r.lastOpenedAt = Int64(Date().timeIntervalSince1970)
        return r
    }
}

// MARK: - Process lifecycle

extension ACPSessionManager {
    /// Ensures the session has a live connection. Idempotent — if a runner
    /// already exists for this session, returns immediately. On cold start,
    /// runs the setup check; if ready, spawns the process, initialises ACP,
    /// and calls `session/new` (new sessions) or `session/load` (reopened).
    func attach(to sessionId: ACPSession.ID, freshlyCreated: Bool) async {
        guard let session = sessions[sessionId] else { return }
        if runners[sessionId] != nil { return }

        guard let spec = ACPLaunchCatalog.spec(for: session.agentId) else {
            session.setupState = .needsSetup(reason: "No ACP launch spec for \(session.agentId)")
            return
        }
        let checker = ACPSetupChecker(env: ProcessInfo.processInfo.environment)
        let setup = await checker.evaluate(spec.setupCheck)
        guard case .ready = setup else {
            session.setupState = .needsSetup(reason: setup.reasonText)
            return
        }
        session.setupState = .ready

        let client: ACPStdioClient
        do {
            if spec.command.hasPrefix("/") {
                client = try ACPStdioClient(
                    executable: URL(fileURLWithPath: spec.command),
                    arguments: spec.arguments,
                    environment: Self.mergeEnv(extra: spec.extraEnv))
            } else {
                client = try ACPStdioClient(
                    executable: URL(fileURLWithPath: "/usr/bin/env"),
                    arguments: [spec.command] + spec.arguments,
                    environment: Self.mergeEnv(extra: spec.extraEnv))
            }
            try client.start()
        } catch {
            session.lastError = "Failed to launch agent: \(error.localizedDescription)"
            return
        }
        let connection = ACPConnection(client: client)
        // Collect a short tail of stderr so we can surface it when the
        // agent rejects initialize / new for protocol or auth reasons.
        let stderrBuffer = StderrBuffer()
        let stderrTask = Task { [weak client] in
            guard let stream = (client as? ACPStdioClient)?.incomingStderr else { return }
            for await data in stream {
                stderrBuffer.append(data)
            }
        }
        do {
            try await connection.initialize()
            // Always call `session/new` — even when reopening, because the
            // server doesn't know about our local UUID, and `remoteSessionId`
            // (the id `session/new` previously returned) isn't persisted.
            // Most ACP agents also don't implement `session/load`. The user-
            // visible history comes from the local SQLite store, loaded in
            // `openSession`; the server just gets a fresh conversation.
            let result = try await connection.newSession(cwd: worktreePath)
            session.remoteSessionId = result.sessionId
            session.availableModels = result.availableModels
            session.availableModes = result.availableModes
            session.currentModel = result.currentModel
            session.currentMode = result.currentMode
            session.promptSuggestions = result.promptSuggestions
            session.availableConfigOptions = result.configOptions
            let runner = ACPSessionRunner(session: session, connection: connection,
                                          store: store, sessionId: sessionId,
                                          worktreePath: worktreePath,
                                          onDirtyCheck: onDirtyCheck,
                                          onLiveBufferRead: onLiveBufferRead)
            runner.start()
            runners[sessionId] = runner
            session.attached = true
            runner.flushQueueIfIdle()
            stderrTask.cancel()
        } catch {
            // Give stderr a moment to drain so the message is the real cause.
            try? await Task.sleep(nanoseconds: 200_000_000)
            stderrTask.cancel()
            let tail = stderrBuffer.tail()
            let base = "ACP initialize/new failed: \(error.localizedDescription)"
            session.lastError = tail.isEmpty ? base : base + "\nstderr: " + tail
            await connection.shutdown()
        }
    }

    func detach(sessionId: ACPSession.ID) async {
        // Reset transient session state SYNCHRONOUSLY before any await.
        // The steer task is unstructured and can resume during the
        // `connection.shutdown()` await below — if `session.attached`
        // is still true at that point, its post-`userCancel` liveness
        // check passes and it dispatches `sendNow` against a connection
        // being torn down. Flipping the flag here closes that window.
        if let session = sessions[sessionId] {
            session.attached = false
            session.transcript.streamingState = .idle
            // Normalize any in-flight queue head: the sendNow task that
            // owned it is gone with the runner, so the next attach must
            // see a `.pending` head to be able to flush it. Without this,
            // closing a tab mid-flush leaves the cached session's head
            // as `.sending`; the next openSession returns the cached
            // object (skipping `restoreQueue`), the post-attach flush
            // sees `.sending`, and the queue stays stuck until a full
            // app restart reloads from SQLite.
            session.restoreQueue(session.queue)
        }
        if let runner = runners.removeValue(forKey: sessionId) {
            // Invalidate the in-flight prompt BEFORE shutting down the
            // connection. The unstructured `sendNow` task survives stop()
            // and the connection close will make its RPC throw — we want
            // its catch path to recognise the failure as "deliberately
            // cancelled" so it skips `setQueueHeadError` and the queue
            // head can come back as cleanly `.pending` after restoreQueue.
            runner.invalidateActivePrompt()
            runner.stop()
            await runner.connection.shutdown()
        }
    }

    private static func mergeEnv(extra: [String: String]) -> [String: String] {
        var env = ACPProcessEnvironment.augmented()
        // Strip env vars that mark this process as running INSIDE a coding
        // agent's session. Without this, `claude-code-acp` (and likely any
        // other Anthropic-aware tool we spawn) refuses to start, reporting
        // "Claude Code cannot be launched inside another Claude Code session"
        // — which is exactly what happens when Alas is run from a terminal
        // that's itself inside Claude Code.
        for key in [
            "CLAUDECODE", "CLAUDE_CODE", "CLAUDE_PROJECT_DIR",
            "CLAUDE_CODE_ENTRYPOINT", "CLAUDE_SESSION_ID",
        ] {
            env.removeValue(forKey: key)
        }
        for (k, v) in extra { env[k] = v }
        return env
    }
}

private extension ACPSetupResult {
    var reasonText: String {
        switch self {
        case .ready: return ""
        case .missing(let r): return r
        case .error(let m): return m
        }
    }
}

/// Thread-safe ring of stderr bytes from the agent process. Keeps the last
/// ~2 KB so we can surface useful context when initialize/new fails.
private final class StderrBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var bytes = Data()
    private let cap = 2048
    func append(_ d: Data) {
        lock.lock()
        defer { lock.unlock() }
        bytes.append(d)
        if bytes.count > cap {
            bytes.removeSubrange(0..<(bytes.count - cap))
        }
    }
    func tail() -> String {
        lock.lock()
        defer { lock.unlock() }
        return String(data: bytes, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }
}
