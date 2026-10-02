import Foundation

/// A parent session's open `/btw` side question. `sessionID` is nil until
/// the hidden side session exists; `id` tells a replaced question apart.
struct ACPSideQuestion: Equatable, Sendable {
    let id = UUID()
    let question: String
    var sessionID: ACPSession.ID?
    var error: String?
    /// Set once the question reached the side session; Keep needs it.
    var isSubmitted = false
    /// Set while Keep is storing the promotion, so it runs once.
    var isPromoting = false
}

enum ACPSideQuestionError: LocalizedError, Equatable {
    case notAccepted
    case unsafeMode
    case unenforceable

    var errorDescription: String? {
        switch self {
        case .notAccepted:
            "The side session couldn't accept the question."
        case .unsafeMode:
            "Couldn't switch the side session to a read-only mode, so the question wasn't sent."
        case .unenforceable:
            "This agent runs its tools without asking for permission, so a side question can't be kept read-only."
        }
    }
}

/// Slash commands Alas handles itself instead of sending to the agent.
enum ACPAlasSlashCommand: Equatable {
    case btw(question: String)

    static let btwSuggestion = ACPPromptSuggestion(
        command: "/btw",
        description: "Ask a side question in a read-only fork. The current turn keeps running.",
        hint: "question"
    )

    static func parse(_ text: String) -> ACPAlasSlashCommand? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix(btwSuggestion.command) else { return nil }
        let rest = trimmed.dropFirst(btwSuggestion.command.count)
        guard rest.first.map({ $0.isWhitespace }) ?? true else { return nil }
        return .btw(question: rest.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    static func isAlasCommand(_ suggestion: ACPPromptSuggestion) -> Bool {
        suggestion == btwSuggestion
    }

    /// Alas commands first; an agent command with the same name is hidden,
    /// because Alas intercepts it before it could reach the agent.
    static func suggestions(
        alas: [ACPPromptSuggestion],
        agent: [ACPPromptSuggestion]
    ) -> [ACPPromptSuggestion] {
        let alasCommands = Set(alas.map(\.command))
        return alas + agent.filter { !alasCommands.contains($0.command) }
    }
}

/// What the composer's submit does with a draft that may be `/btw`.
enum ACPSideQuestionSubmitRoute: Equatable {
    /// Not a side question here; the draft goes to the main session.
    case passThrough
    /// A side question that can't be asked as drafted; the draft stays.
    case refuse(String)
    case ask(question: String)

    /// `isAvailable` is whether this tab offers `/btw` at all; elsewhere an
    /// agent's own `/btw` goes through untouched.
    static func resolve(
        text: String,
        hasAttachments: Bool,
        intent: ACPSubmitIntent,
        isAvailable: Bool
    ) -> ACPSideQuestionSubmitRoute {
        guard isAvailable, case .btw(let question)? = ACPAlasSlashCommand.parse(text) else {
            return .passThrough
        }
        if hasAttachments {
            return .refuse("/btw doesn't support attachments yet. Remove them to ask a side question.")
        }
        if case .schedule = intent {
            return .refuse("/btw can't be scheduled. Send it now to ask a side question.")
        }
        return .ask(question: question)
    }
}

/// What the side card shows, derived from the question and its session.
enum ACPSideQuestionPhase: Equatable {
    case composing
    case starting
    case streaming
    case answered
    case failed(String)

    static func resolve(
        question: String,
        creationError: String?,
        hasSession: Bool,
        sessionError: String?,
        isTurnActive: Bool,
        hasPrompt: Bool,
        hasOutput: Bool
    ) -> ACPSideQuestionPhase {
        if let error = creationError ?? sessionError { return .failed(error) }
        guard hasSession else { return question.isEmpty ? .composing : .starting }
        // Output is anything the latest turn produced after its question:
        // text, tool calls, or blocked calls.
        if isTurnActive { return hasOutput ? .streaming : .starting }
        // Once its prompt is in the transcript, an idle turn has finished,
        // even one that ended with only a stop reason.
        return hasPrompt ? .answered : .starting
    }
}

/// Where a `/btw` side question forks its parent: the last agent answer
/// with text. A running turn is left out, and so is a prompt interrupted
/// before any answer, so the side session never inherits a prompt without
/// its answer. Nil when there is no answer yet; the side session starts blank.
enum ACPSideQuestionBoundaryPolicy {
    @MainActor
    static func boundary(messages: [ACPMessage], isTurnActive: Bool) -> ACPForkMessageBoundary? {
        var candidates = messages[...]
        if isTurnActive {
            guard let inFlightPrompt = messages.lastIndex(where: { $0.forkBoundaryKind == .user }) else {
                return nil
            }
            candidates = messages[..<inFlightPrompt]
        }
        guard let message = candidates.last(where: { $0.forkBoundaryKind == .agent && $0.hasForkableText }) else {
            return nil
        }
        return ACPForkMessageBoundary(stableID: message.stableId, kind: .agent)
    }

    static func title(for question: String) -> String {
        let firstLine = question.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        return "/btw: \(firstLine.trimmingCharacters(in: .whitespaces))"
    }
}

/// Agents whose read-only state Alas can actually enforce. The permission
/// gate only sees calls an agent asks about, and agents run tools that the
/// user's own rules allow without asking. Claude's plan mode and Codex's
/// read-only sandbox hold regardless of those rules; other agents (OpenCode,
/// Pi, Copilot, …) offer no such mode, so side questions refuse them.
enum ACPSideQuestionSupportPolicy {
    static func canEnforceReadOnly(agentId: String) -> Bool {
        ["claude", "codex"].contains(agentId)
    }
}

/// What a read-only `/btw` side session may run. Reads are allowed so the
/// side agent can look things up; `fetch` asks because it sends data off the
/// machine; anything else, including unknown kinds, is rejected.
enum ACPSideQuestionPermissionRule {
    enum Decision: Equatable { case allow, ask, reject }

    static func decide(kind: String?) -> Decision {
        switch kind {
        case "read", "search", "think": .allow
        case "fetch": .ask
        default: .reject
        }
    }
}

/// The mode a side session switches to: plan when the agent has one,
/// otherwise away from modes that approve tool calls on their own. Works on
/// the mode chip's options, whether the agent backs them with
/// `session/set_mode` or a config option. Adapters that don't send
/// `_meta.kind` fall back to well-known mode ids; a current mode that stays
/// unclassified is not trusted.
enum ACPSideQuestionModePolicy {
    /// Nil when the current mode can stay.
    static func preferredModeID(options: [ChipSpec.Item], currentID: String?) -> String? {
        if let plan = options.first(where: { kind(of: $0) == .plan }) {
            return plan.id == currentID ? nil : plan.id
        }
        guard !allows(options: options, currentID: currentID) else { return nil }
        return options.first { kind(of: $0) == .standard }?.id
    }

    /// Whether a config-option mode change took effect. An empty echo comes
    /// from adapters that don't return the refreshed options, and stands; a
    /// full one must show the target selected.
    static func acceptsEcho(_ echoed: [ACPConfigOption], configID: String, target: String) -> Bool {
        guard !echoed.isEmpty else { return true }
        return echoed.first { $0.id == configID }?.currentValue == .string(target)
    }

    /// Whether a side session may ask its question in `currentID`.
    static func allows(options: [ChipSpec.Item], currentID: String?) -> Bool {
        guard !options.isEmpty else { return true }
        guard let current = options.first(where: { $0.id == currentID }),
              let kind = kind(of: current)
        else { return false }
        // These run tool calls without asking, so the read-only permission
        // gate would never see them.
        return kind != .fullAccess && kind != .autoReview
    }

    private static func kind(of item: ChipSpec.Item) -> ACPModeKind? {
        item.kind ?? knownKinds[item.id]
    }

    /// Mode ids of Claude and Codex adapters that predate `_meta.kind`.
    private static let knownKinds: [String: ACPModeKind] = [
        "default": .standard,
        "read-only": .standard,
        "plan": .plan,
        "auto": .autoReview,
        "agent": .autoReview,
        "bypassPermissions": .fullAccess,
        "agent-full-access": .fullAccess,
    ]
}

private extension ACPMessage {
    @MainActor
    var hasForkableText: Bool {
        let text: String
        switch self {
        case .user(_, _, let value, _, _): text = value
        case .agent(_, _, let buffer): text = buffer.value
        default: return false
        }
        return !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}
