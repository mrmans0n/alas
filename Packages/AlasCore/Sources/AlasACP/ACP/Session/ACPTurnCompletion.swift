import Foundation
import AlasFoundation
import AlasModel
import AlasPlatform
import AlasFeatures
import AlasCode

/// One finished prompt turn on a session, reported by `ACPSessionRunner`
/// after the `session/prompt` RPC settles. Consumed by the orchestration
/// layer to decide whether a delegated child's parent should be told.
public struct ACPTurnCompletion: Equatable, Sendable {
    public enum Result: Equatable, Sendable {
        case completed
        case failed(String)
        case cancelled
        /// Foreground work ended without a successful end_turn result.
        case stopped(ACPStopReason)
        /// Stopped by a provider usage limit; Alas may resume it later.
        case limited
    }

    /// Cap for `lastAgentText`; the tail of the message is kept.
    public static let lastAgentTextLimit = 1_200

    public let sessionId: String
    /// Epoch milliseconds captured when the user prompt was recorded. Millisecond
    /// (not second) precision is required: `ACPSessionOrchestrationPolicy
    /// .outcomeDisposition` compares this against `ACPDelegationRecord
    /// .lastParentReportAt`, and the coordinator derives the outcome message's
    /// id from it — whole-second precision let two distinct turns starting in
    /// the same second collide on both the comparison and the id.
    public let startedAt: Int64
    public let result: Result
    /// The delegated prompt that started this turn, if any.
    public let delegatedSource: ACPDelegatedPromptSource?
    /// Trimmed tail of the final agent message of the turn, or nil when the
    /// turn produced no agent text.
    public let lastAgentText: String?
    /// The turn's own `_meta.quota`; nil when the adapter sent none or the turn ended without a prompt result.
    public var quota: ACPPromptQuota? = nil
    /// Resolves the turn's cumulative cost for usage history; nil when the runner did not report one.
    public var cost: ACPTurnCost? = nil
    /// Epoch milliseconds when the prompt went to the agent; nil when it never did. Later than `startedAt` by the
    /// checkpoint, attachment and context work before sending.
    public var sentAt: Int64? = nil
    /// Epoch milliseconds when the turn ended; nil when the runner did not stamp it. Usage can be reported later.
    public var endedAt: Int64? = nil
    /// The session's model when the prompt went to the agent; nil when it never did or none was known.
    public var model: String? = nil
    /// A context-recovery prompt Alas sent, reported only as usage.
    public var recovery = false
    /// An autonomous cycle the adapter ran after a turn settled at its result, reported only as usage: its cost is
    /// kept apart from the prompt turns around it.
    public var background = false

    public init(sessionId: String, startedAt: Int64, result: Result, delegatedSource: ACPDelegatedPromptSource?, lastAgentText: String?, quota: ACPPromptQuota? = nil, cost: ACPTurnCost? = nil, sentAt: Int64? = nil, endedAt: Int64? = nil, model: String? = nil, recovery: Bool = false, background: Bool = false) {
        self.sessionId = sessionId
        self.startedAt = startedAt
        self.result = result
        self.delegatedSource = delegatedSource
        self.lastAgentText = lastAgentText
        self.quota = quota
        self.cost = cost
        self.sentAt = sentAt
        self.endedAt = endedAt
        self.model = model
        self.recovery = recovery
        self.background = background
    }
}

/// A finished turn's cumulative cost: the session's, when a `usage_update` with a cost arrived during the turn, and
/// nil when none did, so a turn never reports a stale total as its own. The turn's last update may still be on the
/// stream when its result arrives, so `resolve` can wait, without touching the runner, until the updates sent before
/// the result have been taken off it. The completion itself is never held for this.
@MainActor
public final class ACPTurnCost: Equatable {
    /// Updates sent before the result that were still on the stream then.
    public struct Later: Sendable {
        /// Every update sent before the result has been taken off the stream.
        public let settled: @MainActor () -> Bool
        /// More can still be taken off it.
        public let live: @MainActor () -> Bool
        /// The turn's cost from the updates taken off so far; never one sent after the result.
        public let sentBeforeResult: @MainActor () -> ACPUsageInfo.Cost?

        public init(settled: @escaping @MainActor () -> Bool, live: @escaping @MainActor () -> Bool, sentBeforeResult: @escaping @MainActor () -> ACPUsageInfo.Cost?) {
            self.settled = settled
            self.live = live
            self.sentBeforeResult = sentBeforeResult
        }
    }

    /// The cost as of the result.
    private let known: ACPUsageInfo.Cost?
    private let later: Later?

    public init(known: ACPUsageInfo.Cost?, later: Later? = nil) {
        self.known = known
        self.later = later
    }

    /// Waits at most a second for the updates sent before the result.
    public func resolve() async -> ACPUsageInfo.Cost? {
        guard let later else { return known }
        // ponytail: a yield loop with a deadline, as `ACPSessionRunner.persistPermissionDecision` drains.
        let deadline = ContinuousClock.now + .seconds(1)
        while !later.settled(), later.live(), ContinuousClock.now < deadline {
            await Task.yield()
        }
        return later.sentBeforeResult() ?? known
    }

    public nonisolated static func == (lhs: ACPTurnCost, rhs: ACPTurnCost) -> Bool { lhs === rhs }
}
