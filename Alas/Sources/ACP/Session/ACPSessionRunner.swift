import Foundation

@MainActor
final class ACPSessionRunner {
    let session: ACPSession
    let connection: ACPConnection
    let store: ACPSessionStore
    /// LOCAL session id — our UUID assigned by `ACPSessionManager.createSession`,
    /// used as the persistence key in `ACPSessionStore`. The protocol-side
    /// (remote) session id lives on `session.remoteSessionId` and is what
    /// we pass to every `session/*` JSON-RPC call.
    let sessionId: String
    /// Absolute filesystem path of the worktree this session is anchored
    /// to. Distinct from `session.worktreeId`, which is a stable opaque
    /// identifier used for persistence. Every agent file request is
    /// validated against this path before being honoured.
    let worktreePath: String
    /// Single policy instance shared between the runner (where the agent's
    /// `requestPermission` resumes a continuation) and the UI (where the
    /// user's click resolves it). Storing it here is the single source of
    /// truth that previously caused the "tool calls stuck on pending"
    /// bug — the UI was creating its own copy with no continuation.
    let policy: ACPPermissionPolicy
    /// Optional hook called before each agent file-write to check whether the
    /// target path has a live, dirty editor buffer. When it returns `true` a
    /// `systemNotice` is appended to the session so the user is aware the
    /// write landed on top of unsaved changes. `nil` disables the check.
    private let onDirtyCheck: ((String) -> Bool)?
    /// Optional hook used by the read handler to pull in-memory editor
    /// contents for an open dirty buffer, falling back to disk when the
    /// closure returns `nil`. Lets the agent see what the user sees.
    private let onLiveBufferRead: ((String) -> String?)?
    /// Called when the runner forces transcript tail-follow before recording
    /// a user prompt, so manager-owned scroll memory stays in sync with the
    /// runtime session state.
    private let onResumeTranscriptTail: (() -> Void)?
    /// The sanitized + extras-merged env the agent process itself was
    /// launched with. Used to seed the terminal host so agent-spawned
    /// commands inherit exactly the same view — including the stripped
    /// CLAUDECODE/CLAUDE_SESSION_ID markers that would otherwise leak
    /// back in via a re-augment from `ProcessInfo`.
    private let agentEnv: [String: String]
    private let ownerInstanceId: String?
    private let onAuthRequired: ((ACPSessionRunner, String) async -> Void)?
    private let onPersist: (() -> Void)?
    private var updatesTask: Task<Void, Never>?
    private var permissionsTask: Task<Void, Never>?
    private var questionsTask: Task<Void, Never>?
    private var filesTask: Task<Void, Never>?
    private var terminalsTask: Task<Void, Never>?
    private var pendingQuestionContinuation: CheckedContinuation<ACPQuestionResponse, Never>?
    private var pendingQuestionPreviousStreamingState: ACPSession.StreamingState?
    private var seq: Int64 = 0
    private var steerUndoExpiryTask: Task<Void, Never>?
    /// Monotonic prompt counter + active/cancelled bookkeeping (inherited
    /// from main / PR #338). Reused by the queue's sendNow path:
    /// `activePromptID` identifies the task that currently owns
    /// `streamingState`; `cancelledPromptIDs` carries explicit
    /// invalidations (steer, userCancel) so a slow `session/cancel`
    /// can't let a stale completion clobber the successor task.
    private var nextPromptID = 0
    private var activePromptID: Int?
    private var cancelledPromptIDs: Set<Int> = []
    private var appliedUpdateCount = 0
    private var persistedMessageCount: Int
    private var pendingCompletedOutputBoundaryUpdateCount: Int?
    private var pendingStreamingPersistIndices: Set<Int> = []
    private var pendingStreamingPersistSnapshots: [Int: StreamingPersistSnapshot] = [:]
    private var streamingPersistTask: Task<Void, Never>?
    private let streamingPersistDebounceNanos: UInt64
    private var suppressingLoadReplay: Bool
    private var loadReplaySuppressionTarget: Int?
    private var observedUpdateCount = 0
    /// Set while `steer` is between `userCancel` and the redirect's
    /// `sendNow`. `flushQueueIfIdle` no-ops while this is true so an
    /// Undo tapped during the cancel round-trip can't drain the just-
    /// restored snapshot ahead of the steer's replacement prompt. Once
    /// the redirect is in flight, normal drain semantics resume.
    private var steerInProgress: Bool = false

    private struct StreamingPersistSnapshot {
        let kind: String
        let payload: Data
        let basePayload: Data?
    }

    init(session: ACPSession, connection: ACPConnection, store: ACPSessionStore,
         sessionId: String, worktreePath: String,
         agentEnv: [String: String] = ProcessInfo.processInfo.environment,
         suppressingLoadReplay: Bool = false,
         onDirtyCheck: ((String) -> Bool)? = nil,
         onLiveBufferRead: ((String) -> String?)? = nil,
         onAuthRequired: ((ACPSessionRunner, String) async -> Void)? = nil,
         onPersist: (() -> Void)? = nil,
         onResumeTranscriptTail: (() -> Void)? = nil,
         streamingPersistDebounceNanos: UInt64 = 250_000_000,
         ownerInstanceId: String? = nil)
    {
        self.session = session
        self.connection = connection
        self.store = store
        self.sessionId = sessionId
        self.worktreePath = worktreePath
        self.agentEnv = agentEnv
        self.ownerInstanceId = ownerInstanceId
        self.onAuthRequired = onAuthRequired
        self.onPersist = onPersist
        self.streamingPersistDebounceNanos = streamingPersistDebounceNanos
        self.suppressingLoadReplay = suppressingLoadReplay
        self.onDirtyCheck = onDirtyCheck
        self.onLiveBufferRead = onLiveBufferRead
        self.onResumeTranscriptTail = onResumeTranscriptTail
        self.persistedMessageCount = (try? store.messageCount(sessionId: sessionId)) ?? 0
        self.seq = Int64(persistedMessageCount)
        // Capture the three values holdsLeaseForWrite() reads so the closure
        // can be formed before `self` is fully initialised (policy is the
        // last stored property). The logic is identical to holdsLeaseForWrite.
        let _store = store
        let _sessionId = sessionId
        let _ownerInstanceId = ownerInstanceId
        self.policy = ACPPermissionPolicy(
            session: session,
            log: ACPPermissionDecisionLog(store: store, canWrite: {
                guard let id = _ownerInstanceId else { return true }
                return (try? _store.loadLease(sessionId: _sessionId))?.ownerInstance == id
            })
        )
    }

    func start() {
        updatesTask = Task { [weak self] in
            guard let self else { return }
            for await u in self.connection.client.incomingUpdates {
                await MainActor.run {
                    self.observedUpdateCount += 1
                    self.appliedUpdateCount += 1
                    if self.suppressingLoadReplay {
                        if let target = self.loadReplaySuppressionTarget,
                           self.observedUpdateCount >= target {
                            self.suppressingLoadReplay = false
                            // Disallow streaming boundary crossings until the next prompt
                            // starts. Any agentMessageChunk that would cross a completed-
                            // output boundary in this window is a late replay slip — the
                            // session-level flag prevents it from creating a duplicate
                            // bubble without blocking in-progress continuation updates.
                            self.session.allowsStreamingBoundaryCrossing = false
                        }
                        return
                    }
                    let shouldBatchStreamingPersist = self.shouldBatchStreamingPersist(for: u.update)
                    let dirty = self.session.apply(u.update)
                    if shouldBatchStreamingPersist {
                        self.scheduleStreamingPersist(dirty)
                    } else {
                        self.flushStreamingPersist()
                        self.persistIndices(dirty)
                    }
                    if self.applyPendingCompletedOutputBoundaryIfReady() {
                        self.flushQueueIfIdle()
                    }
                }
            }
            // The for-await also exits when the task gets cancelled —
            // that's the intentional detach path (tab close, worktree
            // teardown). Don't pollute the persisted transcript with
            // an "Agent disconnected" notice in that case; only flag
            // the unexpected stream-end.
            if Task.isCancelled { return }
            await MainActor.run {
                self.session.agentState = .disconnected
                self.session.transcript.streamingState = .idle
                // No flushQueueIfIdle() here: the connection is dead, so
                // the next prompt would just fail. The queue stays put
                // and drains naturally on the next successful reattach.
                self.appendAndPersistSystemNotice("Agent disconnected.")
            }
        }

        permissionsTask = Task { @MainActor [weak self] in
            guard let self else { return }
            for await (id, params) in self.connection.client.permissionRequests {
                let scopeKey = "tool:\(params.toolCall.title ?? params.toolCall.toolCallId)"
                let response = await self.policy.evaluate(scopeKey: scopeKey, options: params.options, params: params)
                self.connection.client.respondToPermission(id: id, response: response)
            }
        }

        questionsTask = Task { @MainActor [weak self] in
            guard let self else { return }
            for await request in self.connection.client.questionRequests {
                let response = await self.awaitQuestionResponse(request)
                if Task.isCancelled { return }
                self.connection.client.respondToQuestion(id: request.id, response: response)
                self.flushQueueIfIdle()
            }
        }

        // Agent-spawned terminals must see the exact env the agent
        // itself was launched with — same augmented PATH (npm / cargo
        // resolve under launchd's minimal PATH) and same scrubbed
        // CLAUDECODE/CLAUDE_SESSION_ID markers (otherwise a Claude-
        // aware CLI run from the terminal refuses to start).
        session.terminalHost.updateContext(sessionCwd: worktreePath,
                                           sessionEnv: agentEnv)

        filesTask = Task { @MainActor [weak self] in
            guard let self else { return }
            let writer = ACPFileWriter(
                worktreeRoot: URL(fileURLWithPath: self.worktreePath)
            )
            for await req in self.connection.client.fileRequests {
                switch req {
                case .read(let id, let params):
                    do {
                        // Same containment check as the write path —
                        // without this an adapter could request any
                        // absolute path (e.g. `~/.ssh/config`) and
                        // exfiltrate it without a permission prompt.
                        let target = try writer.resolveInsideWorktree(path: params.path)
                        // Prefer the live editor buffer when the file
                        // is open and dirty so the agent sees what the
                        // user sees (avoids "agent reads stale disk,
                        // then writes a replacement that clobbers
                        // unsaved edits").
                        let full: String
                        if let live = self.onLiveBufferRead?(target.path) {
                            full = live
                        } else {
                            let data = try Data(contentsOf: target)
                            full = String(data: data, encoding: .utf8) ?? ""
                        }
                        let sliced = Self.sliceLines(full, line: params.line, limit: params.limit)
                        let body = try JSONEncoder().encode(ACPFsReadResult(content: sliced))
                        self.connection.client.respondToFileRequest(id: id, result: .success(body))
                    } catch ACPFileWriter.Error.outsideWorktree(let p) {
                        self.appendAndPersistSystemNotice("Blocked read outside worktree: \(p)")
                        self.connection.client.respondToFileRequest(
                            id: id,
                            result: .failure(.init(code: -32001, message: "path outside worktree", data: nil))
                        )
                    } catch {
                        self.connection.client.respondToFileRequest(
                            id: id,
                            result: .failure(.init(code: -32000, message: error.localizedDescription, data: nil))
                        )
                    }
                case .write(let id, let params):
                    // Guard the actual disk write: if this runner has lost
                    // the session lease (takeover), deny the request rather
                    // than modifying the working tree on behalf of a session
                    // another instance now owns.
                    // Note: terminal execution is also covered — Fix 1's
                    // prompt stand-down tears the runner down within ~100 ms
                    // of a takeover ping, and runner.stop() calls
                    // terminalHost.killAll(), so in-flight terminal commands
                    // are already gated by that path.
                    guard self.holdsLeaseForWrite() else {
                        self.connection.client.respondToFileRequest(
                            id: id,
                            result: .failure(.init(code: -32003, message: "lease lost to another instance", data: nil)))
                        break
                    }
                    if self.onDirtyCheck?(params.path) == true {
                        self.appendAndPersistSystemNotice("Agent wrote to \(URL(fileURLWithPath: params.path).lastPathComponent) — you have unsaved changes in this file.")
                    }
                    do {
                        let res = try writer.write(path: params.path, content: params.content)
                        // Persist the worktree-relative path so the
                        // "Open diff" button can pass it straight to
                        // `git.diff(file:)` (which keys by relative
                        // path). Storing the absolute path silently
                        // produced empty diffs.
                        let storedPath = self.relativeToWorktree(params.path) ?? params.path
                        self.appendAndPersistFileEdit(.init(path: storedPath, added: res.added, removed: res.removed, oldText: res.oldText, newText: res.newText))
                        // ACP `fs/write_text_file` is defined as
                        // returning `result: null`. Encoding an empty
                        // Swift struct produced `{}`, which spec-strict
                        // SDKs reject as a protocol error even though
                        // the write succeeded.
                        let body = Data("null".utf8)
                        self.connection.client.respondToFileRequest(id: id, result: .success(body))
                    } catch ACPFileWriter.Error.outsideWorktree(let p) {
                        self.appendAndPersistSystemNotice("Blocked write outside worktree: \(p)")
                        self.connection.client.respondToFileRequest(
                            id: id,
                            result: .failure(.init(code: -32001, message: "path outside worktree", data: nil)))
                    } catch {
                        self.connection.client.respondToFileRequest(
                            id: id,
                            result: .failure(.init(code: -32000, message: error.localizedDescription, data: nil)))
                    }
                }
            }
        }

        terminalsTask = Task { @MainActor [weak self] in
            guard let self else { return }
            for await req in self.connection.client.terminalRequests {
                self.handleTerminalRequest(req)
            }
        }
    }

    func finishSuppressingLoadReplay(throughYieldedUpdateCount target: Int) {
        guard suppressingLoadReplay else { return }
        loadReplaySuppressionTarget = target
        if observedUpdateCount >= target {
            suppressingLoadReplay = false
            session.allowsStreamingBoundaryCrossing = false
        }
    }

    func stop() {
        flushStreamingPersistOnStop()
        updatesTask?.cancel()
        permissionsTask?.cancel()
        questionsTask?.cancel()
        filesTask?.cancel()
        terminalsTask?.cancel()
        resolvePendingQuestion(.init(outcome: .cancelled), restorePreviousState: false)
        // Kill agent-spawned subprocesses now. ACPSessionManager keeps
        // the ACPSession cached after detach, so the session's deinit-
        // time killAll() won't fire on tab close — without this an
        // active `npm test`/`sleep`/server outlives the agent.
        session.terminalHost.killAll()
        onPersist?()
    }

    private func awaitQuestionResponse(_ request: ACPQuestionRequest) async -> ACPQuestionResponse {
        pendingQuestionPreviousStreamingState = session.transcript.streamingState
        session.transcript.streamingState = .awaitingInput
        session.transcript.pendingQuestion = .init(id: request.id, params: request.params)
        return await withCheckedContinuation { continuation in
            pendingQuestionContinuation = continuation
        }
    }

    func answerQuestion(_ response: ACPQuestionResponse) {
        resolvePendingQuestion(response)
    }

    private func resolvePendingQuestion(
        _ response: ACPQuestionResponse,
        restorePreviousState: Bool = true
    ) {
        guard let continuation = pendingQuestionContinuation else { return }
        pendingQuestionContinuation = nil
        session.transcript.pendingQuestion = nil
        if session.transcript.streamingState == .awaitingInput {
            session.transcript.streamingState = restorePreviousState
                ? pendingQuestionPreviousStreamingState ?? .idle
                : .idle
        }
        pendingQuestionPreviousStreamingState = nil
        continuation.resume(returning: response)
    }

    private func handleTerminalRequest(_ req: ACPTerminalRequest) {
        let host = self.session.terminalHost
        switch req {
        case .create(let id, let p):
            // Gate terminal creation on the lease: a runner that has lost
            // the writer lease must not start new terminal side effects in
            // the brief window before stand-down tears it down. This is
            // defense-in-depth alongside the heartbeat/stand-down path
            // (which calls stop() → terminalHost.killAll() within ~100ms
            // of a takeover ping). Matches the existing file-write gate.
            guard holdsLeaseForWrite() else {
                self.connection.client.respondToTerminalRequest(
                    id: id, result: .failure(.init(code: -32003, message: "lease lost to another instance", data: nil)))
                break
            }
            do {
                let res = try host.create(p)
                self.connection.client.respondToTerminalRequest(
                    id: id, result: .success(try JSONEncoder().encode(res)))
            } catch ACPTerminalHostError.tooManyTerminals {
                self.connection.client.respondToTerminalRequest(
                    id: id, result: .failure(.init(code: -32000, message: "too many terminals", data: nil)))
            } catch ACPTerminalHostError.spawnFailed(let msg) {
                self.connection.client.respondToTerminalRequest(
                    id: id, result: .failure(.init(code: -32000, message: msg, data: nil)))
            } catch {
                self.connection.client.respondToTerminalRequest(
                    id: id, result: .failure(.init(code: -32000, message: error.localizedDescription, data: nil)))
            }
        case .output(let id, let p):
            do {
                let res = try host.output(p)
                self.connection.client.respondToTerminalRequest(
                    id: id, result: .success(try JSONEncoder().encode(res)))
            } catch ACPTerminalHostError.notFound {
                self.connection.client.respondToTerminalRequest(
                    id: id, result: .failure(.init(code: -32602, message: "terminal not found", data: nil)))
            } catch {
                self.connection.client.respondToTerminalRequest(
                    id: id, result: .failure(.init(code: -32000, message: error.localizedDescription, data: nil)))
            }
        case .waitForExit(let id, let p):
            // Capture only the host + client so a long-running waitForExit
            // doesn't pin the runner (and its session) in memory if the
            // session is torn down before the agent's underlying process
            // exits. ACPTerminalHost has no back-reference to ACPSession,
            // so this lets the session deinit (and its killAll()) run
            // while the wait task is still parked on the host.
            let client = self.connection.client
            Task { @MainActor in
                do {
                    let res = try await host.waitForExit(p)
                    client.respondToTerminalRequest(
                        id: id, result: .success(try JSONEncoder().encode(res)))
                } catch ACPTerminalHostError.notFound {
                    client.respondToTerminalRequest(
                        id: id, result: .failure(.init(code: -32602, message: "terminal not found", data: nil)))
                } catch {
                    client.respondToTerminalRequest(
                        id: id, result: .failure(.init(code: -32000, message: error.localizedDescription, data: nil)))
                }
            }
        case .kill(let id, let p):
            // Gate terminal kill on the lease: a former writer that lost
            // the session lease must not mutate terminals for a session
            // another instance now owns. Note: runner.stop() calls
            // terminalHost.killAll() directly (NOT through this handler),
            // so teardown is unaffected by this gate.
            guard holdsLeaseForWrite() else {
                self.connection.client.respondToTerminalRequest(
                    id: id, result: .failure(.init(code: -32003, message: "lease lost to another instance", data: nil)))
                break
            }
            do {
                try host.kill(p)
                self.connection.client.respondToTerminalRequest(
                    id: id, result: .success(Data("null".utf8)))
            } catch ACPTerminalHostError.notFound {
                self.connection.client.respondToTerminalRequest(
                    id: id, result: .failure(.init(code: -32602, message: "terminal not found", data: nil)))
            } catch {
                self.connection.client.respondToTerminalRequest(
                    id: id, result: .failure(.init(code: -32000, message: error.localizedDescription, data: nil)))
            }
        case .release(let id, let p):
            // Gate terminal release on the lease: a former writer that lost
            // the session lease must not mutate terminals for a session
            // another instance now owns. Note: runner.stop() calls
            // terminalHost.killAll() directly (NOT through this handler),
            // so teardown is unaffected by this gate.
            guard holdsLeaseForWrite() else {
                self.connection.client.respondToTerminalRequest(
                    id: id, result: .failure(.init(code: -32003, message: "lease lost to another instance", data: nil)))
                break
            }
            do {
                try host.release(p)
                self.connection.client.respondToTerminalRequest(
                    id: id, result: .success(Data("null".utf8)))
            } catch ACPTerminalHostError.notFound {
                self.connection.client.respondToTerminalRequest(
                    id: id, result: .failure(.init(code: -32602, message: "terminal not found", data: nil)))
            } catch {
                self.connection.client.respondToTerminalRequest(
                    id: id, result: .failure(.init(code: -32000, message: error.localizedDescription, data: nil)))
            }
        }
    }

    /// Cancel ownership of any in-flight prompt RPC. The unstructured
    /// `sendNow` task survives `stop()` (it isn't a child task); calling
    /// this marks its `activePromptID` as cancelled so when the RPC
    /// eventually fails (because `connection.shutdown()` killed it) the
    /// catch path treats it as a deliberate cancel — skipping
    /// `setQueueHeadError`. Without this, detach during a queued flush
    /// would persist a `lastError` on the queue head, and the next
    /// attach's `flushQueueIfIdle` would skip it (guard requires
    /// `lastError == nil`), forcing the user to click Retry.
    func invalidateActivePrompt() {
        if let promptID = activePromptID {
            cancelledPromptIDs.insert(promptID)
            activePromptID = nil
        }
    }

    /// Re-upsert the session's persistence row to capture changes to
    /// title / model / mode / autoRun that the runner mutated directly.
    /// `ACPSessionManager.persist` does the same thing plus a recent-
    /// list refresh; the runner skips that because it has no manager
    /// handle, and the next open via the manager picks up the new row.
    func persistSessionRow(preserveTitle: Bool = true) {
        guard holdsLeaseForWrite() else { return }
        guard let row = try? store.loadSession(id: sessionId) else { return }
        let now = Int64(Date().timeIntervalSince1970)
        try? store.upsertSession(.init(
            id: row.id, agentId: row.agentId, title: session.title,
            titleSource: session.titleSource,
            currentModel: session.currentModel, currentMode: session.currentMode,
            autoRun: session.autoRunEnabled,
            createdAt: row.createdAt, updatedAt: now,
            lastOpenedAt: row.lastOpenedAt, archived: row.archived
        ), preserveTitle: preserveTitle)
    }

    func persistGeneratedTitleIfStoredPlaceholder() {
        guard holdsLeaseForWrite() else { return }
        let now = Int64(Date().timeIntervalSince1970)
        guard (try? store.updateGeneratedTitleIfPlaceholder(
            id: sessionId,
            title: session.title,
            updatedAt: now
        )) == true else {
            guard let row = try? store.loadSession(id: sessionId) else { return }
            if row.titleSource != .placeholder {
                session.title = row.title
                session.titleSource = row.titleSource
            }
            return
        }
    }

    /// Returns `absolutePath` relative to the runner's worktree, or
    /// `nil` if the path escapes it. Used by the file-edit card so the
    /// diff opener can hand the value straight to `git.diff(file:)`.
    func relativeToWorktree(_ absolutePath: String) -> String? {
        let root = URL(fileURLWithPath: worktreePath).standardizedFileURL.path
        let prefix = root.hasSuffix("/") ? root : root + "/"
        let target = URL(fileURLWithPath: absolutePath).standardizedFileURL.path
        guard target.hasPrefix(prefix) else { return nil }
        return String(target.dropFirst(prefix.count))
    }

    /// ACP `fs/read_text_file` accepts optional `line` (1-indexed
    /// start) and `limit` (max lines) parameters. Honouring them lets
    /// agents fetch bounded slices of large files instead of always
    /// receiving the whole content (and avoids dumping huge files into
    /// the agent's context window).
    static func sliceLines(_ full: String, line: Int?, limit: Int?) -> String {
        if line == nil, limit == nil { return full }
        let lines = full.split(separator: "\n", omittingEmptySubsequences: false)
        let startLine = max(1, line ?? 1)
        let startIdx = min(startLine - 1, lines.count)
        let endIdx: Int
        if let limit, limit > 0 {
            endIdx = min(startIdx + limit, lines.count)
        } else {
            endIdx = lines.count
        }
        return lines[startIdx ..< endIdx].joined(separator: "\n")
    }

    /// Called from every "user interrupted" code path (Esc, composer Stop
    /// button, toolbar Stop). Sends `session/cancel` over the wire, stops
    /// any pending permission continuation, marks in-flight tool calls as
    /// canceled, posts a system notice, and flips `streamingState` back
    /// to `.idle`. Persists all mutations so they survive a reload.
    func userCancel() async {
        // Capture the prompt + queue head the user INTENDED to stop
        // BEFORE awaiting `connection.cancel`. Without this snapshot, a
        // natural completion of the in-flight prompt during the cancel
        // round-trip would let the success path drain a queue item, and
        // `activePromptID` after the await would point at the freshly-
        // flushed queued send — so Stop would cancel + pop a prompt the
        // user only queued, not the one they pressed Stop on.
        // Snapshot the intended target AND insert it into
        // `cancelledPromptIDs` BEFORE awaiting `connection.cancel`. The
        // cancel notification can make the in-flight `session/prompt`
        // RPC throw before we resume; if `cancelledPromptIDs` isn't
        // populated by then, the prompt task's catch path reads
        // `wasCancelled == false`, calls `setQueueHeadError`, and
        // flips the queue head back to `.pending` with a lastError.
        // The post-await block below then can't pop it (status no
        // longer `.sending`), leaving the cancelled prompt stuck at
        // the front of the queue. Pre-registering the cancellation
        // makes the catch path skip the error path entirely.
        let intended: (promptID: Int?, queueHeadID: UUID?) = await MainActor.run {
            let snapshot: (promptID: Int?, queueHeadID: UUID?) = (
                activePromptID,
                session.queue.first.flatMap { $0.status == .sending ? $0.id : nil }
            )
            if let promptID = snapshot.promptID {
                cancelledPromptIDs.insert(promptID)
            }
            return snapshot
        }
        // A former writer that lost the lease must not send a cancel RPC to
        // the agent for a session another instance now owns. The local
        // bookkeeping above (cancelledPromptIDs insert) is fine to keep —
        // it only affects this runner's own sendNow catch path and has no
        // cross-instance side effects.
        guard holdsLeaseForWrite() else { return }
        let remoteId = session.remoteSessionId ?? sessionId
        try? await connection.cancel(sessionId: remoteId)
        await MainActor.run {
            flushStreamingPersist()
            if let promptID = intended.promptID {
                // Only clear activePromptID if it's still ours — a
                // natural completion + queued promotion during the
                // cancel await would have moved it on.
                if activePromptID == promptID {
                    activePromptID = nil
                }
            }
            policy.userCancelled()
            resolvePendingQuestion(.init(outcome: .cancelled))
            let changedIndices = session.cancelInFlightToolCalls()
            session.terminalHost.killAll()
            if holdsLeaseForWrite() {
                for i in changedIndices {
                    let m = session.transcript.messages[i]
                    if let payload = try? ACPMessageCodec.encode(m) {
                        let id = "msg-\(sessionId)-\(i)"
                        try? store.updateMessagePayload(id: id, payload: payload)
                    }
                }
            }
            // Pop the head ONLY if it's the same `.sending` item we
            // were aiming at. If a queued item promoted itself during
            // the await it's a fresh prompt the user hasn't stopped —
            // leave it alone.
            if let stoppedID = intended.queueHeadID,
               let current = session.queue.first,
               current.id == stoppedID,
               current.status == .sending {
                session.queue.removeFirst()
                persistQueue()
            }
            appendAndPersistSystemNotice("Interrupted by user.")
            // Only force state to .idle if a successor prompt hasn't
            // already taken ownership. A natural completion of the
            // intended prompt during the cancel await can let
            // flushQueueIfIdle promote a queued head to .sending and
            // dispatch its sendNow; that successor now owns
            // streamingState. Forcing .idle here would make the UI
            // think the agent is free, hide the Stop pill, and let the
            // composer accept another direct send mid-flight.
            let successorOwnsState = activePromptID != nil
                && activePromptID != intended.promptID
            if !successorOwnsState {
                session.transcript.streamingState = .idle
            }
            flushQueueIfIdle()
        }
    }
}

extension ACPSessionRunner {
    /// Legacy callsite shim: defaults to `.auto` intent (immediate send
    /// when idle, queue when busy).
    func send(text: String, attachments: [ACPMessage.Attachment]) {
        send(text: text, attachments: attachments, intent: .auto, onPromptFinished: nil)
    }

    /// Backwards-compatible shim for callers that supply a completion but
    /// don't care about intent (e.g. existing tests, pre-queue callers).
    func send(
        text: String,
        attachments: [ACPMessage.Attachment],
        onPromptFinished: (@MainActor (_ succeeded: Bool) -> Void)?
    ) {
        send(text: text, attachments: attachments, intent: .auto, onPromptFinished: onPromptFinished)
    }

    func send(
        text: String,
        attachments: [ACPMessage.Attachment],
        intent: ACPSubmitIntent,
        draft: ACPComposerDraft? = nil,
        onPromptFinished: (@MainActor (_ succeeded: Bool) -> Void)? = nil
    ) {
        let blocks = Self.blocks(text: text, attachments: attachments)
        send(blocks: blocks, intent: intent, draft: draft, onPromptFinished: onPromptFinished)
    }

    /// Build the canonical `[ACPContentBlock]` array from a composer-shaped
    /// `(text, attachments)` pair: a leading text block followed by one block
    /// per attachment — a DEFERRED `.image` (data: nil, carrying the staged
    /// file uri) for image attachments, a `.resourceLink` for everything else.
    /// Image blocks stay deferred here so SQLite never holds base64; `hydrate`
    /// resolves them at send time. Shared with
    /// `ACPSessionManager.enqueueWhileRecovering` so prompts persisted before
    /// the runner exists look identical on the wire to ones the runner enqueues.
    static func blocks(
        text: String,
        attachments: [ACPMessage.Attachment]
    ) -> [ACPContentBlock] {
        // Omit the leading text block for an image-only prompt so we don't send
        // an empty/whitespace `.text` ahead of the image(s). The composer leaves
        // a trailing space after an image chip, so the image-only text is " ",
        // not "" — trim before deciding.
        var blocks: [ACPContentBlock] = text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? []
            : [.text(text)]
        for a in attachments {
            if let mime = a.mimeType, mime.hasPrefix("image/") {
                // Deferred: the staged file is referenced by uri; the inline
                // base64 (or resource-link fallback) is resolved at send time
                // by `hydrate`, so SQLite never stores the base64 payload.
                blocks.append(.image(data: nil, uri: a.uri, mimeType: mime))
            } else {
                blocks.append(.resourceLink(uri: a.uri, name: a.name))
            }
        }
        return blocks
    }

    /// Maximum dimension for an inline base64 image, in pixels.
    nonisolated static let inlineImageMaxDimension: CGFloat = 1568

    /// Resolve deferred attachment blocks just before sending. When the agent
    /// supports inline images, read the staged image file, downscale, and
    /// base64-encode it; otherwise degrade to a `file://` resource link the
    /// agent reads from disk. When the agent supports embedded context,
    /// readable text resource links inside the worktree become ACP `resource`
    /// blocks. Persisted queue state stays lightweight either way.
    ///
    /// `nonisolated async` so the synchronous file reads + downscale/base64
    /// encoding (up to 10 × 20 MB) run off the main actor; awaiting it from the
    /// main-actor send path hops to the cooperative pool instead of freezing
    /// the composer/transcript while a prompt is prepared.
    nonisolated static func hydrate(
        _ blocks: [ACPContentBlock],
        promptCapabilities: ACPInitializeResult.ACPPromptCapabilities,
        worktreePath: String
    ) async -> [ACPContentBlock] {
        blocks.map { block in
            if case .image(let data, let uri, _) = block, data == nil, let uri {
                let name = (URL(string: uri)?.lastPathComponent) ?? "image"
                if promptCapabilities.image,
                   let fileURL = URL(string: uri),
                   let encoded = ACPImageEncoding.inlineBase64(fileURL: fileURL, maxDimension: inlineImageMaxDimension) {
                    return .image(data: encoded.data, uri: nil, mimeType: encoded.mimeType)
                }
                return .resourceLink(uri: uri, name: name)
            }
            if case .resourceLink(let uri, let name) = block,
               promptCapabilities.embeddedContext,
               let embedded = Self.embeddedTextResource(uri: uri, name: name, worktreePath: worktreePath) {
                return embedded
            }
            return block
        }
    }

    nonisolated private static func embeddedTextResource(
        uri: String,
        name: String?,
        worktreePath: String
    ) -> ACPContentBlock? {
        guard let fileURL = URL(string: uri), fileURL.isFileURL else {
            return nil
        }
        let rootURL = URL(fileURLWithPath: worktreePath).resolvingSymlinksInPath()
        let resolvedURL = fileURL.resolvingSymlinksInPath()
        guard Self.isWithinWorktree(resolvedURL, rootURL: rootURL) else {
            return nil
        }
        guard let values = try? resolvedURL.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
              values.isRegularFile == true else {
            return nil
        }
        if let byteCount = values.fileSize, byteCount > 1_000_000 {
            return nil
        }
        guard let text = try? String(contentsOf: resolvedURL, encoding: .utf8) else {
            return nil
        }
        return .resource(uri: uri, mimeType: Self.textMimeType(for: resolvedURL, fallbackName: name), text: text)
    }

    nonisolated private static func isWithinWorktree(_ url: URL, rootURL: URL) -> Bool {
        let rootPath = rootURL.path
        let path = url.path
        return path == rootPath || path.hasPrefix(rootPath + "/")
    }

    nonisolated private static func textMimeType(for url: URL, fallbackName: String?) -> String {
        let ext = (url.pathExtension.isEmpty ? URL(fileURLWithPath: fallbackName ?? "").pathExtension : url.pathExtension)
            .lowercased()
        switch ext {
        case "md", "markdown": return "text/markdown"
        case "json": return "application/json"
        case "html", "htm": return "text/html"
        case "css": return "text/css"
        case "js", "mjs", "cjs": return "text/javascript"
        case "xml": return "application/xml"
        case "yaml", "yml": return "application/yaml"
        default: return "text/plain"
        }
    }

    /// Backwards-compatible helper for existing image-only tests.
    nonisolated static func hydrate(_ blocks: [ACPContentBlock], imageInputSupported: Bool) async -> [ACPContentBlock] {
        await hydrate(blocks, promptCapabilities: .init(image: imageInputSupported), worktreePath: "/")
    }

    /// Primary entry. Resolves the routing then dispatches to one of:
    ///   - sendNow  → records the user prompt, awaits prompt RPC
    ///   - enqueue  → appends to queue + persists
    ///   - steer    → cancels in-flight + clears queue + sends (Task 8)
    ///   - noOp     → empty composer, ignore
    /// `draft` is the structured composer state for lossless edit-restore;
    /// it's consumed only on the `enqueue` route and ignored on the others
    /// (sendNow/steer have no queued item to annotate).
    func send(
        blocks: [ACPContentBlock],
        intent: ACPSubmitIntent,
        draft: ACPComposerDraft? = nil,
        onPromptFinished: (@MainActor (_ succeeded: Bool) -> Void)? = nil
    ) {
        let route = ACPSubmitRoute.resolve(
            intent: intent,
            state: session.transcript.streamingState,
            queueEmpty: session.queue.isEmpty,
            blocksEmpty: blocks.isEmpty,
            inFlightSteer: steerInProgress)
        switch route {
        case .noOp:
            // Composer guards empty submits before invoking onSubmit, but
            // tell the caller the submit was rejected so its draft state
            // stays consistent.
            Task { @MainActor in onPromptFinished?(false) }
        case .sendNow:
            sendNow(blocks: blocks, queuedItemId: nil, onPromptFinished: onPromptFinished)
        case .enqueue:
            session.enqueue(blocks: blocks, draft: draft)
            persistQueue()
            // The user's prompt was accepted into the queue — from the
            // composer's perspective this is a successful submission so
            // the persisted draft can be cleared. The actual RPC fires
            // later when the flusher drains the head.
            Task { @MainActor in onPromptFinished?(true) }
        case .steer:
            steer(blocks: blocks, onPromptFinished: onPromptFinished)
        }
    }

    /// Persist the current queue snapshot. Called after every mutation:
    /// enqueue, edit, remove, reorder, head-status flip. Failures are
    /// swallowed — the same pattern as transcript persistence; surfacing
    /// would block the UI for a transient SQLite error and we'd rather
    /// lose a queue snapshot than the user's draft.
    func persistQueue() {
        guard holdsLeaseForWrite() else { return }
        try? store.upsertQueue(sessionId: sessionId, items: session.queue)
    }

    /// Drain the queue head if the runner is still live, setup is not
    /// blocked on auth, no prompt owns the transport, transcript state is
    /// `.idle`, the head is `.pending`, and the head has no `lastError`.
    /// Marks the head `.sending`, persists, and dispatches `sendNow` with the
    /// head's id so success can pop the right item and failure can flag the
    /// right item without disturbing the rest of the queue.
    ///
    /// Chained drain is implicit: sendNow's completion sets state to
    /// `.idle` and calls back here.
    func flushQueueIfIdle() {
        guard holdsLeaseForWrite() else { return }
        guard !steerInProgress,
              session.agentState == .ready,
              activePromptID == nil,
              session.transcript.streamingState == .idle,
              let head = session.queue.first,
              head.status == .pending,
              head.lastError == nil
        else { return }
        if case .needsAuth = session.setupState { return }
        session.markQueueHeadSending()
        persistQueue()
        sendNow(blocks: head.blocks, queuedItemId: head.id)
    }

    /// User clicked the row-local "send now" affordance for a queued item.
    /// While idle this just promotes the item to the drainable head. While a
    /// turn is active, it behaves like steering: cancel the current turn,
    /// discard the remaining queue, and send the selected queued prompt.
    func forceSendQueuedItem(id: UUID) {
        guard holdsLeaseForWrite() else { return }
        guard let idx = session.queue.firstIndex(where: { $0.id == id }),
              session.queue[idx].status == .pending
        else { return }

        if session.transcript.streamingState == .idle,
           activePromptID == nil,
           !steerInProgress {
            guard session.forceQueueItem(id: id) else { return }
            persistQueue()
            flushQueueIfIdle()
            return
        }

        guard session.agentState == .ready else {
            guard session.forceQueueItem(id: id) else { return }
            persistQueue()
            flushQueueIfIdle()
            return
        }

        let item = session.queue.remove(at: idx)
        persistQueue()
        steer(blocks: item.blocks, recordUserPrompt: !item.transcriptRecorded)
    }

    /// Cancel the in-flight turn (if any), discard the ENTIRE queue
    /// (including any `.sending` head whose `sendNow` task is mid-RPC),
    /// then send the new prompt as a fresh turn. Only the `.pending`
    /// items are snapshotted for undo — restoring a previously-`.sending`
    /// item would just re-fire the prompt the user just redirected away
    /// from. The stale in-flight task gets neutralised because `sendNow`
    /// guards every completion-side mutation on `queue.first?.id ==
    /// queuedItemId`; once we've emptied the queue, the orphan task
    /// resolves to a no-op.
    func steer(
        blocks: [ACPContentBlock],
        recordUserPrompt: Bool = true,
        onPromptFinished: (@MainActor (_ succeeded: Bool) -> Void)? = nil
    ) {
        let snapshot = session.queue.filter { $0.status == .pending }
        session.queue.removeAll()
        if !snapshot.isEmpty {
            session.steerUndo = .init(id: UUID(), snapshot: snapshot)
            armSteerUndoExpiry()
        }
        persistQueue()
        // Invalidate the in-flight prompt NOW (before awaiting userCancel)
        // so its completion can't race the redirect during the cancel
        // round-trip. Without this, a slow `session/cancel` leaves the
        // old `activePromptID` valid; the cancelled RPC's completion
        // would then flip state to .idle, opening a window where the
        // composer could accept another submit before the redirect's
        // `sendNow` installs a new one.
        if let promptID = activePromptID {
            cancelledPromptIDs.insert(promptID)
            activePromptID = nil
        }
        // Suppress queue flushing until the redirect is installed: while
        // userCancel awaits the cancel notification, an Undo tap would
        // re-prepend the snapshot to the queue and userCancel's own
        // trailing flushQueueIfIdle would then dispatch the "discarded"
        // item ahead of the steer's replacement prompt.
        steerInProgress = true

        Task { [weak self] in
            guard let self else { return }
            await self.userCancel()
            await MainActor.run {
                self.steerInProgress = false
                // If the session was detached while we were awaiting
                // `userCancel` (tab closed, worktree torn down), the
                // runner has been removed from `ACPSessionManager` and
                // the connection shut down. Firing `sendNow` now would
                // append the redirect to a detached session and persist
                // a `lastError` against the dead connection. Bail out
                // and tell the composer the submit didn't land so its
                // draft stays put.
                guard self.session.agentState == .ready else {
                    onPromptFinished?(false)
                    return
                }
                self.sendNow(
                    blocks: blocks,
                    queuedItemId: nil,
                    recordUserPrompt: recordUserPrompt,
                    onPromptFinished: onPromptFinished
                )
            }
        }
    }

    /// Re-prepend the most-recent steer-undo snapshot to the queue and
    /// clear the buffer. Called when the user taps "Undo" on the toast.
    func steerUndo() {
        guard let undo = session.steerUndo, !undo.snapshot.isEmpty else { return }
        session.restorePendingSnapshot(undo.snapshot)
        session.steerUndo = nil
        steerUndoExpiryTask?.cancel()
        steerUndoExpiryTask = nil
        persistQueue()
        flushQueueIfIdle()
    }

    /// Exposed for tests + the toast view so it can show / hide.
    func steerUndoSnapshot() -> [QueuedPrompt]? { session.steerUndo?.snapshot }

    private func armSteerUndoExpiry() {
        steerUndoExpiryTask?.cancel()
        steerUndoExpiryTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            await MainActor.run {
                self?.session.steerUndo = nil
                self?.steerUndoExpiryTask = nil
            }
        }
    }

    /// Direct prompt RPC path. `queuedItemId` is set when called by the
    /// flusher; nil when called from the user-typed-and-submitted path.
    /// `onPromptFinished` fires when the active turn ends (success or
    /// cancel/failure) and lets the composer reconcile its persisted
    /// draft. Stale completions (steer cancelled us; another sendNow
    /// took ownership) skip the callback so the composer stays in sync
    /// with the SUCCESSOR turn only.
    func sendNow(
        blocks: [ACPContentBlock],
        queuedItemId: UUID?,
        recordUserPrompt: Bool = true,
        onPromptFinished: (@MainActor (_ succeeded: Bool) -> Void)? = nil
    ) {
        let promptID = nextPromptID
        nextPromptID += 1
        // Register ownership SYNCHRONOUSLY, before the Task spawn. Without
        // this, `detach.invalidateActivePrompt()` (or another concurrent
        // cancel) could land between the increment above and the Task's
        // first `MainActor.run`, see no active prompt to invalidate, and
        // the Task would then run normally, fail on `connection.shutdown`,
        // and persist `lastError` on the queue head — defeating the
        // detach-clears-cleanly fix from the previous commit.
        activePromptID = promptID
        Task { [weak self, onPromptFinished] in
            guard let self else {
                await MainActor.run { onPromptFinished?(false) }
                return
            }
            let proceeded = await MainActor.run { () -> Bool in
                // If we were cancelled while this Task was being scheduled,
                // exit without touching transcript or state. The connection
                // may already be torn down by detach, and recording the
                // user prompt now would leak transcript writes into a
                // detached session.
                if self.activePromptID != promptID {
                    self.cancelledPromptIDs.remove(promptID)
                    return false
                }
                // Re-allow streaming boundary crossings now that we are inside
                // the Task and have confirmed this prompt is still active. The
                // RPC is sent below, so any agent chunk that follows is genuine
                // new output — N+1 bubble creation is correct from here on.
                self.session.allowsStreamingBoundaryCrossing = true
                // Record the user prompt BEFORE awaiting `session/prompt`.
                // The agent streams `session/update` notifications through
                // `incomingUpdates` while the RPC is in flight, so if we
                // recorded after the await an agent_message_chunk could
                // land first and the transcript would render answer-
                // before-question. Skip for a queued retry whose prompt
                // is already in the transcript from the previous attempt.
                let shouldRecord: Bool = {
                    guard recordUserPrompt else { return false }
                    if let qid = queuedItemId,
                       let idx = self.session.queue.firstIndex(where: { $0.id == qid }),
                       self.session.queue[idx].transcriptRecorded {
                        return false
                    }
                    return true
                }()
                if shouldRecord {
                    let before = self.session.transcript.messages.count
                    let titleBefore = self.session.title
                    if !self.session.followsTranscriptTail {
                        self.session.followsTranscriptTail = true
                        self.onResumeTranscriptTail?()
                    }
                    self.session.recordUserPrompt(text: Self.textPreview(of: blocks),
                                                  attachments: Self.attachments(of: blocks))
                    self.persistFromIndex(before)
                    if self.session.title != titleBefore {
                        self.persistGeneratedTitleIfStoredPlaceholder()
                    }
                    if let qid = queuedItemId,
                       let idx = self.session.queue.firstIndex(where: { $0.id == qid }) {
                        self.session.queue[idx].transcriptRecorded = true
                        self.persistQueue()
                    }
                }
                self.session.transcript.streamingState = .sending
                return true
            }
            guard proceeded else {
                await MainActor.run { onPromptFinished?(false) }
                return
            }
            do {
                let remoteId = self.session.remoteSessionId ?? self.sessionId
                // Read the capability flags on the main actor (cheap), then
                // hydrate off-main so file reads + encoding don't block UI.
                let promptCapabilities = self.session.promptCapabilities
                let wireBlocks = await Self.hydrate(
                    blocks,
                    promptCapabilities: promptCapabilities,
                    worktreePath: self.worktreePath
                )
                try await self.connection.prompt(sessionId: remoteId, blocks: wireBlocks)
                await MainActor.run {
                    let isActivePrompt = self.activePromptID == promptID
                    let hasNewerActivePrompt = self.activePromptID != nil && !isActivePrompt
                    if isActivePrompt {
                        if queuedItemId != nil {
                            _ = self.session.popQueueHead()
                            self.persistQueue()
                        }
                        self.activePromptID = nil
                        if self.deferCompletedOutputBoundaryUntilUpdatesDrain() {
                            self.flushQueueIfIdle()
                        }
                    }
                    self.cancelledPromptIDs.remove(promptID)
                    if !hasNewerActivePrompt {
                        onPromptFinished?(true)
                    }
                }
            } catch {
                await MainActor.run {
                    let wasCancelled = self.cancelledPromptIDs.remove(promptID) != nil
                    let isActivePrompt = self.activePromptID == promptID
                    let hasNewerActivePrompt = self.activePromptID != nil && !isActivePrompt
                    if isActivePrompt {
                        self.flushStreamingPersist()
                        let authReason = wasCancelled ? nil : ACPAuthFailure.message(from: error)
                        let errorMessage = authReason ?? error.localizedDescription
                        if queuedItemId != nil, !wasCancelled, authReason == nil {
                            // Queued send failed naturally — leave the item
                            // at the head with lastError so the bubble shows
                            // Retry. Cancelled queued sends had the item
                            // discarded elsewhere (steer) and don't surface.
                            self.session.setQueueHeadError(errorMessage)
                            self.persistQueue()
                        } else if queuedItemId != nil, authReason != nil {
                            self.session.restoreQueue(self.session.queue)
                            self.persistQueue()
                        } else if queuedItemId == nil, !wasCancelled {
                            self.session.lastError = "prompt failed: \(errorMessage)"
                        }
                        if let authReason {
                            self.session.setupState = .needsAuth(
                                methods: self.session.authMethods,
                                reason: authReason
                            )
                            self.session.agentState = .failed(authReason)
                            Task { @MainActor in
                                await self.onAuthRequired?(self, authReason)
                            }
                        }
                        self.activePromptID = nil
                        if self.deferCompletedOutputBoundaryUntilUpdatesDrain() {
                            self.flushQueueIfIdle()
                        }
                    }
                    if !hasNewerActivePrompt {
                        onPromptFinished?(wasCancelled)
                    }
                }
            }
        }
    }

    func sendRecoveryContext(
        _ prompt: String,
        onCompleted: (@MainActor (_ delivered: Bool) -> Void)? = nil
    ) {
        let promptID = nextPromptID
        nextPromptID += 1
        activePromptID = promptID
        Task { [weak self, onCompleted] in
            guard let self else {
                await MainActor.run { onCompleted?(false) }
                return
            }
            let proceeded = await MainActor.run { () -> Bool in
                if self.activePromptID != promptID {
                    self.cancelledPromptIDs.remove(promptID)
                    return false
                }
                self.session.allowsStreamingBoundaryCrossing = true
                self.session.transcript.streamingState = .sending
                return true
            }
            guard proceeded else {
                await MainActor.run { onCompleted?(false) }
                return
            }
            do {
                let remoteId = self.session.remoteSessionId ?? self.sessionId
                try await self.connection.prompt(sessionId: remoteId, blocks: [.text(prompt)])
                await MainActor.run {
                    let wasCancelled = self.cancelledPromptIDs.remove(promptID) != nil
                    let isActivePrompt = self.activePromptID == promptID
                    if isActivePrompt {
                        self.activePromptID = nil
                        if self.deferCompletedOutputBoundaryUntilUpdatesDrain() {
                            self.flushQueueIfIdle()
                        }
                    }
                    // Always resolve the recovery status, even when a newer
                    // prompt (e.g. the user steered) has taken over the
                    // transport. Unlike `sendNow`, whose completion legitimately
                    // hands UI state to its successor turn, this callback is the
                    // ONLY thing that clears the "Restoring…" spinner — skipping
                    // it on supersession strands the spinner forever.
                    onCompleted?(isActivePrompt && !wasCancelled)
                }
            } catch {
                await MainActor.run {
                    _ = self.cancelledPromptIDs.remove(promptID)
                    let isActivePrompt = self.activePromptID == promptID
                    if isActivePrompt {
                        self.flushStreamingPersist()
                        self.activePromptID = nil
                        self.session.transcript.streamingState = .idle
                    }
                    // See the success path above: the recovery status must
                    // resolve regardless of supersession or the spinner strands.
                    onCompleted?(false)
                }
            }
        }
    }

    /// First text block as the user-facing preview. Used when recording
    /// the queued item's bubble in the transcript on flush. Concatenating
    /// every text block matches the wire shape we already send.
    static func textPreview(of blocks: [ACPContentBlock]) -> String {
        blocks.compactMap { b -> String? in
            if case .text(let s) = b { return s }
            return nil
        }.joined()
    }

    /// Attachments derived from the prompt blocks for the user-bubble UI:
    /// resource links plus deferred image blocks (which still carry the staged
    /// file uri). Mirrors the shape `recordUserPrompt` expects (which
    /// previously came from the composer-level attachments array). Inline-
    /// hydrated images (uri == nil) are intentionally skipped — they have no
    /// file to point the thumbnail at and only appear post-`hydrate`.
    static func attachments(of blocks: [ACPContentBlock]) -> [ACPMessage.Attachment] {
        blocks.compactMap { b -> ACPMessage.Attachment? in
            if case .resourceLink(let uri, let name) = b {
                return ACPMessage.Attachment(uri: uri, name: name)
            }
            if case .resource(let uri, _, _) = b {
                return ACPMessage.Attachment(uri: uri, name: URL(string: uri)?.lastPathComponent)
            }
            if case .image(_, let uri, let mime) = b, let uri {
                let name = URL(string: uri)?.lastPathComponent
                return ACPMessage.Attachment(uri: uri, name: name, mimeType: mime ?? "image/png")
            }
            return nil
        }
    }

    private func deferCompletedOutputBoundaryUntilUpdatesDrain() -> Bool {
        let target = connection.client.yieldedUpdateCount
        pendingCompletedOutputBoundaryUpdateCount = max(
            pendingCompletedOutputBoundaryUpdateCount ?? target,
            target
        )
        return applyPendingCompletedOutputBoundaryIfReady()
    }

    private func applyPendingCompletedOutputBoundaryIfReady() -> Bool {
        guard let target = pendingCompletedOutputBoundaryUpdateCount,
              appliedUpdateCount >= target
        else { return false }
        pendingCompletedOutputBoundaryUpdateCount = nil
        flushStreamingPersist()
        session.markCompletedOutputBoundary()
        guard activePromptID == nil else { return false }
        session.transcript.streamingState = .idle
        return true
    }

    /// Append a system notice to the session AND persist it. Use this
    /// instead of `session.appendSystemNotice` directly so the message
    /// survives a session reload.
    func appendAndPersistSystemNotice(_ text: String) {
        let before = session.transcript.messages.count
        session.appendSystemNotice(text)
        persistFromIndex(before)
    }

    /// Append a file-edit card to the session AND persist it.
    func appendAndPersistFileEdit(_ edit: ACPMessage.FileEdit) {
        let before = session.transcript.messages.count
        session.appendFileEdit(edit)
        persistFromIndex(before)
    }
}

extension ACPSessionRunner {
    /// True when this runner may write — it still holds the session lease.
    /// When `ownerInstanceId` is nil (tests that construct a runner directly
    /// without a lease), gating is disabled and writes always proceed.
    private func holdsLeaseForWrite() -> Bool {
        guard let ownerInstanceId else { return true }
        return (try? store.loadLease(sessionId: sessionId))?.ownerInstance == ownerInstanceId
    }

    private func shouldBatchStreamingPersist(for update: ACPSessionUpdate) -> Bool {
        guard activePromptID != nil else { return false }
        switch session.transcript.streamingState {
        case .sending, .streaming:
            break
        case .idle, .awaitingPermission, .awaitingInput:
            return false
        }
        switch update {
        case .agentMessageChunk, .agentThoughtChunk, .toolCallUpdate:
            return true
        case .userMessageChunk, .toolCall, .plan, .availableModelsUpdate,
             .currentModeUpdate, .currentModelUpdate,
             .sessionConfigOptionsUpdate, .availableCommandsUpdate,
             .usageUpdate, .unknown:
            return false
        }
    }

    private func scheduleStreamingPersist(_ indices: Set<Int>) {
        guard !indices.isEmpty else { return }
        snapshotStreamingPersistPayloads(for: indices)
        pendingStreamingPersistIndices.formUnion(indices)
        guard streamingPersistTask == nil else { return }
        streamingPersistTask = Task { @MainActor [weak self] in
            guard let self else { return }
            try? await Task.sleep(nanoseconds: self.streamingPersistDebounceNanos)
            guard !Task.isCancelled else { return }
            self.flushStreamingPersist()
        }
    }

    private func flushStreamingPersist() {
        flushStreamingPersist(requiresLease: true)
    }

    private func flushStreamingPersistOnStop() {
        // During takeover, the lease row may already point at the new owner
        // by the time stand-down stops this runner. The pending rows here are
        // snapshots captured while this runner still held the lease; flush
        // them once so the debounce buffer is not the only copy.
        flushStreamingPersist(requiresLease: false)
    }

    private func flushStreamingPersist(requiresLease: Bool) {
        streamingPersistTask?.cancel()
        streamingPersistTask = nil
        guard !pendingStreamingPersistIndices.isEmpty else { return }
        if !requiresLease {
            persistStreamingPersistSnapshots()
            return
        }
        let indices = pendingStreamingPersistIndices
        if persistIndices(indices, requiresLease: requiresLease) {
            pendingStreamingPersistIndices.subtract(indices)
            for i in indices {
                pendingStreamingPersistSnapshots.removeValue(forKey: i)
            }
        }
    }

    private func snapshotStreamingPersistPayloads(for indices: Set<Int>) {
        guard holdsLeaseForWrite() else { return }
        let messages = session.transcript.messages
        for i in indices {
            guard i >= 0, i < messages.count else { continue }
            let message = messages[i]
            guard let payload = try? ACPMessageCodec.encode(message) else { continue }
            let id = "msg-\(sessionId)-\(i)"
            let basePayload = i < persistedMessageCount ? try? store.loadMessagePayload(id: id) : nil
            if i < persistedMessageCount, basePayload == nil { continue }
            pendingStreamingPersistSnapshots[i] = .init(kind: message.kind, payload: payload, basePayload: basePayload)
        }
    }

    private func persistStreamingPersistSnapshots() {
        guard !pendingStreamingPersistSnapshots.isEmpty else { return }
        let now = Int64(Date().timeIntervalSince1970)
        let snapshots = pendingStreamingPersistSnapshots
        for i in snapshots.keys.sorted() {
            guard let snapshot = snapshots[i] else { continue }
            let id = "msg-\(sessionId)-\(i)"
            if i < persistedMessageCount {
                guard let basePayload = snapshot.basePayload,
                      (try? store.updateMessagePayloadIfUnchanged(
                        id: id,
                        payload: snapshot.payload,
                        expectedPayload: basePayload
                      )) == true else {
                    continue
                }
            } else {
                do {
                    try store.appendMessage(sessionId: sessionId, id: id, kind: snapshot.kind,
                                            seq: Int64(i), payload: snapshot.payload, createdAt: now)
                    persistedMessageCount = max(persistedMessageCount, i + 1)
                } catch {
                    continue
                }
            }
            pendingStreamingPersistIndices.remove(i)
            pendingStreamingPersistSnapshots.removeValue(forKey: i)
        }
        onPersist?()
    }

    /// Persist the specific message rows touched by an `apply()` call.
    /// Use this instead of `persistFromIndex` when the caller can name
    /// exactly which indices changed — a plan or tool-call update may
    /// mutate a row anywhere in the transcript, not just the trailing
    /// one, so the count-delta heuristic in `persistFromIndex` would
    /// write back the wrong row.
    @discardableResult
    func persistIndices(_ indices: Set<Int>, requiresLease: Bool = true) -> Bool {
        streamingPersistTask?.cancel()
        streamingPersistTask = nil
        guard !requiresLease || holdsLeaseForWrite() else { return false }
        guard !indices.isEmpty else { return true }
        let messages = session.transcript.messages
        let now = Int64(Date().timeIntervalSince1970)
        for i in indices.sorted() {
            guard i >= 0, i < messages.count else { continue }
            let m = messages[i]
            guard let payload = try? ACPMessageCodec.encode(m) else { continue }
            let id = "msg-\(sessionId)-\(i)"
            if i < persistedMessageCount {
                try? store.updateMessagePayload(id: id, payload: payload)
            } else {
                do {
                    try store.appendMessage(sessionId: sessionId, id: id, kind: m.kind,
                                            seq: Int64(i), payload: payload, createdAt: now)
                    persistedMessageCount = max(persistedMessageCount, i + 1)
                } catch {
                    if (try? store.updateMessageRow(id: id, kind: m.kind, seq: Int64(i), payload: payload)) == true {
                        persistedMessageCount = max(persistedMessageCount, i + 1)
                    }
                }
            }
        }
        onPersist?()
        return true
    }

    /// Persist messages from the apply() boundary. Three cases:
    ///   1. apply() appended N >= 1 new messages: persist them as new rows.
    ///   2. apply() mutated the trailing message in place (chunk-merge,
    ///      tool-call update, plan update): persist that trailing row.
    ///   3. apply() did nothing (e.g. availableModelsUpdate): nothing to do.
    ///
    /// `from` is the message count CAPTURED BEFORE apply(); compare it
    /// against the current count to figure out which case we're in. The
    /// previous version dropped case 2 silently — chunk-merged agent
    /// text was visible in memory but never written, so reopening a
    /// session lost most of the conversation.
    func persistFromIndex(_ from: Int) {
        flushStreamingPersist()
        guard holdsLeaseForWrite() else { return }
        let messages = session.transcript.messages
        guard messages.count > 0 else { return }

        let lowerBound: Int
        if from < messages.count {
            // New messages appended (possibly with the trailing one
            // also mutated as a side effect of the same apply()).
            lowerBound = from
        } else if from == messages.count {
            // No new entries — the trailing one was mutated. Re-persist it.
            lowerBound = messages.count - 1
        } else {
            return
        }

        let now = Int64(Date().timeIntervalSince1970)
        for i in lowerBound..<messages.count {
            let m = messages[i]
            guard let payload = try? ACPMessageCodec.encode(m) else { continue }
            let id = "msg-\(sessionId)-\(i)"
            if i < persistedMessageCount {
                try? store.updateMessagePayload(id: id, payload: payload)
            } else {
                do {
                    try store.appendMessage(sessionId: sessionId, id: id, kind: m.kind,
                                            seq: Int64(i), payload: payload, createdAt: now)
                    persistedMessageCount = max(persistedMessageCount, i + 1)
                } catch {
                    if (try? store.updateMessageRow(id: id, kind: m.kind, seq: Int64(i), payload: payload)) == true {
                        persistedMessageCount = max(persistedMessageCount, i + 1)
                    }
                }
            }
        }
        onPersist?()
    }
}
