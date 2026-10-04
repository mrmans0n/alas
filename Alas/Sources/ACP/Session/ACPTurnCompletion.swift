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
}

/// A finished turn's cumulative cost: the session's, when a `usage_update` with a cost arrived during the turn, and
/// nil when none did, so a turn never reports a stale total as its own. The turn's last update may still be on the
/// stream when its result arrives, so `resolve` waits, without touching the runner, until the updates sent before
/// the result have been taken off it. The completion itself is never held for this.
@MainActor
final class ACPTurnCost: Equatable {
    private let known: ACPUsageInfo.Cost?
    private let settled: @MainActor () -> Bool
    private let live: @MainActor () -> Bool
    private let read: @MainActor () -> ACPUsageInfo.Cost?

    /// `known` is the cost as of the result; `settled` says the updates sent before it were taken off the stream,
    /// `live` that more still can be, and `read` gives the cost once settled.
    init(
        known: ACPUsageInfo.Cost?, settled: @escaping @MainActor () -> Bool, live: @escaping @MainActor () -> Bool,
        read: @escaping @MainActor () -> ACPUsageInfo.Cost?
    ) {
        self.known = known
        self.settled = settled
        self.live = live
        self.read = read
    }

    /// Waits at most a second; if the stream went away first, the cost as of the result.
    func resolve() async -> ACPUsageInfo.Cost? {
        // ponytail: a yield loop with a deadline, as `ACPSessionRunner.persistPermissionDecision` drains.
        let deadline = ContinuousClock.now + .seconds(1)
        while !settled(), live(), ContinuousClock.now < deadline {
            await Task.yield()
        }
        return settled() ? read() : known
    }

    nonisolated static func == (lhs: ACPTurnCost, rhs: ACPTurnCost) -> Bool { lhs === rhs }
}
