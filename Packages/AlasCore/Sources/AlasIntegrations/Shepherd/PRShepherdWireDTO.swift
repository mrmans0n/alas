import Foundation
import AlasFoundation
import AlasModel
import AlasPlatform

/// Agent-facing JSON of the `pr_create` MCP tool. Snake_cased on the wire by
/// `ReviewCommentWireDTO.jsonLine`'s key strategy.
public struct PRCreateResultWire: Encodable, Equatable, Sendable {
    public init(number: Int, url: String, provider: String, headSha: String, created: Bool, uncommittedChanges: Bool, shepherd: Shepherd) {
        self.number = number
        self.url = url
        self.provider = provider
        self.headSha = headSha
        self.created = created
        self.uncommittedChanges = uncommittedChanges
        self.shepherd = shepherd
    }

    public struct Shepherd: Encodable, Equatable, Sendable {
        public init(autoFix: Bool, autoMerge: Bool, reviewBeforePush: Bool) {
            self.autoFix = autoFix
            self.autoMerge = autoMerge
            self.reviewBeforePush = reviewBeforePush
        }

        public var autoFix: Bool
        public var autoMerge: Bool
        public var reviewBeforePush: Bool
    }

    public var number: Int
    public var url: String
    public var provider: String
    public var headSha: String
    public var created: Bool
    public var uncommittedChanges: Bool
    public var shepherd: Shepherd
}

extension PRCreateResultWire {
    public init(
        request: ReviewRequest, headSHA: String, created: Bool, uncommittedChanges: Bool, record: ShepherdRecord,
        reviewBeforePush: Bool
    ) {
        self.init(
            number: request.number,
            url: request.url.absoluteString,
            provider: request.provider.rawValue,
            headSha: headSHA,
            created: created,
            uncommittedChanges: uncommittedChanges,
            shepherd: Shepherd(autoFix: record.autoFix, autoMerge: record.autoMerge, reviewBeforePush: reviewBeforePush)
        )
    }
}

/// Review before push state for one owning session, as `pr_create` and
/// `pr_status` report it. Optional fields encode as explicit `null`.
public struct ShipReviewWire: Encodable, Equatable, Sendable {
    public init(
        state: String, round: Int, maxRounds: Int, reviewer: String, headSha: String?, openFindings: Int, message: String?
    ) {
        self.state = state
        self.round = round
        self.maxRounds = maxRounds
        self.reviewer = reviewer
        self.headSha = headSha
        self.openFindings = openFindings
        self.message = message
    }

    public var state: String
    public var round: Int
    public var maxRounds: Int
    /// "codex/gpt-5.2", or the agent id alone for its default model.
    public var reviewer: String
    public var headSha: String?
    public var openFindings: Int
    /// Why the review stopped; nil while it hasn't.
    public var message: String?

    public enum CodingKeys: String, CodingKey {
        case state, round, maxRounds, reviewer, headSha, openFindings, message
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(state, forKey: .state)
        try container.encode(round, forKey: .round)
        try container.encode(maxRounds, forKey: .maxRounds)
        try container.encode(reviewer, forKey: .reviewer)
        try container.encode(headSha, forKey: .headSha)
        try container.encode(openFindings, forKey: .openFindings)
        try container.encode(message, forKey: .message)
    }
}

extension ShipReviewWire {
    /// `reviewer` is the resolved reviewer, "agent/model" or "agent";
    /// `openFindings` the current round's findings still active in the pane.
    public init(record: ShipReviewRecord, reviewer: String, openFindings: Int) {
        let state: String
        let head: String?
        var message: String?
        switch record.phase {
        case .idle:
            state = "idle"
            head = record.currentRound?.headSHA
        case let .reviewing(headSHA, _):
            state = "reviewing"
            head = headSHA
        case let .awaitingFix(headSHA):
            state = "awaiting_fix"
            head = headSHA
        case let .pushing(headSHA):
            state = "pushing"
            head = headSHA
        case let .stopped(stop):
            state = "stopped"
            head = record.currentRound?.headSHA
            message = ShipReviewPresentation.stopMessage(stop, maxRounds: record.maxRounds)
        }
        self.init(
            state: state,
            round: record.currentRound?.number ?? 0,
            maxRounds: record.maxRounds,
            reviewer: reviewer,
            headSha: head,
            openFindings: openFindings,
            message: message
        )
    }
}

/// `pr_create` while the push waits for review before push. Not an error:
/// Alas pushes and opens the request itself once the review is clean.
public struct PRCreateReviewingWire: Encodable, Equatable, Sendable {
    public var status = "reviewing"
    public var review: ShipReviewWire
    public var message: String

    public init(review: ShipReviewWire, message: String) {
        self.review = review
        self.message = message
    }
}

/// Agent-facing JSON of the `pr_status` MCP tool. Optional fields encode as
/// explicit `null` so agents always see the same keys.
public struct PRStatusWire: Encodable, Equatable, Sendable {
    public init(pullRequest: PullRequest?, shepherd: Shepherd?, review: ShipReviewWire?) {
        self.pullRequest = pullRequest
        self.shepherd = shepherd
        self.review = review
    }

    public struct FailingCheck: Encodable, Equatable, Sendable {
        public init(name: String, workflow: String?, url: String?) {
            self.name = name
            self.workflow = workflow
            self.url = url
        }

        public var name: String
        public var workflow: String?
        public var url: String?

        public enum CodingKeys: String, CodingKey {
            case name, workflow, url
        }

        public func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(name, forKey: .name)
            try container.encode(workflow, forKey: .workflow)
            try container.encode(url, forKey: .url)
        }
    }

    public struct Checks: Encodable, Equatable, Sendable {
        public init(passed: Int, failed: Int, pending: Int, skipped: Int, failing: [FailingCheck]) {
            self.passed = passed
            self.failed = failed
            self.pending = pending
            self.skipped = skipped
            self.failing = failing
        }

        public var passed: Int
        public var failed: Int
        public var pending: Int
        public var skipped: Int
        public var failing: [FailingCheck]
    }

    public struct ThreadEntry: Encodable, Equatable, Sendable {
        public init(id: String, path: String?, line: Int?, author: String?, trust: String, body: String, url: String?) {
            self.id = id
            self.path = path
            self.line = line
            self.author = author
            self.trust = trust
            self.body = body
            self.url = url
        }

        public var id: String
        public var path: String?
        public var line: Int?
        public var author: String?
        public var trust: String
        public var body: String
        public var url: String?

        public enum CodingKeys: String, CodingKey {
            case id, path, line, author, trust, body, url
        }

        public func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(id, forKey: .id)
            try container.encode(path, forKey: .path)
            try container.encode(line, forKey: .line)
            try container.encode(author, forKey: .author)
            try container.encode(trust, forKey: .trust)
            try container.encode(body, forKey: .body)
            try container.encode(url, forKey: .url)
        }
    }

    public struct PullRequest: Encodable, Equatable, Sendable {
        public init(number: Int, url: String, state: String, draft: Bool, headSha: String?, mergeState: String, checks: Checks, threads: [ThreadEntry], missingRequiredReviewers: [String]) {
            self.number = number
            self.url = url
            self.state = state
            self.draft = draft
            self.headSha = headSha
            self.mergeState = mergeState
            self.checks = checks
            self.threads = threads
            self.missingRequiredReviewers = missingRequiredReviewers
        }

        public var number: Int
        public var url: String
        public var state: String
        public var draft: Bool
        public var headSha: String?
        public var mergeState: String
        public var checks: Checks
        public var threads: [ThreadEntry]
        public var missingRequiredReviewers: [String]

        public enum CodingKeys: String, CodingKey {
            case number, url, state, draft, headSha, mergeState, checks, threads, missingRequiredReviewers
        }

        public func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(number, forKey: .number)
            try container.encode(url, forKey: .url)
            try container.encode(state, forKey: .state)
            try container.encode(draft, forKey: .draft)
            try container.encode(headSha, forKey: .headSha)
            try container.encode(mergeState, forKey: .mergeState)
            try container.encode(checks, forKey: .checks)
            try container.encode(threads, forKey: .threads)
            try container.encode(missingRequiredReviewers, forKey: .missingRequiredReviewers)
        }
    }

    public struct Shepherd: Encodable, Equatable, Sendable {
        public init(
            phase: String, autoFix: Bool, autoMerge: Bool, fixAttempts: Int, maxFixAttempts: Int, rulesSource: String,
            reviewBeforePush: Bool
        ) {
            self.phase = phase
            self.autoFix = autoFix
            self.autoMerge = autoMerge
            self.fixAttempts = fixAttempts
            self.maxFixAttempts = maxFixAttempts
            self.rulesSource = rulesSource
            self.reviewBeforePush = reviewBeforePush
        }

        public var phase: String
        public var autoFix: Bool
        public var autoMerge: Bool
        public var fixAttempts: Int
        public var maxFixAttempts: Int
        public var rulesSource: String
        public var reviewBeforePush: Bool
    }

    public var pullRequest: PullRequest?
    public var shepherd: Shepherd?
    /// Nil when review before push is off for the session.
    public var review: ShipReviewWire?

    public enum CodingKeys: String, CodingKey {
        case pullRequest, shepherd, review
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(pullRequest, forKey: .pullRequest)
        try container.encode(shepherd, forKey: .shepherd)
        try container.encode(review, forKey: .review)
    }
}

extension PRStatusWire.PullRequest {
    /// `threads` lists actionable threads whose head comment comes from a
    /// trusted reviewer, the set the shepherd acts on. Each check is counted
    /// once: cancelled counts as failed, unknown as pending. A nil
    /// `headReviewers` (not fetched, or the fetch failed) lists every required
    /// reviewer as missing, matching the merge gate's fail-closed rule.
    public init(request: ReviewRequest, rules: ShepherdRules, headReviewers: Set<String>?) {
        let failing = request.checks.filter { $0.bucket == .fail || $0.bucket == .cancel }
        self.init(
            number: request.number,
            url: request.url.absoluteString,
            state: request.state.rawValue,
            draft: request.isDraft,
            headSha: request.headSHA,
            mergeState: request.mergeState.rawValue,
            checks: PRStatusWire.Checks(
                passed: request.checks.filter { $0.bucket == .pass }.count,
                failed: failing.count,
                pending: request.checks.filter { $0.bucket == .pending || $0.bucket == .unknown }.count,
                skipped: request.checks.filter { $0.bucket == .skipping }.count,
                failing: failing.map {
                    PRStatusWire.FailingCheck(name: $0.name, workflow: $0.workflow, url: $0.detailURL?.absoluteString)
                }
            ),
            threads: request.threads
                .filter { $0.isActionable && $0.headAuthorTrust == .trusted }
                .map {
                    PRStatusWire.ThreadEntry(
                        id: $0.id, path: $0.path, line: $0.line, author: $0.author,
                        trust: $0.headAuthorTrust.rawValue, body: $0.body, url: $0.url?.absoluteString
                    )
                },
            missingRequiredReviewers: rules.requiredReviewers.filter {
                !(headReviewers?.contains($0.lowercased()) ?? false)
            }
        )
    }
}

extension PRStatusWire.Shepherd {
    public init(record: ShepherdRecord, rules: ShepherdRules, reviewBeforePush: Bool) {
        self.init(
            phase: Self.wireName(record.phase),
            autoFix: record.autoFix,
            autoMerge: record.autoMerge,
            fixAttempts: record.fixAttempts,
            maxFixAttempts: record.fixAttemptBudget,
            rulesSource: Self.wireName(rules.source),
            reviewBeforePush: reviewBeforePush
        )
    }

    public static func wireName(_ phase: ShepherdPhase) -> String {
        switch phase {
        case .watching: "watching"
        case .fixing: "fixing"
        case .awaitingPush: "awaiting_push"
        case .merging: "merging"
        case .queued: "queued"
        case .escalated: "escalated"
        case .paused: "paused"
        case .merged: "merged"
        case .closed: "closed"
        }
    }

    public static func wireName(_ source: ShepherdRules.Source) -> String {
        switch source {
        case .localFile: "local_file"
        case .repoFile: "repo_file"
        case .projectSettings: "project_settings"
        case .none: "none"
        }
    }
}
