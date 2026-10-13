import Foundation

/// Agent-facing JSON of the `pr_create` MCP tool. Snake_cased on the wire by
/// `ReviewCommentWireDTO.jsonLine`'s key strategy.
struct PRCreateResultWire: Encodable, Equatable, Sendable {
    struct Shepherd: Encodable, Equatable, Sendable {
        var autoFix: Bool
        var autoMerge: Bool
    }

    var number: Int
    var url: String
    var provider: String
    var headSha: String
    var created: Bool
    var uncommittedChanges: Bool
    var shepherd: Shepherd
}

extension PRCreateResultWire {
    init(request: ReviewRequest, headSHA: String, created: Bool, uncommittedChanges: Bool, record: ShepherdRecord) {
        self.init(
            number: request.number,
            url: request.url.absoluteString,
            provider: request.provider.rawValue,
            headSha: headSHA,
            created: created,
            uncommittedChanges: uncommittedChanges,
            shepherd: Shepherd(autoFix: record.autoFix, autoMerge: record.autoMerge)
        )
    }
}

/// Agent-facing JSON of the `pr_status` MCP tool. Optional fields encode as
/// explicit `null` so agents always see the same keys.
struct PRStatusWire: Encodable, Equatable, Sendable {
    struct FailingCheck: Encodable, Equatable, Sendable {
        var name: String
        var workflow: String?
        var url: String?

        enum CodingKeys: String, CodingKey {
            case name, workflow, url
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(name, forKey: .name)
            try container.encode(workflow, forKey: .workflow)
            try container.encode(url, forKey: .url)
        }
    }

    struct Checks: Encodable, Equatable, Sendable {
        var passed: Int
        var failed: Int
        var pending: Int
        var skipped: Int
        var failing: [FailingCheck]
    }

    struct ThreadEntry: Encodable, Equatable, Sendable {
        var id: String
        var path: String?
        var line: Int?
        var author: String?
        var trust: String
        var body: String
        var url: String?

        enum CodingKeys: String, CodingKey {
            case id, path, line, author, trust, body, url
        }

        func encode(to encoder: Encoder) throws {
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

    struct PullRequest: Encodable, Equatable, Sendable {
        var number: Int
        var url: String
        var state: String
        var draft: Bool
        var headSha: String?
        var mergeState: String
        var checks: Checks
        var threads: [ThreadEntry]
        var missingRequiredReviewers: [String]

        enum CodingKeys: String, CodingKey {
            case number, url, state, draft, headSha, mergeState, checks, threads, missingRequiredReviewers
        }

        func encode(to encoder: Encoder) throws {
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

    struct Shepherd: Encodable, Equatable, Sendable {
        var phase: String
        var autoFix: Bool
        var autoMerge: Bool
        var fixAttempts: Int
        var rulesSource: String
    }

    var pullRequest: PullRequest?
    var shepherd: Shepherd?

    enum CodingKeys: String, CodingKey {
        case pullRequest, shepherd
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(pullRequest, forKey: .pullRequest)
        try container.encode(shepherd, forKey: .shepherd)
    }
}

extension PRStatusWire.PullRequest {
    /// `threads` lists actionable threads whose head comment comes from a
    /// trusted reviewer, the set the shepherd acts on. Each check is counted
    /// once: cancelled counts as failed, unknown as pending. A nil
    /// `headReviewers` (not fetched, or the fetch failed) lists every required
    /// reviewer as missing, matching the merge gate's fail-closed rule.
    init(request: ReviewRequest, rules: ShepherdRules, headReviewers: Set<String>?) {
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
    init(record: ShepherdRecord, rules: ShepherdRules) {
        self.init(
            phase: Self.wireName(record.phase),
            autoFix: record.autoFix,
            autoMerge: record.autoMerge,
            fixAttempts: record.fixAttempts,
            rulesSource: Self.wireName(rules.source)
        )
    }

    static func wireName(_ phase: ShepherdPhase) -> String {
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

    static func wireName(_ source: ShepherdRules.Source) -> String {
        switch source {
        case .localFile: "local_file"
        case .repoFile: "repo_file"
        case .projectSettings: "project_settings"
        case .none: "none"
        }
    }
}
