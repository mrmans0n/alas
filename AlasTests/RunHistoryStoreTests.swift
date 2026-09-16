import Foundation
import Testing
@testable import Alas

struct RunHistoryStoreTests {
    private let epoch = Date(timeIntervalSince1970: 1_700_000_000)

    private func entry(
        id: String = UUID().uuidString,
        worktreeID: String = "wt-1",
        completedAt: Date? = nil,
        output: RunHistoryOutput = .available(text: "output", truncated: false)
    ) -> RunHistoryEntry {
        RunHistoryEntry(
            id: id,
            scriptKey: "repo:dev.sh",
            scriptName: "Dev",
            worktreeID: worktreeID,
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
}
