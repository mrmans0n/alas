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
        hasAnswer: Bool
    ) -> ACPSideQuestionPhase {
        if let error = creationError ?? sessionError { return .failed(error) }
        guard hasSession else { return question.isEmpty ? .composing : .starting }
        if isTurnActive { return hasAnswer ? .streaming : .starting }
        return hasAnswer ? .answered : .starting
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
/// `session/set_mode` or a config option.
enum ACPSideQuestionModePolicy {
    /// Nil when the current mode can stay.
    static func preferredModeID(options: [ChipSpec.Item], currentID: String?) -> String? {
        if let plan = options.first(where: { $0.kind == .plan }) {
            return plan.id == currentID ? nil : plan.id
        }
        guard let current = options.first(where: { $0.id == currentID }), selfApproves(current) else {
            return nil
        }
        return options.first { $0.kind == .standard }?.id
    }

    /// Whether a side session may ask its question in `currentID`.
    static func allows(options: [ChipSpec.Item], currentID: String?) -> Bool {
        guard let current = options.first(where: { $0.id == currentID }) else { return true }
        return !selfApproves(current)
    }

    /// These modes run tool calls without asking, so the read-only
    /// permission gate would never see them.
    private static func selfApproves(_ item: ChipSpec.Item) -> Bool {
        item.kind == .fullAccess || item.kind == .autoReview
    }
}

enum ACPSideQuestionError: LocalizedError, Equatable {
    case unsafeMode

    var errorDescription: String? {
        switch self {
        case .unsafeMode:
            "Couldn't switch the side session to a read-only mode, so the question wasn't sent."
        }
    }
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
