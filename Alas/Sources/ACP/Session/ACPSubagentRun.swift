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
    /// The child's own transcript, in arrival order.
    @Published private(set) var messages: [ACPMessage] = []

    /// Set the first time a terminal state lands, so the row can show how
    /// long the child ran without re-deriving it from message timestamps.
    private(set) var startedAt: Date
    private(set) var finishedAt: Date?

    private var createdAts: [Int] = []

    init(
        subagentSessionId: String,
        name: String? = nil,
        task: String? = nil,
        state: ACPSubagentState = .running,
        capabilities: ACPSubagentCapabilities = .init(),
        startedAt: Date = Date()
    ) {
        self.subagentSessionId = subagentSessionId
        self.name = name
        self.task = task
        self.state = state
        self.capabilities = capabilities
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
        if let startedAt { self.startedAt = startedAt }
    }

    func apply(state newState: ACPSubagentState, at timestamp: Date = Date()) {
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
            let text = Self.text(of: chunk.content)
            guard !text.isEmpty else { return [] }
            return [append(.user(
                id: UUID(),
                messageId: chunk.messageId,
                text: text,
                attachments: []), at: timestamp)]
        case .toolCall(let payload):
            return [append(
                .toolCall(ACPSession.makeToolCall(from: payload, at: timestamp)),
                at: timestamp)]
        case .toolCallUpdate(let update):
            guard let index = messages.lastIndex(where: {
                if case .toolCall(let tc) = $0 { return tc.toolCallId == update.toolCallId }
                return false
            }), case .toolCall(var tc) = messages[index] else { return [] }
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

    /// Restores a persisted child transcript. Replaces whatever is in
    /// memory, so hydration is idempotent across repeated loads.
    func restore(messages restored: [ACPMessage], createdAts timestamps: [Date]) {
        messages = restored
        createdAts = timestamps.map { Int($0.timeIntervalSince1970) }
        if let first = timestamps.first { startedAt = min(startedAt, first) }
    }

    func createdAt(at index: Int) -> Date {
        guard index >= 0, index < createdAts.count else { return startedAt }
        return Date(timeIntervalSince1970: TimeInterval(createdAts[index]))
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

    /// The row a chunk extends: the matching `messageId` when the agent
    /// supplies one, otherwise the trailing row of that kind — but only
    /// while nothing else has closed the run (a tool call or a new prompt
    /// starts a fresh bubble, exactly as in the parent transcript).
    private func trailingIndex(of kind: StreamKind, messageId: String?) -> Int? {
        for index in stride(from: messages.count - 1, through: 0, by: -1) {
            switch messages[index] {
            case .agent(_, let id, _):
                if kind == .agent, messageId == nil || id == messageId { return index }
                return nil
            case .thought(_, let id, _):
                if kind == .thought, messageId == nil || id == messageId { return index }
                return nil
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
        return messages.count - 1
    }

    private static func text(of block: ACPContentBlock) -> String {
        if case .text(let value) = block { return value }
        return ""
    }
}
