import Foundation
import Testing
@testable import Alas

private final class FakeGGRunner: GGCommandRunning, @unchecked Sendable {
    private let result: ProcessResult

    init(result: ProcessResult) {
        self.result = result
    }

    func run(args: [String], cwd: URL?) async throws -> ProcessResult {
        result
    }
}

private final class ControlledInboxRunner: GGCommandRunning, @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: AsyncThrowingStream<String, Error>.Continuation?
    private(set) var lastArgs: [String] = []

    func run(args: [String], cwd: URL?) async throws -> ProcessResult {
        ProcessResult(exitCode: 0, stdout: "", stderr: "")
    }

    func runStreaming(args: [String], cwd: URL?) -> AsyncThrowingStream<String, Error> {
        lock.lock()
        lastArgs = args
        lock.unlock()
        return AsyncThrowingStream { continuation in
            self.lock.lock()
            self.continuation = continuation
            self.lock.unlock()
        }
    }

    func yield(_ line: String) {
        lock.lock()
        let continuation = continuation
        lock.unlock()
        continuation?.yield(line)
    }

    func finish(throwing error: Error? = nil) {
        lock.lock()
        let continuation = continuation
        lock.unlock()
        if let error { continuation?.finish(throwing: error) } else { continuation?.finish() }
    }
}

private enum GGInboxTestTimeout: Error {
    case timedOut
}

@MainActor
private func waitUntil(
    timeout: TimeInterval = 2,
    _ condition: () async -> Bool
) async throws {
    let deadline = Date().addingTimeInterval(timeout)
    while !(await condition()) {
        guard Date() < deadline else { throw GGInboxTestTimeout.timedOut }
        try await Task.sleep(nanoseconds: 1_000_000)
    }
}

@MainActor
struct GGInboxStoreTests {
    private static let emptySummary = #"{"event":"summary","total_items":0,"buckets":{"refresh_failed":[],"ready_to_land":[],"changes_requested":[],"blocked_on_ci":[],"awaiting_review":[],"behind_base":[],"draft":[]},"stack_errors":[],"version":1,"command":"inbox"}"#
    private static let emptyJSONL = #"{"event":"start","total_candidates":0,"total_stack_errors":0,"version":1,"command":"inbox"}"# + "\n" + emptySummary

    @Test func refreshStoresSnapshotAndTimestamp() async throws {
        let store = GGInboxStore()
        let runner = FakeGGRunner(result: ProcessResult(exitCode: 0, stdout: Self.emptyJSONL, stderr: ""))
        let fixed = Date(timeIntervalSince1970: 1_000)
        await store.refresh(projectId: "p1", repoPath: "/repo", service: GGService(runner: runner), now: { fixed })
        let state = try #require(store.states["p1"])
        #expect(state.snapshot?.totalItems == 0)
        #expect(state.fetchedAt == fixed)
        #expect(state.lastError == nil)
        #expect(state.isRefreshing == false)
    }

    @Test func refreshFailureKeepsStaleSnapshotAndSetsError() async throws {
        let store = GGInboxStore()
        let okRunner = FakeGGRunner(result: ProcessResult(exitCode: 0, stdout: Self.emptyJSONL, stderr: ""))
        await store.refresh(projectId: "p1", repoPath: "/repo", service: GGService(runner: okRunner))
        let failRunner = FakeGGRunner(result: ProcessResult(exitCode: 1, stdout: "", stderr: "forge unreachable"))
        await store.refresh(projectId: "p1", repoPath: "/repo", service: GGService(runner: failRunner))
        let state = try #require(store.states["p1"])
        #expect(state.snapshot != nil) // stale snapshot retained
        #expect(state.lastError != nil)
        #expect(state.isRefreshing == false)
    }

    @Test func refreshDedupesWhileInFlight() async throws {
        let store = GGInboxStore()
        let runner = ControlledInboxRunner()
        let task = Task { @MainActor in
            await store.refresh(projectId: "p1", repoPath: "/repo", service: GGService(runner: runner))
        }
        try await waitUntil { runner.lastArgs == ["inbox", "--jsonl"] }

        await store.refresh(projectId: "p1", repoPath: "/repo", service: GGService(runner: runner))
        #expect(store.states["p1"]?.isRefreshing == true)
        #expect(store.states["p1"]?.snapshot == nil)

        runner.yield(#"{"event":"start","total_candidates":0,"total_stack_errors":0,"version":1,"command":"inbox"}"#)
        try await waitUntil { store.states["p1"]?.refreshProgress?.total == 0 }
        runner.yield(Self.emptySummary)
        runner.finish()
        await task.value
    }

    @Test func staleness() {
        let now = Date(timeIntervalSince1970: 10_000)
        #expect(GGInboxStore.isStale(fetchedAt: nil, now: now))
        #expect(GGInboxStore.isStale(fetchedAt: now.addingTimeInterval(-120), now: now))
        #expect(!GGInboxStore.isStale(fetchedAt: now.addingTimeInterval(-119), now: now))
    }

    @Test func invalidateExpiresFreshnessWithoutDiscardingVisibleSnapshot() async throws {
        let store = GGInboxStore()
        let runner = FakeGGRunner(result: ProcessResult(exitCode: 0, stdout: Self.emptyJSONL, stderr: ""))
        let fetchedAt = Date(timeIntervalSince1970: 1_000)
        await store.refresh(projectId: "p1", repoPath: "/repo", service: GGService(runner: runner), now: { fetchedAt })

        store.invalidate(projectId: "p1")

        let state = try #require(store.states["p1"])
        #expect(state.snapshot != nil)
        #expect(state.fetchedAt == nil)
        #expect(state.lastError == nil)
    }

    @Test func invalidateDuringRefreshPreventsOlderCompletionFromPublishing() async throws {
        let store = GGInboxStore()
        let runner = ControlledInboxRunner()
        let refresh = Task { @MainActor in
            await store.refresh(
                projectId: "p1",
                repoPath: "/repo",
                service: GGService(runner: runner),
                now: { Date(timeIntervalSince1970: 2_000) }
            )
        }
        try await waitUntil { runner.lastArgs == ["inbox", "--jsonl"] }

        store.invalidate(projectId: "p1")
        runner.yield(#"{"event":"start","total_candidates":0,"total_stack_errors":0,"version":1,"command":"inbox"}"#)
        runner.yield(Self.emptySummary)
        runner.finish()
        await refresh.value

        let state = try #require(store.states["p1"])
        #expect(state.snapshot == nil)
        #expect(state.fetchedAt == nil)
        #expect(state.isRefreshing == false)
    }

    @Test func invalidateDuringRefreshRetainsPreviouslyVisibleSnapshot() async throws {
        let store = GGInboxStore()
        let oldRunner = FakeGGRunner(result: ProcessResult(exitCode: 0, stdout: Self.emptyJSONL, stderr: ""))
        await store.refresh(
            projectId: "p1",
            repoPath: "/repo",
            service: GGService(runner: oldRunner),
            now: { Date(timeIntervalSince1970: 1_000) }
        )
        let previousSnapshot = try #require(store.states["p1"]?.snapshot)

        let runner = ControlledInboxRunner()
        let refresh = Task { @MainActor in
            await store.refresh(
                projectId: "p1",
                repoPath: "/repo",
                service: GGService(runner: runner),
                now: { Date(timeIntervalSince1970: 2_000) }
            )
        }
        try await waitUntil { runner.lastArgs == ["inbox", "--jsonl"] }

        store.invalidate(projectId: "p1")
        let replacementSummary = Self.emptySummary.replacingOccurrences(of: #""total_items":0"#, with: #""total_items":9"#)
        runner.yield(#"{"event":"start","total_candidates":0,"total_stack_errors":0,"version":1,"command":"inbox"}"#)
        runner.yield(replacementSummary)
        runner.finish()
        await refresh.value

        let state = try #require(store.states["p1"])
        #expect(state.snapshot == previousSnapshot)
        #expect(state.fetchedAt == nil)
        #expect(state.isRefreshing == false)
    }

    @Test func refreshKeepsOldSnapshotUntilFirstCompletionThenPublishesPartialState() async throws {
        let store = GGInboxStore()
        let old = GGInboxSnapshot(totalItems: 9, buckets: GGInboxBuckets(), stackErrors: [])
        store.states["p1"] = .init(snapshot: old, fetchedAt: Date(timeIntervalSince1970: 100))
        let runner = ControlledInboxRunner()
        let task = Task { @MainActor in
            await store.refresh(projectId: "p1", repoPath: "/repo", service: GGService(runner: runner), now: { Date(timeIntervalSince1970: 200) })
        }
        try await waitUntil { runner.lastArgs == ["inbox", "--jsonl"] }

        runner.yield(#"{"event":"start","total_candidates":2,"total_stack_errors":0,"version":1,"command":"inbox"}"#)
        try await waitUntil { store.states["p1"]?.refreshProgress?.total == 2 }
        #expect(store.states["p1"]?.snapshot == old)

        runner.yield(Self.readyEntryEvent(completed: 1, total: 2))
        try await waitUntil { store.states["p1"]?.refreshProgress?.completed == 1 }
        #expect(store.states["p1"]?.snapshot?.totalItems == 1)
        #expect(store.states["p1"]?.snapshot != old)

        runner.yield(Self.emptySummary)
        runner.finish()
        await task.value
        #expect(store.states["p1"]?.snapshot?.totalItems == 0)
        #expect(store.states["p1"]?.fetchedAt == Date(timeIntervalSince1970: 200))
        #expect(store.states["p1"]?.refreshProgress == nil)
    }

    @Test func entryErrorPublishesRefreshFailureWithoutPRURL() async throws {
        let store = GGInboxStore()
        let runner = ControlledInboxRunner()
        let task = Task { @MainActor in
            await store.refresh(projectId: "p1", repoPath: "/repo", service: GGService(runner: runner))
        }
        try await waitUntil { runner.lastArgs == ["inbox", "--jsonl"] }

        runner.yield(Self.start(total: 2))
        try await waitUntil { store.states["p1"]?.refreshProgress?.total == 2 }
        runner.yield(Self.entryErrorEvent(completed: 1, total: 2))
        try await waitUntil { store.states["p1"]?.refreshProgress?.completed == 1 }
        let entry = try #require(store.states["p1"]?.snapshot?.buckets.refreshFailed.first)
        #expect(entry.prUrl == nil)
        #expect(entry.refreshError == "provider unavailable")

        runner.yield(Self.emptySummary)
        runner.finish()
        await task.value
    }

    @Test func excludedEntryPublishesEmptyPartialStateAndAdvancesProgress() async throws {
        let store = GGInboxStore()
        let old = GGInboxSnapshot(totalItems: 9, buckets: GGInboxBuckets(), stackErrors: [])
        store.states["p1"] = .init(snapshot: old, fetchedAt: Date(timeIntervalSince1970: 100))
        let runner = ControlledInboxRunner()
        let task = Task { @MainActor in
            await store.refresh(projectId: "p1", repoPath: "/repo", service: GGService(runner: runner))
        }
        try await waitUntil { runner.lastArgs == ["inbox", "--jsonl"] }

        runner.yield(Self.start(total: 2))
        try await waitUntil { store.states["p1"]?.refreshProgress?.total == 2 }
        runner.yield(Self.excludedEntryEvent(completed: 1, total: 2))
        try await waitUntil { store.states["p1"]?.refreshProgress?.completed == 1 }
        #expect(store.states["p1"]?.snapshot?.totalItems == 0)
        #expect(store.states["p1"]?.snapshot != old)

        runner.yield(Self.emptySummary)
        runner.finish()
        await task.value
    }

    @Test func partialEntriesRemainInStableDisplayOrderWhenCompletionOrderDiffers() async throws {
        let store = GGInboxStore()
        let runner = ControlledInboxRunner()
        let task = Task { @MainActor in
            await store.refresh(projectId: "p1", repoPath: "/repo", service: GGService(runner: runner))
        }
        try await waitUntil { runner.lastArgs == ["inbox", "--jsonl"] }

        runner.yield(Self.start(total: 2))
        try await waitUntil { store.states["p1"]?.refreshProgress?.total == 2 }
        runner.yield(Self.readyEntryEvent(stackName: "perf", position: 2, completed: 1, total: 2))
        try await waitUntil { store.states["p1"]?.refreshProgress?.completed == 1 }
        runner.yield(Self.readyEntryEvent(stackName: "auth", position: 1, completed: 2, total: 2))
        try await waitUntil { store.states["p1"]?.refreshProgress?.completed == 2 }
        #expect(store.states["p1"]?.snapshot?.buckets.readyToLand.map(\.stackName) == ["auth", "perf"])

        runner.yield(Self.emptySummary)
        runner.finish()
        await task.value
    }

    @Test func stackErrorsPublishWithFirstPartialSnapshot() async throws {
        let store = GGInboxStore()
        let runner = ControlledInboxRunner()
        let task = Task { @MainActor in
            await store.refresh(projectId: "p1", repoPath: "/repo", service: GGService(runner: runner))
        }
        try await waitUntil { runner.lastArgs == ["inbox", "--jsonl"] }

        runner.yield(Self.start(total: 1))
        try await waitUntil { store.states["p1"]?.refreshProgress?.total == 1 }
        runner.yield(#"{"event":"stack_error","stack_name":"broken","error":"missing base","version":1,"command":"inbox"}"#)
        runner.yield(Self.readyEntryEvent(completed: 1, total: 1))
        try await waitUntil { store.states["p1"]?.refreshProgress?.completed == 1 }
        #expect(store.states["p1"]?.snapshot?.stackErrors == [GGInboxStackError(stackName: "broken", error: "missing base")])

        runner.yield(Self.emptySummary)
        runner.finish()
        await task.value
    }

    @Test func fatalEOFBeforeSummaryRestoresOldSnapshotAndFetchedAt() async throws {
        let store = GGInboxStore()
        let old = GGInboxSnapshot(totalItems: 9, buckets: GGInboxBuckets(), stackErrors: [])
        let oldFetchedAt = Date(timeIntervalSince1970: 100)
        store.states["p1"] = .init(snapshot: old, fetchedAt: oldFetchedAt)
        let runner = ControlledInboxRunner()
        let task = Task { @MainActor in
            await store.refresh(projectId: "p1", repoPath: "/repo", service: GGService(runner: runner))
        }
        try await waitUntil { runner.lastArgs == ["inbox", "--jsonl"] }

        runner.yield(Self.start(total: 1))
        try await waitUntil { store.states["p1"]?.refreshProgress?.total == 1 }
        runner.yield(Self.readyEntryEvent(completed: 1, total: 1))
        try await waitUntil { store.states["p1"]?.snapshot?.totalItems == 1 }
        runner.finish()
        await task.value

        let state = try #require(store.states["p1"])
        #expect(state.snapshot == old)
        #expect(state.fetchedAt == oldFetchedAt)
        #expect(state.refreshProgress == nil)
        #expect(state.lastError != nil)
    }

    @Test func invalidationAfterPartialPublicationRestoresOldSnapshotAndIgnoresSummary() async throws {
        let store = GGInboxStore()
        let old = GGInboxSnapshot(totalItems: 9, buckets: GGInboxBuckets(), stackErrors: [])
        store.states["p1"] = .init(snapshot: old, fetchedAt: Date(timeIntervalSince1970: 100))
        let runner = ControlledInboxRunner()
        let task = Task { @MainActor in
            await store.refresh(projectId: "p1", repoPath: "/repo", service: GGService(runner: runner), now: { Date(timeIntervalSince1970: 200) })
        }
        try await waitUntil { runner.lastArgs == ["inbox", "--jsonl"] }

        runner.yield(Self.start(total: 1))
        try await waitUntil { store.states["p1"]?.refreshProgress?.total == 1 }
        runner.yield(Self.readyEntryEvent(completed: 1, total: 1))
        try await waitUntil { store.states["p1"]?.snapshot?.totalItems == 1 }
        store.invalidate(projectId: "p1")
        runner.yield(Self.emptySummary)
        runner.finish()
        await task.value

        let state = try #require(store.states["p1"])
        #expect(state.snapshot == old)
        #expect(state.fetchedAt == nil)
        #expect(state.isRefreshing == false)
        #expect(state.refreshProgress == nil)
    }

    @Test func pruneDropsRemovedProjectsAndIsValueDiffed() {
        let store = GGInboxStore()
        store.states = ["keep": .init(), "drop": .init()]
        store.prune(keepingProjectIds: ["keep"])
        #expect(Array(store.states.keys) == ["keep"])
        store.prune(keepingProjectIds: ["keep"]) // no-op prune
        #expect(Array(store.states.keys) == ["keep"])
    }

    private static func start(total: Int) -> String {
        #"{"event":"start","total_candidates":\#(total),"total_stack_errors":0,"version":1,"command":"inbox"}"#
    }

    private static func readyEntryEvent(
        stackName: String = "auth",
        position: Int = 1,
        completed: Int,
        total: Int
    ) -> String {
        #"{"event":"entry","completed":\#(completed),"total_candidates":\#(total),"included":true,"bucket":"ready_to_land","remote_state":"open","entry":{"stack_name":"\#(stackName)","position":\#(position),"sha":"abc\#(position)","title":"Add \#(stackName)","pr_number":\#(40 + position),"pr_url":"https://example.test/\#(40 + position)","ci_status":"success","behind_base":null},"version":1,"command":"inbox"}"#
    }

    private static func excludedEntryEvent(completed: Int, total: Int) -> String {
        #"{"event":"entry","completed":\#(completed),"total_candidates":\#(total),"included":false,"bucket":null,"remote_state":"closed","entry":{"stack_name":"auth","position":1,"sha":"abc123","title":"Add login","pr_number":42,"pr_url":"https://example.test/42","ci_status":"success","behind_base":null},"version":1,"command":"inbox"}"#
    }

    private static func entryErrorEvent(completed: Int, total: Int) -> String {
        #"{"event":"entry_error","completed":\#(completed),"total_candidates":\#(total),"included":true,"bucket":"refresh_failed","entry":{"stack_name":"auth","position":1,"sha":"abc123","title":"Add login","pr_number":42,"pr_url":"https://example.test/42","ci_status":"success","behind_base":null},"error":"provider unavailable","version":1,"command":"inbox"}"#
    }
}
