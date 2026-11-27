import Foundation
import AlasFoundation
import AlasModel
import AlasPlatform
import AlasFeatures
import AlasCode

/// A session the composer can attach as context (see `ACPSessionReference`).
public struct ACPSessionMentionCandidate: Identifiable, Hashable, Sendable {
    public let id: String
    public let projectId: String
    public let title: String
    public let agentName: String
    public let worktreeName: String

    public init(id: String, projectId: String, title: String, agentName: String, worktreeName: String) {
        self.id = id
        self.projectId = projectId
        self.title = title
        self.agentName = agentName
        self.worktreeName = worktreeName
    }
}

/// Sessions shown above the files: the most recent ones for an empty query,
/// otherwise the best fuzzy matches on title, agent, and worktree.
public enum MentionSessionRanking: Sendable {
    public static let maxDisplay = 5

    /// `candidates` arrive most recent first; ties keep that order.
    public static func rank(
        _ candidates: [ACPSessionMentionCandidate], query: String, limit: Int = maxDisplay
    ) -> [ACPSessionMentionCandidate] {
        let tokens = query.split(whereSeparator: \.isWhitespace).map(String.init)
        guard !tokens.isEmpty else { return Array(candidates.prefix(limit)) }
        var scored: [(candidate: ACPSessionMentionCandidate, score: Double, order: Int)] = []
        for (order, candidate) in candidates.enumerated() {
            let detail = "\(candidate.agentName) \(candidate.worktreeName)"
            var total = 0.0
            var matched = true
            for token in tokens {
                // Title matches outrank agent or worktree matches.
                let titleScore = FuzzyMatch.score(query: token, target: candidate.title)?.score.advanced(by: 8)
                let detailScore = FuzzyMatch.score(query: token, target: detail)?.score
                guard let best = [titleScore, detailScore].compactMap(\.self).max() else {
                    matched = false
                    break
                }
                total += best
            }
            if matched { scored.append((candidate, total, order)) }
        }
        scored.sort { $0.score != $1.score ? $0.score > $1.score : $0.order < $1.order }
        return scored.prefix(limit).map(\.candidate)
    }
}

/// An agent, or one of its models, the composer can name for delegation
/// (see `ACPAgentReference`).
public struct ACPAgentMentionCandidate: Identifiable, Hashable, Sendable {
    public let agentId: String
    public let agentName: String
    public let modelId: String?
    public let modelName: String?

    public init(agentId: String, agentName: String, modelId: String? = nil, modelName: String? = nil) {
        self.agentId = agentId
        self.agentName = agentName
        self.modelId = modelId
        self.modelName = modelName
    }

    public var id: String { modelId.map { "\(agentId)\u{0}\($0)" } ?? agentId }
    public var displayName: String { modelName.map { "\(agentName) · \($0)" } ?? agentName }

    /// Each available agent, followed by each model it offers.
    public static func candidates(from agents: [ACPDelegationAgentSummary]) -> [ACPAgentMentionCandidate] {
        agents.filter(\.available).flatMap { agent in
            [ACPAgentMentionCandidate(agentId: agent.id, agentName: agent.displayName)]
                + agent.modelCatalog.models.map {
                    ACPAgentMentionCandidate(
                        agentId: agent.id, agentName: agent.displayName, modelId: $0.id, modelName: $0.name)
                }
        }
    }
}

/// Agents and models shown above the sessions once the query names one.
public enum MentionAgentRanking: Sendable {
    public static let maxDisplay = 4
    /// Shorter queries match too much of the catalog (`o` starts "Opus",
    /// "OMP", "openai-…"), so a bare `@` keeps listing sessions and files.
    public static let minQueryLength = 2

    /// Every word of `query`, split at spaces and `:` (so `codex:sol` works),
    /// must start a word of the candidate's agent or model id or name.
    /// Agents come before models; otherwise candidates keep their order.
    public static func rank(
        _ candidates: [ACPAgentMentionCandidate], query: String, limit: Int = maxDisplay
    ) -> [ACPAgentMentionCandidate] {
        let tokens = query.lowercased().split { $0.isWhitespace || $0 == ":" }.map(String.init)
        guard tokens.joined().count >= minQueryLength else { return [] }
        let matches = candidates.filter { candidate in
            let fields = [candidate.agentId, candidate.agentName, candidate.modelId ?? "", candidate.modelName ?? ""]
                .map { $0.lowercased() }
            return tokens.allSatisfy { token in fields.contains { startsWord($0, with: token) } }
        }
        return Array((matches.filter { $0.modelId == nil } + matches.filter { $0.modelId != nil }).prefix(limit))
    }

    /// Whether `token` starts `field` or the part after any
    /// non-alphanumeric character, so `6.2` and `sol` both find "gpt-6.2-sol".
    static func startsWord(_ field: String, with token: String) -> Bool {
        var index = field.startIndex
        var atBoundary = true
        while index < field.endIndex {
            if atBoundary, field[index...].hasPrefix(token) { return true }
            atBoundary = !(field[index].isLetter || field[index].isNumber)
            index = field.index(after: index)
        }
        return false
    }
}
