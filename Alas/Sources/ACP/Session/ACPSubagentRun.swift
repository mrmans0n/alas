import Combine
import Foundation

/// One native subagent (child ACP session) owned by a parent session.
///
/// Deliberately much smaller than `ACPTranscript`: a child transcript is
/// never the scroll root, is not forkable, and is not backfilled in
/// windows, so none of the replay-dedup, anchor or window machinery
/// applies. What it does share with the parent is tool-call projection —
/// that goes through `ACPSession.makeToolCall` / `applyToolCallUpdate` so
/// a child's cards can never render differently from the parent's.
///
/// Observable in its own right so an expanded child row re-renders on its
/// own streaming chunks without invalidating the parent's message list.
@MainActor
final class ACPSubagentRun: ObservableObject, Identifiable {
    let subagentSessionId: String
    nonisolated var id: String { subagentSessionId }

    @Published private(set) var name: String?
    @Published private(set) var task: String?
    @Published private(set) var state: ACPSubagentState
    @Published private(set) var capabilities: ACPSubagentCapabilities
    /// Diagnostic text from the most recent failure, when the agent
    /// provided one (OpenCode's status notification; the standard
    /// `subagent_state_update` carries none). Sticky across further
    /// updates that don't themselves carry a new error, so the reason a
    /// row failed survives whatever housekeeping update lands after it.
    @Published private(set) var lastError: String?
    /// The child's own transcript, in arrival order.
    @Published private(set) var messages: [ACPMessage] = []

    /// Set the first time a terminal state lands, so the row can show how
    /// long the child ran without re-deriving it from message timestamps.
    private(set) var startedAt: Date
    private(set) var finishedAt: Date?

    private var createdAts: [Int] = []
    /// The SQL `seq` for the message at the SAME array position. See
    /// `restore` for why this can't just be the array index.
    private var seqs: [Int64] = []
    private var nextSeq: Int64 = 0
    /// Identities (message id / tool-call id) already reconciled once in
    /// the CURRENT `session/load` replay window. See `applyReplayed`.
    private var replayTouchedIdentities: Set<ReplayIdentity> = []
    private enum ReplayIdentity: Hashable {
        case text(StreamKind, String)
        case user(String)
        /// Stands in for `.text` when the agent omits `messageId`. Keyed by
        /// kind only, since the live model itself has no finer identity for
        /// id-less chunks — they all extend whatever the trailing row of
        /// that kind is (`legacyTrailingIndex`).
        case legacyText(StreamKind)
    }

    init(
        subagentSessionId: String,
        name: String? = nil,
        task: String? = nil,
        state: ACPSubagentState = .running,
        capabilities: ACPSubagentCapabilities = .init(),
        lastError: String? = nil,
        startedAt: Date = Date()
    ) {
        self.subagentSessionId = subagentSessionId
        self.name = name
        self.task = task
        self.state = state
        self.capabilities = capabilities
        self.lastError = lastError
        self.startedAt = startedAt
    }

    /// Title shown on the collapsed row.
    var displayName: String {
        if let name, !name.isEmpty { return name }
        return "Subagent"
    }

    var isRunning: Bool { !state.isTerminal }

    /// Merges a (possibly repeated) spawn announcement. OpenCode has no
    /// explicit spawn message, so Alas synthesizes one for every child
    /// notification — this must therefore be idempotent, and must never
    /// resurrect a child that already reported a terminal state.
    func merge(spawn: ACPSubagentSpawn) {
        if let incoming = spawn.name, !incoming.isEmpty, incoming != name {
            name = incoming
        }
        if let incoming = spawn.task, !incoming.isEmpty, incoming != task {
            task = incoming
        }
        if spawn.capabilities != .init(), spawn.capabilities != capabilities {
            capabilities = spawn.capabilities
        }
    }

    /// Adopts the facts persisted on the parent row. Used when a session is
    /// re-hydrated (open, or a read-only mirror's refresh) so an existing
    /// run keeps its identity — and therefore the row's expanded state —
    /// instead of being replaced wholesale.
    func adopt(_ descriptor: ACPSubagentRowDescriptor, startedAt: Date?) {
        if name != descriptor.name { name = descriptor.name }
        if task != descriptor.task { task = descriptor.task }
        if state != descriptor.state { state = descriptor.state }
        if capabilities != descriptor.capabilities { capabilities = descriptor.capabilities }
        if lastError != descriptor.lastError { lastError = descriptor.lastError }
        if let startedAt { self.startedAt = startedAt }
    }

    func apply(state newState: ACPSubagentState, error: String? = nil, at timestamp: Date = Date()) {
        // Captured ahead of the unchanged-state guard: OpenCode can resend
        // the SAME terminal state with diagnostic text a later notification
        // didn't carry, and a non-empty error is never worth discarding.
        if let error, !error.isEmpty { lastError = error }
        guard state != newState else { return }
        state = newState
        if newState.isTerminal {
            finishedAt = timestamp
        } else {
            finishedAt = nil
        }
    }

    /// Applies one child-scoped `session/update`, returning the indices of
    /// the child transcript rows it touched so the caller can persist
    /// exactly those.
    @discardableResult
    func apply(_ update: ACPSessionUpdate, at timestamp: Date = Date()) -> Set<Int> {
        switch update {
        case .agentMessageChunk(let chunk):
            return appendStreaming(
                text: Self.text(of: chunk.content),
                kind: .agent,
                messageId: chunk.messageId,
                phase: chunk.phase,
                metadata: chunk.metadata,
                at: timestamp)
        case .agentThoughtChunk(let chunk):
            return appendStreaming(
                text: Self.text(of: chunk.content),
                kind: .thought,
                messageId: chunk.messageId,
                phase: chunk.phase,
                metadata: chunk.metadata,
                at: timestamp)
        case .userMessageChunk(let chunk):
            // The task handed to the child. Rendered so the reader can see
            // what it was actually asked, not just the spawn's summary.
            //
            // A prompt arrives as one update per content block, so blocks
            // sharing a `messageId` extend one bubble rather than opening
            // a new one each time, and an image or resource block carries
            // its attachment instead of vanishing as empty text.
            let text = Self.text(of: chunk.content)
            let attachments = ACPSessionRunner.attachments(of: [chunk.content])
            guard !text.isEmpty || !attachments.isEmpty else { return [] }
            if let messageId = chunk.messageId,
               let index = userIndex(messageId: messageId),
               case .user(let id, _, let existingText, let existingAttachments, let source) = messages[index] {
                messages[index] = .user(
                    id: id,
                    messageId: messageId,
                    text: existingText + text,
                    attachments: existingAttachments + attachments.filter {
                        !existingAttachments.contains($0)
                    },
                    delegatedSource: source)
                return [index]
            }
            return [append(.user(
                id: UUID(),
                messageId: chunk.messageId,
                text: text,
                attachments: attachments), at: timestamp)]
        case .toolCall(let payload):
            return [append(
                .toolCall(ACPSession.makeToolCall(from: payload, at: timestamp)),
                at: timestamp)]
        case .toolCallUpdate(let update):
            guard let index = toolCallIndex(id: update.toolCallId),
                  case .toolCall(var tc) = messages[index] else { return [] }
            ACPSession.applyToolCallUpdate(update, to: &tc, at: timestamp)
            messages[index] = .toolCall(tc)
            return [index]
        case .plan(let entries):
            let items = entries.map { ACPMessage.PlanItem(content: $0.content, status: $0.status) }
            if let index = messages.lastIndex(where: {
                if case .plan = $0 { return true }
                return false
            }), case .plan(let existingId, _) = messages[index] {
                messages[index] = .plan(id: existingId, items)
                return [index]
            }
            return [append(.plan(id: UUID(), items), at: timestamp)]
        case .availableModelsUpdate, .currentModeUpdate, .currentModelUpdate,
             .sessionConfigOptionsUpdate, .availableCommandsUpdate, .usageUpdate,
             .sessionInfoUpdate, .compactionUpdate, .compactionSummaryChunk,
             .notice, .subagentSpawned, .subagentStateUpdate, .unknown:
            // Session-level state of a child session has no UI of its own:
            // the child has no composer, model picker, context ring or
            // notice banner.
            return []
        }
    }

    /// Reconciles one child-scoped `session/update` received while
    /// `session/load` replay is suppressed.
    ///
    /// Persistence of child rows is NOT batched/debounced the way the
    /// parent's streamed text is (see `ACPSessionRunner.applySubagentUpdate`),
    /// but it is still asynchronous — a queued write can be in flight when
    /// the app quits. `session/load` then replays the agent's own history,
    /// which is authoritative and complete for every row it names. Simply
    /// dropping that replay (the pre-existing behaviour) is right for the
    /// common case — nothing was lost, the write landed — but silently
    /// loses content in the crash-before-flush case.
    ///
    /// So the FIRST replayed touch of an existing row resets it (discarding
    /// whatever hydration produced for that specific row only), then
    /// reconciliation reuses the ordinary live-merge path to rebuild it
    /// from what replay actually sends. A row that already matched ends up
    /// identical; a row that lost content is recovered; a row hydration
    /// never had at all (an entirely missing message) is created exactly
    /// as the live path would. A SECOND replayed touch of the same
    /// identity extends the just-rebuilt row rather than resetting again.
    ///
    /// Tool calls need no reset step: a `.toolCall` payload during replay
    /// is upserted by id (replacing an existing row, creating a missing
    /// one), which is naturally idempotent however many times the same id
    /// is replayed, and `.toolCallUpdate` already looks its target up by id
    /// at any position — the ordinary `apply(_:at:)` path suffices for both.
    @discardableResult
    func applyReplayed(_ update: ACPSessionUpdate, at timestamp: Date = Date()) -> Set<Int> {
        switch update {
        case .agentMessageChunk(let chunk):
            resetTextRowOnFirstReplayTouch(kind: .agent, messageId: chunk.messageId)
        case .agentThoughtChunk(let chunk):
            resetTextRowOnFirstReplayTouch(kind: .thought, messageId: chunk.messageId)
        case .userMessageChunk(let chunk):
            resetUserRowOnFirstReplayTouch(messageId: chunk.messageId)
        case .toolCall(let payload):
            // Upsert by id rather than delegating to `apply(_:at:)`, which
            // always APPENDS a `.toolCall` payload — correct live (an
            // adapter announces a given id once), wrong on replay (the
            // announcement itself is replayed, and appending would
            // duplicate a row hydration already restored).
            if let index = toolCallIndex(id: payload.toolCallId), case .toolCall(let existing) = messages[index] {
                var fresh = ACPSession.makeToolCall(from: payload, at: timestamp)
                // `makeToolCall` derives timing from THIS payload alone
                // (in-progress starts now, otherwise nothing), which is
                // right for a first announcement but wrong for a replayed
                // one: keep whatever the restored row already recorded,
                // falling back to the fresh value only for a row that had
                // none — the "never reached storage" recovery case.
                fresh.executionStartedAt = existing.executionStartedAt ?? fresh.executionStartedAt
                fresh.executionFinishedAt = existing.executionFinishedAt ?? fresh.executionFinishedAt
                messages[index] = .toolCall(fresh)
                return [index]
            }
        default:
            break
        }
        return apply(update, at: timestamp)
    }

    /// Called once per `session/load` replay window so an identity touched
    /// in an EARLIER window (this run outliving more than one reattach)
    /// doesn't suppress a reset it should get in this one.
    func beginReplayReconciliation() {
        replayTouchedIdentities.removeAll()
    }

    func endReplayReconciliation() {
        replayTouchedIdentities.removeAll()
    }

    /// Restores a persisted child transcript. Replaces whatever is in
    /// memory, so hydration is idempotent across repeated loads.
    ///
    /// `seqs` defaults to array position for callers that never persist
    /// (tests constructing a run directly). Production hydration always
    /// passes the ACTUAL stored `seq` values: persistence can leave gaps —
    /// one write in a sequence fails while a later one succeeds — and this
    /// array can therefore be non-contiguous even though `messages` itself
    /// is a dense, compacted list.
    func restore(
        messages restored: [ACPMessage],
        createdAts timestamps: [Date],
        seqs storedSeqs: [Int64]? = nil
    ) {
        messages = restored
        createdAts = timestamps.map { Int($0.timeIntervalSince1970) }
        seqs = storedSeqs ?? Array(0..<Int64(restored.count))
        nextSeq = (seqs.max() ?? -1) + 1
        if let first = timestamps.first { startedAt = min(startedAt, first) }
    }

    func createdAt(at index: Int) -> Date {
        guard index >= 0, index < createdAts.count else { return startedAt }
        return Date(timeIntervalSince1970: TimeInterval(createdAts[index]))
    }

    /// The SQL `seq` the row at `index` is stored under (or should be
    /// stored under, for a row appended since the last restore). NOT the
    /// same as `index` once persistence has left a gap — see `restore`.
    func seq(at index: Int) -> Int64 {
        guard index >= 0, index < seqs.count else { return Int64(index) }
        return seqs[index]
    }

    // MARK: - Private

    private enum StreamKind {
        case agent
        case thought
    }

    private func appendStreaming(
        text: String,
        kind: StreamKind,
        messageId: String?,
        phase: ACPMessagePhase?,
        metadata: AnyCodable?,
        at timestamp: Date
    ) -> Set<Int> {
        guard !text.isEmpty else { return [] }
        if let index = trailingIndex(of: kind, messageId: messageId) {
            switch messages[index] {
            case .agent(_, _, let buffer), .thought(_, _, let buffer):
                buffer.append(text)
                buffer.adopt(phase: phase, metadata: metadata)
                return [index]
            default:
                break
            }
        }
        let buffer = StreamingText(text, phase: phase, metadata: metadata)
        let message: ACPMessage = switch kind {
        case .agent: .agent(id: UUID(), messageId: messageId, buffer)
        case .thought: .thought(id: UUID(), messageId: messageId, buffer)
        }
        return [append(message, at: timestamp)]
    }

    /// The row a chunk extends.
    ///
    /// With a `messageId` the whole child transcript is searched for that
    /// id, exactly as the parent transcript's message-id index does:
    /// agents interleave ids (a commentary stream resuming after a final
    /// answer chunk, say), so stopping at the newest non-matching row
    /// would split one logical message across several rows.
    ///
    /// Without one there is no identity to match on, so the chunk extends
    /// the trailing row of its kind — and only while nothing has closed
    /// the run, since a tool call or a new prompt starts a fresh bubble.
    private func trailingIndex(of kind: StreamKind, messageId: String?) -> Int? {
        guard let messageId else { return legacyTrailingIndex(of: kind) }
        for index in stride(from: messages.count - 1, through: 0, by: -1) {
            switch messages[index] {
            case .agent(_, let id, _) where kind == .agent && id == messageId:
                return index
            case .thought(_, let id, _) where kind == .thought && id == messageId:
                return index
            default:
                continue
            }
        }
        return nil
    }

    /// The child's prompt bubble carrying `messageId`, if it is still the
    /// open one. Bounded by the newest row so a later prompt reusing an id
    /// cannot reopen an older bubble.
    private func userIndex(messageId: String) -> Int? {
        for index in stride(from: messages.count - 1, through: 0, by: -1) {
            guard case .user(_, let id, _, _, _) = messages[index] else { continue }
            return id == messageId ? index : nil
        }
        return nil
    }

    /// On the first replayed touch of `messageId`, blanks whatever row
    /// already carries it — if any — so the normal live-merge path that
    /// runs right after in `applyReplayed` rebuilds it purely from what
    /// replay sends, rather than appending on top of a possibly-stale
    /// hydrated value. A later touch of the same identity in this same
    /// replay window is a no-op here, since the row is already mid-rebuild.
    private func resetTextRowOnFirstReplayTouch(kind: StreamKind, messageId: String?) {
        guard let messageId else {
            // No per-message identity to key on — an agent that omits
            // `messageId` gives every chunk of a kind the SAME identity in
            // the live model too (`legacyTrailingIndex` always extends the
            // trailing row), so the reset is scoped the same way: once per
            // kind per replay window, on the trailing row of that kind.
            guard replayTouchedIdentities.insert(.legacyText(kind)).inserted,
                  let index = legacyTrailingIndex(of: kind)
            else { return }
            resetTextRow(at: index, kind: kind, messageId: nil)
            return
        }
        guard replayTouchedIdentities.insert(.text(kind, messageId)).inserted,
              let index = trailingIndex(of: kind, messageId: messageId)
        else { return }
        resetTextRow(at: index, kind: kind, messageId: messageId)
    }

    private func resetTextRow(at index: Int, kind: StreamKind, messageId: String?) {
        switch (kind, messages[index]) {
        case (.agent, .agent(let id, _, _)):
            messages[index] = .agent(id: id, messageId: messageId, StreamingText())
        case (.thought, .thought(let id, _, _)):
            messages[index] = .thought(id: id, messageId: messageId, StreamingText())
        default:
            break
        }
    }

    /// Companion to `resetTextRowOnFirstReplayTouch` for the child's prompt
    /// bubble.
    private func resetUserRowOnFirstReplayTouch(messageId: String?) {
        guard let messageId else { return }
        guard replayTouchedIdentities.insert(.user(messageId)).inserted else { return }
        guard let index = userIndex(messageId: messageId),
              case .user(let id, _, _, _, let source) = messages[index]
        else { return }
        messages[index] = .user(id: id, messageId: messageId, text: "", attachments: [], delegatedSource: source)
    }

    /// A tool-call row for `id`, at any position — unlike the merge lookups
    /// above, a replayed (or updated) tool call must be found regardless of
    /// what has been appended after it.
    private func toolCallIndex(id: String) -> Int? {
        messages.lastIndex {
            if case .toolCall(let tc) = $0 { return tc.toolCallId == id }
            return false
        }
    }

    private func legacyTrailingIndex(of kind: StreamKind) -> Int? {
        for index in stride(from: messages.count - 1, through: 0, by: -1) {
            switch messages[index] {
            case .agent:
                return kind == .agent ? index : nil
            case .thought:
                return kind == .thought ? index : nil
            case .toolCall, .user, .fileEdit:
                return nil
            case .plan, .systemNotice:
                continue
            }
        }
        return nil
    }

    private func append(_ message: ACPMessage, at timestamp: Date) -> Int {
        messages.append(message)
        createdAts.append(Int(timestamp.timeIntervalSince1970))
        seqs.append(nextSeq)
        nextSeq += 1
        return messages.count - 1
    }

    private static func text(of block: ACPContentBlock) -> String {
        if case .text(let value) = block { return value }
        return ""
    }
}
