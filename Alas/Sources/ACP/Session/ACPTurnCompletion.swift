import Foundation

/// One finished prompt turn on a session, reported by `ACPSessionRunner`
/// after the `session/prompt` RPC settles. Consumed by the orchestration
/// layer to decide whether a delegated child's parent should be told.
struct ACPTurnCompletion: Equatable, Sendable {
    enum Result: Equatable, Sendable {
        case completed
        case failed(String)
        case cancelled
        /// Stopped by a provider usage limit; Alas may resume it later.
        case limited
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
    /// The turn's own `_meta.quota`; nil when the adapter sent none or the turn ended without a prompt result.
    var quota: ACPPromptQuota? = nil
    /// Resolves the turn's cumulative cost for usage history; nil when the runner did not report one.
    var cost: ACPTurnCost? = nil
    /// Epoch milliseconds when the prompt went to the agent; nil when it never did. Later than `startedAt` by the
    /// checkpoint, attachment and context work before sending.
    var sentAt: Int64? = nil
    /// The session's model when the prompt went to the agent; nil when it never did or none was known.
    var model: String? = nil
    /// A context-recovery prompt Alas sent, reported only as usage.
    var recovery = false
}

/// A finished turn's cumulative cost: the session's, when a `usage_update` with a cost arrived during the turn, and
/// nil when none did, so a turn never reports a stale total as its own. The turn's last update may still be on the
/// stream when its result arrives, so `resolve` can wait, without touching the runner, until the updates sent before
/// the result have been taken off it. The completion itself is never held for this.
@MainActor
final class ACPTurnCost: Equatable {
    /// Updates sent before the result that were still on the stream then.
    struct Later {
        /// Every update sent before the result has been taken off the stream.
        let settled: @MainActor () -> Bool
        /// More can still be taken off it.
        let live: @MainActor () -> Bool
        /// The turn's cost from the updates taken off so far; never one sent after the result.
        let sentBeforeResult: @MainActor () -> ACPUsageInfo.Cost?
    }

    /// The cost as of the result.
    private let known: ACPUsageInfo.Cost?
    private let later: Later?

    init(known: ACPUsageInfo.Cost?, later: Later? = nil) {
        self.known = known
        self.later = later
    }

    /// Waits at most a second for the updates sent before the result.
    func resolve() async -> ACPUsageInfo.Cost? {
        guard let later else { return known }
        // ponytail: a yield loop with a deadline, as `ACPSessionRunner.persistPermissionDecision` drains.
        let deadline = ContinuousClock.now + .seconds(1)
        while !later.settled(), later.live(), ContinuousClock.now < deadline {
            await Task.yield()
        }
        return later.sentBeforeResult() ?? known
    }

    nonisolated static func == (lhs: ACPTurnCost, rhs: ACPTurnCost) -> Bool { lhs === rhs }
}
