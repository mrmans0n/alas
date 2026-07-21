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

private actor SuspendedInboxRunner: GGCommandRunning {
    private var started = false
    private var continuation: CheckedContinuation<ProcessResult, Never>?

    func run(args: [String], cwd: URL?) async throws -> ProcessResult {
        started = true
        return await withCheckedContinuation { continuation = $0 }
    }

    func hasStarted() -> Bool { started }

    func finish(with result: ProcessResult) {
        continuation?.resume(returning: result)
        continuation = nil
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
    private static let emptyJSON = #"{"version":1,"total_items":0,"buckets":{"ready_to_land":[],"changes_requested":[],"blocked_on_ci":[],"awaiting_review":[],"behind_base":[],"draft":[]},"stack_errors":[]}"#

    @Test func refreshStoresSnapshotAndTimestamp() async throws {
        let store = GGInboxStore()
        let runner = FakeGGRunner(result: ProcessResult(exitCode: 0, stdout: Self.emptyJSON, stderr: ""))
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
        let okRunner = FakeGGRunner(result: ProcessResult(exitCode: 0, stdout: Self.emptyJSON, stderr: ""))
        await store.refresh(projectId: "p1", repoPath: "/repo", service: GGService(runner: okRunner))
        let failRunner = FakeGGRunner(result: ProcessResult(exitCode: 1, stdout: "", stderr: "forge unreachable"))
        await store.refresh(projectId: "p1", repoPath: "/repo", service: GGService(runner: failRunner))
        let state = try #require(store.states["p1"])
        #expect(state.snapshot != nil) // stale snapshot retained
        #expect(state.lastError != nil)
        #expect(state.isRefreshing == false)
    }

    @Test func refreshDedupesWhileInFlight() async {
        let store = GGInboxStore()
        store.states["p1"] = .init(isRefreshing: true)
        let runner = FakeGGRunner(result: ProcessResult(exitCode: 0, stdout: Self.emptyJSON, stderr: ""))
        await store.refresh(projectId: "p1", repoPath: "/repo", service: GGService(runner: runner))
        // Guard returned before running: no snapshot was written.
        #expect(store.states["p1"]?.snapshot == nil)
    }

    @Test func staleness() {
        let now = Date(timeIntervalSince1970: 10_000)
        #expect(GGInboxStore.isStale(fetchedAt: nil, now: now))
        #expect(GGInboxStore.isStale(fetchedAt: now.addingTimeInterval(-120), now: now))
        #expect(!GGInboxStore.isStale(fetchedAt: now.addingTimeInterval(-119), now: now))
    }

    @Test func invalidateExpiresFreshnessWithoutDiscardingVisibleSnapshot() async throws {
        let store = GGInboxStore()
        let runner = FakeGGRunner(result: ProcessResult(exitCode: 0, stdout: Self.emptyJSON, stderr: ""))
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
        let runner = SuspendedInboxRunner()
        let refresh = Task { @MainActor in
            await store.refresh(
                projectId: "p1",
                repoPath: "/repo",
                service: GGService(runner: runner),
                now: { Date(timeIntervalSince1970: 2_000) }
            )
        }
        try await waitUntil { await runner.hasStarted() }

        store.invalidate(projectId: "p1")
        await runner.finish(with: ProcessResult(exitCode: 0, stdout: Self.emptyJSON, stderr: ""))
        await refresh.value

        let state = try #require(store.states["p1"])
        #expect(state.snapshot == nil)
        #expect(state.fetchedAt == nil)
        #expect(state.isRefreshing == false)
    }

    @Test func invalidateDuringRefreshRetainsPreviouslyVisibleSnapshot() async throws {
        let store = GGInboxStore()
        let oldRunner = FakeGGRunner(result: ProcessResult(exitCode: 0, stdout: Self.emptyJSON, stderr: ""))
        await store.refresh(
            projectId: "p1",
            repoPath: "/repo",
            service: GGService(runner: oldRunner),
            now: { Date(timeIntervalSince1970: 1_000) }
        )
        let previousSnapshot = try #require(store.states["p1"]?.snapshot)

        let runner = SuspendedInboxRunner()
        let refresh = Task { @MainActor in
            await store.refresh(
                projectId: "p1",
                repoPath: "/repo",
                service: GGService(runner: runner),
                now: { Date(timeIntervalSince1970: 2_000) }
            )
        }
        try await waitUntil { await runner.hasStarted() }

        store.invalidate(projectId: "p1")
        let replacementJSON = Self.emptyJSON.replacingOccurrences(of: #""total_items":0"#, with: #""total_items":9"#)
        await runner.finish(with: ProcessResult(exitCode: 0, stdout: replacementJSON, stderr: ""))
        await refresh.value

        let state = try #require(store.states["p1"])
        #expect(state.snapshot == previousSnapshot)
        #expect(state.fetchedAt == nil)
        #expect(state.isRefreshing == false)
    }

    @Test func pruneDropsRemovedProjectsAndIsValueDiffed() {
        let store = GGInboxStore()
        store.states = ["keep": .init(), "drop": .init()]
        store.prune(keepingProjectIds: ["keep"])
        #expect(Array(store.states.keys) == ["keep"])
        store.prune(keepingProjectIds: ["keep"]) // no-op prune
        #expect(Array(store.states.keys) == ["keep"])
    }
}
