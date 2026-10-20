import Foundation
import AlasFoundation
import AlasModel
import AlasPlatform
import AlasFeatures
import AlasCode
import AlasIntegrations

/// One event's params. Each event sets only its own fields; the rest are omitted.
public struct PluginEventParams: Codable, Equatable, Sendable {
    public var session: String?
    public var worktree: String?
    /// `session/state`: the session's state. `review/changed`: the pull request's, or `none`.
    public var state: String?
    public var script: String?
    public var run: String?
    /// `run/finished`: `succeeded`, `failed`, `stopped` or `unknown`, and the exit code when the command reported one.
    public var outcome: String?
    public var exitCode: Int?
    public var number: Int?
    public var checks: PluginReviewChecks?
    /// `turn/finished` (API 12).
    public var turn: UsageTurn?

    public init(session: String? = nil, worktree: String? = nil, state: String? = nil, script: String? = nil, run: String? = nil, outcome: String? = nil, exitCode: Int? = nil, number: Int? = nil, checks: PluginReviewChecks? = nil, turn: UsageTurn? = nil) {
        self.session = session
        self.worktree = worktree
        self.state = state
        self.script = script
        self.run = run
        self.outcome = outcome
        self.exitCode = exitCode
        self.number = number
        self.checks = checks
        self.turn = turn
    }
}

public struct PluginEventMessage: Equatable, Sendable {
    public let event: PluginEvent
    public let params: PluginEventParams

    public init(event: PluginEvent, params: PluginEventParams) {
        self.event = event
        self.params = params
    }
}

/// The latest run of one script in one worktree.
public struct PluginRunState: Equatable, Sendable {
    public let run: String
    public let worktree: String
    public let script: String
    /// Nil while the run is going.
    public var outcome: RunOutcome?

    public init(run: String, worktree: String, script: String, outcome: RunOutcome? = nil) {
        self.run = run
        self.worktree = worktree
        self.script = script
        self.outcome = outcome
    }
}

public struct PluginReviewChecks: Codable, Equatable, Sendable {
    public let passed: Int
    public let failed: Int
    public let pending: Int

    public init(passed: Int, failed: Int, pending: Int) {
        self.passed = passed
        self.failed = failed
        self.pending = pending
    }
}

/// A worktree's pull request as the review loop last saw it.
public struct PluginReviewState: Equatable, Sendable {
    public let worktree: String
    /// `open`, `closed`, `merged`, or `none` without a pull request.
    public let state: String
    public var number: Int?
    public var checks: PluginReviewChecks?

    public init(worktree: String, state: String, number: Int? = nil, checks: PluginReviewChecks? = nil) {
        self.worktree = worktree
        self.state = state
        self.number = number
        self.checks = checks
    }
}

extension PluginReviewState {
    /// Kept small: the pull request's number and state, and its checks counted by result.
    public init(snapshot: ReviewLoopSnapshot, worktree: String) {
        guard let request = snapshot.reviewRequest else {
            self.init(worktree: worktree, state: "none")
            return
        }
        let buckets = request.checks.map(\.bucket)
        self.init(
            worktree: worktree, state: request.state.rawValue, number: request.number,
            checks: PluginReviewChecks(
                passed: buckets.filter { $0 == .pass }.count,
                failed: buckets.filter { $0 == .fail || $0 == .cancel }.count,
                pending: buckets.filter { $0 == .pending }.count))
    }
}
