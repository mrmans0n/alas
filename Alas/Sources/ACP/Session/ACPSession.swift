import Foundation
import Combine

@MainActor
final class ACPSession: ObservableObject, Identifiable {
    typealias ID = String

    let id: ID
    let agentId: String
    let worktreeId: String
    let createdAt: Date

    @Published var title: String
    @Published var messages: [ACPMessage] = []
    @Published var availableModels: [ACPModelInfo] = []
    @Published var availableModes: [ACPModeInfo] = []
    @Published var currentModel: String?
    @Published var currentMode: String?
    @Published var promptSuggestions: [ACPPromptSuggestion] = []
    @Published var autoRunEnabled: Bool = false
    @Published var pendingPermission: PendingPermission?
    @Published var streamingState: StreamingState = .idle
    @Published var setupState: SetupState = .checking
    @Published var lastError: String?
    @Published var disconnected: Bool = false
    /// True once a runner has been started for this session — meaning
    /// `initialize` + `session/new` succeeded and we have a live agent on
    /// stdio. Reset to false on detach or when the process exits. The
    /// composer's send button watches this so users can't queue prompts
    /// against a not-yet-attached agent.
    @Published var attached: Bool = false
    /// ACP session id assigned by the agent on `session/new` (or the
    /// id we passed to `session/load`). Used for every subsequent
    /// protocol call (`session/prompt`, `session/cancel`, etc).
    /// Distinct from `id`, which is our locally-generated UUID used
    /// as the persistence key in `ACPSessionStore`.
    /// Not persisted — recreated on each `attach()` if missing.
    var remoteSessionId: String?

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

    init(id: ID, agentId: String, worktreeId: String, title: String, createdAt: Date = Date()) {
        self.id = id
        self.agentId = agentId
        self.worktreeId = worktreeId
        self.title = title
        self.createdAt = createdAt
    }

    func recordUserPrompt(text: String, attachments: [ACPMessage.Attachment]) {
        messages.append(.user(text: text, attachments: attachments))
        if title == "" || title == "New session" {
            title = String(text.prefix(40))
        }
    }

    func apply(_ update: ACPSessionUpdate) {
        switch update {
        case .agentMessageChunk(let block):
            append(text: text(of: block), into: { lastAgent() }, fallback: .agent(text: ""))
        case .userMessageChunk(let block):
            // Agents rarely emit these; treat as informational.
            messages.append(.systemNotice(text: text(of: block)))
        case .agentThoughtChunk(let block):
            append(text: text(of: block), into: { lastThought() }, fallback: .thought(text: ""))
        case .toolCall(let payload):
            let full = payload.content.flatMap { Self.flatten($0) } ?? ""
            messages.append(.toolCall(.init(
                toolCallId: payload.toolCallId,
                title: payload.title,
                kind: payload.kind,
                status: payload.status,
                content: full,
                preview: Self.previewLine(full),
                locations: payload.locations?.map(\.path) ?? [])))
        case .toolCallUpdate(let u):
            updateToolCall(id: u.toolCallId) { tc in
                if let s = u.status { tc.status = s }
                if let c = u.content {
                    let full = Self.flatten(c)
                    tc.content = full
                    tc.preview = Self.previewLine(full)
                }
            }
        case .plan(let entries):
            let items = entries.map { ACPMessage.PlanItem(content: $0.content, status: $0.status) }
            if let i = messages.lastIndex(where: { if case .plan = $0 { return true } else { return false } }) {
                messages[i] = .plan(items)
            } else {
                messages.append(.plan(items))
            }
        case .availableModelsUpdate(let ms):
            availableModels = ms
        case .currentModeUpdate(let modeId):
            currentMode = modeId
        case .currentModelUpdate:
            // Handled in Task 7 (wire chipState into ACPSession)
            break
        case .sessionConfigOptionsUpdate:
            // Handled in Task 7 (wire chipState into ACPSession)
            break
        case .availableCommandsUpdate(let cmds):
            promptSuggestions = cmds
        case .unknown:
            break
        }
    }

    func appendSystemNotice(_ text: String) {
        messages.append(.systemNotice(text: text))
    }

    func appendFileEdit(_ edit: ACPMessage.FileEdit) {
        messages.append(.fileEdit(edit))
    }

    /// Mark any pending/in_progress tool calls as canceled. Called when
    /// the user interrupts streaming so spinners stop and the rendered
    /// status reflects reality (the agent isn't coming back to finish
    /// these). Returns the indices of mutated messages so callers can
    /// persist them.
    func cancelInFlightToolCalls() -> [Int] {
        var changed: [Int] = []
        for i in messages.indices {
            if case .toolCall(var tc) = messages[i],
               tc.status == "in_progress" || tc.status == "pending" {
                tc.status = "canceled"
                messages[i] = .toolCall(tc)
                changed.append(i)
            }
        }
        return changed
    }

    // MARK: helpers

    /// Concatenate the agent's text content blocks into one string. Non-
    /// text blocks (resource links, images) are noted as bracketed
    /// placeholders so the user knows something non-text arrived.
    private static func flatten(_ blocks: [ACPContentBlock]) -> String {
        var out: [String] = []
        for b in blocks {
            switch b {
            case .text(let s):                  out.append(s)
            case .resourceLink(let uri, let n): out.append("[\(n ?? uri)]")
            case .image(_, _):                  out.append("[image]")
            }
        }
        return out.joined(separator: "\n")
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

    private func text(of block: ACPContentBlock) -> String {
        if case .text(let s) = block { return s }
        return ""
    }

    private func lastAgent() -> Int? {
        for i in stride(from: messages.count - 1, through: 0, by: -1) {
            // STOP on .user — every new user turn starts a fresh
            // agent reply. Without this the agent's response to a NEW
            // prompt gets appended to the previous turn's trailing
            // agent message, breaking the conversation order.
            if case .user = messages[i] { return nil }
            if case .agent = messages[i] { return i }
            if case .toolCall = messages[i] { return nil }
            if case .fileEdit = messages[i] { return nil }
        }
        return nil
    }
    private func lastThought() -> Int? {
        for i in stride(from: messages.count - 1, through: 0, by: -1) {
            if case .user = messages[i] { return nil }
            if case .thought = messages[i] { return i }
            if case .agent = messages[i] { return nil }
            if case .toolCall = messages[i] { return nil }
        }
        return nil
    }
    private func append(text addition: String, into locate: () -> Int?, fallback: ACPMessage) {
        if let i = locate() {
            switch messages[i] {
            case .agent(let t):   messages[i] = .agent(text: t + addition)
            case .thought(let t): messages[i] = .thought(text: t + addition)
            default: messages.append(fallback)
            }
        } else {
            switch fallback {
            case .agent: messages.append(.agent(text: addition))
            case .thought: messages.append(.thought(text: addition))
            default: messages.append(fallback)
            }
        }
    }
    private func updateToolCall(id: String, _ mutate: (inout ACPMessage.ToolCall) -> Void) {
        for i in messages.indices {
            if case .toolCall(var tc) = messages[i], tc.toolCallId == id {
                mutate(&tc)
                messages[i] = .toolCall(tc)
                return
            }
        }
    }
}
