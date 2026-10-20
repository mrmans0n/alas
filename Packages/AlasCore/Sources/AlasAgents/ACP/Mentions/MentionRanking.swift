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
