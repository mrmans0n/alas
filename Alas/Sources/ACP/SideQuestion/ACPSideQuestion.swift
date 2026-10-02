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

    var errorDescription: String? {
        switch self {
        case .notAccepted:
            "The side session couldn't accept the question."
        }
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
