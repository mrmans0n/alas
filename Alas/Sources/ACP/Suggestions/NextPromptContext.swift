import Foundation

enum NextPromptContext {
    static let sourceLimit = 128 * 1024
    static let tokenLimit = 8_192

    @MainActor
    static func snapshot(session: ACPSession, completedUserID: UUID) -> [NextPromptTurn]? {
        let messages = session.transcript.messages
        guard let latestIndex = messages.lastIndex(where: {
            if case .user(let id, _, _, _, _) = $0 { return id == completedUserID }
            return false
        }) else { return nil }

        // A completion belongs to its captured user row, not any later row.
        guard !messages[(latestIndex + 1)...].contains(where: {
            if case .user = $0 { return true }
            return false
        }) else { return nil }

        var total = 0
        guard let latest = turn(in: messages, userIndex: latestIndex, endIndex: messages.count,
                                remaining: sourceLimit) else { return nil }
        total += latest.bytes
        var turns = [latest.turn]
        var endIndex = latestIndex
        while let userIndex = messages[..<endIndex].lastIndex(where: {
            if case .user = $0 { return true }
            return false
        }) {
            guard let earlier = turn(in: messages, userIndex: userIndex, endIndex: endIndex,
                                     remaining: sourceLimit - total) else { break }
            total += earlier.bytes
            turns.insert(earlier.turn, at: 0)
            endIndex = userIndex
        }
        return turns
    }

    @MainActor
    private static func turn(in messages: [ACPMessage], userIndex: Int, endIndex: Int,
                             remaining: Int) -> (turn: NextPromptTurn, bytes: Int)? {
        guard case .user(_, _, let user, let attachments, let delegatedSource) = messages[userIndex],
              delegatedSource == nil,
              attachments.allSatisfy(\.isCheckpointReference) else { return nil }
        let userBytes = messages[userIndex].contentUTF8Length
        guard userBytes <= remaining,
              !user.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        var bytes = userBytes
        var agentIndices: [Int] = []
        for index in (userIndex + 1)..<endIndex {
            if case .agent = messages[index] {
                let length = messages[index].contentUTF8Length
                guard length > 0 else { continue }
                let separator = agentIndices.isEmpty ? 0 : 1
                guard separator <= remaining - bytes,
                      length <= remaining - bytes - separator else { return nil }
                bytes += separator + length
                agentIndices.append(index)
            }
        }
        guard !agentIndices.isEmpty else { return nil }
        let assistant = agentIndices.compactMap { index -> String? in
            if case .agent(_, _, let text) = messages[index], !text.value.isEmpty { return text.value }
            return nil
        }.joined(separator: "\n")
        guard !assistant.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return (.init(user: user, assistant: assistant), bytes)
    }

    /// The counter must tokenize the full rendered chat template from these messages.
    static func fit(_ turns: [NextPromptTurn], tokenLimit: Int = tokenLimit,
                    tokenCount: ([LocalTextMessage]) -> Int) -> [NextPromptTurn]? {
        guard !turns.isEmpty else { return nil }
        for first in turns.indices {
            let candidate = Array(turns[first...])
            if tokenCount(NextPromptPolicy.messages(for: candidate)) <= tokenLimit {
                return candidate
            }
        }
        return nil
    }
}
