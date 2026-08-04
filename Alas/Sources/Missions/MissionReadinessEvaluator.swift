import Foundation

enum MissionReadinessSignal: Equatable, Sendable {
    case review(state: ReviewRequestState, identity: MissionReviewIdentity)
    case worktreeArchived
    case worktreeMissing
    case projectRemoved
    case refreshUnavailable
}

enum MissionLegReadinessDecision: Equatable, Sendable {
    case unchanged(reviewIdentity: MissionReviewIdentity?)
    case ready(
        reviewIdentity: MissionReviewIdentity?,
        evidence: MissionLegReadinessEvidence,
        message: String
    )
    case needsAttention(String)
}

enum MissionReadinessEvaluator {
    static let missingWorktreeMessage = "The Mission worktree is no longer available."

    static func evaluate(
        currentState: MissionLegState,
        signal: MissionReadinessSignal,
        observedAt: Date
    ) -> MissionLegReadinessDecision {
        if currentState == .ready {
            if case .review(_, let identity) = signal {
                return .unchanged(reviewIdentity: identity)
            }
            return .unchanged(reviewIdentity: nil)
        }

        switch signal {
        case .review(.merged, let identity):
            return .ready(
                reviewIdentity: identity,
                evidence: .init(kind: .mergedReview, observedAt: observedAt),
                message: "\(identity.provider.reviewRequestLabel) \(identity.provider.reviewRequestNumberPrefix)\(identity.number) merged."
            )
        case .review(_, let identity):
            return .unchanged(reviewIdentity: identity)
        case .worktreeArchived:
            return .ready(
                reviewIdentity: nil,
                evidence: .init(kind: .archivedWorktree, observedAt: observedAt),
                message: "Worktree archived in Alas."
            )
        case .worktreeMissing:
            return .needsAttention(missingWorktreeMessage)
        case .projectRemoved:
            return .needsAttention("The Mission project is no longer available.")
        case .refreshUnavailable:
            return .unchanged(reviewIdentity: nil)
        }
    }
}
