import Foundation
import Testing
@testable import Alas

struct UsageHistoryStoreTests {
    private func temporaryPath() -> String {
        FileManager.default.temporaryDirectory.appendingPathComponent("usage-history-\(UUID().uuidString).sqlite").path
    }

    private func turn(
        session: String = "s1", project: String? = "proj", startedAt: Int64 = 1_000, endedAt: Int64 = 2_000,
        cost: (Double, String)? = nil
    ) -> UsageTurnInput {
        UsageTurnInput(
            session: session, project: project, worktree: "wt", agent: "claude", startedAt: startedAt, endedAt: endedAt,
            result: "completed", cumulativeCost: cost.map { UsageTurn.Cost(amount: $0.0, currency: $0.1) })
    }

    /// A finished turn keeps the counts of its own quota, the answering model and an end no earlier than its start,
    /// and is still there after the store is reopened.
    @Test func aFinishedTurnIsRecordedAndSurvivesAReopen() async throws {
        let path = temporaryPath()
        defer { try? FileManager.default.removeItem(atPath: path) }
        let tokens = ACPTokenCount(
            totalTokens: 0, inputTokens: 10, cachedInputTokens: 20, cachedWriteTokens: 3, outputTokens: 4, reasoningOutputTokens: 5)
        // Recent, so reopening keeps it within the retention.
        let started = Int64(Date().timeIntervalSince1970 * 1000)
        let completion = ACPTurnCompletion(
            sessionId: "s1", startedAt: started, result: .limited, delegatedSource: nil, lastAgentText: nil,
            quota: ACPPromptQuota(tokenCount: tokens, modelUsage: [ACPModelUsage(model: "opus", tokenCount: tokens)]))
        let input = UsageTurnInput(
            completion: completion, agent: "claude", model: "default",
            project: "proj", worktree: "wt", endedAt: started - 1_000)
        _ = try await UsageHistoryStore(path: path).record(input)

        let turns = try await UsageHistoryStore(path: path).turns(project: "proj", since: 0, until: nil, limit: 10).turns
        #expect(turns.count == 1)
        #expect(turns.first?.tokens == UsageTurn.Tokens(
            total: 42, input: 10, cachedInput: 20, cachedWrite: 3, output: 4, reasoningOutput: 5))
        #expect(turns.first?.model == "opus")
        #expect(turns.first?.result == "limited")
        #expect(turns.first?.startedAt == started)
        #expect(turns.first?.endedAt == started)
        #expect(turns.first?.cost == nil)
    }

    /// Each turn's cost is what the session's cumulative cost grew by since its previous recorded turn; a lower
    /// total is a restarted count, and the first total, a change of currency or no cost at all leave it unknown.
    @Test func aTurnsCostIsTheGrowthOfTheSessionsCumulativeCost() async throws {
        let path = temporaryPath()
        defer { try? FileManager.default.removeItem(atPath: path) }
        let store = try UsageHistoryStore(path: path)
        // A turn without a fresh total (nil) keeps the baseline, so the next one is given all the growth since.
        let cumulative: [(Double, String)?] = [(0.10, "USD"), nil, (0.25, "USD"), (0.05, "USD"), (0.07, "EUR")]
        for cost in cumulative {
            _ = try await store.record(turn(cost: cost))
        }
        // The other session's cost does not count towards this one's.
        _ = try await store.record(turn(session: "s2", cost: (1, "USD")))
        let read = try await store.turns(project: nil, since: 0, until: nil, limit: 10).turns.filter { $0.session == "s1" }
        // Newest first, in cents.
        #expect(read.map { $0.cost.map { ($0.amount * 100).rounded() } } == [nil, 5, 15, nil, nil])
    }

    @Test(arguments: [
        ("proj" as String?, Int64(0), Int64?.none, 2, [Int64(3_000), 2_000], true),
        (nil, 1_500, 3_000, 10, [2_500, 2_000], false),
        ("proj", 3_001, nil, 10, [], false),
    ])
    func turnsAreNewestFirstWithinTheirWindowAndProject(
        project: String?, since: Int64, until: Int64?, limit: Int, ends: [Int64], truncated: Bool
    ) async throws {
        let path = temporaryPath()
        defer { try? FileManager.default.removeItem(atPath: path) }
        let store = try UsageHistoryStore(path: path)
        for (end, owner) in [(Int64(1_000), "proj"), (2_000, "proj"), (2_500, "other"), (3_000, "proj")] {
            _ = try await store.record(turn(project: owner, startedAt: end - 500, endedAt: end))
        }
        let page = try await store.turns(project: project, since: since, until: until, limit: limit)
        #expect(page.turns.map(\.endedAt) == ends)
        #expect((page.next != nil) == truncated)
    }

    /// A page that ends inside a run of equal times resumes after its last row, skipping and repeating none.
    @Test func pagesResumeInsideARunOfEqualTimes() async throws {
        let path = temporaryPath()
        defer { try? FileManager.default.removeItem(atPath: path) }
        let store = try UsageHistoryStore(path: path)
        for session in ["a", "b", "c"] {
            _ = try await store.record(turn(session: session, endedAt: 2_000))
            try await store.record(UsageLimitEpisode(
                session: session, project: "proj", worktree: nil, agent: "claude", detectedAt: 2_000, resetsAt: nil,
                resetSource: "unknown"))
        }
        let first = try await store.turns(project: nil, since: 0, until: nil, limit: 2)
        let second = try await store.turns(project: nil, since: 0, until: nil, after: first.next, limit: 2)
        #expect((first.turns + second.turns).map(\.session) == ["c", "b", "a"])
        #expect(second.next == nil)
        let firstLimits = try await store.limits(project: nil, since: 0, until: nil, limit: 2)
        let secondLimits = try await store.limits(project: nil, since: 0, until: nil, after: firstLimits.next, limit: 2)
        #expect((firstLimits.limits + secondLimits.limits).map(\.session) == ["c", "b", "a"])
        #expect(secondLimits.next == nil)
    }

    /// Without a top-level count, a turn's tokens are the sum of its models'.
    @Test func tokensWithoutATopLevelCountAreTheSumOfTheModels() {
        let count = ACPTokenCount(
            totalTokens: 10, inputTokens: 1, cachedInputTokens: 2, cachedWriteTokens: 3, outputTokens: 4, reasoningOutputTokens: 0)
        let completion = ACPTurnCompletion(
            sessionId: "s1", startedAt: 1, result: .completed, delegatedSource: nil, lastAgentText: nil,
            quota: ACPPromptQuota(tokenCount: nil, modelUsage: [
                ACPModelUsage(model: "a", tokenCount: count), ACPModelUsage(model: "b", tokenCount: count),
            ]))
        let input = UsageTurnInput(completion: completion, agent: "claude", model: "default", project: nil, worktree: nil, endedAt: 2)
        #expect(input.tokens == UsageTurn.Tokens(total: 20, input: 2, cachedInput: 4, cachedWrite: 6, output: 8, reasoningOutput: 0))
        #expect(input.model == "default")
    }

    /// A repeated hit of the same episode updates its reset rather than adding a row.
    @Test func aUsageLimitEpisodeIsRecordedOnce() async throws {
        let path = temporaryPath()
        defer { try? FileManager.default.removeItem(atPath: path) }
        let store = try UsageHistoryStore(path: path)
        let detected = Date(timeIntervalSince1970: 1_000)
        for resetsAt in [2_000.0, 3_000] {
            let limit = ACPUsageLimit(
                detectedAt: detected, resetsAt: Date(timeIntervalSince1970: resetsAt), resetSource: .structured,
                probeAttempt: 0, resettable: true)
            try await store.record(UsageLimitEpisode(limit, session: "s1", project: "proj", worktree: "wt", agent: "claude"))
        }
        let page = try await store.limits(project: "proj", since: 0, until: nil, limit: 10)
        #expect(page.limits == [UsageLimitEpisode(
            session: "s1", project: "proj", worktree: "wt", agent: "claude", detectedAt: 1_000_000, resetsAt: 3_000_000,
            resetSource: "structured")])
    }

    @Test func rowsPastTheRetentionAreDroppedOnOpen() async throws {
        let path = temporaryPath()
        defer { try? FileManager.default.removeItem(atPath: path) }
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let day: Int64 = 86_400_000
        let nowMS = Int64(now.timeIntervalSince1970 * 1000)
        let store = try UsageHistoryStore(path: path, now: now)
        _ = try await store.record(turn(startedAt: nowMS - 401 * day, endedAt: nowMS - 401 * day))
        _ = try await store.record(turn(startedAt: nowMS - 399 * day, endedAt: nowMS - 399 * day))
        let reopened = try UsageHistoryStore(path: path, now: now)
        #expect(try await reopened.turns(project: nil, since: 0, until: nil, limit: 10).turns.map(\.endedAt) == [nowMS - 399 * day])
    }
}
