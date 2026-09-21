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

    /// Seq space reserved below a persisted row's own seq for a run of
    /// consecutive missing PREFIX rows recovered ahead of it — see
    /// `insertRecovered`. Far larger than any realistic number of rows a
    /// single crash window could have dropped.
    private static let prefixRecoverySeqReserve: Int64 = 1_000_000

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
    }
    /// The identified prompt row CURRENTLY open for replay continuation
    /// (further blocks of the SAME message), if any — mirrors
    /// `legacyOpenRun`/`legacyOpenUserRun` for id-less rows, except keyed
    /// by the id itself rather than "trailing row of this kind", since two
    /// DIFFERENT turns can reuse the same `messageId` and must not collapse
    /// into the same row just because the id matches. Closed by
    /// `closeLegacyRuns` whenever anything else (a different id, an id-less
    /// prompt, a tool call, a text chunk) closes the turn boundary.
    private var openIdentifiedUserRun: (messageId: String, index: Int)?
    /// How many separate turns reusing the SAME `messageId` have been
    /// STARTED so far this replay window — indexes into that id's own
    /// chronological list of existing rows (`identifiedUserCandidates`)
    /// when a NEW (non-continuation) turn needs a target, exactly like
    /// `legacyRunOrdinal` does for id-less rows.
    private var replayIdentifiedUserOrdinal: [String: Int] = [:]
    /// Array position replay reconciliation has reached, in chronological
    /// order — a row recovered because it's genuinely missing (never
    /// reached storage) is INSERTED here rather than appended, so it lands
    /// in its correct position relative to rows on either side instead of
    /// always at the tail, and gets a `seq` between its new neighbours
    /// instead of always the highest unused one. Advanced past whichever
    /// row every reconciled update (matched OR recovered) resolves to.
    private var replayCursor = 0
    /// Array index of the id-less run of each kind CURRENTLY open for
    /// replay, if any — id-less rows have no identity beyond "the trailing
    /// row of this kind" (mirroring `legacyTrailingIndex`), so a SECOND
    /// historical run of the same kind needs its own explicit open/closed
    /// tracking rather than reusing that trailing search, which would
    /// always find the array's overall newest row regardless of which
    /// chronological run is actually being replayed.
    private var legacyOpenRun: [StreamKind: Int] = [:]
    /// How many separate id-less runs of each kind have been STARTED so
    /// far this window — indexes into that kind's own chronological list
    /// of existing id-less rows when a NEW run needs a target.
    private var legacyRunOrdinal: [StreamKind: Int] = [:]
    /// Companions to `legacyOpenRun`/`legacyRunOrdinal` for id-less user
    /// prompts, which aren't keyed by `StreamKind`.
    private var legacyOpenUserRun: Int?
    private var legacyUserRunOrdinal = 0

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

    func apply(
        state newState: ACPSubagentState, error: String? = nil, at timestamp: Date = Date(),
        replaying: Bool = false
    ) {
        // Captured ahead of the unchanged-state guard: OpenCode can resend
        // the SAME terminal state with diagnostic text a later notification
        // didn't carry, and a non-empty error is never worth discarding.
        if let error, !error.isEmpty { lastError = error }
        // `session/load` resends a child's full lifecycle history — a
        // child already restored as terminal must not be regressed to an
        // earlier nonterminal frame, or a later replayed terminal frame
        // would then overwrite its persisted `finishedAt` with the
        // reattach time, inflating the displayed duration on every reattach.
        if replaying, state.isTerminal, !newState.isTerminal { return }
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
            let attachments = Self.attachments(of: chunk.content)
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
            // Overwrite the existing plan in place only if it belongs to
            // the current turn (sits after the latest prompt), mirroring
            // `ACPTranscript.currentPlanMessageIndex` — otherwise a second
            // turn's plan update would overwrite the first turn's plan
            // instead of starting a new one.
            if let index = lastPlanIndex(), index > (lastUserIndex() ?? -1),
               case .plan(let existingId, _) = messages[index] {
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
    /// A `.toolCall` payload during replay is upserted by id (replacing an
    /// existing row, creating a missing one) — naturally idempotent however
    /// many times the same id is replayed. `.toolCallUpdate` and `.plan`
    /// look their target up by id/kind at any position already, so they
    /// fall straight through to `apply(_:at:)`.
    @discardableResult
    func applyReplayed(_ update: ACPSessionUpdate, at timestamp: Date = Date()) -> Set<Int> {
        switch update {
        case .agentMessageChunk(let chunk):
            return applyReplayedTextChunk(chunk, kind: .agent, at: timestamp)
        case .agentThoughtChunk(let chunk):
            return applyReplayedTextChunk(chunk, kind: .thought, at: timestamp)
        case .userMessageChunk(let chunk):
            return applyReplayedUserChunk(chunk, at: timestamp)
        case .toolCall(let payload):
            closeLegacyRuns()
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
                replayCursor = max(replayCursor, index + 1)
                return [index]
            }
            let index = insertRecovered(
                .toolCall(ACPSession.makeToolCall(from: payload, at: timestamp)), at: timestamp)
            return [index]
        case .plan(let entries):
            return applyReplayedPlan(entries, at: timestamp)
        default:
            return apply(update, at: timestamp)
        }
    }

    /// Called once per `session/load` replay window so state left over
    /// from an EARLIER window (this run outliving more than one reattach)
    /// doesn't suppress a reset — or misplace an insertion — it should get
    /// in this one.
    func beginReplayReconciliation() {
        replayTouchedIdentities.removeAll()
        openIdentifiedUserRun = nil
        replayIdentifiedUserOrdinal.removeAll()
        replayCursor = 0
        legacyOpenRun.removeAll()
        legacyRunOrdinal.removeAll()
        legacyOpenUserRun = nil
        legacyUserRunOrdinal = 0
    }

    func endReplayReconciliation() {
        beginReplayReconciliation()
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

    /// Merges a `session/request_permission` decision into this child's own
    /// transcript, mirroring `ACPSession.mergePermissionDecision` — the
    /// request named THIS child's session id, so its resulting row belongs
    /// here, not in the parent: routing it to the parent instead produces a
    /// duplicate row if a `.toolCall` creation event later arrives (which
    /// IS correctly routed to the child by session id), or an orphaned
    /// child update that finds no matching row at all if only a
    /// `.toolCallUpdate` follows.
    @discardableResult
    func mergePermissionDecision(
        toolCall: ACPPermissionToolCall, facts: AnyCodable?, wasCancelled: Bool, at timestamp: Date = Date()
    ) -> Int {
        if let index = toolCallIndex(id: toolCall.toolCallId), case .toolCall(var tc) = messages[index] {
            if let facts { tc.metadata = ACPSession.mergeMetadata(tc.metadata, facts) }
            if wasCancelled, tc.status == "pending" || tc.status == "in_progress" {
                tc.status = "canceled"
                if tc.executionStartedAt != nil, tc.executionFinishedAt == nil {
                    tc.executionFinishedAt = timestamp
                }
            }
            messages[index] = .toolCall(tc)
            return index
        }
        let status = wasCancelled ? "canceled" : (toolCall.status ?? "pending")
        let payload = ACPToolCallPayload(
            toolCallId: toolCall.toolCallId,
            title: toolCall.title ?? toolCall.toolCallId,
            kind: toolCall.kind,
            status: status,
            content: toolCall.content,
            locations: toolCall.locations,
            rawInput: toolCall.rawInput,
            rawOutput: toolCall.rawOutput,
            metadata: toolCall.metadata,
            name: toolCall.name)
        var fresh = ACPSession.makeToolCall(from: payload, at: timestamp)
        if let facts {
            fresh.metadata = toolCall.metadata.map { ACPSession.mergeMetadata($0, facts) } ?? facts
        }
        return append(.toolCall(fresh), at: timestamp)
    }

    // MARK: - Private

    private enum StreamKind: Hashable {
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
    /// open one. Bounded to the LAST row overall (not merely the newest
    /// `.user` row) — a live turn is closed by ANY agent or tool-call
    /// output that follows it, so a later prompt reusing the same id must
    /// not skip past that intervening content and reopen the earlier
    /// bubble, concatenating both turns' text into one row.
    private func userIndex(messageId: String) -> Int? {
        guard case .user(_, let id, _, _, _) = messages.last, id == messageId else { return nil }
        return messages.count - 1
    }

    /// Replay of an agent/thought chunk. NOT delegated to `apply(_:at:)`
    /// for either its identified or id-less shape:
    ///
    /// - Identified, the first replayed touch of a row that already exists
    ///   resets it (discarding whatever hydration produced for that
    ///   specific row only) so accumulation rebuilds it purely from what
    ///   replay sends; a genuinely missing row is INSERTED at the current
    ///   replay position rather than appended, so it lands between its
    ///   chronological neighbours instead of always at the tail.
    /// - Id-less rows have no identity beyond "the trailing row of this
    ///   kind" (`legacyTrailingIndex`), which always finds the array's
    ///   OVERALL newest matching row — fine for a single run, wrong for a
    ///   SECOND historical run replayed after a boundary (a tool call, a
    ///   prompt, the other text kind) has closed the first one, since that
    ///   boundary sits AFTER both runs in the array. `legacyOpenRun` tracks
    ///   which row is currently being extended instead, closed by
    ///   `closeLegacyRuns` on every boundary-shaped update; a NEW run picks
    ///   the next unreconciled historical row from `legacyTextCandidates`,
    ///   in chronological order, or inserts a fresh one if none remain.
    private func applyReplayedTextChunk(
        _ chunk: ACPTextChunk, kind: StreamKind, at timestamp: Date
    ) -> Set<Int> {
        let text = Self.text(of: chunk.content)
        guard !text.isEmpty else { return [] }
        closeLegacyRuns(keepingTextRun: kind)
        if let messageId = chunk.messageId {
            let isFirstTouch = replayTouchedIdentities.insert(.text(kind, messageId)).inserted
            if let index = trailingIndex(of: kind, messageId: messageId) {
                if isFirstTouch { resetTextRow(at: index, kind: kind, messageId: messageId) }
                appendToTextRow(at: index, kind: kind, text: text, phase: chunk.phase, metadata: chunk.metadata)
                replayCursor = max(replayCursor, index + 1)
                return [index]
            }
            let index = insertRecovered(
                Self.makeTextMessage(
                    kind: kind, messageId: messageId, text: text,
                    phase: chunk.phase, metadata: chunk.metadata),
                at: timestamp)
            return [index]
        }
        if let openIndex = legacyOpenRun[kind], openIndex < messages.count {
            appendToTextRow(at: openIndex, kind: kind, text: text, phase: chunk.phase, metadata: chunk.metadata)
            replayCursor = max(replayCursor, openIndex + 1)
            return [openIndex]
        }
        let candidates = legacyTextCandidates(of: kind)
        let ordinal = legacyRunOrdinal[kind, default: 0]
        legacyRunOrdinal[kind] = ordinal + 1
        if ordinal < candidates.count {
            let index = candidates[ordinal]
            resetTextRow(at: index, kind: kind, messageId: nil)
            appendToTextRow(at: index, kind: kind, text: text, phase: chunk.phase, metadata: chunk.metadata)
            legacyOpenRun[kind] = index
            replayCursor = max(replayCursor, index + 1)
            return [index]
        }
        let index = insertRecovered(
            Self.makeTextMessage(kind: kind, messageId: nil, text: text, phase: chunk.phase, metadata: chunk.metadata),
            at: timestamp)
        legacyOpenRun[kind] = index
        return [index]
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

    private func appendToTextRow(
        at index: Int, kind: StreamKind, text: String, phase: ACPMessagePhase?, metadata: AnyCodable?
    ) {
        switch (kind, messages[index]) {
        case (.agent, .agent(_, _, let buffer)), (.thought, .thought(_, _, let buffer)):
            buffer.append(text)
            buffer.adopt(phase: phase, metadata: metadata)
        default:
            break
        }
    }

    private static func makeTextMessage(
        kind: StreamKind, messageId: String?, text: String, phase: ACPMessagePhase?, metadata: AnyCodable?
    ) -> ACPMessage {
        let buffer = StreamingText(text, phase: phase, metadata: metadata)
        switch kind {
        case .agent: return .agent(id: UUID(), messageId: messageId, buffer)
        case .thought: return .thought(id: UUID(), messageId: messageId, buffer)
        }
    }

    /// Every id-less row of `kind`, in chronological (ascending) order —
    /// the candidate list a NEW id-less replay run picks its target from.
    private func legacyTextCandidates(of kind: StreamKind) -> [Int] {
        messages.indices.filter { index in
            switch (kind, messages[index]) {
            case (.agent, .agent(_, nil, _)): return true
            case (.thought, .thought(_, nil, _)): return true
            default: return false
            }
        }
    }

    /// Replay of a child prompt. An identified prompt uses the SAME
    /// open-run/ordinal tracking id-less rows do (mirroring
    /// `applyReplayedTextChunk`), except keyed by the id itself rather than
    /// "trailing row of this kind": `openIdentifiedUserRun` extends further
    /// blocks of the SAME message, and `identifiedUserCandidates`/
    /// `replayIdentifiedUserOrdinal` pick the NEXT unconsumed occurrence of
    /// that id for a new (non-continuation) turn — a plain backward search
    /// would resolve two DIFFERENT turns reusing the same id to the same
    /// (newest) row every time. Id-less prompts use the equivalent
    /// `legacyOpenUserRun`/`legacyUserRunOrdinal` tracking.
    private func applyReplayedUserChunk(_ chunk: ACPTextChunk, at timestamp: Date) -> Set<Int> {
        let text = Self.text(of: chunk.content)
        let attachments = Self.attachments(of: chunk.content)
        guard !text.isEmpty || !attachments.isEmpty else { return [] }
        if let messageId = chunk.messageId {
            closeLegacyRuns(keepingIdentifiedUserRun: messageId)
            if let open = openIdentifiedUserRun, open.messageId == messageId, open.index < messages.count {
                appendToUserRow(at: open.index, messageId: messageId, text: text, attachments: attachments)
                replayCursor = max(replayCursor, open.index + 1)
                return [open.index]
            }
            // Not a continuation of the currently open row (a different,
            // or no, identity was open) — pick the NEXT unconsumed
            // occurrence of this specific id, chronologically, rather than
            // an unconditional backward search for the array's overall
            // newest match. Two turns can reuse the same `messageId`; an
            // unconditional search would resolve BOTH replayed occurrences
            // to the same (newest) row, combining both turns' prompts and
            // leaving the earlier row stale — exactly the bug
            // `legacyUserCandidates`/`legacyUserRunOrdinal` already avoid
            // for id-less rows, mirrored here for a reused id.
            let candidates = identifiedUserCandidates(withId: messageId)
            let ordinal = replayIdentifiedUserOrdinal[messageId, default: 0]
            replayIdentifiedUserOrdinal[messageId] = ordinal + 1
            if ordinal < candidates.count {
                let index = candidates[ordinal]
                if case .user(let id, _, _, _, let source) = messages[index] {
                    messages[index] = .user(
                        id: id, messageId: messageId, text: "", attachments: [], delegatedSource: source)
                }
                appendToUserRow(at: index, messageId: messageId, text: text, attachments: attachments)
                openIdentifiedUserRun = (messageId, index)
                replayCursor = max(replayCursor, index + 1)
                return [index]
            }
            let index = insertRecovered(
                .user(id: UUID(), messageId: messageId, text: text, attachments: attachments), at: timestamp)
            openIdentifiedUserRun = (messageId, index)
            return [index]
        }
        closeLegacyRuns(keepingUserRun: true)
        if let openIndex = legacyOpenUserRun, openIndex < messages.count {
            appendToUserRow(at: openIndex, messageId: nil, text: text, attachments: attachments)
            replayCursor = max(replayCursor, openIndex + 1)
            return [openIndex]
        }
        let candidates = legacyUserCandidates()
        let ordinal = legacyUserRunOrdinal
        legacyUserRunOrdinal += 1
        if ordinal < candidates.count {
            let index = candidates[ordinal]
            if case .user(let id, _, _, _, let source) = messages[index] {
                messages[index] = .user(id: id, messageId: nil, text: "", attachments: [], delegatedSource: source)
            }
            appendToUserRow(at: index, messageId: nil, text: text, attachments: attachments)
            legacyOpenUserRun = index
            replayCursor = max(replayCursor, index + 1)
            return [index]
        }
        let index = insertRecovered(
            .user(id: UUID(), messageId: nil, text: text, attachments: attachments), at: timestamp)
        legacyOpenUserRun = index
        return [index]
    }

    private func appendToUserRow(at index: Int, messageId: String?, text: String, attachments: [ACPMessage.Attachment]) {
        guard case .user(let id, _, let existingText, let existingAttachments, let source) = messages[index] else {
            return
        }
        messages[index] = .user(
            id: id,
            messageId: messageId,
            text: existingText + text,
            attachments: existingAttachments + attachments.filter { !existingAttachments.contains($0) },
            delegatedSource: source)
    }

    /// Every `.user` row carrying `messageId`, in chronological (ascending)
    /// order — the candidate list a NEW (non-continuation) replay touch of
    /// that id picks its target from. See `openIdentifiedUserRun`.
    private func identifiedUserCandidates(withId messageId: String) -> [Int] {
        messages.indices.filter { index in
            if case .user(_, let id, _, _, _) = messages[index] { return id == messageId }
            return false
        }
    }

    /// Every id-less `.user` row, in chronological (ascending) order.
    private func legacyUserCandidates() -> [Int] {
        messages.indices.filter {
            if case .user(_, nil, _, _, _) = messages[$0] { return true }
            return false
        }
    }

    private func lastPlanIndex() -> Int? {
        messages.lastIndex {
            if case .plan = $0 { return true }
            return false
        }
    }

    private func lastUserIndex() -> Int? {
        messages.lastIndex {
            if case .user = $0 { return true }
            return false
        }
    }

    /// Replay of a per-turn plan. A plan has no stable identity to match
    /// on — only a turn-boundary position, exactly like the live path's own
    /// `apply(_:at:)` bound (`lastPlanIndex()` after `lastUserIndex()`) —
    /// but that live bound is relative to the array's OVERALL newest rows,
    /// which during replay can already include turns chronologically AFTER
    /// the one being replayed right now. So instead this finds the plan
    /// row (if any) belonging to the turn that STARTED most recently at or
    /// before the current replay position: the nearest `.user` row at or
    /// before `replayCursor`, then the first `.plan` row after it and
    /// before the next `.user` row (if any) — reconciling in place when
    /// found, or recovering a plan that never reached storage at all via
    /// `insertRecovered`, exactly like every other row kind already does.
    private func applyReplayedPlan(_ entries: [ACPPlanEntry], at timestamp: Date) -> Set<Int> {
        let items = entries.map { ACPMessage.PlanItem(content: $0.content, status: $0.status) }
        let turnStart = (lastUserIndex(before: replayCursor) ?? -1) + 1
        for index in turnStart..<messages.count {
            switch messages[index] {
            case .user:
                return [insertRecovered(.plan(id: UUID(), items), at: timestamp)]
            case .plan(let existingId, _):
                messages[index] = .plan(id: existingId, items)
                replayCursor = max(replayCursor, index + 1)
                return [index]
            default:
                continue
            }
        }
        return [insertRecovered(.plan(id: UUID(), items), at: timestamp)]
    }

    /// The nearest `.user` row strictly before `limit`, if any.
    private func lastUserIndex(before limit: Int) -> Int? {
        let upper = min(max(limit, 0), messages.count)
        for index in stride(from: upper - 1, through: 0, by: -1) {
            if case .user = messages[index] { return index }
        }
        return nil
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

    /// Closes every id-less (and identified-user) run boundary-closed by
    /// replaying an update of the given shape, mirroring
    /// `legacyTrailingIndex`'s own boundary set: a tool call, a user chunk,
    /// and — for a text run — the OTHER text kind's chunk (an agent chunk
    /// closes an open thought run live, and vice versa). Called at the top
    /// of every replay handler with whichever run (if any) that update
    /// itself might continue.
    private func closeLegacyRuns(
        keepingTextRun kind: StreamKind? = nil,
        keepingUserRun: Bool = false,
        keepingIdentifiedUserRun messageId: String? = nil
    ) {
        for candidate: StreamKind in [.agent, .thought] where candidate != kind {
            legacyOpenRun[candidate] = nil
        }
        if !keepingUserRun { legacyOpenUserRun = nil }
        if openIdentifiedUserRun?.messageId != messageId { openIdentifiedUserRun = nil }
    }

    /// Inserts a row recovered because it's genuinely missing from what
    /// hydration restored, at `replayCursor` — its chronological position —
    /// with a `seq` strictly between its new neighbours when there's room
    /// for one (there always is when the gap is exactly this one row), so
    /// persistence keeps it in the right place too instead of only the
    /// in-memory array being briefly correct. Shifts any open legacy run
    /// tracked at or after the insertion point, since inserting moves it.
    private func insertRecovered(_ message: ACPMessage, at timestamp: Date) -> Int {
        let index = min(max(replayCursor, 0), messages.count)
        let before: Int64? = index > 0 ? seqs[index - 1] : nil
        let after: Int64? = index < seqs.count ? seqs[index] : nil
        let seq: Int64
        switch (before, after) {
        case let (b?, a?) where a > b + 1:
            seq = b + 1
        case let (nil, a?):
            // No lower neighbor at all — this could be the first of SEVERAL
            // consecutive missing prefix rows (e.g. seq 0 and 1 both never
            // persisted, only seq 2 did). Reserving just `a - 1` leaves no
            // room for a second one: its own neighbors would then be
            // exactly adjacent (`a - 1` and `a`), fall through to `nextSeq`
            // below, and reload AFTER `a` even though it sits before it in
            // memory, since SQLite orders by seq. Reserve a wide block
            // instead, so any realistic run of consecutive prefix recoveries
            // still lands in strictly increasing, gap-preserving order.
            seq = a - Self.prefixRecoverySeqReserve
        default:
            seq = nextSeq
        }
        messages.insert(message, at: index)
        createdAts.insert(Int(timestamp.timeIntervalSince1970), at: index)
        seqs.insert(seq, at: index)
        if seq >= nextSeq { nextSeq = seq + 1 }
        for kind: StreamKind in [.agent, .thought] {
            if let open = legacyOpenRun[kind], open >= index { legacyOpenRun[kind] = open + 1 }
        }
        if let open = legacyOpenUserRun, open >= index { legacyOpenUserRun = open + 1 }
        if let open = openIdentifiedUserRun, open.index >= index {
            openIdentifiedUserRun = (open.messageId, open.index + 1)
        }
        replayCursor = index + 1
        return index
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

    /// `ACPSessionRunner.attachments(of:)` only materializes an image block
    /// with a `uri` — right for the parent composer, which always resolves
    /// an image to a file/resource link before it reaches a content block,
    /// but a child prompt can carry an inline base64 `data` payload with no
    /// `uri` at all. Without this, such a block has neither text nor a
    /// matched attachment and the whole prompt update is silently dropped.
    private static func attachments(of block: ACPContentBlock) -> [ACPMessage.Attachment] {
        var attachments = ACPSessionRunner.attachments(of: [block])
        if case .image(let data, let uri, let mimeType) = block, uri == nil,
           let data, !data.isEmpty {
            let mime = mimeType ?? "image/png"
            attachments.append(.init(uri: "data:\(mime);base64,\(data)", name: nil, mimeType: mime))
        }
        return attachments
    }
}
