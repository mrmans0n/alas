import Foundation

/// One finished prompt turn on a session, reported by `ACPSessionRunner`
/// after the `session/prompt` RPC settles. Consumed by the orchestration
/// layer to decide whether a delegated child's parent should be told.
struct ACPTurnCompletion: Equatable, Sendable {
    enum Result: Equatable, Sendable {
        case completed
        case failed(String)
        case cancelled
    }

    /// Cap for `lastAgentText`; the tail of the message is kept.
    static let lastAgentTextLimit = 1_200

    let sessionId: String
    /// Epoch milliseconds captured when the user prompt was recorded. Millisecond
    /// (not second) precision is required: `ACPSessionOrchestrationPolicy
    /// .outcomeDisposition` compares this against `ACPDelegationRecord
    /// .lastParentReportAt`, and the coordinator derives the outcome message's
    /// id from it — whole-second precision let two distinct turns starting in
    /// the same second collide on both the comparison and the id.
    let startedAt: Int64
    let result: Result
    /// The delegated prompt that started this turn, if any.
    let delegatedSource: ACPDelegatedPromptSource?
    /// Trimmed tail of the final agent message of the turn, or nil when the
    /// turn produced no agent text.
    let lastAgentText: String?
}
