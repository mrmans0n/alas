import Testing
import Foundation
@testable import Alas

struct WorktreeUpstreamStatusTests {
    @Test func nonzeroSyncCountsDescribeBothDirections() {
        let status = WorktreeUpstreamStatus(
            ahead: 3,
            behind: 2,
            upstreamRef: "origin/main"
        )

        #expect(status.subtitleItems == [
            .init(text: "↑3", accessibilityLabel: "3 commits ahead of origin/main"),
            .init(text: "↓2", accessibilityLabel: "2 commits behind origin/main")
        ])
    }

    @Test func synchronizedWorktreeHasNoSyncSubtitleItems() {
        let status = WorktreeUpstreamStatus(
            ahead: 0,
            behind: 0,
            upstreamRef: "origin/main"
        )

        #expect(status.subtitleItems.isEmpty)
    }

    @Test func linkedWorktreeDoesNotUseMainWorktreeSyncSubtitle() {
        let status = WorktreeUpstreamStatus(ahead: 1, behind: 1, upstreamRef: "origin/feature")

        #expect(WorktreeRowView.upstreamStatusItems(status, isMain: false).isEmpty)
    }

    @Test func fetchPolicyHonorsAutoFetchSetting() {
        let now = Date(timeIntervalSinceReferenceDate: 1_000)

        #expect(WorktreeUpstreamStatusStore.shouldFetchUpstream(
            autoFetch: false,
            lastFetchAt: nil,
            now: now,
            minFetchInterval: 60
        ) == false)

        #expect(WorktreeUpstreamStatusStore.shouldFetchUpstream(
            autoFetch: true,
            lastFetchAt: nil,
            now: now,
            minFetchInterval: 60
        ))
    }

    @Test func fetchPolicyUsesConfiguredInterval() {
        let now = Date(timeIntervalSinceReferenceDate: 1_000)

        #expect(WorktreeUpstreamStatusStore.fetchInterval(fetchIntervalMinutes: 7) == 420)
        #expect(WorktreeUpstreamStatusStore.fetchInterval(fetchIntervalMinutes: 0) == 60)
        #expect(WorktreeUpstreamStatusStore.shouldFetchUpstream(
            autoFetch: true,
            lastFetchAt: now.addingTimeInterval(-59),
            now: now,
            minFetchInterval: 60
        ) == false)
        #expect(WorktreeUpstreamStatusStore.shouldFetchUpstream(
            autoFetch: true,
            lastFetchAt: now.addingTimeInterval(-60),
            now: now,
            minFetchInterval: 60
        ))
    }

    /// Two projects may expose the same worktree id; status stored under a
    /// bare worktree id would leak one project's ahead/behind into the other.
    @MainActor
    @Test func statusLookupIsScopedByProject() async throws {
        func makeRepo(name: String) async throws -> URL {
            let dir = FileManager.default.temporaryDirectory
                .appendingPathComponent("alas-upstream-\(name)-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            _ = try await Process.git(["init", "-q", "-b", "main"], cwd: dir)
            _ = try await Process.git(["commit", "-q", "--allow-empty", "-m", "init"], cwd: dir)
            return dir
        }
        let repo = try await makeRepo(name: "keyed")
        defer { try? FileManager.default.removeItem(at: repo) }
        _ = try await Process.git(["checkout", "-q", "-b", "feature"], cwd: repo)
        _ = try await Process.git(["commit", "-q", "--allow-empty", "-m", "ahead"], cwd: repo)
        // A real remote-tracking ref: `set-upstream-to` requires origin to
        // exist as a remote, not just a bare refs/remotes entry.
        _ = try await Process.git(["remote", "add", "origin", "."], cwd: repo)
        _ = try await Process.git(["fetch", "-q", "origin"], cwd: repo)
        _ = try await Process.git(["branch", "--set-upstream-to=origin/main", "feature"], cwd: repo)

        let store = WorktreeUpstreamStatusStore()
        let path = URL(fileURLWithPath: repo.path)
        await store.refresh(worktrees: [
            Worktree(
                id: "shared-worktree",
                projectId: "project-a",
                name: "shared",
                branch: "feature",
                path: path,
                status: .clean,
                lastActivity: .distantPast
            ),
            Worktree(
                id: "shared-worktree",
                projectId: "project-b",
                name: "shared",
                branch: "feature",
                path: path,
                status: .clean,
                lastActivity: .distantPast
            ),
        ])

        #expect(store.status(for: "shared-worktree", projectId: "project-a")?.ahead == 1)
        #expect(store.status(for: "shared-worktree", projectId: "project-b")?.ahead == 1)
        // A distinct project id never resolves another project's entry even
        // when the worktree id is identical.
        #expect(store.status(for: "shared-worktree", projectId: "project-c") == nil)
    }
}
