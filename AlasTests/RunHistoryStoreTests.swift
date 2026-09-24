import Foundation
import Testing
@testable import Alas

struct RunHistoryStoreTests {
    private let epoch = Date(timeIntervalSince1970: 1_700_000_000)

    private func entry(
        id: String = UUID().uuidString,
        worktreeID: String = "wt-1",
        projectID: String? = "project-a",
        completedAt: Date? = nil,
        output: RunHistoryOutput = .available(text: "output", truncated: false)
    ) -> RunHistoryEntry {
        RunHistoryEntry(
            id: id,
            scriptKey: "repo:dev.sh",
            scriptName: "Dev",
            worktreeID: worktreeID,
            projectId: projectID,
            branch: "main",
            target: .init(host: nil, workingDirectory: "/tmp/wt"),
            endpoint: URL(string: "http://localhost:3000"),
            outcome: .succeeded,
            startedAt: epoch,
            finishedAt: completedAt ?? epoch,
            portConflict: nil,
            output: output
        )
    }

    private func temporaryPath() -> String {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("run-history-\(UUID().uuidString).sqlite")
            .path
    }

    @Test func reopenedStoreRetainsCompletedEntryAndOutput() async throws {
        let path = temporaryPath()
        defer { try? FileManager.default.removeItem(atPath: path) }
        let stored = entry(output: .available(text: "done\n", truncated: true))

        let first = try RunHistoryStore(path: path)
        try await first.append(stored)

        let reopened = try RunHistoryStore(path: path)
        #expect(try await reopened.entry(id: stored.id) == stored)
    }

    @Test func outputRetainsEmbeddedNULBytes() async throws {
        let store = try RunHistoryStore(path: temporaryPath())
        let stored = entry(id: "nul-output", output: .available(text: "a\u{0}b", truncated: false))

        try await store.append(stored)

        #expect(try await store.entry(id: stored.id) == stored)
    }

    @Test func pageIsNewestFirstAndOmitsOutput() async throws {
        let store = try RunHistoryStore(path: temporaryPath())
        let oldest = entry(id: "oldest", completedAt: epoch)
        let newest = entry(id: "newest", completedAt: epoch.addingTimeInterval(2))
        let middle = entry(id: "middle", completedAt: epoch.addingTimeInterval(1))
        try await store.append(oldest)
        try await store.append(newest)
        try await store.append(middle)

        let page = try await store.page(worktreeID: "wt-1", offset: 1, limit: 1)

        #expect(page.totalCount == 3)
        #expect(page.entries.map(\.id) == ["middle"])
        #expect(page.entries.first?.scriptName == "Dev")
    }

    @Test func appendingDuplicateRunIDDoesNotDuplicateHistory() async throws {
        let store = try RunHistoryStore(path: temporaryPath())
        let first = entry(id: "run-1", output: .available(text: "first", truncated: false))
        let duplicate = entry(id: "run-1", output: .available(text: "second", truncated: false))
        try await store.append(first)
        try await store.append(duplicate)

        let page = try await store.page(worktreeID: "wt-1", offset: 0, limit: 20)

        #expect(page.totalCount == 1)
        #expect(try await store.entry(id: "run-1") == first)
    }

    @Test func appendPrunesOnlyOldestEntriesForThatWorktree() async throws {
        let store = try RunHistoryStore(path: temporaryPath(), maximumEntriesPerWorktree: 2)
        try await store.append(entry(id: "oldest", completedAt: epoch))
        try await store.append(entry(id: "middle", completedAt: epoch.addingTimeInterval(1)))
        try await store.append(entry(id: "newest", completedAt: epoch.addingTimeInterval(2)))
        let other = entry(id: "other", worktreeID: "wt-2", completedAt: epoch)
        try await store.append(other)

        let retained = try await store.page(worktreeID: "wt-1", offset: 0, limit: 20)

        #expect(retained.entries.map(\.id) == ["newest", "middle"])
        #expect(try await store.entry(id: "oldest") == nil)
        #expect(try await store.entry(id: other.id) == other)
    }

    @Test func clearAndPurgeAreScopedToOneWorktree() async throws {
        let store = try RunHistoryStore(path: temporaryPath())
        let first = entry(id: "first", worktreeID: "wt-1")
        let second = entry(id: "second", worktreeID: "wt-2")
        try await store.append(first)
        try await store.append(second)

        try await store.clear(worktreeID: "wt-1")

        #expect(try await store.page(worktreeID: "wt-1", offset: 0, limit: 20).totalCount == 0)
        #expect(try await store.entry(id: second.id) == second)
        try await store.purge(worktreeID: "wt-2")
        #expect(try await store.entry(id: second.id) == nil)
    }

    @Test func clearWithCutoffPreservesLaterCompletions() async throws {
        let store = try RunHistoryStore(path: temporaryPath())
        let old = entry(id: "old", completedAt: epoch)
        let later = entry(id: "later", completedAt: epoch.addingTimeInterval(1))
        try await store.append(old)
        try await store.append(later)

        try await store.clear(worktreeID: "wt-1", finishedOnOrBefore: epoch)

        #expect(try await store.entry(id: "old") == nil)
        #expect(try await store.entry(id: "later") == later)
    }

    @Test func samePathHistoryIsScopedForPagesAndClear() async throws {
        let store = try RunHistoryStore(path: temporaryPath())
        let projectA = entry(id: "project-a-run", projectID: "project-a")
        let projectB = entry(id: "project-b-run", projectID: "project-b")
        try await store.append(projectA)
        try await store.append(projectB)

        let aPage = try await store.page(worktreeID: "wt-1", projectID: "project-a", offset: 0, limit: 20)
        let bPage = try await store.page(worktreeID: "wt-1", projectID: "project-b", offset: 0, limit: 20)
        #expect(aPage.entries.map(\.id) == [projectA.id])
        #expect(bPage.entries.map(\.id) == [projectB.id])
        #expect(try await store.entry(id: projectA.id, worktreeID: "wt-1", projectID: "project-b") == nil)
        #expect(try await store.entry(id: projectB.id, worktreeID: "wt-1", projectID: "project-b") == projectB)

        try await store.clear(worktreeID: "wt-1", projectID: "project-a")

        #expect(try await store.page(worktreeID: "wt-1", projectID: "project-a", offset: 0, limit: 20).totalCount == 0)
        #expect(try await store.page(worktreeID: "wt-1", projectID: "project-b", offset: 0, limit: 20).entries.map(\.id) == [projectB.id])
    }

    @Test func retentionLimitIsIndependentForProjectsSharingAWorktreeID() async throws {
        let store = try RunHistoryStore(path: temporaryPath(), maximumEntriesPerWorktree: 1)
        try await store.append(entry(id: "a-old", projectID: "project-a", completedAt: epoch))
        try await store.append(entry(id: "a-new", projectID: "project-a", completedAt: epoch.addingTimeInterval(2)))
        try await store.append(entry(id: "b-old", projectID: "project-b", completedAt: epoch))
        try await store.append(entry(id: "b-new", projectID: "project-b", completedAt: epoch.addingTimeInterval(2)))

        let aPage = try await store.page(worktreeID: "wt-1", projectID: "project-a", offset: 0, limit: 20)
        let bPage = try await store.page(worktreeID: "wt-1", projectID: "project-b", offset: 0, limit: 20)
        #expect(aPage.entries.map(\.id) == ["a-new"])
        #expect(bPage.entries.map(\.id) == ["b-new"])
        #expect(try await store.entry(id: "a-old") == nil)
        #expect(try await store.entry(id: "b-old") == nil)
    }

    @Test func firstProjectScopedReadAdoptsLegacyRowsWithoutSharingThem() async throws {
        let store = try RunHistoryStore(path: temporaryPath())
        let legacy = entry(id: "legacy-run", projectID: nil)
        try await store.append(legacy)

        let firstRead = try await store.page(worktreeID: "wt-1", projectID: "project-a", offset: 0, limit: 20)
        let secondRead = try await store.page(worktreeID: "wt-1", projectID: "project-b", offset: 0, limit: 20)

        #expect(firstRead.entries.map(\.id) == [legacy.id])
        #expect(firstRead.entries.first?.projectId == "project-a")
        #expect(secondRead.entries.isEmpty)
        #expect(try await store.entry(id: legacy.id, worktreeID: "wt-1", projectID: "project-a")?.projectId == "project-a")
    }

    @Test func openingPreProjectSchemaMigratesAndAdoptsLegacyHistory() async throws {
        let path = temporaryPath()
        defer {
            try? FileManager.default.removeItem(atPath: path)
            try? FileManager.default.removeItem(atPath: "\(path)-wal")
            try? FileManager.default.removeItem(atPath: "\(path)-shm")
        }
        do {
            let database = try SQLiteDatabase(path: path)
            try database.exec("""
            CREATE TABLE run_history (
                run_id TEXT PRIMARY KEY,
                script_key TEXT NOT NULL,
                script_name TEXT NOT NULL,
                worktree_id TEXT NOT NULL,
                branch TEXT NOT NULL,
                target_host TEXT,
                target_working_directory TEXT NOT NULL,
                endpoint TEXT,
                outcome TEXT NOT NULL,
                exit_code INTEGER,
                started_at REAL NOT NULL,
                finished_at REAL NOT NULL,
                conflict_kind TEXT,
                conflict_worktree_id TEXT,
                conflict_branch TEXT,
                conflict_script_name TEXT,
                output_kind TEXT NOT NULL,
                output_text TEXT,
                output_truncated INTEGER NOT NULL DEFAULT 0
            )
            """)
            try database.exec("""
            INSERT INTO run_history (
                run_id, script_key, script_name, worktree_id, branch,
                target_host, target_working_directory, endpoint, outcome, exit_code,
                started_at, finished_at, conflict_kind, conflict_worktree_id,
                conflict_branch, conflict_script_name, output_kind, output_text, output_truncated
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """, bindings: [
                "legacy-schema-run", "repo:dev.sh", "Dev", "wt-1", "main",
                nil, "/tmp/wt", nil, "succeeded", nil,
                epoch.timeIntervalSince1970, epoch.timeIntervalSince1970,
                nil, nil, nil, nil, "available", "legacy output", 0,
            ])
        }

        do {
            let store = try RunHistoryStore(path: path)
            let adopted = try await store.page(worktreeID: "wt-1", projectID: "project-a", offset: 0, limit: 20)
            let otherProject = try await store.page(worktreeID: "wt-1", projectID: "project-b", offset: 0, limit: 20)

            #expect(adopted.entries.map(\.id) == ["legacy-schema-run"])
            #expect(adopted.entries.first?.projectId == "project-a")
            #expect(otherProject.entries.isEmpty)
        }
    }
}
