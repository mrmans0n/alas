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

enum ACPSessionTitleSource: String, Codable, Sendable {
    case placeholder
    case generated
    case manual
}

struct ACPGoalState: Equatable, Hashable, Sendable {
    let objective: String
    let status: String?
    let tokenBudget: Int?
}

struct ACPRetryStatus: Equatable {
    let turnId: String?
    let detail: String?
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
    private(set) var origin: ACPSessionOrigin
    @Published var availableModels: [ACPModelInfo] = []
    @Published var availableModes: [ACPModeInfo] = []
    @Published var availableConfigOptions: [ACPConfigOption] = []
    /// Runtime-only provider state learned from the adapter on each attach.
    @Published var providerCapabilities: EmptyObject?
    @Published var availableProviders: [ACPProviderInfo] = []
    @Published var currentModel: String?
    @Published var contextUsage: ACPUsageInfo?
    @Published var currentMode: String?
    @Published var currentGoal: ACPGoalState?
    @Published var promptSuggestions: [ACPPromptSuggestion] = []
    @Published var autoRunEnabled: Bool = false
    @Published var setupState: SetupState = .checking
    @Published var lastError: String?
    /// Runtime-only state reported by Codex while its current turn retries.
    @Published private(set) var retryStatus: ACPRetryStatus?
    @Published var contextRestoreWarning: ContextRestoreWarning?
    @Published var contextRecoveryStatus: ContextRecoveryStatus?
    /// Runtime-only transcript scroll intent. When true, the ACP message
    /// list follows new content and restores to the latest bottom after
    /// returning to this session. Set false when the user scrolls upward.
    @Published var followsTranscriptTail: Bool = true
    /// Lifecycle state of the agent process backing this session.
    /// Single source of truth for the composer, header pill, and runner
    /// registry checks.
    /// Note: `AgentState.idle` means "no runner spawned yet" (process
    /// lifecycle), distinct from `StreamingState.idle` which means
    /// "runner is attached but not currently mid-prompt" (turn lifecycle).
    @Published var agentState: AgentState = .idle
    /// Runtime-only state for bounded remote SSH reconnection attempts.
    @Published var autoReconnecting: Bool = false
    /// Prompt content capabilities learned from ACP `initialize`.
    /// Runtime-only: re-learned on each attach, never persisted. Drives
    /// send-time hydration in `ACPSessionRunner.hydrate`.
    @Published var promptCapabilities: ACPInitializeResult.ACPPromptCapabilities = .init()
    /// Session capabilities learned from ACP `initialize`.
    /// Runtime-only: re-learned on each attach and used to select a fork
    /// mechanism for this session.
    @Published var sessionCapabilities: ACPInitializeResult.ACPAgentSessionCapabilities?
    /// Persisted fork lineage hydrated with the session. A nil value means
    /// this session was not created as a fork.
    @Published var forkRecord: ACPSessionForkRecord?
    /// Auth methods learned from ACP `initialize`.
    /// Runtime-only: re-learned on each attach and used when an agent asks
    /// the client to authenticate before ACP can continue.
    @Published var authMethods: [ACPInitializeResult.ACPAuthMethod] = []
    /// Runtime-only MCP attachment result for the most recent attach. It
    /// contains no resolved commands, environment values, or headers.
    @Published var mcpAttachmentSummary: MCPAttachmentSummary?
    /// MCP context preamble queued for the next prompt of a freshly created
    /// remote session. Wire-only: prepended to the outgoing blocks by the
    /// runner, never recorded in the transcript. Cleared after the first
    /// successful `session/prompt`. Persisted so an app restart before the
    /// first prompt does not lose it.
    @Published var pendingMCPPreamble: String?
    /// Whether this session's MCP preamble was delivered in a prompt.
    @Published var mcpPreambleSent: Bool = false
    /// Runtime-only status for adapters that ignore ACP MCP config
    /// (`ACPMCPInjectionSupport.external`): how Alas tools and user MCP
    /// servers actually reach this agent. Recomputed on every attach.
    @Published var mcpExternalStatus: ACPMCPExternalStatus?
    /// Registration state of the built-in "alas" MCP server for the current
    /// attach. Drives the MCP status control's warning + transport-switch action.
    @Published var builtInMCPRegistration: MCPServerRegistration = .unknown
    /// Whether the attached adapter advertised HTTP MCP support on `initialize`.
    /// Learned on each attach. Gates the "switch to HTTP transport" action: an
    /// adapter without HTTP MCP falls back to stdio, so offering the switch
    /// would loop back to a `.notRegistered` stdio server.
    @Published var adapterSupportsHTTPMCP: Bool = false
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

    /// Running text of streaming chunks that arrived with an unrecognised
    /// `messageId` while `allowsStreamingBoundaryCrossing` was false and
    /// still look like a late load-replay (their accumulated text is
    /// contained in an already-present message). Keyed by kind + messageId
    /// (ids are kind-scoped elsewhere — see `messageIndex` and `stableId` —
    /// so a thought and an agent chunk that reuse the same id must not share
    /// a candidate). Held rather than dropped so that if the stream diverges
    /// — i.e. it is genuine new output whose leading fragment merely
    /// coincided with an earlier message — the full text can be materialised
    /// without losing the leading characters. Cleared once the window ends.
    private var pendingReplayCandidates: [ReplayCandidateKey: ReplayCandidate] = [:]
    /// Monotonic counter stamping each candidate with its arrival order, so a
    /// flush materialises them in the order their first chunk arrived rather
    /// than by the opaque `messageId` (which need not sort chronologically).
    private var replayCandidateArrivalCounter: Int = 0

    private struct ReplayCandidateKey: Hashable {
        let kind: TextMessageKind
        let messageId: String
    }

    /// Two views of the accumulated replay text plus its arrival order.
    /// `display` carries the sentence-boundary separators a live stream
    /// injects (used when the text turns out to be genuine new output and is
    /// materialised); `raw` is the plain concatenation used for matching, so
    /// a replay that splits at a boundary the original stream did not is still
    /// recognised (the injected `\n` would otherwise cause a false mismatch).
    /// `arrivalOrder` preserves first-seen order across the buffer.
    private struct ReplayCandidate {
        var display: String
        var raw: String
        var arrivalOrder: Int
        var phase: ACPMessagePhase?
        var metadata: AnyCodable?
    }

    private var reconciledLocalUserPromptMessageIds: Set<String> = []
    private var reconciledLegacyLocalUserPromptIds: Set<UUID> = []
    private var liveUserChunkMessageIds: Set<String> = []
    private var legacyUserChunkMessageIds: Set<UUID> = []
    private var replayCreatedMetadataTerminalIds: Set<String> = []

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

    var currentProviderDisplayName: String? {
        guard agentState == .ready, providerCapabilities != nil else { return nil }
        let currentProviders = availableProviders.filter { $0.current != nil }
        guard currentProviders.count != 1 || !currentProviders[0].required else { return nil }
        let names = currentProviders
            .map { $0.name ?? $0.providerId }
        return names.isEmpty ? nil : names.joined(separator: ", ")
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
            case .user(_, _, let text, _, _):
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

    func canForkMessage(at index: Int) -> Bool {
        guard transcript.messages.indices.contains(index) else { return false }
        switch transcript.messages[index] {
        case .user(_, _, let text, _, _):
            return !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case .agent(_, _, let buffer):
            guard !buffer.value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return false
            }
            guard transcript.streamingState != .idle else { return true }
            return lastAgent() != index
        default:
            return false
        }
    }

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
        case setupError(reason: String)
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
         origin: ACPSessionOrigin = .alasCreated,
         createdAt: Date = Date(),
         hydrationState: HydrationState = .ready,
         restoredFromPersistence: Bool = false) {
        self.id = id
        self.agentId = agentId
        self.worktreeId = worktreeId
        self.title = title
        self.titleSource = titleSource
        self.origin = origin
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

    func markAsAgentForked() {
        origin = .agentForked
    }

    func recordUserPrompt(
        text: String,
        attachments: [ACPMessage.Attachment],
        delegatedSource: ACPDelegatedPromptSource? = nil
    ) {
        // Materialise any held replay candidate before the new prompt so
        // stranded live text from the just-ended turn keeps its place ahead
        // of the user message instead of being dropped. The runner persists
        // from the pre-call message count, so the flushed rows are saved too.
        _ = flushPendingReplayCandidates()
        transcript.appendMessage(.user(
            id: UUID(),
            messageId: nil,
            text: text,
            attachments: attachments,
            delegatedSource: delegatedSource
        ))
        didAppendTranscriptMessage()
        transcript.completedOutputBoundaryMessageIds.removeAll()
        if titleSource == .placeholder {
            let candidate = Self.removingAlasWorkspaceContext(from: text)
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

    private static func removingAlasWorkspaceContext(from text: String) -> String {
        var result = text
        let openingTag = "<alas-workspace-context>"
        let closingTag = "</alas-workspace-context>"
        while let openingRange = result.range(of: openingTag),
              let closingRange = result.range(
                  of: closingTag,
                  range: openingRange.upperBound..<result.endIndex
              ) {
            result.removeSubrange(openingRange.lowerBound..<closingRange.upperBound)
        }
        return result
    }

    /// Returns the set of transcript message indices that were appended or
    /// mutated by this update. Updates that only touch non-message state
    /// (model lists, mode, etc) return an empty set. The caller uses this
    /// to persist exactly the rows that changed — necessary because a
    /// `.plan` or `.toolCallUpdate` can mutate a message anywhere in the
    /// transcript, not just the trailing row.
    @discardableResult
    func apply(
        _ update: ACPSessionUpdate,
        tracksRetryStatus: Bool = true,
        at timestamp: Date = Date()
    ) -> Set<Int> {
        if tracksRetryStatus {
            switch update {
            case .agentMessageChunk, .agentThoughtChunk, .toolCall, .toolCallUpdate, .plan:
                clearRetryStatus()
            default:
                break
            }
        }
        // Materialise held replay candidates in order before an update that
        // closes their message, so a suppressed short fragment (e.g. "I",
        // buffered because it is a substring of prior output) is emitted in
        // place rather than stranded in `pendingReplayCandidates` and dropped.
        // Once the boundary window has ended, flush everything (residual
        // candidates are genuine output). Within the window:
        //   • a tool call or plan closes the whole in-progress run;
        //   • an agent answer closes an in-progress thought (`lastThought()`
        //     stops at `.agent`), so flush pending thoughts ahead of it — the
        //     agent candidate itself is handled by `appendStreaming`.
        // State-only updates append no row and must NOT flush a buffered
        // chunk into a duplicate; `userMessageChunk` (via `appendUserChunk`)
        // and the thought-before-agent-answer flush (via `appendStreaming`)
        // are both deferred until the incoming chunk is known to be live
        // rather than itself a suppressed replay.
        let kindsToFlush: Set<TextMessageKind>
        if allowsStreamingBoundaryCrossing {
            kindsToFlush = [.agent, .thought]
        } else {
            switch update {
            case .toolCall, .plan, .compactionUpdate, .compactionSummaryChunk:
                kindsToFlush = [.agent, .thought]
            default:
                kindsToFlush = []
            }
        }
        let flushed = kindsToFlush.isEmpty ? [] : flushPendingReplayCandidates(kinds: kindsToFlush)
        let result: Set<Int> = { () -> Set<Int> in
        switch update {
        case .agentMessageChunk(let chunk):
            clearRestoredContextRecoveryStatus()
            let txt = text(of: chunk.content)
            var flushedForAgent: Set<Int> = []
            guard let i = appendStreaming(
                text: txt,
                messageId: chunk.messageId,
                replayKind: .agent,
                locateByMessageId: { id in transcript.messageIndex(messageId: id, kind: .agent) },
                locateLegacy: { lastAgent() },
                replayCandidateMatches: { text in existingMessageContains(kind: .agent, text) },
                adoptContinuation: { candidate, phase, metadata in
                    chunk.messageId.flatMap {
                        adoptReplayContinuation(
                            kind: .agent, candidate: candidate, messageId: $0,
                            phase: phase, metadata: metadata)
                    }
                },
                flushedReplayIndices: &flushedForAgent,
                phase: chunk.phase,
                metadata: chunk.metadata,
                makeNew: { text, phase, metadata in
                    .agent(id: UUID(), messageId: chunk.messageId, StreamingText(text, phase: phase, metadata: metadata))
                }) else {
                return flushedForAgent
            }
            return flushedForAgent.union([i])
        case .userMessageChunk(let chunk):
            let txt = text(of: chunk.content)
            var flushedForUser: Set<Int> = []
            guard let i = appendUserChunk(
                text: txt,
                attachments: ACPSessionRunner.attachments(of: [chunk.content]),
                messageId: chunk.messageId,
                flushedReplayIndices: &flushedForUser) else {
                return []
            }
            return flushedForUser.union([i])
        case .agentThoughtChunk(let chunk):
            clearRestoredContextRecoveryStatus()
            let txt = text(of: chunk.content)
            var flushedForThought: Set<Int> = []
            guard let i = appendStreaming(
                text: txt,
                messageId: chunk.messageId,
                replayKind: .thought,
                locateByMessageId: { id in transcript.messageIndex(messageId: id, kind: .thought) },
                locateLegacy: { lastThought() },
                replayCandidateMatches: { text in existingMessageContains(kind: .thought, text) },
                adoptContinuation: { candidate, phase, metadata in
                    chunk.messageId.flatMap {
                        adoptReplayContinuation(
                            kind: .thought, candidate: candidate, messageId: $0,
                            phase: phase, metadata: metadata)
                    }
                },
                flushedReplayIndices: &flushedForThought,
                phase: chunk.phase,
                metadata: chunk.metadata,
                makeNew: { text, phase, metadata in
                    .thought(id: UUID(), messageId: chunk.messageId, StreamingText(text, phase: phase, metadata: metadata))
                }) else {
                return flushedForThought
            }
            return flushedForThought.union([i])
        case .toolCall(let payload):
            clearRestoredContextRecoveryStatus()
            let items = payload.content ?? []
            let raw = Self.flatten(items)
            let full = Self.stripWrappingFence(raw,
                                               isFinal: Self.isFinalStatus(payload.status))
            let terminalIds = Self.mergeTerminalIds(
                Self.extractTerminalIds(items),
                Self.extractMetadataTerminalIds(payload.metadata, includeExit: payload.content == nil))
            let rawOutputAssets = Self.extractRawOutputAssets(payload.rawOutput)
            transcript.appendMessage(.toolCall(.init(
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
                terminalIds: terminalIds,
                executionStartedAt: payload.status == "in_progress" ? timestamp : nil)),
                createdAt: timestamp)
            didAppendTranscriptMessage()
            transcript.completedOutputBoundaryMessageIds.removeAll()
            applyToolCallMetadata(payload.metadata)
            return [transcript.messages.count - 1]
        case .toolCallUpdate(let u):
            clearRestoredContextRecoveryStatus()
            let touched = updateToolCall(id: u.toolCallId) { tc in
                Self.applyToolCallUpdateFields(u, to: &tc)
                if tc.status == "in_progress", tc.executionStartedAt == nil {
                    tc.executionStartedAt = timestamp
                }
                if Self.isFinalStatus(tc.status), tc.executionStartedAt != nil,
                   tc.executionFinishedAt == nil {
                    tc.executionFinishedAt = timestamp
                }
            }
            if touched != nil {
                applyToolCallMetadata(u.metadata)
            }
            return touched.map { [$0] } ?? []
        case .compactionUpdate(let update):
            clearRestoredContextRecoveryStatus()
            return applyContextCompaction(update)
        case .compactionSummaryChunk(let chunk):
            clearRestoredContextRecoveryStatus()
            return appendContextCompactionSummary(chunk)
        case .sessionInfoUpdate(let info):
            applySessionInfoUpdate(info, tracksRetryStatus: tracksRetryStatus)
            return []
        case .plan(let entries):
            clearRestoredContextRecoveryStatus()
            let items = entries.map { ACPMessage.PlanItem(content: $0.content, status: $0.status) }
            // Overwrite the existing plan in place only if it belongs to
            // the current turn (i.e. sits after the latest user prompt).
            // Otherwise append a fresh plan so the previous turn's plan
            // stays at its original position and the new one is current.
            if let i = transcript.currentPlanMessageIndex,
               case .plan(let existingId, _) = transcript.messages[i] {
                transcript.replaceMessage(at: i, with: .plan(id: existingId, items))
                return [i]
            } else {
                transcript.appendMessage(.plan(id: UUID(), items))
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
        }()
        return flushed.union(result)
    }

    private func applyContextCompaction(_ update: ACPCompactionUpdate) -> Set<Int> {
        let toolCallId = Self.contextCompactionToolCallId(update.compactionId)
        let content = update.summary.map { $0.map(ACPToolCallContent.content) }
        let metadata = Self.contextCompactionMetadata(
            id: update.compactionId,
            trigger: nil,
            error: update.errorWasNull ? AnyCodable(NSNull()) : update.error.map { AnyCodable($0) },
            metadata: update.metadata
        )

        if let existing = transcript.toolCallIndex(toolCallId: toolCallId) {
            return updateToolCall(id: toolCallId) { toolCall in
                toolCall.status = update.status
                toolCall.metadata = Self.mergeMetadata(toolCall.metadata, metadata)
                if update.summaryWasProvided {
                    Self.applyToolCallContent(
                        items: update.summaryWasNull ? [] : (content ?? []),
                        isFinal: Self.isFinalStatus(toolCall.status),
                        rawOutputAssets: [],
                        rawOutputChanged: false,
                        metadataChanged: true,
                        to: &toolCall)
                }
            }.map { [$0] } ?? [existing]
        }

        let items = content ?? []
        let raw = Self.flatten(items)
        transcript.appendMessage(.toolCall(.init(
            toolCallId: toolCallId,
            title: "Compacting context",
            kind: "context_compaction",
            status: update.status,
            content: Self.stripWrappingFence(raw, isFinal: Self.isFinalStatus(update.status)),
            preview: Self.previewLine(raw),
            metadata: metadata
        )))
        didAppendTranscriptMessage()
        transcript.completedOutputBoundaryMessageIds.removeAll()
        return [transcript.messages.count - 1]
    }

    private func appendContextCompactionSummary(_ chunk: ACPCompactionSummaryChunk) -> Set<Int> {
        let toolCallId = Self.contextCompactionToolCallId(chunk.compactionId)
        guard let index = updateToolCall(id: toolCallId, { toolCall in
            let chunkText = text(of: chunk.content)
            guard !chunkText.isEmpty else { return }
            toolCall.replaceContent(toolCall.content + chunkText)
            toolCall.preview = Self.previewLine(toolCall.content)
        }) else {
            return []
        }
        return [index]
    }

    static func contextCompactionToolCallId(_ id: String) -> String {
        "context-compaction:\(id)"
    }

    private static func contextCompactionMetadata(
        id: String,
        trigger: String?,
        error: AnyCodable?,
        metadata: AnyCodable?
    ) -> AnyCodable {
        var facts: [String: AnyCodable] = ["version": AnyCodable(1)]
        facts["id"] = AnyCodable(id)
        if let trigger { facts["trigger"] = AnyCodable(trigger) }
        if let error { facts["error"] = error }
        if let metadata = metadata?.value as? [String: AnyCodable] {
            for key in ["preTokens", "postTokens", "durationMs"] {
                if let value = metadata[key] { facts[key] = value }
            }
        }
        return AnyCodable(["contextCompaction": AnyCodable(facts)])
    }

    /// Materialise held replay candidates of the given `kinds` as new rows
    /// (in a stable order), removing them from the buffer. Returns the
    /// indices appended so the caller can persist them. Called when the
    /// current text message closes (a row-appending update), the boundary
    /// window ends, or the turn completes, so a suppressed short fragment is
    /// never stranded and dropped.
    ///
    /// A candidate whose accumulated text exactly reproduces a complete
    /// existing message of its kind is a pure full replay that never
    /// diverged — it is dropped rather than materialised, preserving replay
    /// suppression. A candidate that merely coincided with a *substring* of a
    /// longer message (a genuine one-chunk reply like "OK" against an
    /// existing "OK done.") is materialised.
    @discardableResult
    private func flushPendingReplayCandidates(kinds: Set<TextMessageKind> = [.agent, .thought]) -> Set<Int> {
        guard !pendingReplayCandidates.isEmpty else { return [] }
        var indices: Set<Int> = []
        // Compare full-replay equality only against messages that existed
        // before this flush, so two distinct held chunks with identical text
        // (two one-chunk "OK" replies) don't collapse — the first materialised
        // row must not make the second look like a replay of it.
        let preFlushCount = transcript.messages.count
        let orderedKeys = pendingReplayCandidates.keys.sorted {
            (pendingReplayCandidates[$0]?.arrivalOrder ?? 0) < (pendingReplayCandidates[$1]?.arrivalOrder ?? 0)
        }
        for key in orderedKeys {
            guard kinds.contains(key.kind), let candidate = pendingReplayCandidates[key] else { continue }
            pendingReplayCandidates.removeValue(forKey: key)
            if existingMessageEquals(kind: key.kind, candidate.display, before: preFlushCount)
                || existingMessageEquals(kind: key.kind, candidate.raw, before: preFlushCount) {
                continue // pure full replay — keep suppressed
            }
            let message: ACPMessage
            switch key.kind {
            case .agent:
                message = .agent(id: UUID(), messageId: key.messageId, StreamingText(candidate.display, phase: candidate.phase, metadata: candidate.metadata))
            case .thought:
                message = .thought(id: UUID(), messageId: key.messageId, StreamingText(candidate.display, phase: candidate.phase, metadata: candidate.metadata))
            case .user:
                continue
            }
            transcript.appendMessage(message)
            didAppendTranscriptMessage()
            indices.insert(transcript.messages.count - 1)
        }
        return indices
    }

    /// Whether some message of `kind` in `transcript.messages[..<upperBound]`
    /// has value exactly equal to `text` — i.e. `text` reproduces that
    /// complete message (a full replay). `upperBound` excludes rows appended
    /// during the current flush so repeated identical outputs are preserved.
    private func existingMessageEquals(kind: TextMessageKind, _ text: String, before upperBound: Int) -> Bool {
        let end = min(upperBound, transcript.messages.count)
        guard end > 0 else { return false }
        return transcript.messages[..<end].contains { message in
            switch (kind, message) {
            case (.agent, .agent(_, _, let buf)),
                 (.thought, .thought(_, _, let buf)):
                return buf.value == text
            default:
                return false
            }
        }
    }

    func applySuppressedReplaySideEffects(_ update: ACPSessionUpdate) -> Set<Int> {
        switch update {
        case .toolCall(let payload):
            guard let touched = updateToolCall(id: payload.toolCallId, { tc in
                Self.applyToolCallPayloadFields(payload, to: &tc)
            }) else { return [] }
            applyToolCallMetadata(payload.metadata, replaying: true)
            return [touched]
        case .toolCallUpdate(let update):
            guard let touched = updateToolCall(id: update.toolCallId, { tc in
                Self.applyToolCallUpdateFields(update, to: &tc, allowFinalSnapshotReplacement: false)
            }) else { return [] }
            applyToolCallMetadata(update.metadata, replaying: true)
            return [touched]
        default:
            return []
        }
    }

    func beginSuppressedReplaySideEffects() {
        replayCreatedMetadataTerminalIds.removeAll()
    }

    func endSuppressedReplaySideEffects() {
        replayCreatedMetadataTerminalIds.removeAll()
    }

    private static func applyToolCallPayloadFields(
        _ payload: ACPToolCallPayload,
        to tc: inout ACPMessage.ToolCall
    ) {
        let canReplaceSnapshot = !Self.isFinalStatus(tc.status)
        if canReplaceSnapshot {
            tc.title = payload.title
            tc.kind = payload.kind
        }
        if canReplaceSnapshot {
            tc.status = payload.status
        }
        if canReplaceSnapshot, let locations = payload.locations { tc.locations = locations.map(\.path) }
        if canReplaceSnapshot, let rawInput = payload.rawInput { tc.rawInput = Self.metadataString(rawInput) }
        var rawOutputAssets: [ACPMessage.ToolCallAsset] = []
        if (canReplaceSnapshot || Self.isFinalStatus(payload.status)), let rawOutput = payload.rawOutput {
            tc.rawOutput = Self.metadataString(rawOutput)
            rawOutputAssets = Self.extractRawOutputAssets(rawOutput)
            tc.assets = Self.mergeAssets(tc.assets, rawOutputAssets)
        }
        if let metadata = payload.metadata {
            tc.metadata = Self.mergeMetadata(tc.metadata, metadata)
            tc.terminalIds = Self.mergeTerminalIds(
                tc.terminalIds,
                Self.extractMetadataTerminalIds(metadata, includeExit: payload.content == nil))
        }

        guard let items = payload.content else { return }
        if !canReplaceSnapshot {
            tc.terminalIds = Self.mergeTerminalIds(
                tc.terminalIds,
                Self.extractTerminalIds(items))
            if Self.isFinalStatus(payload.status) {
                tc.assets = Self.mergeAssets(tc.assets, Self.extractAssets(items))
            }
            return
        }
        Self.applyToolCallContent(
            items: items,
            isFinal: Self.isFinalStatus(payload.status),
            rawOutputAssets: rawOutputAssets,
            rawOutputChanged: payload.rawOutput != nil,
            metadataChanged: payload.metadata != nil,
            to: &tc)
    }

    /// Apply a `tool_call`/`tool_call_update` content payload to `tc`,
    /// taking the suffix-only fast path when the new flattened raw content
    /// is a prefix-extension of the previously applied one.
    ///
    /// Adapters that stream tool output re-emit the full cumulative content
    /// on every update, so the i-th update carries ~i/k · m bytes and the
    /// naive full-reprocess path is O(m·k) total work. Here we cache the
    /// last fully-applied flattened raw content on `tc` and:
    ///
    /// - When `raw` equals the cache AND `isFinal` is unchanged: nothing
    ///   changed, skip all content reprocessing (no `replaceContent`, no
    ///   `previewLine`, no fence strip, no asset/terminal scan).
    /// - When the cache is a non-empty prefix of `raw`, the previous apply
    ///   was not `isFinal`, and items are append-only: suffix-only fast
    ///   path. The new stripped-raw body is `appliedStrippedRaw + suffix`
    ///   (with the opening-fence-unterminated boundary adjustment); the
    ///   `isFinal` trailing-fence strip runs on the single final update.
    ///   `preview` and `contentLanguage` depend only on the first line,
    ///   so they are computed once and reused. Assets and terminal ids are
    ///   scanned only over the items beyond `tc.appliedItemCount`;
    ///   `mergeAssets`/`mergeTerminalIds` dedup.
    /// - Otherwise (first apply, divergent content, appending to a
    ///   finalized snapshot, or post-truncation restore): full reprocess,
    ///   exactly the legacy path, and refresh the cache.
    ///
    /// `isFinal` is computed by the caller from the relevant status field
    /// (`tc.status` for `toolCallUpdate`, `payload.status` for the initial
    /// `toolCall`) so the trailing-fence strip matches the legacy semantics.
    private static func applyToolCallContent(
        items: [ACPToolCallContent],
        isFinal: Bool,
        rawOutputAssets: [ACPMessage.ToolCallAsset],
        rawOutputChanged: Bool,
        metadataChanged: Bool,
        to tc: inout ACPMessage.ToolCall
    ) {
        let raw = Self.flatten(items)
        let prefixItemsUnchanged = Self.prefixItemsUnchanged(
            items: items, snapshot: tc.appliedItemsSnapshot, count: tc.appliedItemCount)
        if let prev = tc.appliedRawContent, raw == prev,
           items.count == tc.appliedItemCount, prefixItemsUnchanged {
            if isFinal == tc.appliedIsFinal && !rawOutputChanged && rawOutputAssets.isEmpty && !metadataChanged {
                // Content unchanged, item count unchanged, prefix items
                // unchanged, same isFinal, no rawOutput change, AND no
                // metadata change — nothing to do for the content body.
                // `rawOutputChanged` / `metadataChanged` guard the cases
                // where the update carried a new `rawOutput` or `_meta`
                // that changed terminal ids / assets even though the
                // flattened text is identical: the caller already merged
                // the new values, but the old terminal ids / stale image
                // are still in `tc.terminalIds` / `tc.assets`. Full
                // reprocess rebuilds from the current content + metadata
                // + rawOutput, matching the legacy semantics.
                // Item-count + prefix-items guards: `flatten` ignores
                // images/resource-links/terminals, so equal flattened text
                // does NOT imply the structured items are the same.
                return
            }
            // Same content but `isFinal` flipped (e.g. status transitioned to
            // completed without the body changing): the trailing-fence strip
            // may need to run. Full reprocess is safe and rare (one update
            // per tool call at most).
            Self.reprocessToolCallContentFull(
                raw: raw, items: items, isFinal: isFinal,
                rawOutputAssets: rawOutputAssets, to: &tc)
            return
        }
        if let prev = tc.appliedRawContent, !prev.isEmpty, raw.hasPrefix(prev),
           !tc.appliedIsFinal,
           items.count >= tc.appliedItemCount,
           prefixItemsUnchanged,
           !metadataChanged,
           !Self.previousRawWasPartialFence(prev) {
            // Suffix-only fast path. The new flattened raw is the previous
            // one with `suffix` appended; `appliedStrippedRaw` is the body
            // after opening-fence removal. We extend that body by the suffix
            // (handling the Case where the opening fence line arrived
            // unterminated in the previous chunk) and, if `isFinal`, apply
            // the trailing-fence strip to the resulting body.
            //
            // `prefixItemsUnchanged` guard: if any of the first
            // `appliedItemCount` items changed (in-place replacement, or a
            // terminal inserted before the text item), the suffix path's
            // `newItemSlice` would miss the structured change. Fall to full
            // reprocess so `extractAssets`/`extractTerminalIds` see the
            // current items.
            //
            // `previousRawWasPartialFence` guard: if the previous raw was a
            // PARTIAL opening fence (e.g. "``" — not yet a complete fence
            // line), `stripWrappingFence` did NOT strip it, so
            // `appliedStrippedRaw` still contains the partial fence. The
            // suffix might complete the fence line, which the legacy full
            // reprocess would now recognize and strip. Fall to full
            // reprocess in that case.
            let suffix = String(raw.dropFirst(prev.count))
            // When the opening fence is unterminated, `appliedStrippedRaw`
            // is empty and `extendStrippedRaw` needs the previous raw
            // fence line to re-validate. Otherwise it appends to
            // `appliedStrippedRaw` (the stripped body).
            let extendBase = tc.appliedOpeningFenceUnterminated ? prev : tc.appliedStrippedRaw
            let (newStrippedRaw, unterminated, needsFullReprocess) = Self.extendStrippedRaw(
                previousRaw: extendBase,
                suffix: suffix,
                openingFenceUnterminated: tc.appliedOpeningFenceUnterminated)
            if needsFullReprocess {
                Self.reprocessToolCallContentFull(
                    raw: raw, items: items, isFinal: isFinal,
                    rawOutputAssets: rawOutputAssets, to: &tc)
                return
            }
            let newStripped: String
            if isFinal && tc.appliedOpeningFenceStripped {
                // Only strip a trailing fence line when an opening fence
                // was actually recognized. Ordinary tool output whose
                // final line happens to be "```" must NOT be dropped —
                // `stripWrappingFence` guards the same way.
                newStripped = Self.stripTrailingFenceLine(newStrippedRaw)
            } else {
                newStripped = newStrippedRaw
            }
            tc.replaceContent(newStripped)
            tc.isContentTruncated = false
            // Refresh `preview`/`contentLanguage` when the first line is
            // still incomplete. `previewLine` is the first non-empty line;
            // once the first line is complete (followed by a newline or
            // EOF), the preview is stable. But if the previous preview was
            // derived from a partial first line (e.g. "bui" from "bui"),
            // and the suffix extends that first line (e.g. "lding\n..."),
            // the preview must be recomputed. Detect this: if the previous
            // `appliedStrippedRaw` had no newline, the first line was
            // incomplete and we recompute. Once a newline exists in
            // `appliedStrippedRaw`, the first line is stable.
            if tc.preview == nil || !Self.firstLineIsComplete(tc.appliedStrippedRaw) {
                tc.preview = Self.previewLine(newStripped)
            }
            if tc.contentLanguage == nil || !Self.firstLineIsComplete(tc.appliedStrippedRaw) {
                tc.contentLanguage = Self.wrappingFenceLanguage(raw)
            }
            let newItemSlice: [ACPToolCallContent]
            if tc.appliedItemCount < items.count {
                newItemSlice = Array(items[tc.appliedItemCount..<items.count])
            } else {
                newItemSlice = []
            }
            tc.terminalIds = Self.mergeTerminalIds(
                Self.mergeTerminalIds(
                    tc.terminalIds,
                    Self.extractTerminalIds(newItemSlice)),
                Self.extractMetadataTerminalIds(tc.metadata, includeExit: false))
            let preservedRawOutputAssets = rawOutputAssets.isEmpty
                ? Self.extractStoredRawOutputAssets(tc.rawOutput, existingAssets: tc.assets)
                : rawOutputAssets
            // Preserve content assets from items already processed (they
            // may still be present in the cumulative snapshot even when
            // `newItemSlice` is empty — e.g. an image item that stays while
            // a text item grows in place). Merge the existing image/resource
            // assets with the new ones; `mergeAssets` dedups by value.
            let existingContentAssets = Self.contentAssetsFromItems(
                items, prefix: tc.appliedItemCount)
            tc.assets = Self.mergeAssets(
                Self.mergeAssets(existingContentAssets, Self.extractAssets(newItemSlice)),
                preservedRawOutputAssets)
            tc.appliedRawContent = raw
            tc.appliedItemCount = items.count
            tc.appliedIsFinal = isFinal
            tc.appliedStrippedRaw = newStrippedRaw
            tc.appliedOpeningFenceUnterminated = unterminated
            tc.appliedItemsSnapshot = items
            return
        }
        Self.reprocessToolCallContentFull(
            raw: raw, items: items, isFinal: isFinal,
            rawOutputAssets: rawOutputAssets, to: &tc)
    }

    /// Full reprocess path: the legacy behaviour, plus refresh the
    /// `appliedRawContent`/`appliedItemCount`/`appliedIsFinal`/
    /// `appliedStrippedRaw`/`appliedOpeningFenceUnterminated` cache so the
    /// next update can take the suffix-only fast path. Extracted from
    /// `applyToolCallPayloadFields`/`applyToolCallUpdateFields` so both
    /// share one implementation.
    private static func reprocessToolCallContentFull(
        raw: String,
        items: [ACPToolCallContent],
        isFinal: Bool,
        rawOutputAssets: [ACPMessage.ToolCallAsset],
        to tc: inout ACPMessage.ToolCall
    ) {
        let full = Self.stripWrappingFence(raw, isFinal: isFinal)
        tc.replaceContent(full)
        tc.isContentTruncated = false
        tc.preview = Self.previewLine(full)
        tc.contentLanguage = Self.wrappingFenceLanguage(raw)
        tc.terminalIds = Self.mergeTerminalIds(
            Self.extractTerminalIds(items),
            Self.extractMetadataTerminalIds(tc.metadata, includeExit: false))
        let preservedRawOutputAssets = rawOutputAssets.isEmpty
            ? Self.extractStoredRawOutputAssets(tc.rawOutput, existingAssets: tc.assets)
            : rawOutputAssets
        tc.assets = Self.mergeAssets(Self.extractAssets(items), preservedRawOutputAssets)
        tc.appliedRawContent = raw
        tc.appliedItemCount = items.count
        tc.appliedIsFinal = isFinal
        // Derive the stripped-raw (opening fence removed, trailing fence
        // NOT removed) and whether the opening fence line is still
        // unterminated. `stripWrappingFence` with isFinal=false returns
        // exactly the stripped-raw; if the raw starts with an opening
        // fence and has no newline, the stripped-raw is empty and the
        // fence is unterminated.
        let strippedRaw = Self.stripWrappingFence(raw, isFinal: false)
        tc.appliedStrippedRaw = strippedRaw
        tc.appliedOpeningFenceUnterminated = Self.openingFenceUnterminated(
            raw: raw, strippedRaw: strippedRaw)
        // Track whether an opening fence was actually stripped: the
        // suffix path's trailing-fence strip must only run when the
        // opening fence was recognized.
        let firstLine = raw.split(separator: "\n", omittingEmptySubsequences: false).first.map(String.init) ?? raw
        tc.appliedOpeningFenceStripped = Self.isOpeningFence(firstLine)
        tc.appliedItemsSnapshot = items
    }

    /// Whether the first `count` items of `items` have the same
    /// STRUCTURED content (images, resource-links, terminals, diffs) as
    /// the first `count` items of `snapshot`. Text items are NOT compared
    /// element-wise: in the common cumulative streaming shape the single
    /// text item grows in place (`[text("a")]` -> `[text("ab")]`), and
    /// comparing it would force a full reprocess on every update,
    /// defeating the suffix-only fast path. Since `flatten` ignores
    /// non-text items, equal flattened text plus equal structured items
    /// guarantees the items array is consistent with the previous apply.
    /// An in-place image replacement (image(old) -> image(new)) or a
    /// terminal inserted before the text both change a structured item
    /// and are detected here. Cost is O(count).
    private static func prefixItemsUnchanged(
        items: [ACPToolCallContent],
        snapshot: [ACPToolCallContent],
        count: Int
    ) -> Bool {
        guard count > 0 else { return true }
        guard items.count >= count, snapshot.count >= count else {
            return false
        }
        for i in 0..<count {
            if !Self.structuredContentEqual(items[i], snapshot[i]) {
                return false
            }
        }
        return true
    }

    /// Whether two `ACPToolCallContent` items have the same structured
    /// payload. Text items are treated as equal (the text is allowed to
    /// grow — the flattened-raw prefix check guards the text content).
    /// Images, resource-links, resources, terminals, and diffs are
    /// compared exactly — a change to any of those must force a full
    /// reprocess so `extractAssets`/`extractTerminalIds` re-scan.
    private static func structuredContentEqual(
        _ lhs: ACPToolCallContent,
        _ rhs: ACPToolCallContent
    ) -> Bool {
        switch (lhs, rhs) {
        case (.content(.text), .content(.text)):
            return true
        case (.terminal(let a), .terminal(let b)):
            return a == b
        case (.diff(let p1, let o1, let n1), .diff(let p2, let o2, let n2)):
            return p1 == p2 && o1 == o2 && n1 == n2
        case (.content(.image(let d1, let u1, let m1)),
              .content(.image(let d2, let u2, let m2))):
            return d1 == d2 && u1 == u2 && m1 == m2
        case (.content(.resourceLink(let u1, let n1)),
              .content(.resourceLink(let u2, let n2))):
            return u1 == u2 && n1 == n2
        case (.content(.resource(let u1, let m1, _)),
              .content(.resource(let u2, let m2, _))):
            return u1 == u2 && m1 == m2
        case (.unknown, .unknown):
            return true
        default:
            return false
        }
    }

    /// Whether the first line of `strippedRaw` is stable — i.e. the body
    /// has a non-empty first line followed by a newline, so the preview
    /// (first non-empty line) and fence language (first line) won't change
    /// on a suffix update. Used to decide whether `preview`/
    /// `contentLanguage` need recomputing. While the first line is still
    /// being built (no newline yet) or the first line is empty (the
    /// preview may come from a LATER line), each suffix can extend or
    /// start the first non-empty line and change the preview/fence.
    private static func firstLineIsComplete(_ strippedRaw: String) -> Bool {
        // Find the first newline. Everything before it is the first line.
        // If there's no newline, the first line is still growing.
        guard let newlineIndex = strippedRaw.firstIndex(of: "\n") else {
            return false
        }
        let firstLine = strippedRaw[..<newlineIndex]
        // An empty first line means the preview comes from a later line
        // which may not have arrived yet. Keep recomputing.
        return !firstLine.isEmpty
    }

    /// Whether `previousRaw` is a PARTIAL opening fence — a prefix of
    /// a potential `` ``` `` fence line that could still grow into a
    /// valid opening fence with more characters. Only returns true for
    /// strings that are strict prefixes of `` ``` `` (1 or 2 backticks)
    /// or `` ``` `` followed by valid tag characters (letters, digits,
    /// `_`, `+`, `-`) without a newline. A string like `` `cmd` `` (inline
    /// code) or `` ```{ `` (invalid tag) is NOT a partial fence — it can
    /// never become a valid opening fence, so the suffix path is safe.
    /// `isOpeningFence` (complete fence) is handled separately by
    /// `appliedOpeningFenceUnterminated`; this guard is for the case
    /// where the previous raw was NOT recognized as a fence at all but
    /// could still become one.
    private static func previousRawWasPartialFence(_ previousRaw: String) -> Bool {
        guard !previousRaw.isEmpty else { return false }
        // A complete opening fence (with or without a newline) is handled
        // by `appliedOpeningFenceUnterminated` / `appliedOpeningFenceStripped`.
        // Here we only care about fence PREFIXES that weren't yet recognized.
        if Self.isOpeningFence(previousRaw) { return false }
        return Self.couldBeOpeningFencePrefix(previousRaw)
    }

    /// Extract content assets (images, resource links, resources) from
    /// the first `prefix` items of `items`, for preserving across suffix
    /// updates. Used when `newItemSlice` is empty but the cumulative
    /// snapshot still carries content assets from earlier items.
    private static func contentAssetsFromItems(
        _ items: [ACPToolCallContent],
        prefix: Int
    ) -> [ACPMessage.ToolCallAsset] {
        let count = min(prefix, items.count)
        guard count > 0 else { return [] }
        return Self.extractAssets(Array(items[0..<count]))
    }

    /// Extend `prev` (the previously stripped-raw body, after opening
    /// fence removal) by `suffix` (the newly arrived raw tail). Returns
    /// the new stripped-raw body, the updated `openingFenceUnterminated`
    /// flag, and whether the extension can be taken incrementally. When
    /// the previous chunk left the opening fence line unterminated, the
    /// first newline in `suffix` completes it; the completed line is
    /// re-validated against `isOpeningFence`. If it grew into a form
    /// that is NOT a valid opening fence (e.g. `` ```{.swift} `` where
    /// `{` is not in the allowed tag character set), the line was a
    /// false positive and incremental stripping can't safely proceed —
    /// `needsFullReprocess` returns true so the caller falls back.
    private static func extendStrippedRaw(
        previousRaw: String,
        suffix: String,
        openingFenceUnterminated: Bool
    ) -> (strippedRaw: String, unterminated: Bool, needsFullReprocess: Bool) {
        if openingFenceUnterminated {
            if let newlineRange = suffix.range(of: "\n") {
                let after = String(suffix[newlineRange.upperBound...])
                // The completed fence line is `previousRaw + suffix[..<newline]`.
                // Re-validate against `isOpeningFence`: if it grew into a
                // form that is NOT a valid opening fence (e.g. "```{.swift}"
                // where `{` is not in the allowed tag character set), the
                // partial fence was a false positive and we must fall back
                // to full reprocess so the line is kept in the body.
                let completedLine = previousRaw + String(suffix[..<newlineRange.lowerBound])
                if Self.isOpeningFence(completedLine) {
                    return (after, false, false)
                }
                return ("", false, true)
            }
            // No newline yet: the opening fence line is still being built.
            // Re-validate the growing line: if it can no longer be a valid
            // opening fence (e.g. "```{" — the `{` is not a valid tag
            // character), the partial fence was a false positive and we
            // must fall back so the line is kept in the body. Otherwise
            // keep waiting for more characters.
            let growingLine = previousRaw + suffix
            if Self.couldBeOpeningFencePrefix(growingLine) {
                return ("", true, false)
            }
            return ("", false, true)
        }
        // `previousRaw` is not used in the non-unterminated path; the
        // caller passes the stripped-raw body as the accumulator.
        return (previousRaw + suffix, false, false)
    }

    /// Whether `s` is a prefix of a potential opening fence line — i.e.
    /// it is a strict prefix of `` ``` `` (1 or 2 backticks) OR it starts
    /// with `` ``` `` and the rest (so far) is all valid tag characters.
    /// Used by `extendStrippedRaw` to decide whether a still-growing line
    /// should keep waiting for more characters before being classified
    /// as a fence. A line like `` ```sw `` is a prefix of `` ```swift ``
    /// (valid), while `` ```{.swift} `` is not (the `{` disqualifies it
    /// even though it starts with `` ``` ``). A line like `` `cmd` `` is
    /// not a fence prefix (the `c` after the first backtick means it can
    /// never become `` ``` ``).
    private static func couldBeOpeningFencePrefix(_ s: String) -> Bool {
        // 1 or 2 backticks: strict prefix of "```".
        if s == "`" || s == "``" { return true }
        guard s.hasPrefix("```") else { return false }
        let rest = s.dropFirst(3)
        return rest.allSatisfy { $0.isLetter || $0.isNumber || $0 == "_" || $0 == "+" || $0 == "-" }
    }

    /// Whether `raw` starts with an opening fence line that has no
    /// terminating newline (so the next suffix's first newline will
    /// end the fence line and start the stripped-raw body, rather than
    /// being a content separator).
    private static func openingFenceUnterminated(raw: String, strippedRaw: String) -> Bool {
        // No newline at all: if this is an opening fence line, it's
        // unterminated; otherwise (no fence, single-line body) it's not.
        guard raw.firstIndex(of: "\n") != nil else {
            return Self.isOpeningFence(raw)
        }
        // A newline exists: any opening fence is terminated (even if the
        // body after it is still empty).
        return false
    }

    /// Apply only the trailing-fence-strip step of `stripWrappingFence` to
    /// `body` (the stripped-raw content, opening fence already removed).
    /// Mirrors the `isFinal` branch: trim trailing empty lines, drop a
    /// trailing `"```"` line if present, otherwise restore the trimmed
    /// empties. Used by the suffix-only fast path on the single update
    /// that flips `isFinal` to true; cost is O(body), once per tool call.
    private static func stripTrailingFenceLine(_ body: String) -> String {
        var lines = body.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
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
        return lines.joined(separator: "\n")
    }

    private static func applyToolCallUpdateFields(
        _ update: ACPToolCallUpdate,
        to tc: inout ACPMessage.ToolCall,
        allowFinalSnapshotReplacement: Bool = true
    ) {
        let canReplaceSnapshot = allowFinalSnapshotReplacement || !Self.isFinalStatus(tc.status)
        var rawOutputAssets: [ACPMessage.ToolCallAsset] = []
        if canReplaceSnapshot, let title = update.title { tc.title = title }
        if canReplaceSnapshot, let status = update.status { tc.status = status }
        if canReplaceSnapshot, let locations = update.locations { tc.locations = locations.map(\.path) }
        if canReplaceSnapshot, let rawInput = update.rawInput { tc.rawInput = Self.metadataString(rawInput) }
        if (canReplaceSnapshot || update.status.map(Self.isFinalStatus) == true), let rawOutput = update.rawOutput {
            tc.rawOutput = Self.metadataString(rawOutput)
            rawOutputAssets = Self.extractRawOutputAssets(rawOutput)
            tc.assets = Self.mergeAssets(tc.assets, rawOutputAssets)
        }
        if let metadata = update.metadata {
            tc.metadata = Self.mergeMetadata(tc.metadata, metadata)
            tc.terminalIds = Self.mergeTerminalIds(
                tc.terminalIds,
                Self.extractMetadataTerminalIds(metadata, includeExit: update.content == nil))
        }
        if let content = update.content {
            if !canReplaceSnapshot {
                if let status = update.status, Self.isFinalStatus(status) {
                    tc.assets = Self.mergeAssets(tc.assets, Self.extractAssets(content))
                    tc.terminalIds = Self.mergeTerminalIds(
                        tc.terminalIds,
                        Self.extractTerminalIds(content))
                }
                return
            }
            Self.applyToolCallContent(
                items: content,
                isFinal: Self.isFinalStatus(tc.status),
                rawOutputAssets: rawOutputAssets,
                rawOutputChanged: update.rawOutput != nil,
                metadataChanged: update.metadata != nil,
                to: &tc)
        } else if update.rawOutput != nil || update.metadata != nil {
            // Side-channel-only update (no content) changed `tc.assets` /
            // `tc.terminalIds` via the rawOutput/metadata handling above.
            // Invalidate the content cache so a later duplicate-content
            // snapshot does NOT take the identical-text skip (which would
            // miss the side-channel changes). The next content update
            // falls to full reprocess, rebuilding `tc.assets` /
            // `tc.terminalIds` from the current content + rawOutput +
            // metadata — matching the legacy semantics.
            tc.appliedRawContent = nil
            tc.appliedItemCount = 0
            tc.appliedIsFinal = false
            tc.appliedStrippedRaw = ""
            tc.appliedOpeningFenceUnterminated = false
            tc.appliedOpeningFenceStripped = false
            tc.appliedItemsSnapshot = []
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
        // A system notice closes the current output run; materialise any held
        // replay candidate first so it keeps its place ahead of the notice.
        flushPendingReplayCandidates()
        transcript.appendMessage(.systemNotice(id: UUID(), text: text))
        didAppendTranscriptMessage()
    }

    func appendFileEdit(_ edit: ACPMessage.FileEdit) {
        clearRestoredContextRecoveryStatus()
        // A file edit closes the current output run (see lastAgent()/
        // lastThought(), which stop at .fileEdit); materialise any held replay
        // candidate first so text that arrived before the edit stays ahead of
        // it. This path does not flow through `apply`, so it must flush here.
        flushPendingReplayCandidates()
        transcript.appendMessage(.fileEdit(id: UUID(), edit))
        didAppendTranscriptMessage()
        transcript.completedOutputBoundaryMessageIds.removeAll()
    }

    func replaceTranscriptMessages(
        _ messages: [ACPMessage],
        createdAts: [Date]? = nil,
        messageIndexOffset: Int = 0
    ) {
        transcript.replaceMessages(
            with: messagesPreservingToolCallContentRevisions(messages),
            createdAts: createdAts,
            messageIndexOffset: messageIndexOffset
        )
    }

    private func messagesPreservingToolCallContentRevisions(_ messages: [ACPMessage]) -> [ACPMessage] {
        let previousToolCalls = transcript.messages.reduce(into: [String: ACPMessage.ToolCall]()) { result, message in
            if case .toolCall(let toolCall) = message {
                result[toolCall.toolCallId] = toolCall
            }
        }

        guard !previousToolCalls.isEmpty else {
            return messages
        }

        return messages.map { message in
            guard case .toolCall(var toolCall) = message,
                  let previous = previousToolCalls[toolCall.toolCallId] else {
                return message
            }
            toolCall.contentRevision = previous.contentRevision
            if toolCall.content != previous.content {
                toolCall.contentRevision &+= 1
            }
            return .toolCall(toolCall)
        }
    }

    /// Insert `older` at the head of the transcript and shift `visibleHead`
    /// forward by `older.count` so the visible tail window stays anchored to
    /// the same messages. Used by the post-hydration backfill that prepends
    /// pre-tail messages after the UI has already painted the tail.
    func prependTranscriptMessages(_ older: [ACPMessage], createdAts: [Date]? = nil) {
        guard !older.isEmpty else { return }
        transcript.prependMessages(older, createdAts: createdAts)
        // Keep the visible window anchored to the tail the user is already
        // looking at while trimming newly-hidden historical tool output.
        transcript.shiftVisibleHeadAfterPrepending(older.count)
    }

    func markCompletedOutputBoundary() {
        clearRetryStatus()
        // The turn's output is complete; materialise any held replay
        // candidate now (before marking boundaries so the flushed final
        // message is itself recorded as a completed boundary). Otherwise a
        // buffered final chunk whose text happens to be a substring of prior
        // output — a one-chunk reply like "OK" — would stay outside
        // `transcript.messages`, never persist, and be lost on detach/reopen,
        // since turn completion reaches here without an `ACPSessionUpdate`.
        _ = flushPendingReplayCandidates()
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
    func enqueue(
        blocks: [ACPContentBlock],
        draft: ACPComposerDraft? = nil,
        delegatedSource: ACPDelegatedPromptSource? = nil
    ) {
        queue.append(QueuedPrompt(blocks: blocks, draft: draft, delegatedSource: delegatedSource))
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
        queue[idx].advanceBrokerOperationAttempt()
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
    @discardableResult
    func markQueueHeadSending() -> String? {
        guard !queue.isEmpty, queue[0].status == .pending else { return nil }
        queue[0].status = .sending
        queue[0].lastError = nil
        return queue[0].brokerOperationKey
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
    func setQueueHeadError(_ message: String, advancesBrokerOperationAttempt: Bool = false) {
        guard !queue.isEmpty else { return }
        var item = queue.removeFirst()
        item.status = .pending
        if advancesBrokerOperationAttempt {
            item.advanceBrokerOperationAttempt()
        }
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
                transcript.replaceMessage(at: i, with: .toolCall(tc))
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

    private static func extractMetadataTerminalIds(_ metadata: AnyCodable?, includeExit: Bool = true) -> [String] {
        guard let root = Self.metadataObject(metadata) else { return [] }
        let fields = includeExit
            ? ["terminal_info", "terminal_output", "terminal_output_delta", "terminal_exit"]
            : ["terminal_info", "terminal_output", "terminal_output_delta"]
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
            if key == "contextCompaction",
               let existingCompaction = Self.metadataObject(merged[key]),
               let updatedCompaction = Self.metadataObject(value) {
                merged[key] = AnyCodable(existingCompaction.merging(updatedCompaction) { _, update in update })
            } else {
                merged[key] = value
            }
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

    private func applyToolCallMetadata(_ metadata: AnyCodable?, replaying: Bool = false) {
        guard let root = Self.metadataObject(metadata) else { return }

        if let info = Self.metadataObject(root["terminal_info"]),
           let terminalId = Self.metadataScalarString(info["terminal_id"]) {
            if shouldApplyMetadataTerminalSideEffect(terminalId: terminalId, replaying: replaying) {
                terminalHost.recordMetadataTerminalInfo(
                    terminalId: terminalId,
                    cwd: Self.metadataScalarString(info["cwd"]))
            }
        }

        if let output = Self.metadataObject(root["terminal_output"]),
           let terminalId = Self.metadataScalarString(output["terminal_id"]),
           let text = Self.metadataScalarString(output["data"]) {
            if shouldApplyMetadataTerminalSideEffect(
                terminalId: terminalId,
                replaying: replaying,
                replace: true
            ) {
                terminalHost.appendMetadataOutput(
                    terminalId: terminalId,
                    data: Data(text.utf8),
                    replace: true)
            }
        }

        if let delta = Self.metadataObject(root["terminal_output_delta"]),
           let terminalId = Self.metadataScalarString(delta["terminal_id"]),
           let text = Self.metadataScalarString(delta["data"]) {
            if shouldApplyMetadataTerminalSideEffect(
                terminalId: terminalId,
                replaying: replaying,
                replace: false
            ) {
                terminalHost.appendMetadataOutput(
                    terminalId: terminalId,
                    data: Data(text.utf8),
                    replace: false)
            }
        }

        if let exit = Self.metadataObject(root["terminal_exit"]),
           let terminalId = Self.metadataScalarString(exit["terminal_id"]) {
            if shouldApplyMetadataTerminalExitSideEffect(terminalId: terminalId, replaying: replaying) {
                terminalHost.recordMetadataExit(
                    terminalId: terminalId,
                    exitStatus: ACPTerminalExitStatus(
                        exitCode: Self.metadataInt(exit["exit_code"]),
                        signal: Self.metadataScalarString(exit["signal"])))
            }
        }
    }

    private func shouldApplyMetadataTerminalSideEffect(
        terminalId: String,
        replaying: Bool,
        replace: Bool = false
    ) -> Bool {
        guard replaying else { return true }
        if replace { return true }
        if replayCreatedMetadataTerminalIds.contains(terminalId) { return true }
        if let terminal = terminalHost.terminal(id: terminalId),
           terminal.retainedByteCount > 0 || terminal.exitStatus != nil {
            return false
        }
        replayCreatedMetadataTerminalIds.insert(terminalId)
        return true
    }

    private func shouldApplyMetadataTerminalExitSideEffect(terminalId: String, replaying: Bool) -> Bool {
        guard replaying else { return true }
        if replayCreatedMetadataTerminalIds.contains(terminalId) { return true }
        if let terminal = terminalHost.terminal(id: terminalId) {
            return terminal.exitStatus == nil
        }
        replayCreatedMetadataTerminalIds.insert(terminalId)
        return true
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

    private static func metadataBool(_ value: AnyCodable?) -> Bool? {
        guard let raw = value?.value, !(raw is NSNull) else { return nil }
        return raw as? Bool
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
            || lower.contains("\"data\"")
            || lower.contains("\"url\"")
            || lower.contains("\"mimetype\"")
            || lower.contains("\"mime_type\"")
        else { return [] }
        if lower.contains("[truncated]") {
            return existingAssets.filter { $0.kind == .image }
        }
        return existingAssets.filter { asset in
            guard asset.kind == .image else { return false }
            if let data = asset.data,
               !data.isEmpty,
               rawOutput.contains(String(data.prefix(128))) {
                return true
            }
            if let uri = asset.uri, rawOutput.contains(uri) { return true }
            if let uri = asset.uri,
               Self.rawOutputContainsStableURIPrefix(rawOutput, uri: uri) {
                return true
            }
            return false
        }
    }

    private static func rawOutputContainsStableURIPrefix(_ rawOutput: String, uri: String) -> Bool {
        guard uri.count >= 128 else { return false }
        if dataImageMimeType(uri) != nil {
            return rawOutput.contains(String(uri.prefix(128)))
        }
        guard let components = URLComponents(string: uri),
              components.scheme != nil,
              components.host != nil
        else { return false }
        return rawOutput.contains(String(uri.prefix(128)))
    }

    private static func assetName(from uri: String?) -> String? {
        guard let uri, !uri.isEmpty else { return nil }
        if uri.trimmingCharacters(in: .whitespacesAndNewlines).lowercased().hasPrefix("data:") {
            return nil
        }
        return URL(string: uri)?.lastPathComponent
            ?? URL(fileURLWithPath: uri).lastPathComponent
    }

    private func applySessionInfoUpdate(
        _ info: ACPSessionInfoUpdate,
        tracksRetryStatus: Bool
    ) {
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
        if tracksRetryStatus { applyRetryMetadata(info.metadata) }
    }

    func clearRetryStatus() {
        retryStatus = nil
    }

    private func applyRetryMetadata(_ metadata: AnyCodable?) {
        guard let root = Self.metadataObject(metadata),
              let codex = Self.metadataObject(root["codex"]),
              codex.keys.contains("error")
        else { return }
        guard let error = Self.metadataObject(codex["error"]),
              Self.metadataBool(error["willRetry"]) == true
        else {
            clearRetryStatus()
            return
        }
        retryStatus = ACPRetryStatus(
            turnId: Self.metadataScalarString(error["turnId"]),
            detail: Self.retryDetail(error["message"])
        )
    }

    private static func retryDetail(_ value: AnyCodable?) -> String? {
        guard let message = metadataScalarString(value) else { return nil }
        let compact = message.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard !compact.isEmpty else { return nil }
        return String(compact.prefix(240))
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
            // A file edit closes the current output run, matching lastAgent()
            // and markCompletedOutputBoundary(); a thought after an edit is a
            // new bubble, so a legacy chunk (or a replay continuation adopted
            // via this index) must not extend the pre-edit thought.
            if case .fileEdit = transcript.messages[i] { return nil }
        }
        return nil
    }

    private enum TextMessageKind: Hashable {
        case user
        case agent
        case thought
    }

    private func appendUserChunk(text addition: String, attachments newAttachments: [ACPMessage.Attachment], messageId: String?, flushedReplayIndices: inout Set<Int>) -> Int? {
        let located = messageId.flatMap { transcript.messageIndex(messageId: $0, kind: .user) }
        if let i = located,
           case .user(let id, let existingMessageId, let text, let attachments, let delegatedSource) = transcript.messages[i] {
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
            transcript.replaceMessage(at: i, with: .user(
                id: id,
                messageId: existingMessageId,
                text: mergedText,
                attachments: mergedAttachments,
                delegatedSource: delegatedSource))
            if let existingMessageId {
                liveUserChunkMessageIds.insert(existingMessageId)
            }
            transcript.noteStreamingChange(at: i)
            return i
        }

        if let i = lastEchoedLocalUserPromptIndex(matching: addition, attachments: newAttachments),
           case .user(let id, let existingMessageId, let text, let attachments, let delegatedSource) = transcript.messages[i] {
            if existingMessageId == nil {
                if let messageId {
                    transcript.replaceMessage(at: i, with: .user(
                        id: id,
                        messageId: messageId,
                        text: text,
                        attachments: Self.mergingAttachments(attachments, newAttachments),
                        delegatedSource: delegatedSource))
                    reconciledLocalUserPromptMessageIds.insert(messageId)
                    transcript.noteStreamingChange(at: i)
                } else {
                    reconciledLegacyLocalUserPromptIds.insert(id)
                }
            }
            return i
        }

        if messageId == nil,
           let i = lastLegacyUserChunkIndex(),
           case .user(let id, let existingMessageId, let text, let attachments, let delegatedSource) = transcript.messages[i] {
            let mergedText = text + Self.streamingSeparator(between: text, and: addition) + addition
            let mergedAttachments = Self.mergingAttachments(attachments, newAttachments)
            if text == mergedText && attachments == mergedAttachments {
                return i
            }
            transcript.replaceMessage(at: i, with: .user(
                id: id,
                messageId: existingMessageId,
                text: mergedText,
                attachments: mergedAttachments,
                delegatedSource: delegatedSource))
            transcript.noteStreamingChange(at: i)
            return i
        }

        if messageId != nil,
           !allowsStreamingBoundaryCrossing,
           userMessageExists(containing: addition, attachments: newAttachments) {
            return nil
        }

        if addition.isEmpty {
            guard !newAttachments.isEmpty else { return nil }
            // A genuine new prompt closes the current text message; flush any
            // held replay candidate first so it keeps its place ahead of the
            // prompt. Deferred to here (past the replay guard above) so a
            // replayed user chunk never materialises a still-buffered chunk.
            flushedReplayIndices = flushPendingReplayCandidates()
            let id = UUID()
            transcript.appendMessage(.user(id: id, messageId: messageId, text: addition, attachments: newAttachments))
            if let messageId {
                liveUserChunkMessageIds.insert(messageId)
            } else {
                legacyUserChunkMessageIds.insert(id)
            }
            didAppendTranscriptMessage()
            transcript.completedOutputBoundaryMessageIds.removeAll()
            return transcript.messages.count - 1
        }

        // Genuine new prompt (past the replay guard): flush held replay
        // candidates first so they keep their place ahead of the prompt.
        flushedReplayIndices = flushPendingReplayCandidates()
        let id = UUID()
        transcript.appendMessage(.user(id: id, messageId: messageId, text: addition, attachments: newAttachments))
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
        if case .user(let id, let messageId, _, _, _) = transcript.messages[index],
           messageId == nil,
           legacyUserChunkMessageIds.contains(id) {
            return index
        }
        return nil
    }

    private func lastEchoedLocalUserPromptIndex(matching text: String, attachments: [ACPMessage.Attachment]) -> Int? {
        guard !text.isEmpty || !attachments.isEmpty else { return nil }
        return transcript.messages.indices.reversed().first { index in
            if case .user(let id, let messageId, let existing, let existingAttachments, _) = transcript.messages[index] {
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

    /// Whether some existing message of `kind` contains `text` — i.e.
    /// `text` could be the running span of a late load-replay stream that
    /// reproduces part of an already-present message. Uses containment
    /// rather than prefix matching because a replay slip can begin
    /// mid-message: the suppression counter can fall between chunks of a
    /// replayed message, so the first chunk reaching `appendStreaming`
    /// may be a middle fragment (`"world"` of `"hello world"`). Drives the
    /// replay guard in `appendStreaming`. Scans the whole transcript — a
    /// full replay can re-deliver a message that sits before a later user
    /// prompt, and that must still be suppressed; only *adoption* of a
    /// continuation is restricted to the trailing turn.
    private func existingMessageContains(kind: TextMessageKind, _ text: String) -> Bool {
        guard !text.isEmpty else { return false }
        return transcript.messages.contains { message in
            switch (kind, message) {
            case (.agent, .agent(_, _, let buf)),
                 (.thought, .thought(_, _, let buf)):
                return buf.value.contains(text)
            default:
                return false
            }
        }
    }

    /// When a diverged replay `candidate` reproduces the *entire* trailing
    /// in-progress bubble of `kind` as a prefix and then continues past it,
    /// the stream is that already-present message replayed under a
    /// regenerated id and continued past the boundary window. Append only
    /// the text beyond the bubble (so the hydrated prefix is not duplicated)
    /// and rebind the bubble to the regenerated `messageId` so subsequent
    /// chunks target it via `messageIndex`. Returns the adopted message's
    /// index, or nil when the candidate does not begin with the whole bubble
    /// (genuine new output).
    ///
    /// Only a *whole-bubble* prefix is adopted, never a partial suffix. A
    /// regenerated id that reproduces just the tail of the bubble is
    /// indistinguishable from a genuinely separate message that happens to
    /// start with the bubble's last word (`"hello world"` followed by a new
    /// `"world again"` reads identically to a mid-message replay `"world"` +
    /// `"!"`), and ACP message ids normally delimit separate rows — so a
    /// partial match starts its own row rather than risk a corrupting merge.
    /// A mid-message replay slip that is then continued therefore surfaces as
    /// a (rare) duplicate bubble instead; that is the accepted trade-off for
    /// never mutating a genuinely separate message into an existing bubble.
    ///
    /// The adoption target is exactly `lastAgent()`/`lastThought()` — the
    /// same trailing bubble a legacy (id-less) chunk would extend — so the
    /// boundary rules (a user prompt, tool call, or file edit closes the
    /// run; an agent row closes a thought; plans are skipped) stay
    /// consistent with the rest of streaming instead of being re-derived.
    private func adoptReplayContinuation(
        kind: TextMessageKind,
        candidate: String,
        messageId: String,
        phase: ACPMessagePhase?,
        metadata: AnyCodable?
    ) -> Int? {
        let trailingIndex: Int?
        switch kind {
        case .agent: trailingIndex = lastAgent()
        case .thought: trailingIndex = lastThought()
        case .user: trailingIndex = nil
        }
        guard let i = trailingIndex else { return nil }
        let existing: String
        switch transcript.messages[i] {
        case .agent(_, _, let buf), .thought(_, _, let buf):
            existing = buf.value
        default:
            return nil
        }
        guard !existing.isEmpty, candidate.hasPrefix(existing) else { return nil }
        let suffix = String(candidate.dropFirst(existing.count))
        guard !suffix.isEmpty else { return nil }
        switch transcript.messages[i] {
        case .agent(let id, _, let buf):
            buf.adopt(phase: phase, metadata: metadata)
            buf.append(suffix)
            transcript.replaceMessage(at: i, with: .agent(id: id, messageId: messageId, buf))
        case .thought(let id, _, let buf):
            buf.adopt(phase: phase, metadata: metadata)
            buf.append(suffix)
            transcript.replaceMessage(at: i, with: .thought(id: id, messageId: messageId, buf))
        default:
            return nil
        }
        transcript.noteStreamingChange(at: i)
        return i
    }

    private func userMessageExists(containing text: String, attachments: [ACPMessage.Attachment]) -> Bool {
        guard !text.isEmpty || !attachments.isEmpty else { return false }
        return transcript.messages.contains { message in
            guard case .user(_, _, let existing, let existingAttachments, _) = message else { return false }
            if !text.isEmpty, existing.contains(text) {
                return true
            }
            return !attachments.isEmpty && attachments.allSatisfy { existingAttachments.contains($0) }
        }
    }

    /// Returns the index of the message that was appended or mutated.
    private func appendStreaming(text addition: String,
                                 messageId: String?,
                                 replayKind: TextMessageKind,
                                 locateByMessageId: (String) -> Int?,
                                 locateLegacy: () -> Int?,
                                 replayCandidateMatches: (String) -> Bool,
                                 adoptContinuation: (String, ACPMessagePhase?, AnyCodable?) -> Int?,
                                 flushedReplayIndices: inout Set<Int>,
                                 phase: ACPMessagePhase?,
                                 metadata: AnyCodable?,
                                 makeNew: (String, ACPMessagePhase?, AnyCodable?) -> ACPMessage) -> Int? {
        // Any held candidates from a prior window are flushed (materialised)
        // by `apply` before this runs — once `allowsStreamingBoundaryCrossing`
        // is true, or on the closing non-text update — so they are never
        // stranded or leaked into a later window.
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
                    let startsNewPhasedRow = messageId == nil
                        && buf.phase != nil
                        && phase != nil
                        && buf.phase != phase
                    if !startsNewPhasedRow {
                        buf.adopt(phase: phase, metadata: metadata)
                        buf.append(Self.streamingSeparator(between: buf.value, and: addition) + addition)
                        transcript.noteStreamingChange(at: i)
                        return i
                    }
                default:
                    break
                }
            }
        }
        // Late load-replay guard for an unrecognised messageId. A replay
        // re-streams text that is already present, so we accumulate this
        // messageId's chunks and keep suppressing while the running text
        // stays contained in some existing message. Containment (not just
        // a prefix) is required because a replay slip can start mid-message
        // — the suppression counter may fall between chunks, so the first
        // chunk seen here can be a middle fragment ("world" of "hello
        // world"). Once the running text diverges it is genuine new output
        // — materialise it in full so no leading fragment is lost (a short
        // first fragment like "I" coinciding with an earlier message would
        // otherwise be dropped, corrupting the text). Single-chunk full
        // replays and chunked/mid-stream replays never create a message.
        // On divergence, if the candidate begins with an existing message
        // it is that message replayed under a regenerated id and continued
        // — adopt it (append only the divergent suffix) instead of
        // materialising a new row that duplicates the hydrated prefix.
        var newMessageText = addition
        var newMessagePhase = phase
        var newMessageMetadata = metadata
        if let messageId, !allowsStreamingBoundaryCrossing {
            let candidateKey = ReplayCandidateKey(kind: replayKind, messageId: messageId)
            let previous = pendingReplayCandidates[candidateKey]
            let previousDisplay = previous?.display ?? ""
            let previousRaw = previous?.raw ?? ""
            let display = previousDisplay + Self.streamingSeparator(between: previousDisplay, and: addition) + addition
            let raw = previousRaw + addition
            let candidatePhase = previous?.phase ?? phase
            let candidateMetadata = AnyCodable.mergingMetadata(previous?.metadata, metadata)
            // Match on both forms: the display form (as a live stream would
            // build it) and the raw concatenation, so a replay that splits
            // at a sentence boundary the original stream did not is still
            // recognised rather than duplicated by the injected separator.
            if replayCandidateMatches(display) || replayCandidateMatches(raw) {
                // Preserve the first-seen arrival order across accumulation.
                let arrivalOrder: Int
                if let previous {
                    arrivalOrder = previous.arrivalOrder
                } else {
                    arrivalOrder = replayCandidateArrivalCounter
                    replayCandidateArrivalCounter += 1
                }
                pendingReplayCandidates[candidateKey] = ReplayCandidate(
                    display: display,
                    raw: raw,
                    arrivalOrder: arrivalOrder,
                    phase: candidatePhase,
                    metadata: candidateMetadata)
                return nil
            }
            pendingReplayCandidates.removeValue(forKey: candidateKey)
            if let adopted = adoptContinuation(display, candidatePhase, candidateMetadata)
                ?? adoptContinuation(raw, candidatePhase, candidateMetadata) {
                return adopted
            }
            newMessageText = display
            newMessagePhase = candidatePhase
            newMessageMetadata = candidateMetadata
        }
        // A new agent row is live output that closes an in-progress thought
        // (`lastThought()` stops at `.agent`); flush pending thoughts ahead of
        // it now that the chunk is known not to be suppressed as replay. (The
        // located/adopt paths above continue a bubble that predates any held
        // thought, so their order is already correct.)
        if replayKind == .agent {
            flushedReplayIndices.formUnion(flushPendingReplayCandidates(kinds: [.thought]))
        }
        transcript.appendMessage(makeNew(newMessageText, newMessagePhase, newMessageMetadata))
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
        guard let i = transcript.toolCallIndex(toolCallId: id),
              case .toolCall(var toolCall) = transcript.messages[i] else { return nil }
        mutate(&toolCall)
        transcript.replaceMessage(at: i, with: .toolCall(toolCall))
        return i
    }

    private func didAppendTranscriptMessage() {
        advanceRenderWindowIfFollowingTail()
    }

    private func clearRestoredContextRecoveryStatus() {
        guard contextRecoveryStatus == .restored else { return }
        contextRecoveryExpiryTask?.cancel()
        contextRecoveryExpiryTask = nil
        contextRecoveryStatus = nil
    }

    private func advanceRenderWindowIfFollowingTail() {
        guard followsTranscriptTail else { return }
        transcript.setVisibleHead(max(0, transcript.messages.count - ACPTranscript.tailWindow))
    }
}
