import Foundation
import AlasFoundation
import AlasModel
import AlasPlatform
import AlasFeatures
import AlasCode
import AlasACP

/// A parent session's open `/btw` side question. `sessionID` is nil until
/// the hidden side session exists; `id` tells a replaced question apart.
public struct ACPSideQuestion: Equatable, Sendable {
    public let id = UUID()
    public let question: String
    public var sessionID: ACPSession.ID?
    public var error: String?
    /// Set once the question reached the side session; Keep needs it.
    public var isSubmitted = false
    /// Set while Keep is storing the promotion, so it runs once.
    public var isPromoting = false

    /// Sent ahead of every prompt in a side session, never recorded. Claude's
    /// plan mode otherwise turns any question into a plan, and the exit-plan
    /// request it ends with is blocked, so the turn ends with no answer.
    public static let guidance = """
    This is a quick side question asked while another task runs. Answer it \
    directly in text. You may read files to answer, but do not write a plan, \
    edit files, or ask to leave plan mode. Any edit, write, or command will be \
    rejected, so don't attempt them.
    """

    /// The error a blocked write or command returns to the agent. Agents
    /// read it, so it says what to do instead.
    public static let readOnlyRejection =
        "Rejected: this is a read-only side question. Do not retry or try another way to change files or run commands; answer in text."

    public init(question: String, sessionID: ACPSession.ID? = nil, error: String? = nil, isSubmitted: Bool = false, isPromoting: Bool = false) {
        self.question = question
        self.sessionID = sessionID
        self.error = error
        self.isSubmitted = isSubmitted
        self.isPromoting = isPromoting
    }
}

/// The calls Alas blocked in a side session, folded for the card's chip.
public struct ACPSideQuestionBlockedSummary: Equatable, Sendable {
    public struct Entry: Equatable, Sendable {
        public let title: String
        public let count: Int

        public init(title: String, count: Int) {
            self.title = title
            self.count = count
        }
    }

    public let entries: [Entry]
    public let total: Int

    public init(_ blocked: [ACPBlockedToolCall]) {
        var order: [String] = []
        var counts: [String: Int] = [:]
        for call in blocked {
            if counts[call.title] == nil { order.append(call.title) }
            counts[call.title, default: 0] += 1
        }
        entries = order.map { Entry(title: $0, count: counts[$0] ?? 0) }
        total = blocked.count
    }

    public var label: String {
        "\(total) action\(total == 1 ? "" : "s") skipped · read-only"
    }
}

/// Slash commands Alas handles itself instead of sending to the agent.
public enum ACPAlasSlashCommand: Equatable, Sendable {
    case btw(question: String)
    /// The toolbar's Ship action. `arguments` is whatever followed the command.
    case ship(arguments: String)

    public static let btwSuggestion = ACPPromptSuggestion(
        command: "/btw",
        description: "Ask a side question in a read-only fork. The current turn keeps running.",
        hint: "question"
    )

    public static let shipSuggestion = ACPPromptSuggestion(
        command: "/ship",
        description: "Have this session open a PR for the branch, or shepherd the open one."
    )

    public static func parse(_ text: String) -> ACPAlasSlashCommand? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let question = arguments(of: btwSuggestion, in: trimmed) { return .btw(question: question) }
        if let arguments = arguments(of: shipSuggestion, in: trimmed) { return .ship(arguments: arguments) }
        return nil
    }

    private static func arguments(of suggestion: ACPPromptSuggestion, in text: String) -> String? {
        guard text.hasPrefix(suggestion.command) else { return nil }
        let rest = text.dropFirst(suggestion.command.count)
        guard rest.first.map({ $0.isWhitespace }) ?? true else { return nil }
        return rest.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public static func isAlasCommand(_ suggestion: ACPPromptSuggestion) -> Bool {
        suggestion == btwSuggestion || suggestion == shipSuggestion
    }

    /// Alas commands first; an agent command with the same name is hidden,
    /// because Alas intercepts it before it could reach the agent.
    public static func suggestions(
        alas: [ACPPromptSuggestion],
        agent: [ACPPromptSuggestion]
    ) -> [ACPPromptSuggestion] {
        let alasCommands = Set(alas.map(\.command))
        return alas + agent.filter { !alasCommands.contains($0.command) }
    }
}

/// What the composer's submit does with a draft that may be `/btw`.
public enum ACPSideQuestionSubmitRoute: Equatable, Sendable {
    /// Not a side question here; the draft goes to the main session.
    case passThrough
    /// A side question that can't be asked as drafted; the draft stays.
    case refuse(String)
    case ask(question: String)

    /// `isAvailable` is whether this tab offers `/btw` at all; elsewhere an
    /// agent's own `/btw` goes through untouched.
    public static func resolve(
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
public enum ACPSideQuestionPhase: Equatable, Sendable {
    case composing
    case starting
    case streaming
    case answered
    case failed(String)

    public static func resolve(
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
public enum ACPSideQuestionBoundaryPolicy: Sendable {
    @MainActor
    public static func boundary(messages: [ACPMessage], isTurnActive: Bool) -> ACPForkMessageBoundary? {
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

    public static func title(for question: String) -> String {
        let firstLine = question.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        return "/btw: \(firstLine.trimmingCharacters(in: .whitespaces))"
    }
}

private extension ACPMessage {
    @MainActor
    var hasForkableText: Bool {
        let text: String
        switch self {
        case .user(_, _, let value, _, _, _): text = value
        case .agent(_, _, let buffer): text = buffer.value
        default: return false
        }
        return !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}
