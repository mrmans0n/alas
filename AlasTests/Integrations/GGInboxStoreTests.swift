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

    @Test func pruneDropsRemovedProjectsAndIsValueDiffed() {
        let store = GGInboxStore()
        store.states = ["keep": .init(), "drop": .init()]
        store.prune(keepingProjectIds: ["keep"])
        #expect(Array(store.states.keys) == ["keep"])
        store.prune(keepingProjectIds: ["keep"]) // no-op prune
        #expect(Array(store.states.keys) == ["keep"])
    }
}
