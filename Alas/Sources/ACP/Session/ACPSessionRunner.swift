import Foundation

@MainActor
final class ACPSessionRunner {
    let session: ACPSession
    let connection: ACPConnection
    let persistence: ACPSessionPersistence
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
    let remoteHost: String?
    let usesRemoteHostRegistry: Bool
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
    private let onUserCancel: (() -> Void)?
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
    private let canWrite: () -> Bool
    private let validateLease: () async -> Bool
    private let leaseFenceProvider: () -> ACPSessionLeaseFence?
    private let onAuthRequired: ((ACPSessionRunner, String) async -> Void)?
    private let onPersist: (() -> Void)?
    private let onSessionTitleUpdated: ((String) -> Void)?
    private var updatesTask: Task<Void, Never>?
    private var permissionsTask: Task<Void, Never>?
    private var filesTask: Task<Void, Never>?
    private var terminalsTask: Task<Void, Never>?
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
    private var persistenceTail: Task<Void, Never>?
    private var persistenceGeneration = 0
    private var pendingCompletedOutputBoundaryUpdateCount: Int?
    private var pendingStreamingPersistIndices: Set<Int> = []
    /// Revisions distinguish a new streamed chunk from the payload currently
    /// being written. A successful write may only clear the revision it saw.
    private var pendingStreamingPersistRevisions: [Int: Int] = [:]
    private var streamingPersistInFlightIndices: Set<Int> = []
    private var pendingStreamingPersistSnapshots: [Int: StreamingPersistSnapshot] = [:]
    private var pendingStreamingPersistAcknowledgements: [ACPDurableConsumptionAcknowledgement] = []
    /// The exact payload bytes this runner last wrote for each message row.
    /// Used as the compare-and-swap base when a takeover forces a stand-down
    /// flush, so the CAS never reads the (potentially growing) payload blob
    /// from SQLite on the streaming path.
    private var lastPersistedPayloads: [Int: Data] = [:]
    private var capturingPersistedBaseIndices: Set<Int> = []
    /// Set once a cross-process takeover is detected mid-stream. While true,
    /// streamed chunks are no longer buffered for persistence and the
    /// stand-down flush writes the frozen snapshots via compare-and-swap
    /// instead of the (now-diverging) live transcript.
    private var streamingLeaseLost = false
    private var streamingPersistTask: Task<Void, Never>?
    private let streamingPersistDebounceNanos: UInt64
    private struct PendingIncomingUpdate {
        let params: ACPSessionUpdateParams
        let receivedWhileHoldingLease: Bool
    }

    private var pendingIncomingUpdates: [PendingIncomingUpdate] = []
    private var incomingUpdateFlushTask: Task<Void, Never>?
    private let incomingUpdateCoalesceNanos: UInt64
    private var suppressingLoadReplay: Bool
    private var loadReplaySuppressionTarget: Int?
    private var observedUpdateCount = 0
    /// Set while `steer` is between `userCancel` and the redirect's
    /// `sendNow`. `flushQueueIfIdle` no-ops while this is true so an
    /// Undo tapped during the cancel round-trip can't drain the just-
    /// restored snapshot ahead of the steer's replacement prompt. Once
    /// the redirect is in flight, normal drain semantics resume.
    private var steerInProgress: Bool = false
    /// Holds an idle source session at its persisted remote head while
    /// `session/fork` is in flight. New prompts remain queued until the
    /// target adapter has created the branch.
    private var nativeForkBarrierActive = false
    var onUnexpectedDisconnect: (() -> Void)?

    /// How many trailing rows to retain in `lastPersistedPayloads`. Only the
    /// actively-streamed tail is ever re-persisted, so older rows can be
    /// dropped; a pruned row that is somehow touched again falls back to a
    /// one-time SQLite read in `freezeStreamingPersistSnapshots`.
    private static let lastPersistedPayloadsWindow = 256

    private struct StreamingPersistSnapshot {
        let kind: String
        let payload: Data
        let basePayload: Data?
    }

    init(session: ACPSession, connection: ACPConnection, store: ACPSessionStore? = nil,
         sessionId: String, worktreePath: String,
         agentEnv: [String: String] = ProcessInfo.processInfo.environment,
         remoteHost: String? = nil,
         usesRemoteHostRegistry: Bool = true,
         suppressingLoadReplay: Bool = false,
         onDirtyCheck: ((String) -> Bool)? = nil,
         onLiveBufferRead: ((String) -> String?)? = nil,
         onUserCancel: (() -> Void)? = nil,
         onAuthRequired: ((ACPSessionRunner, String) async -> Void)? = nil,
         onPersist: (() -> Void)? = nil,
         onSessionTitleUpdated: ((String) -> Void)? = nil,
         onResumeTranscriptTail: (() -> Void)? = nil,
         streamingPersistDebounceNanos: UInt64 = 250_000_000,
         incomingUpdateCoalesceNanos: UInt64 = 16_000_000,
         ownerInstanceId: String? = nil,
         persistence: ACPSessionPersistence? = nil,
         persistedMessageCount: Int? = nil,
         canWrite: (() -> Bool)? = nil,
         validateLease: (() async -> Bool)? = nil,
         leaseFenceProvider: (() -> ACPSessionLeaseFence?)? = nil)
    {
        precondition(store != nil || persistence != nil, "ACPSessionRunner requires persistence")
        let resolvedPersistence = persistence ?? ACPSessionPersistence(path: store!.path)
        self.session = session
        self.connection = connection
        self.persistence = resolvedPersistence
        self.sessionId = sessionId
        self.worktreePath = worktreePath
        self.remoteHost = remoteHost
        self.usesRemoteHostRegistry = usesRemoteHostRegistry
        self.agentEnv = agentEnv
        self.ownerInstanceId = ownerInstanceId
        self.onAuthRequired = onAuthRequired
        self.onPersist = onPersist
        self.onSessionTitleUpdated = onSessionTitleUpdated
        self.streamingPersistDebounceNanos = streamingPersistDebounceNanos
        self.incomingUpdateCoalesceNanos = incomingUpdateCoalesceNanos
        self.suppressingLoadReplay = suppressingLoadReplay
        if suppressingLoadReplay {
            session.beginSuppressedReplaySideEffects()
        }
        self.onDirtyCheck = onDirtyCheck
        self.onLiveBufferRead = onLiveBufferRead
        self.onUserCancel = onUserCancel
        self.onResumeTranscriptTail = onResumeTranscriptTail
        let initialPersistedMessageCount = persistedMessageCount
            ?? store.flatMap { try? $0.messageCount(sessionId: sessionId) }
            ?? 0
        self.persistedMessageCount = initialPersistedMessageCount
        self.seq = Int64(initialPersistedMessageCount)
        // Capture the three values holdsLeaseForWrite() reads so the closure
        // can be formed before `self` is fully initialised (policy is the
        // last stored property). The logic is identical to holdsLeaseForWrite.
        let _sessionId = sessionId
        let _ownerInstanceId = ownerInstanceId
        let defaultCanWrite = {
            guard let id = _ownerInstanceId else { return true }
            guard let store else { return false }
            return (try? store.loadLease(sessionId: _sessionId))?.ownerInstance == id
        }
        self.canWrite = canWrite ?? defaultCanWrite
        self.validateLease = validateLease ?? { canWrite?() ?? defaultCanWrite() }
        let initialLease = ownerInstanceId.flatMap { owner in
            guard let lease = try? store?.loadLease(sessionId: sessionId),
                  lease.ownerInstance == owner else { return nil as ACPSessionLeaseFence? }
            return ACPSessionLeaseFence(
                sessionId: sessionId,
                ownerInstance: owner,
                token: lease.token
            )
        }
        self.leaseFenceProvider = leaseFenceProvider ?? { initialLease }
        self.policy = ACPPermissionPolicy(
            session: session,
            log: ACPPermissionDecisionLog(
                persistence: resolvedPersistence,
                canWrite: canWrite ?? defaultCanWrite,
                leaseFence: leaseFenceProvider
            )
        )
    }

    private func enqueuePersistence(
        _ operation: @escaping @Sendable (ACPSessionPersistence) async throws -> Void
    ) {
        let previous = persistenceTail
        let persistence = persistence
        persistenceGeneration += 1
        persistenceTail = Task { @MainActor in
            await previous?.value
            guard !Task.isCancelled else { return }
            try? await operation(persistence)
        }
    }

    private func enqueuePersistence<Result: Sendable>(
        _ operation: @escaping @Sendable (ACPSessionPersistence) async throws -> Result,
        completion: @escaping @MainActor (Result?) async -> Void
    ) {
        let previous = persistenceTail
        let persistence = persistence
        persistenceGeneration += 1
        let task = Task { @MainActor in
            await previous?.value
            guard !Task.isCancelled else { return }
            await completion(try? await operation(persistence))
        }
        persistenceTail = Task { await task.value }
    }

    func flushPersistence() async {
        while let tail = persistenceTail {
            let generation = persistenceGeneration
            await tail.value
            if persistenceGeneration == generation { return }
        }
    }

    func start() {
        session.clearRetryStatus()
        updatesTask = Task { [weak self] in
            guard let self else { return }
            for await u in self.connection.client.incomingUpdates {
                self.enqueueIncomingUpdate(u)
            }
            // The for-await also exits when the task gets cancelled —
            // that's the intentional detach path (tab close, worktree
            // teardown). Don't pollute the persisted transcript with
            // an "Agent disconnected" notice in that case; only flag
            // the unexpected stream-end.
            if Task.isCancelled { return }
            self.flushPendingIncomingUpdates(flushQueueWhenBoundaryReady: false)
            await MainActor.run {
                self.session.clearRetryStatus()
                self.session.agentState = .disconnected
                self.session.transcript.streamingState = .idle
                // No flushQueueIfIdle() here: the connection is dead, so
                // the next prompt would just fail. The queue stays put
                // and drains naturally on the next successful reattach.
                self.appendAndPersistSystemNotice("Agent disconnected.")
                self.onUnexpectedDisconnect?()
            }
        }

        permissionsTask = Task { @MainActor [weak self] in
            guard let self else { return }
            for await (id, params) in self.connection.client.permissionRequests {
                self.flushPendingIncomingUpdates()
                let scopeKey = "tool:\(params.toolCall.title ?? params.toolCall.toolCallId)"
                let response = await self.policy.evaluate(scopeKey: scopeKey, options: params.options, params: params)
                self.connection.client.respondToPermission(id: id, response: response)
            }
        }

        // Agent-spawned terminals must see the exact env the agent
        // itself was launched with — same augmented PATH (npm / cargo
        // resolve under launchd's minimal PATH) and same scrubbed
        // CLAUDECODE/CLAUDE_SESSION_ID markers (otherwise a Claude-
        // aware CLI run from the terminal refuses to start).
        session.terminalHost.updateContext(sessionCwd: worktreePath,
                                           sessionEnv: agentEnv,
                                           sessionRemoteHost: effectiveRemoteHost())

        filesTask = Task { @MainActor [weak self] in
            guard let self else { return }
            let writer = ACPFileWriter(
                worktreeRoot: URL(fileURLWithPath: self.worktreePath)
            )
            let remoteServer = self.effectiveRemoteHost().map {
                ACPRemoteFileServer(host: $0, worktreeRoot: self.worktreePath)
            }
            for await req in self.connection.client.fileRequests {
                self.flushPendingIncomingUpdates()
                switch req {
                case .read(let id, let params):
                    do {
                        if let remoteServer {
                            let target = try remoteServer.lexicallyResolveInsideWorktree(path: params.path)
                            let live = self.onLiveBufferRead?(target)
                            let full = try await remoteServer.read(path: params.path, liveBuffer: live)
                            // Weaker than the local guard, and deliberately
                            // so: the remote read fetches the whole file
                            // regardless of range, so by the time its size is
                            // known it has already crossed the network.
                            // Sizing it first would add an `fs/stat` round
                            // trip to every remote read to catch a rare one.
                            // Refusing here still spares the JSON encode — a
                            // second copy — and the undeliverable response
                            // that would otherwise strand the adapter.
                            let sliced = Self.sliceLines(full, line: params.line, limit: params.limit)
                            if let refusal = Self.readRefusal(
                                name: (target as NSString).lastPathComponent,
                                bytes: sliced.utf8.count
                            ) {
                                self.connection.client.respondToFileRequest(
                                    id: id,
                                    result: .failure(.init(code: -32000, message: refusal, data: nil))
                                )
                                continue
                            }
                            let body = try JSONEncoder().encode(ACPFsReadResult(content: sliced))
                            self.connection.client.respondToFileRequest(id: id, result: .success(body))
                            continue
                        }
                        // Same containment check as the write path —
                        // without this an adapter could request any
                        // absolute path (e.g. `~/.ssh/config`) and
                        // exfiltrate it without a permission prompt.
                        // Cheap pure string work, safe on-main.
                        let target = try writer.resolveInsideWorktree(path: params.path)
                        // Prefer the live editor buffer when the file
                        // is open and dirty so the agent sees what the
                        // user sees (avoids "agent reads stale disk,
                        // then writes a replacement that clobbers
                        // unsaved edits"). This lookup reads editor
                        // state, so it MUST stay on the main actor; only
                        // the resulting snapshot crosses the hop below.
                        let live = self.onLiveBufferRead?(target.path)
                        // Disk read + slice + encode run off-main.
                        let outcome = await Self.serveRead(
                            target: target, liveBuffer: live,
                            line: params.line, limit: params.limit
                        )
                        // A detach/takeover can cancel this task during the
                        // off-main read. `return` (not `break`) so we exit the
                        // whole `filesTask` loop — a bare `break` only leaves
                        // the `switch` and would let a buffered next request
                        // (e.g. an outside-worktree read that persists a notice)
                        // run on a runner that no longer owns the session.
                        if Task.isCancelled { return }
                        switch outcome {
                        case .success(let body):
                            self.connection.client.respondToFileRequest(id: id, result: .success(body))
                        case .failure(let message):
                            self.connection.client.respondToFileRequest(
                                id: id,
                                result: .failure(.init(code: -32000, message: message, data: nil))
                            )
                        }
                    } catch ACPFileWriter.Error.outsideWorktree(let p) {
                        self.appendAndPersistSystemNotice("Blocked read outside worktree: \(p)")
                        self.connection.client.respondToFileRequest(
                            id: id,
                            result: .failure(.init(code: -32001, message: "path outside worktree", data: nil))
                        )
                    } catch ACPRemoteFileServer.ServerError.outsideWorktree(let p) {
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
                    //
                    // Unlike the read path, the write stays fully on the main
                    // actor. An in-app editor save also runs on the main actor,
                    // so a synchronous write here cannot run in parallel with —
                    // and silently clobber — a concurrent save of the same file,
                    // and the lease check / dirty gate stay atomic with the
                    // replacement. Hopping the write off-main safely requires
                    // serializing agent writes against editor saves; that is
                    // deferred to a follow-up. The unbounded-read hot path
                    // (`serveRead`) carries the bulk of the main-thread win.
                    guard await self.hasConfirmedLeaseForSideEffect() else {
                        self.connection.client.respondToFileRequest(
                            id: id,
                            result: .failure(.init(code: -32003, message: "lease lost to another instance", data: nil)))
                        break
                    }
                    if self.onDirtyCheck?(params.path) == true {
                        self.appendAndPersistSystemNotice("Agent wrote to \(URL(fileURLWithPath: params.path).lastPathComponent) — you have unsaved changes in this file.")
                    }
                    do {
                        let res: ACPFileWriter.Result
                        if let remoteServer {
                            res = try await remoteServer.write(path: params.path, content: params.content) {
                                guard self.holdsLeaseForWrite() else {
                                    throw ACPRemoteFileServer.ServerError.leaseLost
                                }
                            }
                        } else {
                            res = try writer.write(path: params.path, content: params.content)
                        }
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
                    } catch ACPRemoteFileServer.ServerError.outsideWorktree(let p) {
                        self.appendAndPersistSystemNotice("Blocked write outside worktree: \(p)")
                        self.connection.client.respondToFileRequest(
                            id: id,
                            result: .failure(.init(code: -32001, message: "path outside worktree", data: nil)))
                    } catch ACPRemoteFileServer.ServerError.leaseLost {
                        self.connection.client.respondToFileRequest(
                            id: id,
                            result: .failure(.init(code: -32003, message: "lease lost to another instance", data: nil)))
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
                await self.handleTerminalRequest(req)
            }
        }
    }

    private func enqueueIncomingUpdate(_ update: ACPSessionUpdateParams) {
        let receivedWhileHoldingLease = holdsLeaseForWrite()
        if receivedWhileHoldingLease {
            capturePersistedBasesForIncomingUpdate(update.update)
        }
        pendingIncomingUpdates.append(.init(
            params: update,
            receivedWhileHoldingLease: receivedWhileHoldingLease
        ))
        guard incomingUpdateFlushTask == nil else { return }
        incomingUpdateFlushTask = Task { @MainActor [weak self] in
            guard let self else { return }
            try? await Task.sleep(nanoseconds: self.incomingUpdateCoalesceNanos)
            guard !Task.isCancelled else { return }
            self.flushPendingIncomingUpdates()
        }
    }

    private func capturePersistedBasesForIncomingUpdate(_ update: ACPSessionUpdate) {
        for index in persistedCandidateIndices(for: update) {
            capturePersistedBaseIfNeeded(at: index)
        }
    }

    private func persistedCandidateIndices(for update: ACPSessionUpdate) -> Set<Int> {
        let messages = session.transcript.messages
        switch update {
        case .agentMessageChunk(let chunk):
            if let messageId = chunk.messageId,
               let index = session.transcript.messageIndex(messageId: messageId, kind: .agent) {
                return [index]
            }
            return messages.indices.reversed().first { index in
                if case .agent = messages[index] {
                    return true
                }
                return false
            }.map { [$0] } ?? []
        case .agentThoughtChunk(let chunk):
            if let messageId = chunk.messageId,
               let index = session.transcript.messageIndex(messageId: messageId, kind: .thought) {
                return [index]
            }
            return messages.indices.reversed().first { index in
                if case .thought = messages[index] {
                    return true
                }
                return false
            }.map { [$0] } ?? []
        case .toolCallUpdate(let update):
            return session.transcript.toolCallIndex(toolCallId: update.toolCallId).map { [$0] } ?? []
        case .compactionSummaryChunk(let chunk):
            return session.transcript.toolCallIndex(
                toolCallId: ACPSession.contextCompactionToolCallId(chunk.compactionId)
            ).map { [$0] } ?? []
        case .toolCall, .compactionUpdate,
             .userMessageChunk, .plan, .availableModelsUpdate,
             .currentModeUpdate, .currentModelUpdate, .sessionInfoUpdate,
             .sessionConfigOptionsUpdate, .availableCommandsUpdate,
             .usageUpdate, .unknown:
            return []
        }
    }

    private func flushPendingIncomingUpdates(
        flushQueueWhenBoundaryReady: Bool = true,
        treatBufferedUpdatesAsPromptOwned: Bool = false
    ) {
        incomingUpdateFlushTask?.cancel()
        incomingUpdateFlushTask = nil
        guard !pendingIncomingUpdates.isEmpty else { return }
        let updates = pendingIncomingUpdates
        pendingIncomingUpdates.removeAll(keepingCapacity: true)
        for update in updates {
            applyIncomingUpdate(
                update.params,
                bufferedUpdateReceivedWhileHoldingLease: update.receivedWhileHoldingLease,
                flushQueueWhenBoundaryReady: flushQueueWhenBoundaryReady,
                treatBufferedUpdatesAsPromptOwned: treatBufferedUpdatesAsPromptOwned
            )
        }
    }

    private func applyIncomingUpdate(
        _ params: ACPSessionUpdateParams,
        bufferedUpdateReceivedWhileHoldingLease: Bool = true,
        flushQueueWhenBoundaryReady: Bool = true,
        treatBufferedUpdatesAsPromptOwned: Bool = false
    ) {
        let durableConsumptionAcknowledgement = params.durableConsumptionAcknowledgement
        observedUpdateCount += 1
        appliedUpdateCount += 1
        let preAppliedSessionInfoDirty: Set<Int>?
        if case .sessionInfoUpdate(let info) = params.update {
            flushStreamingPersist()
            preAppliedSessionInfoDirty = session.apply(
                params.update,
                tracksRetryStatus: !suppressingLoadReplay
            )
            applySessionInfoTitle(info)
        } else {
            preAppliedSessionInfoDirty = nil
        }
        if suppressingLoadReplay {
            if let dirty = preAppliedSessionInfoDirty {
                persistIndices(
                    dirty,
                    completion: persistenceCompletion(acknowledging: durableConsumptionAcknowledgement)
                )
            } else {
                _ = session.applySuppressedReplaySideEffects(params.update)
                durableConsumptionAcknowledgement?()
            }
            if let target = loadReplaySuppressionTarget,
               observedUpdateCount >= target {
                finishLoadReplaySuppression()
            }
            return
        }
        if let dirty = preAppliedSessionInfoDirty {
            persistIndices(
                dirty,
                completion: persistenceCompletion(acknowledging: durableConsumptionAcknowledgement)
            )
        } else {
            let isPromptCompletionDrainUpdate = pendingCompletedOutputBoundaryUpdateCount
                .map { appliedUpdateCount <= $0 } ?? false
            let isPromptOwnedBufferedUpdate = bufferedUpdateReceivedWhileHoldingLease
                && (activePromptID != nil || isPromptCompletionDrainUpdate || treatBufferedUpdatesAsPromptOwned)
            let shouldBatchStreamingPersist = shouldBatchStreamingPersist(
                for: params.update,
                isPromptOwnedBufferedUpdate: isPromptOwnedBufferedUpdate,
                hasUnderLeaseBufferedStreamingWrites: !pendingStreamingPersistIndices.isEmpty
            )
            if shouldBatchStreamingPersist {
                // Detect a cross-process takeover BEFORE this chunk mutates
                // the transcript. If the lease has moved, freeze the buffered
                // rows' pre-chunk state so stand-down persists that snapshot,
                // not chunks that belong to the new session owner. Buffered
                // chunks received while the lease was still held are different:
                // they remain owned by this stream even if the coalesced apply
                // happens after activePromptID cleared.
                let holdsLease = holdsLeaseForWrite()
                if !isPromptOwnedBufferedUpdate, !streamingLeaseLost, !holdsLease {
                    freezeStreamingPersistSnapshots()
                    streamingLeaseLost = true
                }
                let dirty = session.apply(params.update)
                if !streamingLeaseLost {
                    scheduleStreamingPersist(
                        dirty,
                        mayCapturePersistedBases: holdsLease,
                        durableConsumptionAcknowledgement: durableConsumptionAcknowledgement
                    )
                }
            } else {
                let dirty = session.apply(params.update)
                flushStreamingPersist()
                persistIndices(
                    dirty,
                    completion: persistenceCompletion(acknowledging: durableConsumptionAcknowledgement)
                )
            }
        }
        if applyPendingCompletedOutputBoundaryIfReady(), flushQueueWhenBoundaryReady {
            flushQueueIfIdle()
        }
    }

    private func persistenceCompletion(
        acknowledging acknowledgement: ACPDurableConsumptionAcknowledgement?
    ) -> ((Bool) -> Void)? {
        guard let acknowledgement else { return nil }
        return { succeeded in
            if succeeded {
                acknowledgement()
            }
        }
    }

    #if DEBUG
    func applyIncomingUpdateForTesting(_ params: ACPSessionUpdateParams) {
        applyIncomingUpdate(params)
    }
    #endif

    func suppressLoadReplay(throughYieldedUpdateCount target: Int) {
        guard target > observedUpdateCount else { return }
        if !suppressingLoadReplay {
            suppressingLoadReplay = true
            session.beginSuppressedReplaySideEffects()
        }
        loadReplaySuppressionTarget = max(loadReplaySuppressionTarget ?? 0, target)
    }

    func finishSuppressingLoadReplay(throughYieldedUpdateCount target: Int) {
        guard suppressingLoadReplay else { return }
        loadReplaySuppressionTarget = target
        flushPendingIncomingUpdates()
        if observedUpdateCount >= target {
            finishLoadReplaySuppression()
        }
    }

    private func finishLoadReplaySuppression() {
        suppressingLoadReplay = false
        session.endSuppressedReplaySideEffects()
        // Disallow streaming boundary crossings until the next prompt starts.
        // If the prompt already started while a delayed replay flush was still
        // pending, keep its live-stream boundary setting intact.
        if activePromptID == nil {
            session.allowsStreamingBoundaryCrossing = false
        }
    }

    func stop() {
        flushPendingIncomingUpdates(
            flushQueueWhenBoundaryReady: false,
            treatBufferedUpdatesAsPromptOwned: true
        )
        session.clearRetryStatus()
        flushStreamingPersistOnStop()
        incomingUpdateFlushTask?.cancel()
        incomingUpdateFlushTask = nil
        updatesTask?.cancel()
        permissionsTask?.cancel()
        filesTask?.cancel()
        terminalsTask?.cancel()
        // A detach/takeover can land while a permission prompt is parked.
        // userCancel() already resolves it; stop() must too, or the policy's
        // continuation is stranded when we tear the connection down.
        policy.userCancelled()
        // Kill agent-spawned subprocesses now. ACPSessionManager keeps
        // the ACPSession cached after detach, so the session's deinit-
        // time killAll() won't fire on tab close — without this an
        // active `npm test`/`sleep`/server outlives the agent.
        session.terminalHost.killAll()
        onPersist?()
    }

    private func handleTerminalRequest(_ req: ACPTerminalRequest) async {
        let host = self.session.terminalHost
        switch req {
        case .create(let id, let p):
            // Gate terminal creation on the lease: a runner that has lost
            // the writer lease must not start new terminal side effects in
            // the brief window before stand-down tears it down. This is
            // defense-in-depth alongside the heartbeat/stand-down path
            // (which calls stop() → terminalHost.killAll() within ~100ms
            // of a takeover ping). Matches the existing file-write gate.
            guard await hasConfirmedLeaseForSideEffect() else {
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
            guard await hasConfirmedLeaseForSideEffect() else {
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
            guard await hasConfirmedLeaseForSideEffect() else {
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
        let title = session.title
        let titleSource = session.titleSource
        let currentModel = session.currentModel
        let currentMode = session.currentMode
        let autoRun = session.autoRunEnabled
        let fence = leaseFenceProvider()
        let sessionId = sessionId
        enqueuePersistence { persistence in
            _ = try await persistence.updateSessionFromRuntime(
                id: sessionId,
                title: title,
                titleSource: titleSource,
                currentModel: currentModel,
                currentMode: currentMode,
                autoRun: autoRun,
                preserveTitle: preserveTitle,
                fence: fence
            )
        }
    }

    func persistGeneratedTitleIfStoredPlaceholder() {
        guard holdsLeaseForWrite() else { return }
        let now = Int64(Date().timeIntervalSince1970)
        let title = session.title
        let fence = leaseFenceProvider()
        let sessionId = sessionId
        enqueuePersistence({ persistence in
            try await persistence.updateGeneratedTitleIfPlaceholder(
                id: sessionId,
                title: title,
                updatedAt: now,
                fence: fence
            )
        }, completion: { [weak self] updated in
            guard updated != true, let self else { return }
            guard let row = try? await self.persistence.loadSession(id: self.sessionId),
                  row.titleSource != .placeholder else { return }
            self.session.title = row.title
            self.session.titleSource = row.titleSource
        })
    }

    func applySessionInfoTitle(_ info: ACPSessionInfoUpdate) {
        guard holdsLeaseForWrite() else { return }
        switch info.title {
        case .absent:
            return
        case .null:
            clearSessionInfoTitle()
        case .value(let rawTitle):
            applySessionInfoTitleValue(rawTitle)
        }
    }

    private func applySessionInfoTitleValue(_ rawTitle: String) {
        let trimmed = rawTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        guard session.titleSource != .manual else { return }

        let now = Int64(Date().timeIntervalSince1970)
        session.title = trimmed
        session.titleSource = .generated
        let fence = leaseFenceProvider()
        let sessionId = sessionId
        enqueuePersistence({ persistence in
            try await persistence.updateGeneratedTitleIfNotManual(
                id: sessionId,
                title: trimmed,
                updatedAt: now,
                fence: fence
            )
        }, completion: { [weak self] updated in
            guard let self else { return }
            if updated == true {
                self.onSessionTitleUpdated?(trimmed)
                return
            }
            guard let row = try? await self.persistence.loadSession(id: self.sessionId),
                  row.titleSource == .manual else { return }
            self.session.title = row.title
            self.session.titleSource = row.titleSource
        })
    }

    private func clearSessionInfoTitle() {
        guard session.titleSource != .manual else { return }

        let now = Int64(Date().timeIntervalSince1970)
        session.title = "New session"
        session.titleSource = .placeholder
        onSessionTitleUpdated?("New session")
        let fence = leaseFenceProvider()
        let sessionId = sessionId
        enqueuePersistence({ persistence in
            try await persistence.clearGeneratedTitleIfNotManual(
                id: sessionId,
                updatedAt: now,
                fence: fence
            )
        }, completion: { [weak self] updated in
            guard updated != true, let self else { return }
            guard let row = try? await self.persistence.loadSession(id: self.sessionId),
                  row.titleSource == .manual else { return }
            self.session.title = row.title
            self.session.titleSource = row.titleSource
        })
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
    nonisolated static func sliceLines(_ full: String, line: Int?, limit: Int?) -> String {
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

    /// Sendable outcome of an off-main agent `fs/read_text_file`. Kept minimal
    /// (only value types) so it can cross back to the main actor without an
    /// `@unchecked Sendable` escape hatch.
    /// Whether a read result is too large to return, and what to tell the
    /// adapter if so.
    ///
    /// Judged on the bytes actually being returned. An earlier version asked
    /// instead whether a range had been requested, which a caller could
    /// satisfy without bounding anything: `sliceLines` runs to end of file
    /// unless `limit` is present *and positive*, so `line: 1` alone — or
    /// `limit: 0` — asks for the whole file while looking like a range.
    ///
    /// Shared by the local and remote read paths so the two cannot drift into
    /// different answers for the same request.
    nonisolated static func readRefusal(name: String, bytes: Int) -> String? {
        guard bytes > maxWholeFileReadBytes else { return nil }
        return "\(name) is \(bytes) bytes, over the "
            + "\(maxWholeFileReadBytes)-byte limit for a single read. "
            + "Request a smaller range with the line and limit parameters."
    }

    /// Whether a request bounds its own result. Only a positive `limit` does;
    /// see `readRefusal`.
    nonisolated static func requestIsBounded(limit: Int?) -> Bool {
        (limit ?? 0) > 0
    }

    /// Largest file returned in full by `fs/read_text_file`.
    ///
    /// Sized by what a consumer can use rather than by what the machine can
    /// hold: this is already far past any model's context window, so a
    /// response beyond it is waste in both directions. Ranged reads are not
    /// subject to it.
    nonisolated static let maxWholeFileReadBytes = 64 * 1024 * 1024

    enum FileReadOutcome: Sendable {
        case success(Data)
        case failure(message: String)
    }

    /// Reads a file from disk (or uses a caller-supplied live-buffer snapshot),
    /// slices it, and JSON-encodes the `fs/read_text_file` response body.
    ///
    /// `nonisolated async` so the disk read + string slicing + encoding run on
    /// the cooperative pool instead of the main actor — agents read files
    /// constantly and a large lockfile/asset would otherwise block the UI. The
    /// live-buffer lookup itself stays on the main actor at the call site; only
    /// its already-materialized `String` snapshot is passed in here.
    nonisolated static func serveRead(
        target: URL,
        liveBuffer: String?,
        line: Int?,
        limit: Int?
    ) async -> FileReadOutcome {
        do {
            // Cheap first pass: a request that does not bound its own result
            // cannot return less than the source, so an oversized source can
            // be refused without reading it.
            if !Self.requestIsBounded(limit: limit) {
                let sourceBytes = liveBuffer.map { $0.utf8.count }
                    ?? (try? target.resourceValues(forKeys: [.fileSizeKey]))?.fileSize
                if let sourceBytes,
                   let refusal = Self.readRefusal(
                       name: target.lastPathComponent, bytes: sourceBytes
                   ) {
                    return .failure(message: refusal)
                }
            }
            let full: String
            if let liveBuffer {
                full = liveBuffer
            } else {
                let data = try Data(contentsOf: target)
                full = String(data: data, encoding: .utf8) ?? ""
            }
            let sliced = sliceLines(full, line: line, limit: limit)
            // Authoritative: whatever was asked for, this is what would be
            // returned, and a generous `limit` can still ask for everything.
            if let refusal = Self.readRefusal(
                name: target.lastPathComponent, bytes: sliced.utf8.count
            ) {
                return .failure(message: refusal)
            }
            let body = try JSONEncoder().encode(ACPFsReadResult(content: sliced))
            return .success(body)
        } catch {
            return .failure(message: error.localizedDescription)
        }
    }

    /// Called from every "user interrupted" code path (Esc, composer Stop
    /// button, toolbar Stop). Sends `session/cancel` over the wire, stops
    /// any pending permission continuation, marks in-flight tool calls as
    /// canceled, posts a system notice, and flips `streamingState` back
    /// to `.idle`. Persists all mutations so they survive a reload.
    func userCancel(confirmingLease: Bool = true) async {
        flushPendingIncomingUpdates(flushQueueWhenBoundaryReady: false)
        session.clearRetryStatus()
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
        if confirmingLease {
            // A former writer that lost the lease must not send a cancel RPC to
            // the agent for a session another instance now owns. The local
            // bookkeeping above (cancelledPromptIDs insert) is fine to keep —
            // it only affects this runner's own sendNow catch path and has no
            // cross-instance side effects.
            guard await hasConfirmedLeaseForSideEffect() else { return }
        }
        onUserCancel?()
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
            let changedIndices = session.cancelInFlightToolCalls()
            session.terminalHost.killAll()
            if holdsLeaseForWrite() {
                _ = persistIndices(Set(changedIndices))
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
        if nativeForkBarrierActive {
            guard !blocks.isEmpty else {
                Task { @MainActor in onPromptFinished?(false) }
                return
            }
            session.enqueue(blocks: blocks, draft: draft)
            persistQueue()
            Task { @MainActor in onPromptFinished?(true) }
            return
        }
        let route = ACPSubmitRoute.resolve(
            intent: intent,
            state: session.transcript.streamingState,
            queueEmpty: session.queue.isEmpty,
            blocksEmpty: blocks.isEmpty,
            hasPendingInput: !session.transcript.pendingUserInputs.isEmpty,
            inFlightSteer: steerInProgress)
        switch route {
        case .noOp:
            // Composer guards empty submits before invoking onSubmit, but
            // tell the caller the submit was rejected so its draft state
            // stays consistent.
            Task { @MainActor in onPromptFinished?(false) }
        case .sendNow:
            sendNow(blocks: blocks, queuedItemId: nil, draft: draft, onPromptFinished: onPromptFinished)
        case .enqueue:
            session.enqueue(blocks: blocks, draft: draft)
            persistQueue()
            // The user's prompt was accepted into the queue — from the
            // composer's perspective this is a successful submission so
            // the persisted draft can be cleared. The actual RPC fires
            // later when the flusher drains the head.
            Task { @MainActor in onPromptFinished?(true) }
        case .steer:
            steer(blocks: blocks, draft: draft, onPromptFinished: onPromptFinished)
        }
    }

    /// Persist the current queue snapshot. Called after every mutation:
    /// enqueue, edit, remove, reorder, head-status flip. Failures are
    /// swallowed — the same pattern as transcript persistence; surfacing
    /// would block the UI for a transient SQLite error and we'd rather
    /// lose a queue snapshot than the user's draft.
    func persistQueue(acknowledging acknowledgement: ACPDurableConsumptionAcknowledgement? = nil) {
        guard holdsLeaseForWrite() else { return }
        let items = session.queue
        let fence = leaseFenceProvider()
        let sessionId = sessionId
        if let acknowledgement {
            enqueuePersistence({ persistence in
                try await persistence.upsertQueue(
                    sessionId: sessionId,
                    items: items,
                    fence: fence
                )
            }, completion: { persisted in
                if persisted == true {
                    acknowledgement()
                }
            })
        } else {
            enqueuePersistence { persistence in
                _ = try await persistence.upsertQueue(
                    sessionId: sessionId,
                    items: items,
                    fence: fence
                )
            }
        }
    }

    /// Persist that the one-time MCP context preamble has been delivered:
    /// clears the pending text and flips `mcpPreambleSent`. Called from
    /// `sendNow` right after the wire prompt that carried the preamble
    /// succeeds — mirrors `persistQueue()`'s fire-and-forget pattern since
    /// losing this write just means the preamble is (harmlessly) resent.
    /// When `holdsLeaseForWrite()` is false this returns early and leaves
    /// the row `pending`: a later hydrate on the writing instance will see
    /// the still-pending row and re-inject the preamble, which is a benign
    /// duplicate delivery — the agent just sees the context text twice.
    private func persistMCPPreambleSent() {
        guard holdsLeaseForWrite() else { return }
        let fence = leaseFenceProvider()
        let sessionId = sessionId
        enqueuePersistence { persistence in
            _ = try await persistence.setMCPPreamble(
                sessionId: sessionId, pendingText: nil, sent: true, fence: fence)
        }
    }

    private func persistForkContextDelivered(
        acknowledging acknowledgement: ACPDurableConsumptionAcknowledgement? = nil
    ) {
        guard holdsLeaseForWrite() else { return }
        let fence = leaseFenceProvider()
        let sessionId = sessionId
        if let acknowledgement {
            enqueuePersistence({ persistence in
                try await persistence.clearForkContextDeliveryPending(
                    targetSessionID: sessionId,
                    fence: fence
                )
            }, completion: { persisted in
                if persisted == true {
                    acknowledgement()
                }
            })
        } else {
            enqueuePersistence { persistence in
                _ = try await persistence.clearForkContextDeliveryPending(
                    targetSessionID: sessionId,
                    fence: fence
                )
            }
        }
    }

    private func persistForkContextDeliveredAndQueue(
        acknowledging acknowledgement: ACPDurableConsumptionAcknowledgement?
    ) {
        guard holdsLeaseForWrite() else { return }
        let items = session.queue
        let fence = leaseFenceProvider()
        let sessionId = sessionId
        enqueuePersistence({ persistence in
            guard try await persistence.clearForkContextDeliveryPending(
                targetSessionID: sessionId,
                fence: fence
            ) else { return false }
            return try await persistence.upsertQueue(
                sessionId: sessionId,
                items: items,
                fence: fence
            )
        }, completion: { persisted in
            if persisted == true {
                acknowledgement?()
            }
        })
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
        guard !nativeForkBarrierActive,
              !steerInProgress,
              session.agentState == .ready,
              activePromptID == nil,
              session.transcript.streamingState == .idle,
              session.transcript.pendingUserInputs.isEmpty,
              let head = session.queue.first,
              head.status == .pending,
              head.lastError == nil
        else { return }
        if case .needsAuth = session.setupState { return }
        let brokerOperationKey = session.markQueueHeadSending()
        persistQueue()
        sendNow(
            blocks: head.blocks,
            queuedItemId: head.id,
            delegatedSource: head.delegatedSource,
            brokerOperationKey: brokerOperationKey
        )
    }

    func beginNativeForkBarrier() async -> Bool {
        guard canBeginNativeForkBarrier,
              await hasConfirmedLeaseForSideEffect(),
              canBeginNativeForkBarrier
        else { return false }
        nativeForkBarrierActive = true
        return true
    }

    func confirmNativeForkBarrier() async -> Bool {
        guard nativeForkBarrierActive else { return false }
        return await hasConfirmedLeaseForSideEffect()
    }

    func endNativeForkBarrier() {
        guard nativeForkBarrierActive else { return }
        nativeForkBarrierActive = false
        flushQueueIfIdle()
    }

    private var canBeginNativeForkBarrier: Bool {
        !nativeForkBarrierActive
            && !steerInProgress
            && session.agentState == .ready
            && activePromptID == nil
            && session.transcript.streamingState == .idle
            && session.transcript.pendingUserInputs.isEmpty
            && session.queue.isEmpty
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

        if nativeForkBarrierActive {
            guard session.forceQueueItem(id: id) else { return }
            persistQueue()
            return
        }

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
        steer(
            blocks: item.blocks,
            delegatedSource: item.delegatedSource,
            recordUserPrompt: !item.transcriptRecorded
        )
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
        delegatedSource: ACPDelegatedPromptSource? = nil,
        recordUserPrompt: Bool = true,
        draft: ACPComposerDraft? = nil,
        onPromptFinished: (@MainActor (_ succeeded: Bool) -> Void)? = nil
    ) {
        flushPendingIncomingUpdates(flushQueueWhenBoundaryReady: false)
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
                    delegatedSource: delegatedSource,
                    recordUserPrompt: recordUserPrompt,
                    draft: draft,
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
        delegatedSource: ACPDelegatedPromptSource? = nil,
        brokerOperationKey: String? = nil,
        recordUserPrompt: Bool = true,
        draft: ACPComposerDraft? = nil,
        onPromptFinished: (@MainActor (_ succeeded: Bool) -> Void)? = nil
    ) {
        flushPendingIncomingUpdates()
        session.clearRetryStatus()
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
            guard await self.hasConfirmedLeaseForSideEffect() else {
                await MainActor.run {
                    if self.activePromptID == promptID {
                        self.activePromptID = nil
                    }
                    self.cancelledPromptIDs.remove(promptID)
                    onPromptFinished?(false)
                }
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
                                                  attachments: Self.attachments(of: blocks),
                                                  delegatedSource: delegatedSource)
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
                self.resetStreamingPersistBuffer()
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
                let pendingPreamble = self.session.pendingMCPPreamble
                let pendingForkContext: String? = {
                    guard let fork = self.session.forkRecord,
                          fork.phase == .ready,
                          fork.mechanism == .transcriptTransfer,
                          fork.contextDeliveryPending
                    else { return nil }
                    return ACPTranscriptMarkdown.forkContext(
                        sourceAgentID: fork.sourceAgentID,
                        messages: Array(self.session.transcript.messages.prefix(fork.inheritedMessageCount))
                    )
                }()
                var wireBlocks = await Self.hydrate(
                    blocks,
                    promptCapabilities: promptCapabilities,
                    worktreePath: self.worktreePath
                )
                // Wire-only context is prepended for the agent and never part
                // of the recorded transcript — recording above used `blocks`.
                var privateBlocks: [ACPContentBlock] = []
                if let pendingPreamble { privateBlocks.append(.text(pendingPreamble)) }
                if let pendingForkContext { privateBlocks.append(.text(pendingForkContext)) }
                wireBlocks.insert(contentsOf: privateBlocks, at: 0)
                guard await self.hasConfirmedLeaseForSideEffect() else {
                    throw CancellationError()
                }
                let promptAcknowledgement = try await self.connection.prompt(
                    sessionId: remoteId,
                    blocks: wireBlocks,
                    brokerOperationKey: brokerOperationKey,
                    acknowledgeDurableConsumption: queuedItemId == nil && pendingForkContext == nil
                )
                await MainActor.run {
                    let isActivePrompt = self.activePromptID == promptID
                    let hasNewerActivePrompt = self.activePromptID != nil && !isActivePrompt
                    let deliveredForkContext = pendingForkContext != nil
                    // The agent received the preamble whenever the RPC above
                    // succeeded, regardless of whether this prompt is still
                    // "active" by the time we get back on the main actor —
                    // guard against a racing change (e.g. a new preamble
                    // queued mid-flight) before clearing.
                    if let pendingPreamble, self.session.pendingMCPPreamble == pendingPreamble {
                        self.session.pendingMCPPreamble = nil
                        self.session.mcpPreambleSent = true
                        self.persistMCPPreambleSent()
                    }
                    if pendingForkContext != nil,
                       var fork = self.session.forkRecord,
                       fork.contextDeliveryPending {
                        fork.contextDeliveryPending = false
                        self.session.forkRecord = fork
                    }
                    if deliveredForkContext {
                        if queuedItemId == nil {
                            self.persistForkContextDelivered(acknowledging: promptAcknowledgement)
                        } else if !isActivePrompt {
                            self.persistForkContextDelivered(acknowledging: promptAcknowledgement)
                        }
                    }
                    if isActivePrompt {
                        self.session.clearRetryStatus()
                        if queuedItemId != nil {
                            _ = self.session.popQueueHead()
                            if deliveredForkContext {
                                self.persistForkContextDeliveredAndQueue(
                                    acknowledging: promptAcknowledgement
                                )
                            } else {
                                self.persistQueue(acknowledging: promptAcknowledgement)
                            }
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
                        self.session.clearRetryStatus()
                        self.flushStreamingPersist()
                        let authReason = wasCancelled ? nil : ACPAuthFailure.message(from: error)
                        let errorMessage = authReason ?? error.localizedDescription
                        if queuedItemId != nil, !wasCancelled, authReason == nil {
                            // Queued send failed naturally — leave the item
                            // at the head with lastError so the bubble shows
                            // Retry. Cancelled queued sends had the item
                            // discarded elsewhere (steer) and don't surface.
                            let terminalBrokerFailure: Bool = {
                                guard brokerOperationKey != nil else { return false }
                                if case ACPClientError.jsonrpc = error {
                                    return true
                                }
                                return false
                            }()
                            self.session.setQueueHeadError(
                                errorMessage,
                                advancesBrokerOperationAttempt: terminalBrokerFailure
                            )
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

    @discardableResult
    func sendRecoveryContext(
        _ prompt: String,
        onCompleted: (@MainActor (_ delivered: Bool) -> Void)? = nil
    ) -> Bool {
        guard !nativeForkBarrierActive else { return false }
        flushPendingIncomingUpdates()
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
                self.resetStreamingPersistBuffer()
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
        return true
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
        // markCompletedOutputBoundary() materialises any held replay candidate
        // (a stranded final chunk); persist the appended rows so they survive
        // detach/reopen — no `ACPSessionUpdate` carries them here.
        let before = session.transcript.messages.count
        session.markCompletedOutputBoundary()
        if session.transcript.messages.count > before {
            persistFromIndex(before)
        }
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
        canWrite()
    }

    /// Cached authority is enough for in-memory updates and persistence fences,
    /// but RPCs and process/file side effects must confirm the token against
    /// SQLite immediately before they run.
    private func hasConfirmedLeaseForSideEffect() async -> Bool {
        guard holdsLeaseForWrite() else { return false }
        return await validateLease()
    }

    private func shouldBatchStreamingPersist(
        for update: ACPSessionUpdate,
        isPromptOwnedBufferedUpdate: Bool,
        hasUnderLeaseBufferedStreamingWrites: Bool
    ) -> Bool {
        guard activePromptID != nil
            || isPromptOwnedBufferedUpdate
            || hasUnderLeaseBufferedStreamingWrites
        else { return false }
        switch session.transcript.streamingState {
        case .sending, .streaming:
            break
        case .idle, .awaitingPermission, .awaitingInput:
            return false
        }
        switch update {
        case .agentMessageChunk, .agentThoughtChunk, .toolCallUpdate, .compactionSummaryChunk:
            return true
        case .userMessageChunk, .toolCall, .compactionUpdate,
             .plan, .availableModelsUpdate,
             .currentModeUpdate, .currentModelUpdate, .sessionInfoUpdate,
             .sessionConfigOptionsUpdate, .availableCommandsUpdate,
             .usageUpdate, .unknown:
            return false
        }
    }

    private func scheduleStreamingPersist(
        _ indices: Set<Int>,
        mayCapturePersistedBases: Bool = true,
        durableConsumptionAcknowledgement: ACPDurableConsumptionAcknowledgement? = nil
    ) {
        guard !indices.isEmpty else {
            durableConsumptionAcknowledgement?()
            return
        }
        // Per-chunk work is intentionally cheap: record the dirty indices and
        // arm the debounce. Encoding the (growing) message and reading its
        // stored payload happen once per debounce window in the flush, not
        // once per streamed chunk.
        //
        // One exception: an already-persisted row this runner has not written
        // yet (loaded from disk, or trimmed from the cache) has no compare-and-
        // swap base. Capture its stored payload NOW — the caller reaches here
        // only after confirming we hold the lease, so this reads our own view,
        // not a future owner's. Deferring to the stand-down freeze would be too
        // late (the row could hold a new owner's payload by then), and skipping
        // it would silently drop a legitimate under-lease update. This reads at
        // most once per such row, never on the hot streaming-tail path (a new
        // trailing row is not yet persisted, so it is written, not read).
        if mayCapturePersistedBases {
            for i in indices {
                capturePersistedBaseIfNeeded(at: i)
            }
        }
        pendingStreamingPersistIndices.formUnion(indices)
        if let durableConsumptionAcknowledgement {
            pendingStreamingPersistAcknowledgements.append(durableConsumptionAcknowledgement)
        }
        for index in indices {
            pendingStreamingPersistRevisions[index, default: 0] += 1
        }
        guard streamingPersistTask == nil else { return }
        streamingPersistTask = Task { @MainActor [weak self] in
            guard let self else { return }
            try? await Task.sleep(nanoseconds: self.streamingPersistDebounceNanos)
            guard !Task.isCancelled else { return }
            self.flushStreamingPersist()
        }
    }

    private func capturePersistedBaseIfNeeded(at index: Int) {
        guard index < persistedMessageCount,
              lastPersistedPayloads[index] == nil,
              !capturingPersistedBaseIndices.contains(index),
              let fence = leaseFenceProvider()
        else { return }
        capturingPersistedBaseIndices.insert(index)
        let id = "msg-\(sessionId)-\(index)"
        enqueuePersistence({ persistence in
            try await persistence.loadMessagePayload(id: id, fence: fence)
        }, completion: { [weak self] payload in
            guard let self else { return }
            self.capturingPersistedBaseIndices.remove(index)
            guard let payload = payload ?? nil else { return }
            self.lastPersistedPayloads[index] = payload
            if self.streamingLeaseLost {
                self.freezeStreamingPersistSnapshots()
                self.persistStreamingPersistSnapshots()
            }
        })
    }

    private func flushStreamingPersist() {
        flushStreamingPersist(requiresLease: true)
    }

    /// Clear streaming-persist buffer state carried over from a prior stream.
    /// A taken-over stream leaves frozen snapshots and a set latch behind; if
    /// this runner later reacquires the lease and sends a fresh prompt, those
    /// stale rows must not resurrect.
    private func resetStreamingPersistBuffer() {
        guard streamingLeaseLost else { return }
        streamingLeaseLost = false
        pendingStreamingPersistIndices.removeAll()
        pendingStreamingPersistRevisions.removeAll()
        streamingPersistInFlightIndices.removeAll()
        pendingStreamingPersistSnapshots.removeAll()
        pendingStreamingPersistAcknowledgements.removeAll()
    }

    /// Bound the compare-and-swap base cache to the recent tail so it can't
    /// grow without limit over a long session.
    private func trimLastPersistedPayloads() {
        let keepFrom = persistedMessageCount - Self.lastPersistedPayloadsWindow
        guard keepFrom > 0, lastPersistedPayloads.count > Self.lastPersistedPayloadsWindow else { return }
        lastPersistedPayloads = lastPersistedPayloads.filter { $0.key >= keepFrom }
    }

    private func flushStreamingPersistOnStop() {
        // During takeover, the lease row may already point at the new owner
        // by the time stand-down stops this runner. Flush once so the debounce
        // buffer is not the only copy of the tail chunks.
        flushStreamingPersist(requiresLease: false)
    }

    /// Flush the buffered streaming rows.
    ///
    /// - If a takeover was already detected mid-stream, only the frozen
    ///   snapshots are safe to write, and only via compare-and-swap.
    /// - Otherwise the live transcript is authoritative: try a lease-gated
    ///   write. If that reveals the lease has since moved, freeze the buffered
    ///   rows so a later stand-down can CAS-write them; when this *is* the
    ///   stand-down flush (`requiresLease == false`), CAS-write them now.
    private func flushStreamingPersist(requiresLease: Bool) {
        streamingPersistTask?.cancel()
        streamingPersistTask = nil
        if streamingLeaseLost {
            persistStreamingPersistSnapshots()
            return
        }
        let indices = pendingStreamingPersistIndices.subtracting(streamingPersistInFlightIndices)
        guard !indices.isEmpty else { return }
        let revisions = Dictionary(uniqueKeysWithValues: indices.map {
            ($0, pendingStreamingPersistRevisions[$0, default: 0])
        })
        let acknowledgements = pendingStreamingPersistAcknowledgements
        pendingStreamingPersistAcknowledgements.removeAll(keepingCapacity: true)
        streamingPersistInFlightIndices.formUnion(indices)
        if persistIndices(indices, requiresLease: true, completion: { [weak self] succeeded in
            guard let self else { return }
            self.streamingPersistInFlightIndices.subtract(indices)
            if succeeded {
                for acknowledgement in acknowledgements {
                    acknowledgement()
                }
                for index in indices where self.pendingStreamingPersistRevisions[index] == revisions[index] {
                    self.pendingStreamingPersistIndices.remove(index)
                    self.pendingStreamingPersistRevisions.removeValue(forKey: index)
                }
                if !self.pendingStreamingPersistIndices.isEmpty, !self.streamingLeaseLost {
                    self.flushStreamingPersist()
                }
                return
            }
            self.freezeStreamingPersistSnapshots()
            self.streamingLeaseLost = true
            self.persistStreamingPersistSnapshots()
        }) {
            return
        }
        streamingPersistInFlightIndices.subtract(indices)
        // The lease moved between the last chunk and this flush. Freeze the
        // buffered rows' current state — every chunk so far arrived while we
        // held the lease — for the stand-down CAS write.
        freezeStreamingPersistSnapshots()
        streamingLeaseLost = true
        persistStreamingPersistSnapshots()
    }

    /// Encode the buffered streaming rows from the live transcript into
    /// compare-and-swap snapshots. Called exactly once, at the moment a
    /// takeover is detected, so the payloads capture the last transcript
    /// state produced while we still held the lease.
    private func freezeStreamingPersistSnapshots() {
        let messages = session.transcript.messages
        for i in pendingStreamingPersistIndices {
            guard i >= 0, i < messages.count else { continue }
            let message = messageForPersistence(messages[i])
            guard let payload = try? ACPMessageCodec.encode(message) else { continue }
            let basePayload: Data?
            // A row may have been created by an earlier queued persistence
            // operation even when `persistedMessageCount` has not caught up.
            // Only a payload captured under our token may authorize a CAS
            // update after takeover; otherwise this remains insert-only.
            if let base = lastPersistedPayloads[i] {
                basePayload = base
            } else if i < persistedMessageCount {
                // Never read a missing base after takeover: that could capture
                // the new owner's payload and make a stale CAS destructive.
                continue
            } else {
                basePayload = nil
            }
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
            if let basePayload = snapshot.basePayload {
                let payload = snapshot.payload
                enqueuePersistence { persistence in
                    _ = try await persistence.compareAndSwapMessagePayload(
                        id: id,
                        payload: payload,
                        expectedPayload: basePayload
                    )
                }
            } else {
                let row = ACPStoredMessage(
                    id: id,
                    sessionId: sessionId,
                    kind: snapshot.kind,
                    seq: Int64(i),
                    payload: snapshot.payload,
                    createdAt: now
                )
                enqueuePersistence { persistence in
                    _ = try await persistence.insertMessageIfMissing(row)
                }
                persistedMessageCount = max(persistedMessageCount, i + 1)
            }
            lastPersistedPayloads[i] = snapshot.payload
            pendingStreamingPersistIndices.remove(i)
            pendingStreamingPersistRevisions.removeValue(forKey: i)
            pendingStreamingPersistSnapshots.removeValue(forKey: i)
        }
        trimLastPersistedPayloads()
        onPersist?()
    }

    /// Persist the specific message rows touched by an `apply()` call.
    /// Use this instead of `persistFromIndex` when the caller can name
    /// exactly which indices changed — a plan or tool-call update may
    /// mutate a row anywhere in the transcript, not just the trailing
    /// one, so the count-delta heuristic in `persistFromIndex` would
    /// write back the wrong row.
    @discardableResult
    func persistIndices(
        _ indices: Set<Int>,
        requiresLease: Bool = true,
        completion: ((Bool) -> Void)? = nil
    ) -> Bool {
        streamingPersistTask?.cancel()
        streamingPersistTask = nil
        guard !requiresLease || holdsLeaseForWrite() else { return false }
        guard !indices.isEmpty else {
            completion?(true)
            return true
        }
        let messages = session.transcript.messages
        let now = Int64(Date().timeIntervalSince1970)
        var rows: [ACPStoredMessage] = []
        for i in indices.sorted() {
            guard i >= 0, i < messages.count else { continue }
            let m = messageForPersistence(messages[i])
            guard let payload = try? ACPMessageCodec.encode(m) else { continue }
            let id = "msg-\(sessionId)-\(i)"
            rows.append(ACPStoredMessage(
                id: id,
                sessionId: sessionId,
                kind: m.kind,
                seq: Int64(i),
                payload: payload,
                createdAt: now
            ))
        }
        let fence = requiresLease ? leaseFenceProvider() : nil
        if !rows.isEmpty {
            let messageRows = rows
            enqueuePersistence({ persistence in
                try await persistence.persistMessages(messageRows, fence: fence)
            }, completion: { [weak self] persisted in
                guard let self else { return }
                guard persisted == true else {
                    completion?(false)
                    return
                }
                self.commitPersistedMessageRows(messageRows)
                completion?(true)
            })
        } else {
            completion?(true)
        }
        return true
    }

    private func messageForPersistence(_ message: ACPMessage) -> ACPMessage {
        message
    }

    private func commitPersistedMessageRows(_ rows: [ACPStoredMessage]) {
        for row in rows {
            let index = Int(row.seq)
            persistedMessageCount = max(persistedMessageCount, index + 1)
            lastPersistedPayloads[index] = row.payload
        }
        trimLastPersistedPayloads()
        onPersist?()
    }

    private func effectiveRemoteHost() -> String? {
        remoteHost ?? (usesRemoteHostRegistry ? RemoteHostRegistry.shared.host(forPath: worktreePath) : nil)
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
        var rows: [ACPStoredMessage] = []
        for i in lowerBound..<messages.count {
            let m = messages[i]
            guard let payload = try? ACPMessageCodec.encode(m) else { continue }
            let id = "msg-\(sessionId)-\(i)"
            rows.append(ACPStoredMessage(
                id: id,
                sessionId: sessionId,
                kind: m.kind,
                seq: Int64(i),
                payload: payload,
                createdAt: now
            ))
        }
        let fence = leaseFenceProvider()
        if !rows.isEmpty {
            let messageRows = rows
            enqueuePersistence({ persistence in
                try await persistence.persistMessages(messageRows, fence: fence)
            }, completion: { [weak self] persisted in
                guard let self, persisted == true else { return }
                self.commitPersistedMessageRows(messageRows)
            })
        }
    }
}
