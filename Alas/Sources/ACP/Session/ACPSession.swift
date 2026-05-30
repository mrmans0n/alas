import Foundation
import Combine

enum ACPSessionTitleSource: String, Codable {
    case placeholder
    case generated
    case manual
}

@MainActor
final class ACPSession: ObservableObject, Identifiable {
    typealias ID = String

    let id: ID
    let agentId: String
    let worktreeId: String
    let createdAt: Date
    let transcript = ACPTranscript()
    let terminalHost: ACPTerminalHost = ACPTerminalHost(sessionCwd: "/", sessionEnv: [:])

    @Published var title: String
    @Published var titleSource: ACPSessionTitleSource
    @Published var availableModels: [ACPModelInfo] = []
    @Published var availableModes: [ACPModeInfo] = []
    @Published var availableConfigOptions: [ACPConfigOption] = []
    @Published var currentModel: String?
    @Published var currentMode: String?
    @Published var promptSuggestions: [ACPPromptSuggestion] = []
    @Published var autoRunEnabled: Bool = false
    @Published var composerDraft: ACPComposerDraft = .empty
    @Published private(set) var composerDraftRevision: Int = 0
    @Published var setupState: SetupState = .checking
    @Published var lastError: String?
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
    /// Not persisted — recreated on each `attach()` if missing.
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

    func replaceComposerDraft(_ draft: ACPComposerDraft) {
        composerDraft = draft
        composerDraftRevision += 1
    }

    enum HydrationState: Equatable {
        case loading
        case ready
        case failed(String)
    }
    enum StreamingState: Equatable { case idle, sending, streaming, awaitingPermission }
    enum SetupState: Equatable {
        case checking
        case ready
        case needsSetup(reason: String)
    }
    struct PendingPermission: Identifiable, Equatable {
        let id: JSONRPCID
        let params: ACPPermissionRequestParams
    }

    init(id: ID, agentId: String, worktreeId: String, title: String,
         titleSource: ACPSessionTitleSource = .placeholder,
         createdAt: Date = Date(),
         hydrationState: HydrationState = .ready) {
        self.id = id
        self.agentId = agentId
        self.worktreeId = worktreeId
        self.title = title
        self.titleSource = titleSource
        self.createdAt = createdAt
        self.hydrationState = hydrationState
    }

    deinit {
        // Foundation cannot await main-actor methods from deinit; dispatch.
        let host = terminalHost
        Task { @MainActor in host.killAll() }
    }

    func recordUserPrompt(text: String, attachments: [ACPMessage.Attachment]) {
        transcript.messages.append(.user(id: UUID(), text: text, attachments: attachments))
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
        case .agentMessageChunk(let block):
            let txt = text(of: block)
            let i = appendStreaming(text: txt, locate: { lastAgent() },
                                    makeNew: { .agent(id: UUID(), StreamingText(txt)) })
            return [i]
        case .userMessageChunk(let block):
            // Agents rarely emit these; treat as informational.
            transcript.messages.append(.systemNotice(id: UUID(), text: text(of: block)))
            return [transcript.messages.count - 1]
        case .agentThoughtChunk(let block):
            let txt = text(of: block)
            let i = appendStreaming(text: txt, locate: { lastThought() },
                                    makeNew: { .thought(id: UUID(), StreamingText(txt)) })
            return [i]
        case .toolCall(let payload):
            let items = payload.content ?? []
            let full = Self.stripWrappingFence(Self.flatten(items),
                                               isFinal: Self.isFinalStatus(payload.status))
            transcript.messages.append(.toolCall(.init(
                toolCallId: payload.toolCallId,
                title: payload.title,
                kind: payload.kind,
                status: payload.status,
                content: full,
                preview: Self.previewLine(full),
                locations: payload.locations?.map(\.path) ?? [],
                terminalIds: Self.extractTerminalIds(items))))
            return [transcript.messages.count - 1]
        case .toolCallUpdate(let u):
            let touched = updateToolCall(id: u.toolCallId) { tc in
                if let s = u.status { tc.status = s }
                if let c = u.content {
                    // ACP content updates are full replacement snapshots,
                    // so terminalIds tracks the *current* content — assign
                    // unconditionally, including the empty case, so a
                    // text/diff-only final update doesn't leave a stale
                    // terminal tail rendering in the card.
                    let full = Self.stripWrappingFence(Self.flatten(c),
                                                      isFinal: Self.isFinalStatus(tc.status))
                    tc.content = full
                    tc.preview = Self.previewLine(full)
                    tc.terminalIds = Self.extractTerminalIds(c)
                }
            }
            return touched.map { [$0] } ?? []
        case .plan(let entries):
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
        case .unknown:
            return []
        }
    }

    func appendSystemNotice(_ text: String) {
        transcript.messages.append(.systemNotice(id: UUID(), text: text))
    }

    func appendFileEdit(_ edit: ACPMessage.FileEdit) {
        transcript.messages.append(.fileEdit(id: UUID(), edit))
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

    /// Number of queue items that should render as bubbles below the
    /// transcript. Excludes the `.sending` head because its prompt has
    /// already been appended to the transcript by `ACPSessionRunner.sendNow`
    /// (and the composer's Stop pill conveys the in-flight state). Without
    /// this, the user sees the same message twice — once in the transcript,
    /// once as a "Sending" queued bubble.
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
        return queue.removeFirst()
    }

    /// Roll the `.sending` head back to `.pending` with an error message.
    /// Used by the flusher's failure path. Keeps the item at the head so
    /// the user sees "Retry" on the bubble.
    func setQueueHeadError(_ message: String) {
        guard !queue.isEmpty else { return }
        queue[0].status = .pending
        queue[0].lastError = message
    }

    /// Replace the queue wholesale with a normalized restore set. Called
    /// from `ACPSessionManager.openSession` after pulling rows from the
    /// store. `.sending` items get flipped to `.pending` here so the
    /// flusher re-attempts on next idle.
    func restoreQueue(_ items: [QueuedPrompt]) {
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
            case .content(.resourceLink(let uri, let name)):
                out.append("[\(name ?? uri)]")
            case .content(.image(_, _)):
                out.append("[image]")
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

    private static func extractTerminalIds(_ items: [ACPToolCallContent]) -> [String] {
        items.compactMap { if case .terminal(let id) = $0 { return id } else { return nil } }
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
    /// Returns the index of the message that was appended or mutated.
    private func appendStreaming(text addition: String,
                                locate: () -> Int?,
                                makeNew: () -> ACPMessage) -> Int {
        if let i = locate() {
            switch transcript.messages[i] {
            case .agent(_, let buf), .thought(_, let buf):
                buf.append(addition)
                transcript.streamingTick &+= 1
                return i
            default:
                break
            }
        }
        transcript.messages.append(makeNew())
        return transcript.messages.count - 1
    }
    /// Returns the index of the matching tool call, or nil if no match.
    private func updateToolCall(id: String, _ mutate: (inout ACPMessage.ToolCall) -> Void) -> Int? {
        for i in transcript.messages.indices {
            if case .toolCall(var tc) = transcript.messages[i], tc.toolCallId == id {
                mutate(&tc)
                transcript.messages[i] = .toolCall(tc)
                return i
            }
        }
        return nil
    }
}
