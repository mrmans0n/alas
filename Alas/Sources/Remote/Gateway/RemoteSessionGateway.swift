import Foundation
import Combine

/// Bridges one remote WebSocket connection to the in-process ACP world.
///
/// Transport-agnostic: it consumes decoded `RemoteClientMessage`s and emits
/// `RemoteServerMessage`s via the `send` closure, so it is fully testable
/// without sockets. Observes the live `ACPTranscript` (Combine) and, on
/// change (coalesced), consumes `ACPTranscriptChangeLog` to emit either an
/// incremental delta (only the messages the log marked dirty) or, when the
/// log reports a structural change or the connection has fallen behind, a
/// fresh tail-window snapshot under a bumped epoch. Inbound permission
/// decisions route to the existing `ACPPermissionPolicy.userDecided(...)`
/// after a first-wins staleness guard.
@MainActor
final class RemoteSessionGateway {
    private let provider: RemoteSessionsProvider
    private let send: (RemoteServerMessage) -> Void
    private var subscriptions: [String: AnyCancellable] = [:]
    private var configSubscriptions: [String: AnyCancellable] = [:]
    private var configCoalesce: [String: Task<Void, Never>] = [:]
    private var lastConfig: [String: RemoteSessionConfig] = [:]
    private var coalesce: [String: Task<Void, Never>] = [:]
    private var sessionListRefresh: Task<Void, Never>?
    private var sessionListGeneration = 0
    private var worktreeListRefresh: Task<Void, Never>?
    private var worktreeListGeneration = 0
    private var syncStates: [String: RemoteTranscriptSync] = [:]
    private var trackedSessions: Set<String> = []
    // Per-session request id of the permission/question prompt we last surfaced,
    // so we can tell the client to dismiss it if it gets resolved elsewhere.
    private var lastPermissionReq: [String: Int] = [:]
    private var lastQuestionReq: [String: Int] = [:]
    private var lastElicitationReq: [String: String] = [:]
    private static let coalesceNanos: UInt64 = 80_000_000  // ~80ms

    init(provider: RemoteSessionsProvider, send: @escaping (RemoteServerMessage) -> Void) {
        self.provider = provider
        self.send = send
    }

    func handle(_ message: RemoteClientMessage) async {
        switch message {
        case .listSessions:
            refreshSessionList()
        case .listWorktrees:
            refreshWorktreeList()
        case .listAgents:
            send(.agentList(agents: provider.remoteAgents()))
        case .createSession(let worktreeId, let agentId):
            let result = await provider.createRemoteSession(worktreeId: worktreeId, agentId: agentId)
            switch result {
            case .success(let summary):
                send(.sessionCreated(session: summary))
                refreshSessionList()
            case .failure(let message):
                send(.createSessionFailed(message: message))
            }
        case .subscribe(let id):
            await provider.hydrateIfNeeded(id: id)
            guard let session = provider.session(for: id) else {
                send(.sessionClosed(sessionId: id))
                return
            }
            beginTracking(id: id, session: session)
            await sendSnapshot(id: id, session: session)
            if let cfg = provider.sessionConfig(for: id) {
                send(.sessionConfig(cfg))
            }
            observe(id: id, session: session)
        case .unsubscribe(let id):
            subscriptions[id] = nil
            configSubscriptions[id] = nil
            configCoalesce[id]?.cancel()
            configCoalesce[id] = nil
            lastConfig[id] = nil
            coalesce[id]?.cancel()
            coalesce[id] = nil
            lastPermissionReq[id] = nil
            lastQuestionReq[id] = nil
            lastElicitationReq[id] = nil
            endTracking(id: id)
            syncStates[id] = nil
        case .permissionDecision(let id, let requestId, let optionId, let persistScope):
            await applyDecision(sessionId: id, requestId: requestId, optionId: optionId, persistScope: persistScope)
        case .questionAnswer(let id, let requestId, let answers):
            applyQuestionAnswer(sessionId: id, requestId: requestId, answers: answers)
        case .elicitationResponse(let id, let requestId, let action, let content):
            applyElicitationResponse(
                sessionId: id,
                requestId: requestId,
                action: action,
                content: content
            )
        case .takeOver(let id):
            await provider.takeOver(for: id)
            // Takeover seizes the writer lease synchronously but mostly mutates
            // lease/agent state, not the transcript — so the objectWillChange
            // delta that normally carries `canDrive` may never fire on an idle
            // session. Push a snapshot now so the client learns canDrive=true
            // immediately and the composer unlocks (otherwise the take-over
            // button stays up and sendPrompt stays blocked until some unrelated
            // transcript mutation happens to occur).
            if let session = provider.session(for: id) {
                await sendSnapshot(id: id, session: session)
            }
        case .sendPrompt(let id, let text, let attachments, let intent):
            // Pre-check the lease BEFORE materializing — `materialize` writes the
            // decoded images to disk, and a non-writer must be rejected without
            // leaving orphan files under acp-attachments/. The manager re-checks
            // isWriter too (TOCTOU defense for a takeover that lands mid-flight),
            // so this is an early-out, not the authoritative gate. Auto-takeover
            // still works: the client sends `takeOver` (synchronous lease seize)
            // before `sendPrompt`, so isWriter is already true here.
            guard provider.isWriter(for: id) else {
                send(.promptRejected(sessionId: id))
                return
            }
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            let hasContent = !trimmed.isEmpty || !attachments.isEmpty
            guard hasContent else {
                send(.promptRejected(sessionId: id))
                return
            }
            guard let materialized = materialize(attachments, for: id) else {
                send(.promptRejected(sessionId: id))   // oversize / non-image
                return
            }
            _ = intent // Task 5 wires steer routing; parked here for now.
            // The manager owns the writer/lease re-check and the eventual
            // delivery result. Emit promptRejected on any failure — refused
            // now (not writer / needs auth) OR a session/prompt RPC that fails
            // later — so the client restores the user's text instead of losing
            // it.
            // True only while the call below is still on the stack. A refusal
            // observed in that window is SYNCHRONOUS — the manager refused
            // before recording the user message (no live session / needs auth),
            // so its attachment files are orphans to delete. A refusal that
            // arrives LATER means `sendNow` already recorded the message with
            // these file URIs (the transcript bubble references them), so we
            // must keep the files.
            var refusalIsSynchronous = true
            await provider.sendPrompt(for: id, text: trimmed, attachments: materialized) { [weak self] accepted in
                guard let self else { return }
                if !accepted {
                    self.send(.promptRejected(sessionId: id))
                    if refusalIsSynchronous { self.discardAttachmentFiles(materialized) }
                }
            }
            refusalIsSynchronous = false
        case .stop(let id):
            // Emergency brake: any authenticated subscriber may cancel the
            // running turn; no writer lease required. Ack immediately so the
            // client flips to "stopping" before the ACP round-trip completes.
            send(.stopPending(sessionId: id))
            await provider.stop(for: id)
        case .setModel(let id, let modelId):
            guard provider.isWriter(for: id) else { return }
            await provider.setModel(for: id, modelId: modelId)
        case .setMode(let id, let modeId):
            guard provider.isWriter(for: id) else { return }
            await provider.setMode(for: id, modeId: modeId)
        case .setAutoRun(let id, let enabled):
            guard provider.isWriter(for: id) else { return }
            await provider.setAutoRun(for: id, enabled: enabled)
        case .renameSession(let id, let title):
            let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return }
            guard provider.renameSession(for: id, title: trimmed) else {
                send(.error(message: "Could not rename session."))
                return
            }
            send(.sessionRenamed(sessionId: id, title: trimmed))
            refreshSessionList()
        case .fetchOlder(let id, let beforeIndex, let limit):
            // Ignore pages requested before a snapshot established sync state.
            guard let session = provider.session(for: id), let state = syncStates[id] else { return }
            let clamped = min(max(limit, RemoteTranscriptSync.pageLimitRange.lowerBound),
                              RemoteTranscriptSync.pageLimitRange.upperBound)
            // A concurrent send (snapshot OR ordinary same-epoch delta) can
            // supersede this page mid-serialize the same way it supersedes a
            // dirty delta — see the capturedGeneration comment below. Unlike
            // a dropped delta/snapshot, though, the client has no fallback
            // recovery for a silently-dropped page: only a snapshot resets
            // its "loading earlier messages" state, and an ordinary delta
            // (the common case here) does not, so simply returning would
            // leave the client stuck showing a spinner forever. Retry
            // instead — bounded so pathological continuous churn can't spin
            // forever either; a truncated tool call's content fetched by an
            // earlier attempt stays cached, so a retry is cheap.
            var attempt = 0
            while true {
                let count = session.transcript.messages.count
                let hi = min(max(beforeIndex, 0), count)
                let lo = max(0, hi - clamped)
                // Capture the generation BEFORE the async serialize below —
                // not just the epoch, since a same-epoch concurrent
                // snapshot (e.g. takeOver, or a client resubscribe with no
                // structural change) also supersedes this page without
                // moving the epoch. If a snapshot lands on this same
                // session while a truncated tool call's full content is
                // being fetched, stamping the page with state read AFTER
                // the await would make it look current and be wrongly
                // accepted instead of dropped.
                let capturedGeneration = state.generation
                let wire = await wireMessages(id: id, session: session, indices: Array(lo..<hi))
                attempt += 1
                guard state.generation == capturedGeneration || attempt > Self.maxFetchOlderAttempts else {
                    continue
                }
                send(.transcriptPage(sessionId: id,
                                     epoch: state.epoch,
                                     firstIndex: lo,
                                     messages: wire))
                break
            }
        // Wire protocol only for now — Task 5 wires the actual queue mutations.
        case .queueForceSend, .queueRemove, .queueRetry, .queueEdit, .queueClear, .queueSteerUndo:
            break
        }
    }

    /// Bound on retrying a superseded `fetchOlder` page before sending
    /// whatever was last computed anyway — the client must always get a
    /// response, never an unbounded wait.
    private static let maxFetchOlderAttempts = 5

    private func beginTracking(id: String, session: ACPSession) {
        guard !trackedSessions.contains(id) else { return }
        trackedSessions.insert(id)
        session.transcript.changeLog.retainTracking()
    }

    private func endTracking(id: String) {
        guard trackedSessions.remove(id) != nil else { return }
        provider.session(for: id)?.transcript.changeLog.releaseTracking()
    }

    private func refreshSessionList() {
        sessionListGeneration += 1
        let generation = sessionListGeneration
        sessionListRefresh?.cancel()
        sessionListRefresh = Task { @MainActor [weak self] in
            guard let self else { return }
            let summaries = await provider.sessionSummaries()
            guard !Task.isCancelled, generation == sessionListGeneration else { return }
            send(.sessionList(sessions: summaries))
        }
    }

    private func refreshWorktreeList() {
        worktreeListGeneration += 1
        let generation = worktreeListGeneration
        worktreeListRefresh?.cancel()
        worktreeListRefresh = Task { @MainActor [weak self] in
            guard let self else { return }
            let worktrees = await provider.remoteWorktrees()
            guard !Task.isCancelled, generation == worktreeListGeneration else { return }
            send(.worktreeList(worktrees: worktrees))
        }
    }

    // MARK: attachment materialization

    private static let maxAttachmentsBytes = 10_000_000
    /// Max images per prompt — parity with the native composer's limit.
    static let maxAttachmentCount = 10

    /// Decode wire attachments to files under acp-attachments/. Returns nil if the
    /// batch violates the size cap or any entry isn't a real image (caller rejects
    /// the send).
    ///
    /// The bytes are sniffed for real PNG/JPEG/GIF/WebP magic — parity with the
    /// native composer's `ACPImageStaging`, instead of trusting the client MIME —
    /// and the sniffed type is what we store. The whole batch is validated +
    /// decoded BEFORE any file is written, so a later bad/oversize entry can't
    /// leave earlier files orphaned; a mid-batch write failure rolls back what
    /// it wrote.
    private func materialize(_ wire: [RemoteAttachment], for sessionId: String) -> [ACPMessage.Attachment]? {
        // Cap the count before decoding/writing (parity with the native composer's
        // maxImagesPerMessage) so one prompt can't spray thousands of tiny files.
        guard wire.count <= Self.maxAttachmentCount else { return nil }
        var decoded: [(data: Data, mimeType: String, name: String?)] = []
        var total = 0
        for a in wire {
            guard let data = Data(base64Encoded: a.dataBase64) else { return nil }
            total += data.count
            guard total <= Self.maxAttachmentsBytes else { return nil }
            guard let mime = ACPImageStaging.sniffMIME(data) else { return nil }   // real image only
            decoded.append((data, mime, a.name))
        }
        var written: [URL] = []
        var out: [ACPMessage.Attachment] = []
        for d in decoded {
            guard let url = provider.writeAttachment(d.data, mimeType: d.mimeType, name: d.name, for: sessionId) else {
                written.forEach { try? FileManager.default.removeItem(at: $0) }
                return nil
            }
            written.append(url)
            out.append(.init(uri: url.absoluteString, name: d.name, mimeType: d.mimeType))
        }
        return out
    }

    /// Best-effort delete of attachment files we wrote but that never made it
    /// into the conversation (the manager refused the prompt after materialize).
    private func discardAttachmentFiles(_ attachments: [ACPMessage.Attachment]) {
        for a in attachments {
            if let url = URL(string: a.uri), url.isFileURL {
                try? FileManager.default.removeItem(at: url)
            }
        }
    }

    /// Tear down all observation (called when the connection closes).
    func close() {
        sessionListRefresh?.cancel()
        sessionListRefresh = nil
        worktreeListRefresh?.cancel()
        worktreeListRefresh = nil
        subscriptions.removeAll()
        configSubscriptions.removeAll()
        configCoalesce.values.forEach { $0.cancel() }
        configCoalesce.removeAll()
        lastConfig.removeAll()
        coalesce.values.forEach { $0.cancel() }
        coalesce.removeAll()
        lastPermissionReq.removeAll()
        lastQuestionReq.removeAll()
        lastElicitationReq.removeAll()
        for id in trackedSessions {
            provider.session(for: id)?.transcript.changeLog.releaseTracking()
        }
        trackedSessions.removeAll()
        syncStates.removeAll()
    }

    // MARK: snapshot / delta

    private func sendSnapshot(id: String, session: ACPSession) async {
        let state = syncState(for: id)
        let log = session.transcript.changeLog
        let count = session.transcript.messages.count
        let first = max(0, count - RemoteTranscriptSync.tailWindow)
        // Capture epoch/version BEFORE the async serialize, but do NOT yet
        // commit sentVersion to `state` — see below. Bumping `generation`
        // here — even when `epoch` itself is unchanged (e.g. a same-epoch
        // takeOver or client resubscribe) — lets a concurrently-suspended
        // delta/page detect that THIS snapshot already superseded it.
        state.epoch = log.epoch
        // Defer committing sentVersion, matching the dirty-delta fix above:
        // writing it now would make the change log treat everything dirty
        // up to this point as "already sent" even if this snapshot ends up
        // discarded below (superseded by a same-epoch dirty delta that
        // raced in during the await) — the pre-snapshot dirty indices would
        // then be silently absent from both sends, never re-offered, since
        // sentVersion already covers them. Only commit once we know this
        // snapshot is actually going out.
        let newSentVersion = log.latestVersion
        // Also defer resetting revision — the same hazard as sentVersion,
        // but on the send side instead of the change-log side. A `.none`
        // content-free delta doesn't participate in the generation ticket
        // (it has no reason to — no message content raced it), so it can
        // still complete and send WHILE this snapshot is suspended, bumping
        // `state.revision` past 0. If we'd already reset it to 0 here, and
        // this snapshot then wins (generation unaffected by a `.none`
        // send), its wire payload hardcodes `revision: 0` while
        // `state.revision` is left at whatever the intervening delta bumped
        // it to — the server's internal counter desyncs from what it
        // actually told the client, and every subsequent delta fails the
        // client's `revision === transcriptMeta.revision + 1` check until
        // another full resync happens. Reset it atomically with the send.
        state.generation += 1
        let capturedGeneration = state.generation
        let wire = await wireMessages(id: id, session: session, indices: Array(first..<count))
        // If another send (a concurrent snapshot or dirty delta) claimed a
        // later generation while this one was suspended fetching truncated
        // tool-call content, THIS snapshot's payload is now stale relative
        // to what the client already has or is about to receive. Sending it
        // anyway would roll the client back — snapshots are applied
        // unconditionally client-side (no epoch/revision ordering check),
        // unlike deltas/pages. Discard; whatever claimed the later
        // generation read fresher state and is authoritative.
        if state.generation == capturedGeneration {
            state.sentVersion = newSentVersion
            state.revision = 0
            send(.transcriptSnapshot(sessionId: id,
                                     streamingState: Self.stateString(session.transcript.streamingState),
                                     canDrive: provider.isWriter(for: id),
                                     messages: wire,
                                     firstIndex: first,
                                     totalCount: count,
                                     epoch: state.epoch,
                                     revision: 0))
        }
        emitPendingPermissionIfAny(id: id, session: session)
        emitPendingQuestionIfAny(id: id, session: session)
        emitPendingElicitationIfAny(id: id, session: session)
    }

    private func syncState(for id: String) -> RemoteTranscriptSync {
        if let s = syncStates[id] { return s }
        let s = RemoteTranscriptSync()
        syncStates[id] = s
        return s
    }

    private func observe(id: String, session: ACPSession) {
        // Replace any existing subscription / pending coalesce for this id so a
        // re-subscribe can't leave an orphaned timer firing one stray delta.
        subscriptions[id]?.cancel()
        coalesce[id]?.cancel()
        // ACPTranscript is an ObservableObject; objectWillChange fires on any
        // @Published mutation (new message, streaming chunk, pending permission).
        subscriptions[id] = session.transcript.objectWillChange.sink { [weak self, weak session] _ in
            guard let self, let session else { return }
            // Coalesce bursts of streaming chunks into one delta.
            self.coalesce[id]?.cancel()
            self.coalesce[id] = Task { @MainActor [weak self, weak session] in
                try? await Task.sleep(nanoseconds: Self.coalesceNanos)
                guard !Task.isCancelled, let self, let session else { return }
                await self.sendDelta(id: id, session: session)
            }
        }
        // Re-emit sessionConfig when the session's config publishers change.
        // ACPSession.objectWillChange fires for ANY @Published change (agentState,
        // queue, etc.), not just config — and BEFORE the value settles. Coalesce
        // a run-loop turn's worth of fires into one next-tick read (zero-delay,
        // mirroring the transcript coalesce above) and dedupe against the last
        // config so non-config churn never reaches the wire.
        configSubscriptions[id]?.cancel()
        configCoalesce[id]?.cancel()
        configSubscriptions[id] = session.objectWillChange.sink { [weak self, weak session] _ in
            guard let self, let session else { return }
            self.configCoalesce[id]?.cancel()
            self.configCoalesce[id] = Task { @MainActor [weak self, weak session] in
                guard !Task.isCancelled, let self, let session else { return }
                let cfg = RemoteSessionConfig(
                    sessionId: id,
                    models: session.availableModels.map { RemoteModelInfo(id: $0.id, name: $0.name) },
                    modes: session.availableModes.map { RemoteModelInfo(id: $0.id, name: $0.name) },
                    currentModel: session.currentModel,
                    currentMode: session.currentMode,
                    autoRunEnabled: session.autoRunEnabled,
                    acceptsImages: session.promptCapabilities.image)
                guard self.lastConfig[id] != cfg else { return }
                self.lastConfig[id] = cfg
                self.send(.sessionConfig(cfg))
            }
        }
    }

    /// Emits an incremental delta: only messages the change log marked
    /// dirty since the last send. Structural transcript changes (prepend,
    /// removal, wholesale replacement) resync via a fresh tail snapshot.
    private func sendDelta(id: String, session: ACPSession) async {
        guard let state = syncStates[id] else { return }
        let log = session.transcript.changeLog
        switch log.changes(since: state.sentVersion) {
        case .resync:
            await sendSnapshot(id: id, session: session)
            return
        case .none:
            // No transcript content changed — this tick was a state flip
            // (streamingState / pending prompt). Send a content-free delta
            // so the client still tracks state.
            state.revision += 1
            send(.transcriptDelta(sessionId: id,
                                  streamingState: Self.stateString(session.transcript.streamingState),
                                  canDrive: provider.isWriter(for: id),
                                  upserts: [],
                                  epoch: state.epoch,
                                  revision: state.revision))
        case .dirty(let indices):
            guard indices.count <= RemoteTranscriptSync.dirtyResnapshotThreshold else {
                await sendSnapshot(id: id, session: session)
                return
            }
            // Capture — but do NOT yet commit — the version this delta will
            // cover. Committing it now (before the await) would make the
            // change log treat `indices` as "already sent" even if this
            // delta ends up discarded below: a later dirty mutation would
            // then compute `changes(since:)` against an already-advanced
            // sentVersion and never re-offer these indices, silently losing
            // them until a full resync. Only write it once we know we're
            // actually sending (see the guard below).
            let newSentVersion = log.latestVersion
            // Claim a generation for this send BEFORE the async serialize
            // below — not just on sendSnapshot. Two overlapping dirty
            // deltas can race the same way a delta and a snapshot can: a
            // still-running (cancelled-but-not-stopped) coalesce Task can
            // suspend on a tool-content fetch while a LATER mutation spawns
            // its own coalesce Task that completes and sends first. Without
            // bumping generation here too, the earlier delta would resume,
            // pass an unchanged-generation check, and send its now-stale
            // content at a higher revision — rolling the client back after
            // it already received the newer delta. Bumping on every send
            // attempt (snapshot OR dirty) makes generation a strict
            // "did anyone else claim a send after me" ticket.
            state.generation += 1
            let capturedGeneration = state.generation
            // A dirty tool call's persisted content may have grown past the
            // cached copy — drop it so serialization re-fetches.
            for index in indices where session.transcript.messages.indices.contains(index) {
                if case .toolCall(let tc) = session.transcript.messages[index] {
                    state.invalidateToolContent(tc.toolCallId)
                }
            }
            let wire = await wireMessages(id: id, session: session, indices: indices)
            guard state.generation == capturedGeneration else { return }
            state.sentVersion = newSentVersion
            state.revision += 1
            send(.transcriptDelta(sessionId: id,
                                  streamingState: Self.stateString(session.transcript.streamingState),
                                  canDrive: provider.isWriter(for: id),
                                  upserts: wire,
                                  epoch: state.epoch,
                                  revision: state.revision))
        }
        emitPendingPermissionIfAny(id: id, session: session)
        emitPendingQuestionIfAny(id: id, session: session)
        emitPendingElicitationIfAny(id: id, session: session)
    }

    private func wireMessages(id: String, session: ACPSession, indices: [Int]) async -> [RemoteWireMessage] {
        var wire: [RemoteWireMessage] = []
        wire.reserveCapacity(indices.count)
        for index in indices {
            // Re-check across awaits: a structural mutation mid-serialize can
            // shrink the array; the epoch bump will resync the client.
            guard session.transcript.messages.indices.contains(index) else { continue }
            let message = session.transcript.messages[index]
            wire.append(Self.toWire(
                message,
                index: index,
                fullToolCallContent: await cachedFullToolCallContent(sessionId: id, message: message)))
        }
        return wire
    }

    private func cachedFullToolCallContent(sessionId: String, message: ACPMessage) async -> String? {
        guard case .toolCall(let toolCall) = message, toolCall.isContentTruncated else { return nil }
        let state = syncState(for: sessionId)
        if let cached = state.cachedToolContent(toolCall.toolCallId) { return cached }
        guard let full = await provider.fullToolCallContent(sessionId: sessionId, toolCallId: toolCall.toolCallId)
        else { return nil }
        state.storeToolContent(toolCall.toolCallId, full)
        return full
    }

    private func emitPendingPermissionIfAny(id: String, session: ACPSession) {
        // Only surface a prompt when the session is genuinely awaiting it. A
        // read-only mirror (no runner) can carry a stale pending* while idle —
        // surfacing that would show a prompt the remote can't actually answer.
        if session.transcript.streamingState == .awaitingPermission,
           let pending = session.transcript.pendingPermission {
            let rid = Self.requestIdInt(pending.id)
            lastPermissionReq[id] = rid
            let tc = pending.params.toolCall
            let payload = RemotePermissionPayload(
                requestId: rid,
                toolName: tc.title ?? tc.kind ?? "tool",
                options: pending.params.options.map {
                    RemotePermissionOption(optionId: $0.optionId, name: $0.name, kind: $0.kind)
                })
            send(.permissionRequest(sessionId: id, payload: payload))
        } else if let rid = lastPermissionReq.removeValue(forKey: id) {
            // A prompt we surfaced was resolved elsewhere (the Mac or another
            // client) — tell the client to dismiss it so it doesn't hang.
            send(.permissionResolved(sessionId: id, requestId: rid))
        }
    }

    private func emitPendingQuestionIfAny(id: String, session: ACPSession) {
        if let pending = Self.queuedQuestion(in: session),
           !pending.params.questions.isEmpty {
            let rid = Self.requestIdInt(pending.id)
            lastQuestionReq[id] = rid
            let payload = RemoteQuestionPayload(
                requestId: rid,
                title: pending.params.title,
                questions: pending.params.questions.map { q in
                    RemoteQuestion(
                        id: q.id,
                        prompt: q.prompt,
                        options: q.options.map { RemoteQuestionOption(id: $0.id, label: $0.label) },
                        allowMultiple: q.allowMultiple == true)
                })
            send(.questionRequest(sessionId: id, payload: payload))
        } else if let rid = lastQuestionReq.removeValue(forKey: id) {
            send(.questionResolved(sessionId: id, requestId: rid))
        }
    }

    private func emitPendingElicitationIfAny(id: String, session: ACPSession) {
        if let pending = session.transcript.pendingUserInputs.first,
           case .elicitation = pending.source {
            let requestId = pending.id.uuidString
            guard lastElicitationReq[id] != requestId else { return }
            lastElicitationReq[id] = requestId
            let mode: String
            let elicitationId: String?
            let url: String?
            switch pending.mode {
            case .form:
                mode = "form"
                elicitationId = nil
                url = nil
            case .url(let request):
                mode = "url"
                elicitationId = request.elicitationId
                url = request.url.absoluteString
            }
            let fields = pending.fields.map { field in
                RemoteElicitationField(
                    key: field.key,
                    type: field.schema.type,
                    title: field.label,
                    description: field.schema.description,
                    required: field.required,
                    minLength: field.schema.minLength,
                    maxLength: field.schema.maxLength,
                    minimum: field.schema.minimum,
                    maximum: field.schema.maximum,
                    minItems: field.schema.minItems,
                    maxItems: field.schema.maxItems,
                    format: field.schema.format,
                    pattern: field.schema.pattern,
                    options: field.schema.options.map {
                        .init(value: $0.const, title: $0.title, description: $0.description)
                    },
                    defaultValue: Self.remoteDefault(field.schema.defaultValue)
                )
            }
            send(.elicitationRequest(
                sessionId: id,
                payload: .init(
                    requestId: requestId,
                    title: pending.title,
                    message: pending.message,
                    mode: mode,
                    fields: fields,
                    elicitationId: elicitationId,
                    url: url
                )
            ))
        } else if let requestId = lastElicitationReq.removeValue(forKey: id) {
            send(.elicitationResolved(sessionId: id, requestId: requestId))
        }
    }

    // MARK: decision

    private func applyDecision(sessionId: String, requestId: Int, optionId: String, persistScope: String?) async {
        guard let session = provider.session(for: sessionId),
              let policy = provider.permissionPolicy(for: sessionId),
              let pending = session.transcript.pendingPermission,
              Self.requestIdInt(pending.id) == requestId          // first-wins guard
        else { return }
        guard let option = pending.params.options.first(where: { $0.optionId == optionId }) else { return }

        // Mirror the local SwiftUI prompt's mapping so remote and local
        // decisions log identically (ACPPermissionPrompt.handle).
        let decision: ACPPermissionDecision = option.kind.hasPrefix("allow") ? .allow : .deny
        let scope: ACPPermissionScopeKind?
        if let persistScope {
            scope = persistScope == "session" ? .session
                  : (persistScope == "project" ? .project : nil)
        } else {
            switch option.kind {
            case "allow_once", "reject_once":     scope = nil
            case "allow_always", "reject_always": scope = .project
            default:                              scope = .session
            }
        }

        // Same scopeKey derivation as ACPTabView.scopeKey(for:).
        let scopeKey = Self.scopeKey(for: pending.params)
        await policy.userDecided(scopeKey: scopeKey, optionId: optionId, decision: decision, persistScope: scope)
        lastPermissionReq[sessionId] = nil
        send(.permissionResolved(sessionId: sessionId, requestId: requestId))
    }

    private func applyQuestionAnswer(sessionId: String, requestId: Int, answers: [RemoteQuestionAnswer]) {
        guard let session = provider.session(for: sessionId),
              let pending = Self.queuedQuestion(in: session),
              Self.requestIdInt(pending.id) == requestId          // first-wins guard
        else { return }
        // Require a non-empty selection for every question and order each by the
        // question's option order — the same completeness rule the local prompt
        // enforces (ACPQuestionPrompt.answeredResponse). Ignore malformed/partial
        // input rather than resuming the agent with vacuous answers.
        let selectionByQuestion = Dictionary(answers.map { ($0.questionId, Set($0.selectedOptionIds)) },
                                             uniquingKeysWith: { $1 })
        var acpAnswers: [ACPQuestionAnswer] = []
        for question in pending.params.questions {
            let selected = selectionByQuestion[question.id] ?? []
            // Keep only ids that are real options for this question. If none
            // survive (empty, or unknown ids from a stale/malicious client),
            // treat the answer as incomplete rather than resuming the agent with
            // a vacuous selection.
            let ordered = question.options.map(\.id).filter { selected.contains($0) }
            guard !ordered.isEmpty else { return }
            acpAnswers.append(ACPQuestionAnswer(questionId: question.id, selectedOptionIds: ordered))
        }
        provider.answerQuestion(
            for: sessionId,
            requestId: pending.id,
            .init(outcome: .answered(answers: acpAnswers))
        )
        lastQuestionReq[sessionId] = nil
        send(.questionResolved(sessionId: sessionId, requestId: requestId))
    }

    private static func queuedQuestion(in session: ACPSession) -> ACPSession.PendingQuestion? {
        guard let head = session.transcript.pendingUserInputs.first else {
            return session.transcript.pendingQuestion
        }
        guard case .cursor(let id, let params) = head.source else { return nil }
        return .init(id: id, params: params)
    }

    private func applyElicitationResponse(
        sessionId: String,
        requestId: String,
        action: String,
        content: [String: ACPElicitationValue]?
    ) {
        guard let token = UUID(uuidString: requestId),
              let session = provider.session(for: sessionId),
              let pending = session.transcript.pendingUserInputs.first,
              pending.id == token,
              case .elicitation = pending.source
        else { return }

        let resolvedAction: ACPUserInputAction
        switch action {
        case "accept":
            let content = content ?? [:]
            guard Self.remoteContent(content, satisfies: pending) else { return }
            resolvedAction = .submit(content)
        case "decline":
            resolvedAction = .decline
        case "cancel":
            resolvedAction = .cancel
        default:
            return
        }
        provider.respondToUserInput(for: sessionId, token: token, action: resolvedAction)
        lastElicitationReq[sessionId] = nil
        send(.elicitationResolved(sessionId: sessionId, requestId: requestId))
    }

    private static func remoteContent(
        _ content: [String: ACPElicitationValue],
        satisfies request: ACPUserInputRequest
    ) -> Bool {
        if case .url = request.mode { return content.isEmpty }
        let fields = Dictionary(uniqueKeysWithValues: request.fields.map { ($0.key, $0) })
        guard content.keys.allSatisfy({ fields[$0] != nil }) else { return false }
        for field in request.fields where field.required {
            guard content[field.key] != nil else { return false }
        }
        for (key, value) in content {
            guard let field = fields[key] else { return false }
            switch (field.schema.type, value) {
            case ("string", .string(let string)):
                guard validRemoteString(string, for: field) else { return false }
            case ("number", .number(let number)):
                guard validRemoteNumber(number, for: field) else { return false }
            case ("number", .integer(let integer)):
                guard validRemoteNumber(Double(integer), for: field) else { return false }
            case ("integer", .integer(let integer)):
                guard validRemoteNumber(Double(integer), for: field) else { return false }
            case ("boolean", .boolean):
                continue
            case ("array", .strings(let selected)):
                let allowed = Set(field.schema.options.map(\.const))
                guard selected.allSatisfy(allowed.contains),
                      field.schema.minItems.map({ selected.count >= $0 }) != false,
                      field.schema.maxItems.map({ selected.count <= $0 }) != false
                else { return false }
            default:
                return false
            }
        }
        return true
    }

    private static func validRemoteString(_ value: String, for field: ACPUserInputField) -> Bool {
        guard field.schema.minLength.map({ value.count >= $0 }) != false,
              field.schema.maxLength.map({ value.count <= $0 }) != false
        else { return false }
        if !field.schema.options.isEmpty,
           !field.schema.options.contains(where: { $0.const == value }) {
            return false
        }
        if let pattern = field.schema.pattern,
           let regex = try? NSRegularExpression(pattern: pattern),
           regex.firstMatch(in: value, range: NSRange(value.startIndex..., in: value)) == nil {
            return false
        }
        switch field.schema.format {
        case "email":
            let parts = value.split(separator: "@", omittingEmptySubsequences: false)
            return parts.count == 2 && parts[1].contains(".")
        case "uri":
            return URL(string: value)?.scheme != nil
        case "date":
            return remoteDateFormatter.date(from: value) != nil
        case "date-time":
            let fractionalFormatter = ISO8601DateFormatter()
            fractionalFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            return fractionalFormatter.date(from: value) != nil
                || ISO8601DateFormatter().date(from: value) != nil
        default:
            return true
        }
    }

    private static func validRemoteNumber(_ value: Double, for field: ACPUserInputField) -> Bool {
        value.isFinite
            && field.schema.minimum.map({ value >= $0 }) != false
            && field.schema.maximum.map({ value <= $0 }) != false
    }

    private static let remoteDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .iso8601)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.isLenient = false
        return formatter
    }()

    private static func remoteDefault(_ value: AnyCodable?) -> ACPElicitationValue? {
        guard let raw = value?.value else { return nil }
        if let value = raw as? Bool { return .boolean(value) }
        if let value = raw as? Int { return .integer(value) }
        if let value = raw as? Double { return .number(value) }
        if let value = raw as? String { return .string(value) }
        if let value = raw as? [String] { return .strings(value) }
        if let value = raw as? [AnyCodable] {
            return .strings(value.compactMap { $0.value as? String })
        }
        return nil
    }

    // MARK: serialization helpers

    static func stateString(_ s: ACPSession.StreamingState) -> String {
        switch s {
        case .idle: return "idle"
        case .sending, .streaming: return "streaming"
        case .awaitingPermission: return "awaitingPermission"
        case .awaitingInput: return "awaitingInput"
        }
    }

    /// Extracts the integer request id. In practice `pendingPermission.id` is
    /// always `.number(0)` (set by ACPPermissionPolicy), so the first-wins guard
    /// distinguishes "this prompt is still pending" from "already resolved"
    /// (pending goes nil) rather than telling sequential requests apart — which
    /// is fine because the agent blocks on each prompt before issuing the next.
    static func requestIdInt(_ id: JSONRPCID) -> Int {
        if case .number(let n) = id { return n }
        return -1
    }

    /// scopeKey used to record a permission decision. Replicates the exact
    /// derivation in `ACPTabView.scopeKey(for:)` so remote and local decisions
    /// land on the same key in `permission_decisions`.
    static func scopeKey(for params: ACPPermissionRequestParams) -> String {
        "tool:\(params.toolCall.title ?? params.toolCall.toolCallId)"
    }

    /// Maps a live ACPMessage to the wire DTO. Simple kinds carry `text`;
    /// structured kinds carry a JSON blob the web client renders specially.
    ///
    /// The id is the message's POSITION, not `ACPMessage.stableId`: a read-only
    /// mirror re-decodes the transcript on every refresh, minting fresh UUIDs
    /// each time (`ACPMessageWire.toMessage`), so the per-message id is not
    /// stable across our full re-snapshots. Position is — the Nth message stays
    /// the Nth — so the client can upsert idempotently by `index` instead of
    /// accumulating duplicate copies. Positional ids stay valid across
    /// incremental deltas too: every index-shifting mutation (prepend,
    /// removal, wholesale replacement) is recorded as *structural* by
    /// `ACPTranscriptChangeLog`, which forces a fresh tail snapshot under a
    /// bumped epoch rather than a delta that could otherwise upsert a stale
    /// index against shifted content.
    static func toWire(
        _ message: ACPMessage,
        index: Int,
        fullToolCallContent: String? = nil
    ) -> RemoteWireMessage {
        let sid = "m\(index)"
        switch message {
        case .user(_, _, let text, let attachments, _):
            // The wire carries user text only; surface attachments as a labelled
            // placeholder so an image-only prompt isn't a blank bubble on the
            // phone (we don't serve the image bytes to the client in v1).
            var parts: [String] = []
            if !text.isEmpty { parts.append(text) }
            parts.append(contentsOf: attachments.map { "🖼 \($0.name ?? "Image")" })
            return .init(stableId: sid, kind: "user", text: parts.joined(separator: "\n\n"), json: nil, index: index)
        case .agent(_, _, let streaming):
            return .init(stableId: sid, kind: "agent", text: streaming.value, json: nil, index: index)
        case .thought(_, _, let streaming):
            return .init(stableId: sid, kind: "thought", text: streaming.value, json: nil, index: index)
        case .systemNotice(_, let text):
            return .init(stableId: sid, kind: "systemNotice", text: text, json: nil, index: index)
        case .toolCall(let call):
            return .init(
                stableId: sid,
                kind: "toolCall",
                text: nil,
                json: Self.encodeJSON(remoteToolCall(call, fullContent: fullToolCallContent)),
                index: index
            )
        case .fileEdit(_, let edit):
            return .init(stableId: sid, kind: "fileEdit", text: nil, json: Self.encodeJSON(edit), index: index)
        case .plan(_, let items):
            return .init(stableId: sid, kind: "plan", text: nil, json: Self.encodeJSON(items), index: index)
        }
    }

    private static func remoteToolCall(
        _ call: ACPMessage.ToolCall,
        fullContent: String? = nil
    ) -> ACPMessage.ToolCall {
        var remote = call
        if let fullContent {
            remote.content = fullContent
        }
        remote.rawOutput = nil
        remote.metadata = nil
        remote.assets = call.assets.map { asset in
            ACPMessage.ToolCallAsset(
                kind: asset.kind,
                data: nil,
                uri: Self.remoteAssetURI(asset.uri),
                mimeType: asset.mimeType,
                name: asset.name
            )
        }
        return remote
    }

    private static func remoteAssetURI(_ uri: String?) -> String? {
        guard let uri else { return nil }
        let normalized = uri.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return normalized.hasPrefix("data:") ? nil : uri
    }

    private static func encodeJSON<T: Encodable>(_ value: T) -> String? {
        guard let data = try? JSONEncoder().encode(value) else { return nil }
        return String(data: data, encoding: .utf8)
    }
}
