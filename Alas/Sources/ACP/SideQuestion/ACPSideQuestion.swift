import Foundation

/// Where a `/btw` side question forks its parent: the last completed turn.
/// A turn still running is left out, so the side session never inherits a
/// prompt without its answer.
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
        guard let message = candidates.last(where: { $0.forkBoundaryKind != nil && $0.hasForkableText }),
              let kind = message.forkBoundaryKind
        else { return nil }
        return ACPForkMessageBoundary(stableID: message.stableId, kind: kind)
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
