import Foundation

/// One finished agent turn as Alas recorded it; also what plugins read (`usage/turns`, `turn.finished`).
struct UsageTurn: Codable, Equatable, Sendable {
    struct Tokens: Codable, Equatable, Sendable {
        let total: Int
        let input: Int
        let cachedInput: Int
        let cachedWrite: Int
        let output: Int
        let reasoningOutput: Int
    }

    struct Cost: Codable, Equatable, Sendable {
        let amount: Double
        let currency: String
    }

    let id: Int64
    let session: String
    /// Nil for sessions of a multi-project workspace checkout.
    let project: String?
    let worktree: String?
    let agent: String
    let model: String?
    /// Epoch milliseconds.
    let startedAt: Int64
    let endedAt: Int64
    /// `completed`, `failed`, `cancelled` or `limited`.
    let result: String
    /// Nil when the adapter reported no usage for the turn.
    let tokens: Tokens?
    /// What the turn added to the session's cost; nil when the adapter reports no cost.
    let cost: Cost?
}

/// Where the next page of a `usage/*` read starts: after the row at `before` with id `beforeId`, newest first.
struct UsageCursor: Codable, Equatable, Sendable {
    let before: Int64
    let beforeId: Int64
}

/// A provider usage limit that stopped a session, as first detected.
struct UsageLimitEpisode: Codable, Equatable, Sendable {
    let session: String
    let project: String?
    let worktree: String?
    let agent: String
    /// Epoch milliseconds.
    let detectedAt: Int64
    let resetsAt: Int64?
    /// `structured`, `parsed` or `unknown`.
    let resetSource: String
}

/// What a finished turn contributes, before it gets its row id and cost delta.
struct UsageTurnInput: Equatable, Sendable {
    let session: String
    var project: String?
    var worktree: String?
    let agent: String
    var model: String?
    let startedAt: Int64
    let endedAt: Int64
    let result: String
    var tokens: UsageTurn.Tokens?
    /// The session's cumulative cost as the adapter last reported it.
    var cumulativeCost: UsageTurn.Cost?
}

/// Token, cost and usage-limit history of every agent session, across projects. One database for the whole app
/// rather than the per-worktree session stores, so history outlives a removed worktree and is read in one query.
actor UsageHistoryStore {
    static let retention: TimeInterval = 400 * 86_400

    private let database: SQLiteDatabase

    init(path: String = Paths.usageHistoryDB.path, now: Date = Date()) throws {
        try FileManager.default.createDirectory(
            at: URL(fileURLWithPath: path).deletingLastPathComponent(), withIntermediateDirectories: true)
        database = try SQLiteDatabase(path: path)
        try Self.migrate(database)
        // ponytail: retention is a launch-time sweep by age; add a row cap if someone records millions of turns.
        let cutoff = Int64((now.timeIntervalSince1970 - Self.retention) * 1000)
        try database.exec("DELETE FROM turn_usage WHERE ended_at < ?", bindings: [cutoff])
        try database.exec("DELETE FROM usage_limits WHERE detected_at < ?", bindings: [cutoff])
    }

    /// Stores the turn, with its cost as the change in the session's cumulative cost since its previous recorded turn
    /// that had one. A turn that saw no fresh total records no cost and keeps that baseline, so the next turn that
    /// sees one is given all the growth since. Without a baseline (the session's first cost, or one pruned by the
    /// retention) the turn's cost is unknown: its total may include turns from before recording, and becomes the baseline.
    func record(_ input: UsageTurnInput) throws -> UsageTurn {
        try database.transaction {
            let previous = try database.query("""
            SELECT cost_total, currency FROM turn_usage
            WHERE session_id = ? AND cost_total IS NOT NULL
            ORDER BY id DESC LIMIT 1
            """, bindings: [input.session]).first
            var cost: UsageTurn.Cost?
            // A change of currency leaves the turn's cost unknown.
            if let current = input.cumulativeCost, let previous, previous["currency"] as? String == current.currency,
               let previousTotal = previous["cost_total"] as? Double {
                // ponytail: a lower total means the adapter restarted its count, so all of it is new; a restart
                // that already passed the old total is indistinguishable and undercounts once.
                let amount = current.amount >= previousTotal ? current.amount - previousTotal : current.amount
                cost = UsageTurn.Cost(amount: amount, currency: current.currency)
            }
            let tokens = input.tokens
            let rows = try database.query("""
            INSERT INTO turn_usage (
                session_id, project_id, worktree_id, agent_id, model, started_at, ended_at, result,
                total_tokens, input_tokens, cached_input_tokens, cached_write_tokens, output_tokens,
                reasoning_output_tokens, cost_total, cost_delta, currency
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            RETURNING id
            """, bindings: [
                input.session, input.project, input.worktree, input.agent, input.model,
                input.startedAt, input.endedAt, input.result,
                tokens?.total, tokens?.input, tokens?.cachedInput, tokens?.cachedWrite, tokens?.output,
                tokens?.reasoningOutput, input.cumulativeCost?.amount, cost?.amount, input.cumulativeCost?.currency,
            ])
            return UsageTurn(
                id: rows.first?["id"] as? Int64 ?? 0, session: input.session, project: input.project,
                worktree: input.worktree, agent: input.agent, model: input.model, startedAt: input.startedAt,
                endedAt: input.endedAt, result: input.result, tokens: tokens, cost: cost)
        }
    }

    /// One row per episode: a repeated hit of the same episode only updates its reset.
    func record(_ episode: UsageLimitEpisode) throws {
        try database.exec("""
        INSERT INTO usage_limits (session_id, project_id, worktree_id, agent_id, detected_at, resets_at, reset_source)
        VALUES (?, ?, ?, ?, ?, ?, ?)
        ON CONFLICT(session_id, detected_at) DO UPDATE SET
            resets_at = excluded.resets_at, reset_source = excluded.reset_source
        """, bindings: [
            episode.session, episode.project, episode.worktree, episode.agent,
            episode.detectedAt, episode.resetsAt, episode.resetSource,
        ])
    }

    /// Turns that ended in `[since, until)`, newest first, at most `limit`; `project` nil reads every project.
    /// Past `limit`, `next` resumes after the last turn returned, so turns ending in the same millisecond are neither
    /// skipped nor repeated.
    func turns(
        project: String?, since: Int64, until: Int64?, after cursor: UsageCursor? = nil, limit: Int
    ) throws -> (turns: [UsageTurn], next: UsageCursor?) {
        let (filter, bindings) = Self.filter("ended_at", "id", project: project, since: since, until: until, cursor: cursor)
        let rows = try database.query(
            "SELECT * FROM turn_usage WHERE \(filter) ORDER BY ended_at DESC, id DESC LIMIT ?",
            bindings: bindings + [limit + 1])
        let turns = rows.prefix(limit).map { row in
            let tokens = (row["total_tokens"] as? Int64).map { total in
                UsageTurn.Tokens(
                    total: Int(total), input: Self.int(row["input_tokens"]), cachedInput: Self.int(row["cached_input_tokens"]),
                    cachedWrite: Self.int(row["cached_write_tokens"]), output: Self.int(row["output_tokens"]),
                    reasoningOutput: Self.int(row["reasoning_output_tokens"]))
            }
            let cost = (row["cost_delta"] as? Double).flatMap { amount in
                (row["currency"] as? String).map { UsageTurn.Cost(amount: amount, currency: $0) }
            }
            return UsageTurn(
                id: row["id"] as? Int64 ?? 0, session: row["session_id"] as? String ?? "",
                project: row["project_id"] as? String, worktree: row["worktree_id"] as? String,
                agent: row["agent_id"] as? String ?? "", model: row["model"] as? String,
                startedAt: row["started_at"] as? Int64 ?? 0, endedAt: row["ended_at"] as? Int64 ?? 0,
                result: row["result"] as? String ?? "", tokens: tokens, cost: cost)
        }
        return (Array(turns), rows.count > limit ? turns.last.map { UsageCursor(before: $0.endedAt, beforeId: $0.id) } : nil)
    }

    /// Episodes detected in `[since, until)`, newest first, at most `limit`; `project` nil reads every project.
    func limits(
        project: String?, since: Int64, until: Int64?, after cursor: UsageCursor? = nil, limit: Int
    ) throws -> (limits: [UsageLimitEpisode], next: UsageCursor?) {
        let (filter, bindings) = Self.filter("detected_at", "rowid", project: project, since: since, until: until, cursor: cursor)
        let rows = try database.query(
            "SELECT rowid AS row_id, * FROM usage_limits WHERE \(filter) ORDER BY detected_at DESC, rowid DESC LIMIT ?",
            bindings: bindings + [limit + 1])
        let limits = rows.prefix(limit).map { row in
            UsageLimitEpisode(
                session: row["session_id"] as? String ?? "", project: row["project_id"] as? String,
                worktree: row["worktree_id"] as? String, agent: row["agent_id"] as? String ?? "",
                detectedAt: row["detected_at"] as? Int64 ?? 0, resetsAt: row["resets_at"] as? Int64,
                resetSource: row["reset_source"] as? String ?? "unknown")
        }
        let next = rows.count > limit ? rows[limit - 1] : nil
        return (Array(limits), next.map {
            UsageCursor(before: $0["detected_at"] as? Int64 ?? 0, beforeId: $0["row_id"] as? Int64 ?? 0)
        })
    }

    private static func filter(
        _ column: String, _ idColumn: String, project: String?, since: Int64, until: Int64?, cursor: UsageCursor?
    ) -> (String, [Any?]) {
        var clauses = ["\(column) >= ?"]
        var bindings: [Any?] = [since]
        if let until {
            clauses.append("\(column) < ?")
            bindings.append(until)
        }
        if let cursor {
            clauses.append("(\(column) < ? OR (\(column) = ? AND \(idColumn) < ?))")
            bindings += [cursor.before, cursor.before, cursor.beforeId]
        }
        if let project {
            clauses.append("project_id = ?")
            bindings.append(project)
        }
        return (clauses.joined(separator: " AND "), bindings)
    }

    private static func int(_ value: Any??) -> Int { Int((value ?? nil) as? Int64 ?? 0) }

    /// New tables only so far, so creating what is missing is the whole migration.
    private static func migrate(_ database: SQLiteDatabase) throws {
        try database.exec("""
        CREATE TABLE IF NOT EXISTS turn_usage (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            session_id TEXT NOT NULL,
            project_id TEXT,
            worktree_id TEXT,
            agent_id TEXT NOT NULL,
            model TEXT,
            started_at INTEGER NOT NULL,
            ended_at INTEGER NOT NULL,
            result TEXT NOT NULL,
            total_tokens INTEGER,
            input_tokens INTEGER,
            cached_input_tokens INTEGER,
            cached_write_tokens INTEGER,
            output_tokens INTEGER,
            reasoning_output_tokens INTEGER,
            cost_total REAL,
            cost_delta REAL,
            currency TEXT
        )
        """)
        try database.exec("CREATE INDEX IF NOT EXISTS turn_usage_ended_idx ON turn_usage(ended_at)")
        try database.exec("CREATE INDEX IF NOT EXISTS turn_usage_session_idx ON turn_usage(session_id, id)")
        try database.exec("""
        CREATE TABLE IF NOT EXISTS usage_limits (
            session_id TEXT NOT NULL,
            project_id TEXT,
            worktree_id TEXT,
            agent_id TEXT NOT NULL,
            detected_at INTEGER NOT NULL,
            resets_at INTEGER,
            reset_source TEXT NOT NULL,
            PRIMARY KEY (session_id, detected_at)
        )
        """)
        try database.exec("CREATE INDEX IF NOT EXISTS usage_limits_detected_idx ON usage_limits(detected_at)")
    }
}

extension UsageTurnInput {
    init(
        completion: ACPTurnCompletion, agent: String, model: String?, cumulativeCost: ACPUsageInfo.Cost?, project: String?,
        worktree: String?, endedAt: Int64
    ) {
        let result = switch completion.result {
        case .completed: "completed"
        case .failed: "failed"
        case .cancelled: "cancelled"
        case .limited: "limited"
        }
        let models = completion.quota?.modelUsage ?? []
        // Some adapters send only per-model counts; their sum is the turn's.
        let counts = completion.quota.flatMap { quota in
            quota.tokenCount ?? quota.modelUsage.map(\.tokenCount).reduce(ACPTokenCount?.none) { sum, next in
                sum.map { $0 + next } ?? next
            }
        }
        self.init(
            session: completion.sessionId, project: project, worktree: worktree, agent: agent,
            // The quota names the model that answered when there was exactly one.
            model: models.count == 1 ? models[0].model : model,
            startedAt: completion.startedAt, endedAt: max(endedAt, completion.startedAt), result: result,
            tokens: counts.map {
                UsageTurn.Tokens(
                    total: $0.displayTotal, input: $0.inputTokens, cachedInput: $0.cachedInputTokens,
                    cachedWrite: $0.cachedWriteTokens, output: $0.outputTokens, reasoningOutput: $0.reasoningOutputTokens)
            },
            cumulativeCost: cumulativeCost.map { UsageTurn.Cost(amount: $0.amount, currency: $0.currency) })
    }
}

extension UsageLimitEpisode {
    init(_ limit: ACPUsageLimit, session: String, project: String?, worktree: String?, agent: String) {
        self.init(
            session: session, project: project, worktree: worktree, agent: agent,
            detectedAt: Int64(limit.detectedAt.timeIntervalSince1970 * 1000),
            resetsAt: limit.resetsAt.map { Int64($0.timeIntervalSince1970 * 1000) }, resetSource: limit.resetSource.rawValue)
    }
}

/// Runs work for the same key one after another, in the order it was enqueued; different keys run concurrently.
@MainActor
final class KeyedSerialQueue {
    private var tails: [String: (id: UUID, task: Task<Void, Never>)] = [:]

    func enqueue(_ key: String, _ work: @escaping @MainActor () async -> Void) {
        let previous = tails[key]?.task
        let id = UUID()
        let task = Task { @MainActor [weak self] in
            await previous?.value
            await work()
            if self?.tails[key]?.id == id { self?.tails[key] = nil }
        }
        tails[key] = (id, task)
    }
}

extension AppState {
    /// Records a finished turn of a session of `owner`, and the usage limit that stopped it, then tells plugins.
    func recordTurnUsage(_ completion: ACPTurnCompletion, owner: SessionOwnerID) {
        guard let store = usageHistory, let session = acpManager(for: owner)?.liveSession(for: completion.sessionId) else { return }
        let worktree = owner.worktreeID
        let project = worktree.flatMap { self.worktree(withId: $0)?.projectId }
        let agent = session.agentId
        let model = session.currentModel
        let endedAt = Int64(Date().timeIntervalSince1970 * 1000)
        let episode = completion.result == .limited ? session.usageLimit.map {
            UsageLimitEpisode($0, session: completion.sessionId, project: project, worktree: worktree, agent: session.agentId)
        } : nil
        // Everything but the cost is captured now, so the row is written even if the session goes away meanwhile. In
        // completion order per session, since each turn's cost is measured from the previous row's.
        usageRecording.enqueue(completion.sessionId) { [weak self] in
            let input = UsageTurnInput(
                completion: completion, agent: agent, model: model, cumulativeCost: await completion.cost?.resolve(),
                project: project, worktree: worktree, endedAt: endedAt)
            if let episode { try? await store.record(episode) }
            guard let turn = try? await store.record(input) else { return }
            await self?.pluginManager?.turnFinished(turn)
        }
    }
}
