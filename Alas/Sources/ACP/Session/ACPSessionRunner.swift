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
    private var updatesTask: Task<Void, Never>?
    private var permissionsTask: Task<Void, Never>?
    private var filesTask: Task<Void, Never>?
    private var seq: Int64 = 0

    init(session: ACPSession, connection: ACPConnection, store: ACPSessionStore,
         sessionId: String, worktreePath: String,
         onDirtyCheck: ((String) -> Bool)? = nil,
         onLiveBufferRead: ((String) -> String?)? = nil)
    {
        self.session = session
        self.connection = connection
        self.store = store
        self.sessionId = sessionId
        self.worktreePath = worktreePath
        self.onDirtyCheck = onDirtyCheck
        self.onLiveBufferRead = onLiveBufferRead
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
                        self.appendAndPersistFileEdit(.init(path: storedPath, added: res.added, removed: res.removed))
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
    }

    func stop() {
        updatesTask?.cancel()
        permissionsTask?.cancel()
        filesTask?.cancel()
    }

    /// Re-upsert the session's persistence row to capture changes to
    /// title / model / mode / autoRun that the runner mutated directly.
    /// `ACPSessionManager.persist` does the same thing plus a recent-
    /// list refresh; the runner skips that because it has no manager
    /// handle, and the next open via the manager picks up the new row.
    func persistSessionRow() {
        guard let row = try? store.loadSession(id: sessionId) else { return }
        let now = Int64(Date().timeIntervalSince1970)
        try? store.upsertSession(.init(
            id: row.id, agentId: row.agentId, title: session.title,
            currentModel: session.currentModel, currentMode: session.currentMode,
            autoRun: session.autoRunEnabled,
            createdAt: row.createdAt, updatedAt: now,
            lastOpenedAt: row.lastOpenedAt, archived: row.archived
        ))
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
                let titleBefore = self.session.title
                self.session.recordUserPrompt(text: text, attachments: attachments)
                self.persistFromIndex(before)
                // First-prompt path auto-renames the session to the
                // prompt prefix. Persist the row so the new title
                // survives a reload — without this the toolbar showed
                // the derived name in-memory but the SQLite row stayed
                // on "New session" until the user manually renamed.
                if self.session.title != titleBefore {
                    self.persistSessionRow()
                }
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
