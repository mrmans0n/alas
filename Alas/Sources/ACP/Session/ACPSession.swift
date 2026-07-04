import Foundation
import Combine

/// Narrow observable holder for the rapidly-mutating composer draft.
/// Keystrokes update this object instead of `ACPSession` so the transcript
/// pane is not invalidated while the user types in long sessions.
@MainActor
final class ACPComposerState: ObservableObject {
    private(set) var draft: ACPComposerDraft = .empty
    private(set) var revision: Int = 0

    func replaceDraft(_ draft: ACPComposerDraft) {
        objectWillChange.send()
        self.draft = draft
        revision += 1
    }
}

enum ACPSessionTitleSource: String, Codable {
    case placeholder
    case generated
    case manual
}

struct ACPGoalState: Equatable, Hashable, Sendable {
    let objective: String
    let status: String?
    let tokenBudget: Int?
}

@MainActor
final class ACPSession: ObservableObject, Identifiable {
    typealias ID = String

    let id: ID
    let agentId: String
    let worktreeId: String
    let createdAt: Date
    let restoredFromPersistence: Bool
    let transcript = ACPTranscript()
    let composer = ACPComposerState()
    let terminalHost: ACPTerminalHost = ACPTerminalHost(sessionCwd: "/", sessionEnv: [:])

    @Published var title: String
    @Published var titleSource: ACPSessionTitleSource
    @Published var availableModels: [ACPModelInfo] = []
    @Published var availableModes: [ACPModeInfo] = []
    @Published var availableConfigOptions: [ACPConfigOption] = []
    @Published var currentModel: String?
    @Published var contextUsage: ACPUsageInfo?
    @Published var currentMode: String?
    @Published var currentGoal: ACPGoalState?
    @Published var promptSuggestions: [ACPPromptSuggestion] = []
    @Published var autoRunEnabled: Bool = false
    @Published var setupState: SetupState = .checking
    @Published var lastError: String?
    @Published var contextRestoreWarning: ContextRestoreWarning?
    @Published var contextRecoveryStatus: ContextRecoveryStatus?
    /// Runtime-only transcript scroll intent. When true, the ACP message
    /// list follows new content and restores to the latest bottom after
    /// returning to this session. Set false when the user scrolls upward.
    @Published var followsTranscriptTail: Bool = true
    /// Runtime-only user override for the inline plan sidebar. This is
    /// deliberately not persisted; it only survives while this in-memory
    /// ACP session object is retained.
    @Published var planSidebarMinimized: Bool = false
    /// Lifecycle state of the agent process backing this session.
    /// Single source of truth for the composer, header pill, and runner
    /// registry checks.
    /// Note: `AgentState.idle` means "no runner spawned yet" (process
    /// lifecycle), distinct from `StreamingState.idle` which means
    /// "runner is attached but not currently mid-prompt" (turn lifecycle).
    @Published var agentState: AgentState = .idle
    /// Prompt content capabilities learned from ACP `initialize`.
    /// Runtime-only: re-learned on each attach, never persisted. Drives
    /// send-time hydration in `ACPSessionRunner.hydrate`.
    @Published var promptCapabilities: ACPInitializeResult.ACPPromptCapabilities = .init()
    /// Auth methods learned from ACP `initialize`.
    /// Runtime-only: re-learned on each attach and used when an agent asks
    /// the client to authenticate before ACP can continue.
    @Published var authMethods: [ACPInitializeResult.ACPAuthMethod] = []
    /// Runtime-only auth method selected by the user in the sign-in banner.
    /// The next attach consumes it by calling ACP `authenticate` after
    /// initialize and before session creation/loading.
    var pendingAuthMethodId: String?
    /// Runtime-only first-run attach phase for the brief window between
    /// opening a brand-new ACP chat and receiving the ready remote session.
    /// This is never persisted; restored sessions derive their UI from
    /// persisted session fields instead.
    @Published var firstRunConnectingPhase: ACPFirstRunConnectingPhase?

    private static let metadataPreviewLimit = 4096
    private var contextRecoveryExpiryTask: Task<Void, Never>?

    /// When false, `appendStreaming` discards chunks that would cross a
    /// completed-output boundary (i.e. create a duplicate agent message bubble).
    /// The runner sets this false when load-replay suppression ends and true
    /// when the next prompt starts, preventing late replay frames from creating
    /// duplicate bubbles while still letting fresh in-progress continuation
    /// chunks through (those target non-completed messages, so the boundary
    /// check is never reached).
    var allowsStreamingBoundaryCrossing: Bool = true

    private var reconciledLocalUserPromptMessageIds: Set<String> = []
    private var reconciledLegacyLocalUserPromptIds: Set<UUID> = []
    private var liveUserChunkMessageIds: Set<String> = []
    private var legacyUserChunkMessageIds: Set<UUID> = []

    /// Runtime-only marker for a forced queue item parked behind the current
    /// `.sending` head. If that head fails, it moves behind this item so the
    /// explicit force-send remains next.
    private var forceSendAfterSendingHeadId: UUID?

    var imageInputSupported: Bool { promptCapabilities.image }
    var embeddedContextSupported: Bool { promptCapabilities.embeddedContext }

    /// Display name for the active model: resolves `currentModel` (an id) against
    /// `availableModels`, falling back to the raw id when unknown.
    var currentModelDisplayName: String? {
        guard let id = currentModel else { return nil }
        return availableModels.first { $0.id == id }?.name ?? id
    }

    enum AgentState: Equatable {
        case idle
        case spawning
        case ready
        case disconnected
        case failed(String)
    }
    /// Tracks whether the session's persisted state (messages, queue, draft,
    /// row fields) has been loaded from SQLite. `.loading` is the initial
    /// state for sessions returned by `placeholderSession`; `.ready` is the
    /// initial state for sessions returned by `createSession`. `.failed`
    /// surfaces a hydration error to the view.
    @Published var hydrationState: HydrationState
    /// ACP session id assigned by the agent on `session/new` (or the
    /// id we passed to `session/load`). Used for every subsequent
    /// protocol call (`session/prompt`, `session/cancel`, etc).
    /// Distinct from `id`, which is our locally-generated UUID used
    /// as the persistence key in `ACPSessionStore`.
    /// Persisted in `ACPSessionStore` and refreshed on each successful
    /// `session/new` or `session/load`.
    var remoteSessionId: String?
    @Published var queue: [QueuedPrompt] = []
    @Published var steerUndo: SteerUndoState?
    private var toolCallIndices: [String: Int] = [:]

    struct SteerUndoState: Equatable {
        /// Unique per-snapshot id used by SwiftUI for view diffing — letting
        /// us reset the 5s timer-task whenever a new steer happens before
        /// the previous toast has expired.
        let id: UUID
        let snapshot: [QueuedPrompt]
    }

    struct ContextRestoreWarning: Equatable {
        var message: String
        var canSendTranscript: Bool
    }

    enum ContextRecoveryStatus: Hashable {
        case restoring
        case sendingTranscript
        case restored
        case failed(String)
    }

    var hasConversationTranscript: Bool {
        transcript.messages.contains { message in
            switch message {
            case .user(_, _, let text, _):
                return !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            case .agent(_, _, let buffer):
                return !buffer.value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            default:
                return false
            }
        }
    }

    var composerDraft: ACPComposerDraft { composer.draft }
    var composerDraftRevision: Int { composer.revision }

    func replaceComposerDraft(_ draft: ACPComposerDraft) {
        composer.replaceDraft(draft)
    }

    enum HydrationState: Equatable {
        case loading
        case ready
        case failed(String)
    }
    enum StreamingState: Equatable { case idle, sending, streaming, awaitingPermission, awaitingInput }
    enum SetupState: Equatable {
        case checking
        case ready
        case needsSetup(reason: String)
        case needsAuth(methods: [ACPInitializeResult.ACPAuthMethod], reason: String?)
    }
    struct PendingPermission: Identifiable, Equatable {
        let id: JSONRPCID
        let params: ACPPermissionRequestParams
    }
    struct PendingQuestion: Identifiable, Equatable {
        let id: JSONRPCID
        let params: ACPQuestionRequestParams
    }

    init(id: ID, agentId: String, worktreeId: String, title: String,
         titleSource: ACPSessionTitleSource = .placeholder,
         createdAt: Date = Date(),
         hydrationState: HydrationState = .ready,
         restoredFromPersistence: Bool = false) {
        self.id = id
        self.agentId = agentId
        self.worktreeId = worktreeId
        self.title = title
        self.titleSource = titleSource
        self.createdAt = createdAt
        self.hydrationState = hydrationState
        self.restoredFromPersistence = restoredFromPersistence
    }

    deinit {
        contextRecoveryExpiryTask?.cancel()
        // Foundation cannot await main-actor methods from deinit; dispatch.
        let host = terminalHost
        Task { @MainActor in host.killAll() }
    }

    func recordUserPrompt(text: String, attachments: [ACPMessage.Attachment]) {
        transcript.messages.append(.user(id: UUID(), messageId: nil, text: text, attachments: attachments))
        didAppendTranscriptMessage()
        transcript.completedOutputBoundaryMessageIds.removeAll()
        if titleSource == .placeholder {
            let candidate = text
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .components(separatedBy: .newlines)
                .joined(separator: " ")
            let trimmed = String(candidate.prefix(60))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                title = trimmed
                titleSource = .generated
            }
        }
    }

    /// Returns the set of transcript message indices that were appended or
    /// mutated by this update. Updates that only touch non-message state
    /// (model lists, mode, etc) return an empty set. The caller uses this
    /// to persist exactly the rows that changed — necessary because a
    /// `.plan` or `.toolCallUpdate` can mutate a message anywhere in the
    /// transcript, not just the trailing row.
    @discardableResult
    func apply(_ update: ACPSessionUpdate) -> Set<Int> {
        switch update {
        case .agentMessageChunk(let chunk):
            clearRestoredContextRecoveryStatus()
            let txt = text(of: chunk.content)
            guard let i = appendStreaming(
                text: txt,
                messageId: chunk.messageId,
                locateByMessageId: { id in messageIndex(messageId: id, kind: .agent) },
                locateLegacy: { lastAgent() },
                isLikelyReplay: { text in messageExists(kind: .agent, containing: text) },
                makeNew: { .agent(id: UUID(), messageId: chunk.messageId, StreamingText(txt)) }) else {
                return []
            }
            return [i]
        case .userMessageChunk(let chunk):
            let txt = text(of: chunk.content)
            guard let i = appendUserChunk(
                text: txt,
                attachments: ACPSessionRunner.attachments(of: [chunk.content]),
                messageId: chunk.messageId) else {
                return []
            }
            return [i]
        case .agentThoughtChunk(let chunk):
            clearRestoredContextRecoveryStatus()
            let txt = text(of: chunk.content)
            guard let i = appendStreaming(
                text: txt,
                messageId: chunk.messageId,
                locateByMessageId: { id in messageIndex(messageId: id, kind: .thought) },
                locateLegacy: { lastThought() },
                isLikelyReplay: { text in messageExists(kind: .thought, containing: text) },
                makeNew: { .thought(id: UUID(), messageId: chunk.messageId, StreamingText(txt)) }) else {
                return []
            }
            return [i]
        case .toolCall(let payload):
            clearRestoredContextRecoveryStatus()
            let items = payload.content ?? []
            let raw = Self.flatten(items)
            let full = Self.stripWrappingFence(raw,
                                               isFinal: Self.isFinalStatus(payload.status))
            let terminalIds = Self.mergeTerminalIds(
                Self.extractTerminalIds(items),
                Self.extractMetadataTerminalIds(payload.metadata))
            let rawOutputAssets = Self.extractRawOutputAssets(payload.rawOutput)
            transcript.messages.append(.toolCall(.init(
                toolCallId: payload.toolCallId,
                title: payload.title,
                kind: payload.kind,
                status: payload.status,
                content: full,
                preview: Self.previewLine(full),
                contentLanguage: Self.wrappingFenceLanguage(raw),
                rawInput: Self.metadataString(payload.rawInput),
                rawOutput: Self.metadataString(payload.rawOutput),
                metadata: payload.metadata,
                assets: Self.mergeAssets(Self.extractAssets(items), rawOutputAssets),
                locations: payload.locations?.map(\.path) ?? [],
                terminalIds: terminalIds)))
            didAppendTranscriptMessage()
            transcript.completedOutputBoundaryMessageIds.removeAll()
            applyToolCallMetadata(payload.metadata)
            return [transcript.messages.count - 1]
        case .toolCallUpdate(let u):
            clearRestoredContextRecoveryStatus()
            var appliedMetadata: AnyCodable?
            var metadataTerminalIds: [String] = []
            var rawOutputAssets: [ACPMessage.ToolCallAsset] = []
            let touched = updateToolCall(id: u.toolCallId) { tc in
                if let title = u.title { tc.title = title }
                if let s = u.status { tc.status = s }
                if let locations = u.locations { tc.locations = locations.map(\.path) }
                if let rawInput = u.rawInput { tc.rawInput = Self.metadataString(rawInput) }
                if let rawOutput = u.rawOutput {
                    tc.rawOutput = Self.metadataString(rawOutput)
                    rawOutputAssets = Self.extractRawOutputAssets(rawOutput)
                    tc.assets = Self.mergeAssets(tc.assets, rawOutputAssets)
                }
                if let metadata = u.metadata {
                    tc.metadata = Self.mergeMetadata(tc.metadata, metadata)
                    appliedMetadata = metadata
                    metadataTerminalIds = Self.extractMetadataTerminalIds(metadata)
                    tc.terminalIds = Self.mergeTerminalIds(tc.terminalIds, metadataTerminalIds)
                }
                if let c = u.content {
                    // ACP content updates are full replacement snapshots,
                    // so terminalIds tracks the *current* content — assign
                    // unconditionally, including the empty case, so a
                    // text/diff-only final update doesn't leave a stale
                    // terminal tail rendering in the card.
                    let raw = Self.flatten(c)
                    let full = Self.stripWrappingFence(raw,
                                                      isFinal: Self.isFinalStatus(tc.status))
                    tc.content = full
                    tc.preview = Self.previewLine(full)
                    tc.contentLanguage = Self.wrappingFenceLanguage(raw)
                    tc.terminalIds = Self.mergeTerminalIds(
                        Self.extractTerminalIds(c),
                        Self.extractMetadataTerminalIds(tc.metadata))
                    let preservedRawOutputAssets = rawOutputAssets.isEmpty
                        ? Self.extractStoredRawOutputAssets(tc.rawOutput, existingAssets: tc.assets)
                        : rawOutputAssets
                    tc.assets = Self.mergeAssets(Self.extractAssets(c), preservedRawOutputAssets)
                }
            }
            applyToolCallMetadata(appliedMetadata)
            return touched.map { [$0] } ?? []
        case .sessionInfoUpdate(let info):
            applySessionInfoUpdate(info)
            return []
        case .plan(let entries):
            clearRestoredContextRecoveryStatus()
            let items = entries.map { ACPMessage.PlanItem(content: $0.content, status: $0.status) }
            // Overwrite the existing plan in place only if it belongs to
            // the current turn (i.e. sits after the latest user prompt).
            // Otherwise append a fresh plan so the previous turn's plan
            // stays at its original position and the new one is current.
            let lastUserIdx = transcript.messages.lastIndex { if case .user = $0 { return true } else { return false } } ?? -1
            let currentTurnPlanIdx = transcript.messages.lastIndex { if case .plan = $0 { return true } else { return false } }
                .flatMap { $0 > lastUserIdx ? $0 : nil }
            if let i = currentTurnPlanIdx, case .plan(let existingId, _) = transcript.messages[i] {
                transcript.messages[i] = .plan(id: existingId, items)
                return [i]
            } else {
                transcript.messages.append(.plan(id: UUID(), items))
                didAppendTranscriptMessage()
                transcript.completedOutputBoundaryMessageIds.removeAll()
                return [transcript.messages.count - 1]
            }
        case .availableModelsUpdate(let ms):
            availableModels = ms
            return []
        case .currentModeUpdate(let modeId):
            currentMode = modeId
            return []
        case .currentModelUpdate(let modelId):
            currentModel = modelId
            return []
        case .sessionConfigOptionsUpdate(let opts):
            availableConfigOptions = opts
            return []
        case .availableCommandsUpdate(let cmds):
            promptSuggestions = cmds
            return []
        case .usageUpdate(let info):
            // size <= 0 is unusable (divide-by-zero); treat as "no data".
            contextUsage = (info.size > 0) ? info : nil
            return []
        case .unknown:
            return []
        }
    }

    func applySuppressedReplaySideEffects(_ update: ACPSessionUpdate) {
        switch update {
        case .toolCall(let payload):
            guard let metadata = payload.metadata else { return }
            guard updateToolCall(id: payload.toolCallId, { tc in
                tc.metadata = Self.mergeMetadata(tc.metadata, metadata)
                tc.terminalIds = Self.mergeTerminalIds(
                    tc.terminalIds,
                    Self.extractMetadataTerminalIds(metadata))
            }) != nil else { return }
            applyToolCallMetadata(metadata)
        case .toolCallUpdate(let update):
            guard let metadata = update.metadata else { return }
            guard updateToolCall(id: update.toolCallId, { tc in
                tc.metadata = Self.mergeMetadata(tc.metadata, metadata)
                tc.terminalIds = Self.mergeTerminalIds(
                    tc.terminalIds,
                    Self.extractMetadataTerminalIds(metadata))
            }) != nil else { return }
            applyToolCallMetadata(metadata)
        default:
            break
        }
    }

    func markContextRecoveryRestored(expiryNanoseconds: UInt64 = 30_000_000_000) {
        contextRecoveryExpiryTask?.cancel()
        contextRecoveryStatus = .restored
        contextRecoveryExpiryTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: expiryNanoseconds)
            guard !Task.isCancelled, self?.contextRecoveryStatus == .restored else { return }
            self?.contextRecoveryStatus = nil
            self?.contextRecoveryExpiryTask = nil
        }
    }

    func appendSystemNotice(_ text: String) {
        transcript.messages.append(.systemNotice(id: UUID(), text: text))
        didAppendTranscriptMessage()
    }

    func appendFileEdit(_ edit: ACPMessage.FileEdit) {
        clearRestoredContextRecoveryStatus()
        transcript.messages.append(.fileEdit(id: UUID(), edit))
        didAppendTranscriptMessage()
        transcript.completedOutputBoundaryMessageIds.removeAll()
    }

    func replaceTranscriptMessages(_ messages: [ACPMessage]) {
        transcript.messages = messages
        rebuildToolCallIndices()
    }

    /// Insert `older` at the head of the transcript and shift `visibleHead`
    /// forward by `older.count` so the visible tail window stays anchored to
    /// the same messages. Used by the post-hydration backfill that prepends
    /// pre-tail messages after the UI has already painted the tail.
    func prependTranscriptMessages(_ older: [ACPMessage]) {
        guard !older.isEmpty else { return }
        transcript.messages.insert(contentsOf: older, at: 0)
        // Rebuild tool-call indices because every prior entry's index just
        // shifted by `older.count`. Cheaper than offsetting in place: the
        // cache is dictionary-typed, so a full rebuild is O(N) and avoids
        // any chance of drift if a streaming update lands mid-shift.
        rebuildToolCallIndices()
        // Keep the visible window anchored to the tail the user is already
        // looking at. Bypass `setVisibleHead` — it strips markdown caches
        // for messages below the new head, which is exactly what we want
        // to *avoid* here (older messages weren't visible before the shift
        // and never had caches; the tail's caches must survive untouched).
        transcript.visibleHead = transcript.visibleHead + older.count
    }

    func markCompletedOutputBoundary() {
        transcript.completedOutputBoundaryMessageIds.removeAll()
        for message in transcript.messages.reversed() {
            switch message {
            case .agent, .thought:
                transcript.completedOutputBoundaryMessageIds.insert(message.stableId)
                continue
            case .plan:
                continue
            default:
                return
            }
        }
    }

    /// Append a new pending item to the tail of the queue. Used by the
    /// runner when the user submits while the agent is busy (or while
    /// the queue is already non-empty — see ACPSubmitRoute).
    func enqueue(blocks: [ACPContentBlock], draft: ACPComposerDraft? = nil) {
        queue.append(QueuedPrompt(blocks: blocks, draft: draft))
    }

    /// Remove a specific item by id. The drag-handle X on the bubble
    /// calls this. Safe on .sending items because the UI hides X then —
    /// but we double-guard here to avoid yanking an in-flight RPC.
    func removeFromQueue(id: UUID) {
        guard let idx = queue.firstIndex(where: { $0.id == id }) else { return }
        if queue[idx].status == .sending { return }
        if forceSendAfterSendingHeadId == id {
            forceSendAfterSendingHeadId = nil
        }
        queue.remove(at: idx)
    }

    /// Pull a queued item back into the composer for editing: remove it and
    /// return its restorable draft — but ONLY if it's still `.pending`.
    /// Returns `nil` if the item is gone or already `.sending` (mid-RPC), so
    /// the caller never restores a prompt that's still in flight. This is the
    /// atomic replacement for "check status, then removeFromQueue, then
    /// restore" — collapsing the time-of-check/time-of-use window that let a
    /// flusher-promoted item be duplicated into the composer.
    func takeForEditing(id: UUID) -> ACPComposerDraft? {
        guard let idx = queue.firstIndex(where: { $0.id == id }) else { return nil }
        guard queue[idx].status == .pending else { return nil }
        if forceSendAfterSendingHeadId == id {
            forceSendAfterSendingHeadId = nil
        }
        let item = queue.remove(at: idx)
        return item.restorableDraft
    }

    /// Reorder within the queue. Refuses to move a `.sending` head — the
    /// UI hides the grip on `.sending` items, this is the belt-and-
    /// suspenders guard.
    func moveInQueue(from src: Int, to dst: Int) {
        guard src >= 0, src < queue.count, dst >= 0, dst <= queue.count else { return }
        if queue.indices.contains(src), queue[src].status == .sending { return }
        // If moving across the .sending head (index 0 when sending), refuse.
        if !queue.isEmpty, queue[0].status == .sending, dst == 0 { return }
        let item = queue.remove(at: src)
        queue.insert(item, at: min(dst, queue.count))
    }

    /// Promote a pending queued item to the next drainable position and clear
    /// any previous send error. If a `.sending` head is already in-flight, the
    /// forced item is placed immediately behind it so completion can pop the
    /// current head safely.
    @discardableResult
    func forceQueueItem(id: UUID) -> Bool {
        guard let idx = queue.firstIndex(where: { $0.id == id }) else { return false }
        guard queue[idx].status == .pending else { return false }

        let protectedPrefixCount = (queue.first?.status == .sending) ? 1 : 0
        for bypassedIndex in protectedPrefixCount ..< idx {
            if queue[bypassedIndex].status == .pending,
               queue[bypassedIndex].lastError != nil {
                queue[bypassedIndex].transcriptRecorded = false
            }
        }

        var item = queue.remove(at: idx)
        item.status = .pending
        item.lastError = nil

        let insertAt = protectedPrefixCount
        queue.insert(item, at: min(insertAt, queue.count))
        forceSendAfterSendingHeadId = protectedPrefixCount == 1 ? item.id : nil
        return true
    }

    /// Edit the prompt blocks of a `.pending` item. No-op for `.sending`.
    /// Clears any captured draft — the old segments no longer describe the
    /// new blocks, so a later edit falls back to the heuristic on the
    /// current blocks rather than restoring stale structure.
    ///
    /// This is the only correct path to mutate a queued item's `blocks` —
    /// call it rather than writing `queue[idx].blocks` directly, otherwise a
    /// now-stale `draft` survives and mis-restores on the next edit.
    func editQueueItem(id: UUID, blocks: [ACPContentBlock]) {
        guard let idx = queue.firstIndex(where: { $0.id == id }) else { return }
        if queue[idx].status == .sending { return }
        queue[idx].blocks = blocks
        queue[idx].draft = nil
    }

    /// Remove all `.pending` items; return the snapshot in original order so
    /// the steer-undo toast (or the "Clear queue" header button) can restore
    /// them. A `.sending` item is left in place — it's mid-RPC.
    @discardableResult
    func clearPendingQueue() -> [QueuedPrompt] {
        let snapshot = queue.filter { $0.status == .pending }
        queue.removeAll { $0.status == .pending }
        forceSendAfterSendingHeadId = nil
        return snapshot
    }

    /// Re-prepend a previously-cleared snapshot. Used by the steer-undo
    /// toast. If a `.sending` head exists (e.g. the steer redirect already
    /// completed and the flusher promoted a follow-up to in-flight before
    /// the user tapped Undo), the restored items go AFTER it — otherwise
    /// the in-flight `sendNow`'s `popQueueHead` would key off the wrong
    /// item and the `.sending` head would stay stranded in the queue.
    func restorePendingSnapshot(_ snapshot: [QueuedPrompt]) {
        let insertAt = (queue.first?.status == .sending) ? 1 : 0
        queue.insert(contentsOf: snapshot, at: insertAt)
    }

    /// Number of pending queue items. The transcript UI may render additional
    /// queue rows, such as an in-flight `.sending` head, for row-local status
    /// and action placement.
    var visibleQueueCount: Int {
        queue.reduce(0) { $0 + ($1.status == .sending ? 0 : 1) }
    }

    /// Mark the head item `.sending`. Called by the flusher right before
    /// it spawns the prompt RPC. Clears any previous `lastError` so a
    /// retried item displays cleanly while in-flight.
    func markQueueHeadSending() {
        guard !queue.isEmpty, queue[0].status == .pending else { return }
        queue[0].status = .sending
        queue[0].lastError = nil
    }

    /// Pop the head only if it's currently `.sending`. Returns it. Used by
    /// the flusher's success path.
    @discardableResult
    func popQueueHead() -> QueuedPrompt? {
        guard !queue.isEmpty, queue[0].status == .sending else { return nil }
        let item = queue.removeFirst()
        if forceSendAfterSendingHeadId == item.id {
            forceSendAfterSendingHeadId = nil
        }
        return item
    }

    /// Roll the `.sending` head back to `.pending` with an error message.
    /// Used by the flusher's failure path. Keeps the item at the head so
    /// the user sees "Retry" on the bubble.
    func setQueueHeadError(_ message: String) {
        guard !queue.isEmpty else { return }
        var item = queue.removeFirst()
        item.status = .pending
        item.lastError = message

        if let forcedId = forceSendAfterSendingHeadId,
           let forcedIndex = queue.firstIndex(where: { $0.id == forcedId }) {
            queue.insert(item, at: min(forcedIndex + 1, queue.count))
        } else {
            queue.insert(item, at: 0)
        }
        forceSendAfterSendingHeadId = nil
    }

    /// Replace the queue wholesale with a normalized restore set. Called
    /// from `ACPSessionManager.openSession` after pulling rows from the
    /// store. `.sending` items get flipped to `.pending` here so the
    /// flusher re-attempts on next idle.
    func restoreQueue(_ items: [QueuedPrompt]) {
        forceSendAfterSendingHeadId = nil
        queue = items.map { $0.normalizedAfterRestore() }
    }

    /// Mark any pending/in_progress tool calls as canceled. Called when
    /// the user interrupts streaming so spinners stop and the rendered
    /// status reflects reality (the agent isn't coming back to finish
    /// these). Returns the indices of mutated messages so callers can
    /// persist them.
    func cancelInFlightToolCalls() -> [Int] {
        var changed: [Int] = []
        for i in transcript.messages.indices {
            if case .toolCall(var tc) = transcript.messages[i],
               tc.status == "in_progress" || tc.status == "pending" {
                tc.status = "canceled"
                transcript.messages[i] = .toolCall(tc)
                changed.append(i)
            }
        }
        return changed
    }

    /// Composer-facing normalized chip state. Recomputed on each access
    /// from the current `availableModels` / `availableModes` /
    /// `availableConfigOptions` / `currentModel` / `currentMode`. Cheap —
    /// the inputs are small lists.
    var chipState: ACPChipState {
        ACPChipState.normalize(
            agentId: agentId,
            availableModels: availableModels,
            currentModel: currentModel,
            availableModes: availableModes,
            currentMode: currentMode,
            configOptions: availableConfigOptions)
    }

    // MARK: helpers

    /// Concatenate tool-call content entries into one text blob suitable
    /// for the expanded tool card. Non-text variants are rendered as
    /// readable placeholders so the user can see something happened.
    private static func flatten(_ items: [ACPToolCallContent]) -> String {
        var out: [String] = []
        for item in items {
            switch item {
            case .content(.text(let s)):
                out.append(s)
            case .content(.resourceLink), .content(.image):
                // Asset blocks are preserved on `ToolCall.assets`; including
                // text placeholders here corrupts wrapped prose/code output
                // when an update contains both text and assets.
                continue
            case .content(.resource(_, _, let text)):
                out.append(text)
            case .diff(let path, let old, let new):
                var lines: [String] = ["--- \(path)"]
                if let old, !old.isEmpty {
                    for line in Self.diffLines(old) {
                        lines.append("-\(line)")
                    }
                }
                for line in Self.diffLines(new) {
                    lines.append("+\(line)")
                }
                out.append(lines.joined(separator: "\n"))
            case .terminal:
                // IDs are tracked on tc.terminalIds; the UI renders the live
                // tail structurally, so no text placeholder is appended here.
                continue
            case .unknown:
                // Skipped rather than rendered empty.
                continue
            }
        }
        return out.joined(separator: "\n")
    }

    /// Split a diff hunk into lines while preserving blank lines inside
    /// the content. Drops the empty trailing substring that
    /// `split(omittingEmptySubsequences: false)` produces for inputs
    /// ending in a newline — without this, every normal source-file diff
    /// renders with a spurious empty `-` or `+` line.
    private static func diffLines(_ s: String) -> [Substring] {
        var parts = s.split(separator: "\n", omittingEmptySubsequences: false)
        if parts.last?.isEmpty == true { parts.removeLast() }
        return parts
    }

    /// First non-empty line of `full`, truncated to ~80 chars. Used as
    /// the collapsed-row teaser.
    private static func previewLine(_ full: String) -> String? {
        let firstLine = full.split(separator: "\n", omittingEmptySubsequences: true).first
            ?? full[full.startIndex..<full.endIndex]
        let s = String(firstLine).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return nil }
        return s.count > 80 ? String(s.prefix(80)) + "…" : s
    }

    private static func mergeTerminalIds(_ primary: [String], _ secondary: [String]) -> [String] {
        var seen = Set<String>()
        var merged: [String] = []
        for terminalId in primary + secondary where seen.insert(terminalId).inserted {
            merged.append(terminalId)
        }
        return merged
    }

    private static func extractMetadataTerminalIds(_ metadata: AnyCodable?) -> [String] {
        guard let root = Self.metadataObject(metadata) else { return [] }
        let fields = ["terminal_info", "terminal_output", "terminal_output_delta"]
        return fields.compactMap { field in
            guard let object = Self.metadataObject(root[field]) else { return nil }
            return Self.metadataScalarString(object["terminal_id"])
        }
    }

    private static func mergeMetadata(_ existing: AnyCodable?, _ update: AnyCodable) -> AnyCodable {
        guard var merged = Self.metadataObject(existing),
              let updateObject = Self.metadataObject(update) else {
            return update
        }
        for (key, value) in updateObject {
            merged[key] = value
        }
        return AnyCodable(merged)
    }

    private static func metadataString(_ value: AnyCodable?) -> String? {
        guard let value else { return nil }
        if let string = value.value as? String { return boundedMetadataPreview(string) }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(value) else { return nil }
        return String(data: data, encoding: .utf8).map(boundedMetadataPreview)
    }

    private static func boundedMetadataPreview(_ string: String) -> String {
        guard string.count > metadataPreviewLimit else { return string }
        return String(string.prefix(metadataPreviewLimit)) + "… [truncated]"
    }

    private func applyToolCallMetadata(_ metadata: AnyCodable?) {
        guard let root = Self.metadataObject(metadata) else { return }

        if let info = Self.metadataObject(root["terminal_info"]),
           let terminalId = Self.metadataScalarString(info["terminal_id"]) {
            terminalHost.recordMetadataTerminalInfo(
                terminalId: terminalId,
                cwd: Self.metadataScalarString(info["cwd"]))
        }

        if let output = Self.metadataObject(root["terminal_output"]),
           let terminalId = Self.metadataScalarString(output["terminal_id"]),
           let text = Self.metadataScalarString(output["data"]) {
            terminalHost.appendMetadataOutput(
                terminalId: terminalId,
                data: Data(text.utf8),
                replace: true)
        }

        if let delta = Self.metadataObject(root["terminal_output_delta"]),
           let terminalId = Self.metadataScalarString(delta["terminal_id"]),
           let text = Self.metadataScalarString(delta["data"]) {
            terminalHost.appendMetadataOutput(
                terminalId: terminalId,
                data: Data(text.utf8),
                replace: false)
        }

        if let exit = Self.metadataObject(root["terminal_exit"]),
           let terminalId = Self.metadataScalarString(exit["terminal_id"]) {
            terminalHost.recordMetadataExit(
                terminalId: terminalId,
                exitStatus: ACPTerminalExitStatus(
                    exitCode: Self.metadataInt(exit["exit_code"]),
                    signal: Self.metadataScalarString(exit["signal"])))
        }
    }

    private static func metadataObject(_ value: AnyCodable?) -> [String: AnyCodable]? {
        if let dict = value?.value as? [String: AnyCodable] { return dict }
        if let dict = value?.value as? [String: Any] {
            return dict.mapValues { raw in
                (raw as? AnyCodable) ?? AnyCodable(raw)
            }
        }
        return nil
    }

    private static func metadataScalarString(_ value: AnyCodable?) -> String? {
        guard let raw = value?.value, !(raw is NSNull) else { return nil }
        return raw as? String
    }

    private static func metadataInt(_ value: AnyCodable?) -> Int? {
        guard let raw = value?.value, !(raw is NSNull) else { return nil }
        if let int = raw as? Int { return int }
        if let double = raw as? Double, double.rounded(.towardZero) == double {
            return Int(double)
        }
        return nil
    }

    private static func metadataArray(_ value: AnyCodable?) -> [AnyCodable]? {
        if let array = value?.value as? [AnyCodable] { return array }
        if let array = value?.value as? [Any] {
            return array.map { raw in
                (raw as? AnyCodable) ?? AnyCodable(raw)
            }
        }
        return nil
    }

    private static func extractTerminalIds(_ items: [ACPToolCallContent]) -> [String] {
        items.compactMap { if case .terminal(let id) = $0 { return id } else { return nil } }
    }

    private static func mergeAssets(
        _ primary: [ACPMessage.ToolCallAsset],
        _ secondary: [ACPMessage.ToolCallAsset]
    ) -> [ACPMessage.ToolCallAsset] {
        var seen = Set<ACPMessage.ToolCallAsset>()
        var merged: [ACPMessage.ToolCallAsset] = []
        for asset in primary + secondary where seen.insert(asset).inserted {
            merged.append(asset)
        }
        return merged
    }

    private static func extractAssets(_ items: [ACPToolCallContent]) -> [ACPMessage.ToolCallAsset] {
        items.compactMap { item in
            guard case .content(let block) = item else { return nil }
            switch block {
            case .image(let data, let uri, let mime):
                return .image(data: data, uri: uri, mimeType: mime, name: Self.assetName(from: uri))
            case .resourceLink(let uri, let name):
                return .resource(uri: uri, name: name)
            case .resource(let uri, let mime, _):
                return .resource(uri: uri, name: Self.assetName(from: uri), mimeType: mime)
            case .text:
                return nil
            }
        }
    }

    private static func extractRawOutputAssets(_ value: AnyCodable?) -> [ACPMessage.ToolCallAsset] {
        var assets: [ACPMessage.ToolCallAsset] = []
        collectRawOutputAssets(value, into: &assets)
        return mergeAssets([], assets)
    }

    private static func collectRawOutputAssets(_ value: AnyCodable?, into assets: inout [ACPMessage.ToolCallAsset]) {
        guard let value else { return }

        if let object = metadataObject(value) {
            if let data = metadataScalarString(object["b64_json"]), !data.isEmpty {
                assets.append(.image(data: data, mimeType: "image/png"))
            }
            let rawData = metadataScalarString(object["data"])
            let mimeDataType = rawOutputMimeType(object)
            let consumedDataImage: Bool
            if let data = rawData,
               let mimeType = dataImageMimeType(data) {
                assets.append(.image(data: data, mimeType: mimeType))
                consumedDataImage = true
            } else if let data = rawData,
                      let mimeType = mimeDataType,
                      mimeType.lowercased().hasPrefix("image/"),
                      !data.isEmpty {
                assets.append(.image(data: data, mimeType: mimeType))
                consumedDataImage = true
            } else {
                consumedDataImage = false
            }
            if let uri = metadataScalarString(object["url"]),
               rawOutputURLLooksLikeImage(uri, in: object) {
                assets.append(.image(
                    data: nil,
                    uri: uri,
                    mimeType: dataImageMimeType(uri) ?? rawOutputMimeType(object),
                    name: assetName(from: uri)))
            }

            for (key, child) in object
                where key != "b64_json"
                    && key != "url"
                    && !(key == "data" && consumedDataImage) {
                collectRawOutputAssets(child, into: &assets)
            }
            return
        }

        if let array = metadataArray(value) {
            for child in array {
                collectRawOutputAssets(child, into: &assets)
            }
            return
        }

        if let string = metadataScalarString(value),
           let mimeType = dataImageMimeType(string) {
            assets.append(.image(data: string, mimeType: mimeType))
        } else if let string = metadataScalarString(value),
                  let data = string.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) {
            collectRawOutputAssets(AnyCodable(json), into: &assets)
        }
    }

    private static func dataImageMimeType(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.lowercased().hasPrefix("data:image/"),
              let semicolon = trimmed.firstIndex(of: ";")
        else { return nil }
        return String(trimmed[..<semicolon].dropFirst("data:".count))
    }

    private static func rawOutputURLLooksLikeImage(_ uri: String, in object: [String: AnyCodable]) -> Bool {
        if dataImageMimeType(uri) != nil { return true }
        if rawOutputMimeType(object)?.lowercased().hasPrefix("image/") == true { return true }
        if metadataScalarString(object["type"])?.lowercased() == "image" { return true }
        if object["revised_prompt"] != nil { return true }
        let pathExtension = URL(string: uri)?.pathExtension.lowercased()
            ?? URL(fileURLWithPath: uri).pathExtension.lowercased()
        switch pathExtension {
        case "png", "jpg", "jpeg", "gif", "heic", "heif", "tiff", "webp":
            return true
        default:
            return false
        }
    }

    private static func rawOutputMimeType(_ object: [String: AnyCodable]) -> String? {
        metadataScalarString(object["mimeType"])
            ?? metadataScalarString(object["mime_type"])
            ?? metadataScalarString(object["mimetype"])
    }

    private static func extractStoredRawOutputAssets(
        _ rawOutput: String?,
        existingAssets: [ACPMessage.ToolCallAsset]
    ) -> [ACPMessage.ToolCallAsset] {
        guard let rawOutput else { return [] }
        let parsedAssets = extractRawOutputAssets(AnyCodable(rawOutput))
        if !parsedAssets.isEmpty { return parsedAssets }

        let lower = rawOutput.lowercased()
        guard lower.contains("\"b64_json\"")
            || lower.contains("data:image/")
            || lower.contains("\"url\"")
            || lower.contains("\"mimetype\"")
            || lower.contains("\"mime_type\"")
        else { return [] }
        return existingAssets.filter { asset in
            guard asset.kind == .image else { return false }
            if let data = asset.data,
               !data.isEmpty,
               rawOutput.contains(String(data.prefix(128))) {
                return true
            }
            if let uri = asset.uri, rawOutput.contains(uri) { return true }
            if let uri = asset.uri,
               dataImageMimeType(uri) != nil,
               rawOutput.contains(String(uri.prefix(128))) {
                return true
            }
            return false
        }
    }

    private static func assetName(from uri: String?) -> String? {
        guard let uri, !uri.isEmpty else { return nil }
        if uri.trimmingCharacters(in: .whitespacesAndNewlines).lowercased().hasPrefix("data:") {
            return nil
        }
        return URL(string: uri)?.lastPathComponent
            ?? URL(fileURLWithPath: uri).lastPathComponent
    }

    private func applySessionInfoUpdate(_ info: ACPSessionInfoUpdate) {
        switch info.title {
        case .absent:
            break
        case .null:
            if titleSource != .manual {
                title = "New session"
                titleSource = .placeholder
            }
        case .value(let rawTitle):
            let trimmed = rawTitle.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty, titleSource != .manual {
                title = trimmed
                titleSource = .generated
            }
        }
        applyGoalMetadata(info.metadata)
    }

    private func applyGoalMetadata(_ metadata: AnyCodable?) {
        guard let metadata,
              let root = Self.metadataObject(metadata)
        else { return }

        if let goal = root["goal"] {
            applyGoalValue(goal)
        } else if let codex = Self.metadataObject(root["codex"]),
                  let goal = codex["goal"] {
            applyGoalValue(goal)
        }
    }

    private func applyGoalValue(_ value: AnyCodable) {
        if value.value is NSNull {
            currentGoal = nil
            return
        }
        guard let goal = Self.metadataObject(value) else { return }

        let objective: String
        if let rawObjective = Self.metadataScalarString(goal["objective"])?.trimmingCharacters(in: .whitespacesAndNewlines),
           !rawObjective.isEmpty {
            objective = rawObjective
        } else if let existing = currentGoal {
            objective = existing.objective
        } else {
            return
        }

        currentGoal = ACPGoalState(
            objective: objective,
            status: goal.keys.contains("status") ? Self.metadataScalarString(goal["status"]) : currentGoal?.status,
            tokenBudget: goal.keys.contains("tokenBudget") ? Self.metadataInt(goal["tokenBudget"]) : currentGoal?.tokenBudget)
    }

    /// Best-effort strip of a single pair of markdown code fences that
    /// wrap the entire tool output. Claude sometimes returns its output
    /// inside a ```…``` block; Codex returns raw text. The opening fence
    /// is only recognized at line 1 col 0 so a fence inside the real
    /// output is left alone. The trailing fence is dropped only when
    /// `isFinal` is true — mid-stream we can't tell a closing ``` from a
    /// line of real output that happens to be three backticks.
    static func stripWrappingFence(_ full: String, isFinal: Bool) -> String {
        guard !full.isEmpty else { return full }
        var lines = full.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        guard let first = lines.first, isOpeningFence(first) else { return full }
        lines.removeFirst()
        if isFinal {
            var trailingEmpty = 0
            while let last = lines.last, last.isEmpty {
                lines.removeLast()
                trailingEmpty += 1
            }
            if lines.last == "```" {
                lines.removeLast()
            } else {
                for _ in 0..<trailingEmpty { lines.append("") }
            }
        }
        return lines.joined(separator: "\n")
    }

    static func wrappingFenceLanguage(_ full: String) -> String? {
        guard let first = full.split(separator: "\n", omittingEmptySubsequences: false).first else {
            return nil
        }
        let line = String(first)
        guard line.hasPrefix("```") else { return nil }
        return ACPCodeLanguage.highlighterExtension(for: String(line.dropFirst(3)))
    }

    private static func isOpeningFence(_ line: String) -> Bool {
        guard line.hasPrefix("```") else { return false }
        let rest = line.dropFirst(3)
        return rest.allSatisfy { $0.isLetter || $0.isNumber || $0 == "_" || $0 == "+" || $0 == "-" }
    }

    private static func isFinalStatus(_ status: String) -> Bool {
        switch status {
        case "completed", "failed", "canceled", "cancelled": return true
        default: return false
        }
    }

    private func text(of block: ACPContentBlock) -> String {
        if case .text(let s) = block { return s }
        return ""
    }

    private func lastAgent() -> Int? {
        for i in stride(from: transcript.messages.count - 1, through: 0, by: -1) {
            // STOP on .user — every new user turn starts a fresh
            // agent reply. Without this the agent's response to a NEW
            // prompt gets appended to the previous turn's trailing
            // agent message, breaking the conversation order.
            if case .user = transcript.messages[i] { return nil }
            if case .agent = transcript.messages[i] { return i }
            if case .toolCall = transcript.messages[i] { return nil }
            if case .fileEdit = transcript.messages[i] { return nil }
        }
        return nil
    }
    private func lastThought() -> Int? {
        for i in stride(from: transcript.messages.count - 1, through: 0, by: -1) {
            if case .user = transcript.messages[i] { return nil }
            if case .thought = transcript.messages[i] { return i }
            if case .agent = transcript.messages[i] { return nil }
            if case .toolCall = transcript.messages[i] { return nil }
        }
        return nil
    }

    private enum TextMessageKind {
        case user
        case agent
        case thought
    }

    private func messageIndex(messageId: String, kind: TextMessageKind) -> Int? {
        transcript.messages.firstIndex { message in
            switch (kind, message) {
            case (.user, .user(_, let existing, _, _)),
                 (.agent, .agent(_, let existing, _)),
                 (.thought, .thought(_, let existing, _)):
                return existing == messageId
            default:
                return false
            }
        }
    }

    private func appendUserChunk(text addition: String, attachments newAttachments: [ACPMessage.Attachment], messageId: String?) -> Int? {
        let located = messageId.flatMap { messageIndex(messageId: $0, kind: .user) }
        if let i = located,
           case .user(let id, let existingMessageId, let text, let attachments) = transcript.messages[i] {
            let mergedAttachments = Self.mergingAttachments(attachments, newAttachments)
            let mergedText = text + Self.streamingSeparator(between: text, and: addition) + addition
            if text == mergedText && attachments == mergedAttachments {
                return i
            }
            let isLiveUserChunk = existingMessageId.map {
                liveUserChunkMessageIds.contains($0)
            } == true
            let isReconciledEchoChunk = existingMessageId.map {
                !addition.isEmpty
                    && text.contains(addition)
                    && reconciledLocalUserPromptMessageIds.contains($0)
            } == true && newAttachments.isEmpty
            let isHydratedReplayChunk = existingMessageId.map {
                !addition.isEmpty
                    && text.contains(addition)
                    && !reconciledLocalUserPromptMessageIds.contains($0)
                    && !liveUserChunkMessageIds.contains($0)
            } == true && newAttachments.isEmpty
            if (!isLiveUserChunk && text == addition && attachments == mergedAttachments)
                || isHydratedReplayChunk
                || isReconciledEchoChunk {
                return i
            }
            transcript.messages[i] = .user(
                id: id,
                messageId: existingMessageId,
                text: mergedText,
                attachments: mergedAttachments)
            if let existingMessageId {
                liveUserChunkMessageIds.insert(existingMessageId)
            }
            transcript.streamingTick &+= 1
            return i
        }

        if let i = lastEchoedLocalUserPromptIndex(matching: addition, attachments: newAttachments),
           case .user(let id, let existingMessageId, let text, let attachments) = transcript.messages[i] {
            if existingMessageId == nil {
                if let messageId {
                    transcript.messages[i] = .user(
                        id: id,
                        messageId: messageId,
                        text: text,
                        attachments: Self.mergingAttachments(attachments, newAttachments))
                    reconciledLocalUserPromptMessageIds.insert(messageId)
                    transcript.streamingTick &+= 1
                } else {
                    reconciledLegacyLocalUserPromptIds.insert(id)
                }
            }
            return i
        }

        if messageId == nil,
           let i = lastLegacyUserChunkIndex(),
           case .user(let id, let existingMessageId, let text, let attachments) = transcript.messages[i] {
            let mergedText = text + Self.streamingSeparator(between: text, and: addition) + addition
            let mergedAttachments = Self.mergingAttachments(attachments, newAttachments)
            if text == mergedText && attachments == mergedAttachments {
                return i
            }
            transcript.messages[i] = .user(
                id: id,
                messageId: existingMessageId,
                text: mergedText,
                attachments: mergedAttachments)
            transcript.streamingTick &+= 1
            return i
        }

        if messageId != nil,
           !allowsStreamingBoundaryCrossing,
           userMessageExists(containing: addition, attachments: newAttachments) {
            return nil
        }

        if addition.isEmpty {
            guard !newAttachments.isEmpty else { return nil }
            let id = UUID()
            transcript.messages.append(.user(id: id, messageId: messageId, text: addition, attachments: newAttachments))
            if let messageId {
                liveUserChunkMessageIds.insert(messageId)
            } else {
                legacyUserChunkMessageIds.insert(id)
            }
            didAppendTranscriptMessage()
            transcript.completedOutputBoundaryMessageIds.removeAll()
            return transcript.messages.count - 1
        }

        let id = UUID()
        transcript.messages.append(.user(id: id, messageId: messageId, text: addition, attachments: newAttachments))
        if let messageId {
            liveUserChunkMessageIds.insert(messageId)
        } else {
            legacyUserChunkMessageIds.insert(id)
        }
        didAppendTranscriptMessage()
        transcript.completedOutputBoundaryMessageIds.removeAll()
        return transcript.messages.count - 1
    }

    private static func mergingAttachments(_ existing: [ACPMessage.Attachment],
                                           _ additions: [ACPMessage.Attachment]) -> [ACPMessage.Attachment] {
        additions.reduce(into: existing) { result, attachment in
            if !result.contains(attachment) {
                result.append(attachment)
            }
        }
    }

    private func lastLegacyUserChunkIndex() -> Int? {
        guard let index = transcript.messages.indices.last else { return nil }
        if case .user(let id, let messageId, _, _) = transcript.messages[index],
           messageId == nil,
           legacyUserChunkMessageIds.contains(id) {
            return index
        }
        return nil
    }

    private func lastEchoedLocalUserPromptIndex(matching text: String, attachments: [ACPMessage.Attachment]) -> Int? {
        guard !text.isEmpty || !attachments.isEmpty else { return nil }
        return transcript.messages.indices.reversed().first { index in
            if case .user(let id, let messageId, let existing, let existingAttachments) = transcript.messages[index] {
                guard messageId == nil,
                      !legacyUserChunkMessageIds.contains(id) else { return false }
                if !text.isEmpty {
                    return existing.hasPrefix(text)
                        || (reconciledLegacyLocalUserPromptIds.contains(id) && existing.contains(text))
                }
                return attachments.allSatisfy { existingAttachments.contains($0) }
            }
            return false
        }
    }

    private func messageExists(kind: TextMessageKind, containing text: String) -> Bool {
        guard !text.isEmpty else { return false }
        return transcript.messages.contains { message in
            switch (kind, message) {
            case (.agent, .agent(_, _, let existing)),
                 (.thought, .thought(_, _, let existing)):
                return existing.value.contains(text)
            default:
                return false
            }
        }
    }

    private func userMessageExists(containing text: String, attachments: [ACPMessage.Attachment]) -> Bool {
        guard !text.isEmpty || !attachments.isEmpty else { return false }
        return transcript.messages.contains { message in
            guard case .user(_, _, let existing, let existingAttachments) = message else { return false }
            if !text.isEmpty, existing.contains(text) {
                return true
            }
            return !attachments.isEmpty && attachments.allSatisfy { existingAttachments.contains($0) }
        }
    }

    /// Returns the index of the message that was appended or mutated.
    private func appendStreaming(text addition: String,
                                 messageId: String?,
                                 locateByMessageId: (String) -> Int?,
                                 locateLegacy: () -> Int?,
                                 isLikelyReplay: (String) -> Bool,
                                 makeNew: () -> ACPMessage) -> Int? {
        let located = if let messageId {
            locateByMessageId(messageId)
        } else {
            locateLegacy()
        }
        if let i = located {
            let stableId = transcript.messages[i].stableId
            let crossesCompletedBoundary = transcript.completedOutputBoundaryMessageIds.contains(stableId)
            if messageId != nil,
               !allowsStreamingBoundaryCrossing,
               (crossesCompletedBoundary || hasUserAfterMessage(at: i)) {
                return i
            }
            if crossesCompletedBoundary {
                // Discard if boundary crossings are not allowed — this chunk
                // is a late replay frame arriving after load-replay suppression
                // ended. Return the existing message index without mutating.
                guard allowsStreamingBoundaryCrossing else { return i }
                transcript.completedOutputBoundaryMessageIds.remove(stableId)
            }
            if !crossesCompletedBoundary || messageId != nil {
                switch transcript.messages[i] {
                case .agent(_, _, let buf), .thought(_, _, let buf):
                    buf.append(Self.streamingSeparator(between: buf.value, and: addition) + addition)
                    transcript.streamingTick &+= 1
                    return i
                default:
                    break
                }
            }
        }
        if messageId != nil, !allowsStreamingBoundaryCrossing, isLikelyReplay(addition) {
            return nil
        }
        transcript.messages.append(makeNew())
        didAppendTranscriptMessage()
        return transcript.messages.count - 1
    }

    private func hasUserAfterMessage(at index: Int) -> Bool {
        guard transcript.messages.indices.contains(index), index < transcript.messages.index(before: transcript.messages.endIndex) else {
            return false
        }
        return transcript.messages[(index + 1)...].contains { message in
            if case .user = message {
                return true
            }
            return false
        }
    }

    /// Returns the separator (if any) to insert between two streaming
    /// chunks before appending `next` to `previous`. Adapters sometimes
    /// split their stream at a sentence boundary and drop the trailing
    /// whitespace, so a chunk ending in `.` is followed by one starting
    /// with an uppercase letter — `append` with no separator would glue
    /// them as `completed.Running`, mashing two sentences together. When
    /// we detect that boundary, inject a newline so the second sentence
    /// starts on its own line.
    ///
    /// To avoid corrupting identifiers / URLs / paths that happen to be
    /// split across chunks (`Foo.` + `Bar`, `example.com.` + `Path`), we
    /// require the word immediately before the punctuation to be all
    /// lowercase (a real English word ending a sentence, not a CamelCase
    /// token) and not look like the tail of a URL or path (no `/` or `://`
    /// in the run of non-whitespace preceding the punctuation).
    private static func streamingSeparator(between previous: String, and next: String) -> String {
        guard let last = previous.last, let first = next.first else { return "" }
        if last.isWhitespace || first.isWhitespace { return "" }
        guard last == "." || last == "!" || last == "?" else { return "" }
        // Next chunk must start with an uppercase letter followed by a
        // lowercase one (start of a new sentence, not an all-caps acronym
        // like `API`).
        guard let firstUpper = first.asciiValue,
              firstUpper >= 0x41 && firstUpper <= 0x5A,
              let secondScalar = next.unicodeScalars.dropFirst().first,
              secondScalar.value >= 0x61 && secondScalar.value <= 0x7A
        else { return "" }
        // Walk back from the punctuation over the preceding run of
        // non-whitespace. The word immediately before the punctuation must
        // be all lowercase ASCII letters — this excludes CamelCase tokens
        // like `Foo` in `Foo.Bar` and acronyms like `SHA` in `head SHA.Git`.
        // A `/` or `://` in that run signals a URL/path tail (e.g.
        // `example.com.` split before `Path`), which we also leave alone.
        let scalars = previous.unicodeScalars
        var i = scalars.index(before: scalars.endIndex) // the punctuation
        // No word before the punctuation (chunk is just "." or "!" etc.) —
        // nothing to validate, treat as no separator.
        guard i > scalars.startIndex else { return "" }
        scalars.formIndex(before: &i) // first char of the word run
        var hasSlash = false
        var hasColon = false
        var wordChars: [UInt32] = []
        var precededByWhitespace = false
        while i >= scalars.startIndex {
            let s = scalars[i]
            if s.value == 0x20 || (s.value >= 0x09 && s.value <= 0x0D) {
                precededByWhitespace = true
                break
            }
            wordChars.append(s.value)
            if s == "/" { hasSlash = true }
            if s == ":" { hasColon = true }
            if i == scalars.startIndex { break }
            scalars.formIndex(before: &i)
        }
        // A `/` or `:` in the preceding run signals a URL/path tail
        // (e.g. `example.com.` split before `Path`); leave it alone.
        if hasSlash || hasColon { return "" }
        // The word must be all lowercase ASCII letters. Require it to be
        // preceded by whitespace so a qualified identifier whose left
        // segment is lowercase (`package.Type`, `self.Value`) doesn't get
        // a newline injected — a sentence-ending word in prose is always
        // preceded by a space, a code identifier usually isn't.
        guard precededByWhitespace, !wordChars.isEmpty, wordChars.allSatisfy({ v in
            v >= 0x61 && v <= 0x7A
        }) else { return "" }
        return "\n"
    }
    /// Returns the index of the matching tool call, or nil if no match.
    private func updateToolCall(id: String, _ mutate: (inout ACPMessage.ToolCall) -> Void) -> Int? {
        if let i = toolCallIndices[id],
           transcript.messages.indices.contains(i),
           case .toolCall(var tc) = transcript.messages[i],
           tc.toolCallId == id {
            mutate(&tc)
            transcript.messages[i] = .toolCall(tc)
            return i
        }

        for i in transcript.messages.indices {
            if case .toolCall(var tc) = transcript.messages[i], tc.toolCallId == id {
                toolCallIndices[id] = i
                mutate(&tc)
                transcript.messages[i] = .toolCall(tc)
                return i
            }
        }
        return nil
    }

    private func didAppendTranscriptMessage() {
        let index = transcript.messages.count - 1
        if case .toolCall(let tc) = transcript.messages[index] {
            toolCallIndices[tc.toolCallId] = index
        }
        advanceRenderWindowIfFollowingTail()
    }

    private func clearRestoredContextRecoveryStatus() {
        guard contextRecoveryStatus == .restored else { return }
        contextRecoveryExpiryTask?.cancel()
        contextRecoveryExpiryTask = nil
        contextRecoveryStatus = nil
    }

    private func rebuildToolCallIndices() {
        toolCallIndices.removeAll(keepingCapacity: true)
        for i in transcript.messages.indices {
            if case .toolCall(let tc) = transcript.messages[i] {
                toolCallIndices[tc.toolCallId] = i
            }
        }
    }

    private func advanceRenderWindowIfFollowingTail() {
        guard followsTranscriptTail else { return }
        transcript.setVisibleHead(max(0, transcript.messages.count - ACPTranscript.tailWindow))
    }
}
