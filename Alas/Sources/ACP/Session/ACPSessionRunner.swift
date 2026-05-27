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
    private var updatesTask: Task<Void, Never>?
    private var permissionsTask: Task<Void, Never>?
    private var filesTask: Task<Void, Never>?
    private var seq: Int64 = 0

    init(session: ACPSession, connection: ACPConnection, store: ACPSessionStore,
         sessionId: String, onDirtyCheck: ((String) -> Bool)? = nil) {
        self.session = session
        self.connection = connection
        self.store = store
        self.sessionId = sessionId
        self.onDirtyCheck = onDirtyCheck
        self.policy = ACPPermissionPolicy(
            session: session,
            log: ACPPermissionDecisionLog(store: store)
        )
        if let stored = try? store.loadMessages(sessionId: sessionId) {
            self.seq = Int64(stored.count)
        }
    }

    func start() {
        updatesTask = Task { [weak self] in
            guard let self else { return }
            for await u in self.connection.client.incomingUpdates {
                await MainActor.run {
                    let before = self.session.messages.count
                    self.session.apply(u.update)
                    self.persistFromIndex(before)
                }
            }
            // Stream finished — process exited unexpectedly.
            await MainActor.run {
                self.session.disconnected = true
                self.session.attached = false
                self.session.streamingState = .idle
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

        filesTask = Task { @MainActor [weak self] in
            guard let self else { return }
            let writer = ACPFileWriter(worktreeRoot: URL(fileURLWithPath: self.session.worktreeId))
            for await req in self.connection.client.fileRequests {
                switch req {
                case .read(let id, let params):
                    do {
                        let data = try Data(contentsOf: URL(fileURLWithPath: params.path))
                        let result = ACPFsReadResult(content: String(data: data, encoding: .utf8) ?? "")
                        let body = try JSONEncoder().encode(result)
                        self.connection.client.respondToFileRequest(id: id, result: .success(body))
                    } catch {
                        self.connection.client.respondToFileRequest(
                            id: id,
                            result: .failure(.init(code: -32000, message: error.localizedDescription, data: nil)))
                    }
                case .write(let id, let params):
                    if self.onDirtyCheck?(params.path) == true {
                        self.appendAndPersistSystemNotice("Agent wrote to \(URL(fileURLWithPath: params.path).lastPathComponent) — you have unsaved changes in this file.")
                    }
                    do {
                        let res = try writer.write(path: params.path, content: params.content)
                        self.appendAndPersistFileEdit(.init(path: params.path, added: res.added, removed: res.removed))
                        let body = try JSONEncoder().encode(ACPFsWriteResult())
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
    }

    func stop() {
        updatesTask?.cancel()
        permissionsTask?.cancel()
        filesTask?.cancel()
    }

    /// Called from every "user interrupted" code path (Esc, composer Stop
    /// button, toolbar Stop). Sends `session/cancel` over the wire, stops
    /// any pending permission continuation, marks in-flight tool calls as
    /// canceled, posts a system notice, and flips `streamingState` back
    /// to `.idle`. Persists all mutations so they survive a reload.
    func userCancel() async {
        let remoteId = session.remoteSessionId ?? sessionId
        try? await connection.cancel(sessionId: remoteId)
        await MainActor.run {
            policy.userCancelled()
            let changedIndices = session.cancelInFlightToolCalls()
            for i in changedIndices {
                let m = session.messages[i]
                if let payload = try? ACPMessageCodec.encode(m) {
                    let id = "msg-\(sessionId)-\(i)"
                    try? store.updateMessagePayload(id: id, payload: payload)
                }
            }
            appendAndPersistSystemNotice("Interrupted by user.")
            session.streamingState = .idle
        }
    }
}

extension ACPSessionRunner {
    func send(text: String, attachments: [ACPMessage.Attachment]) {
        var blocks: [ACPContentBlock] = [.text(text)]
        for a in attachments {
            blocks.append(.resourceLink(uri: a.uri, name: a.name))
        }
        Task { [weak self] in
            guard let self else { return }
            await MainActor.run {
                let before = self.session.messages.count
                self.session.recordUserPrompt(text: text, attachments: attachments)
                self.persistFromIndex(before)
                self.session.streamingState = .sending
            }
            do {
                let remoteId = self.session.remoteSessionId ?? self.sessionId
                try await self.connection.prompt(sessionId: remoteId, blocks: blocks)
                await MainActor.run { self.session.streamingState = .streaming }
            } catch {
                await MainActor.run {
                    self.session.lastError = "prompt failed: \(error.localizedDescription)"
                    self.session.streamingState = .idle
                }
            }
        }
    }

    /// Append a system notice to the session AND persist it. Use this
    /// instead of `session.appendSystemNotice` directly so the message
    /// survives a session reload.
    func appendAndPersistSystemNotice(_ text: String) {
        let before = session.messages.count
        session.appendSystemNotice(text)
        persistFromIndex(before)
    }

    /// Append a file-edit card to the session AND persist it.
    func appendAndPersistFileEdit(_ edit: ACPMessage.FileEdit) {
        let before = session.messages.count
        session.appendFileEdit(edit)
        persistFromIndex(before)
    }
}

extension ACPSessionRunner {
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
        let messages = session.messages
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
        let existingCount = (try? store.loadMessages(sessionId: sessionId).count) ?? 0
        for i in lowerBound..<messages.count {
            let m = messages[i]
            guard let payload = try? ACPMessageCodec.encode(m) else { continue }
            let id = "msg-\(sessionId)-\(i)"
            if i < existingCount {
                try? store.updateMessagePayload(id: id, payload: payload)
            } else {
                try? store.appendMessage(sessionId: sessionId, id: id, kind: m.kind,
                                         seq: Int64(i), payload: payload, createdAt: now)
            }
        }
    }
}
