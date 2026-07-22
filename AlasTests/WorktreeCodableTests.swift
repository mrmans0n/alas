import Testing
import Foundation
@testable import Alas

@Suite struct WorktreeCodableTests {
    @Test func roundTripPreservesAllFields() throws {
        let original = Worktree(
            id: "/tmp/foo",
            projectId: "p1",
            name: "feature/x",
            branch: "feature/x",
            path: URL(fileURLWithPath: "/tmp/foo"),
            isMainWorktree: true,
            status: .dirty,
            lastActivity: Date(timeIntervalSince1970: 1_700_000_000),
            createdAt: Date(timeIntervalSince1970: 1_600_000_000),
            addedLines: 12,
            deletedLines: 3
        )

        let encoder = JSONEncoder()
        let data = try encoder.encode(original)

        let decoder = JSONDecoder()
        let decoded = try decoder.decode(Worktree.self, from: data)

        // Worktree.Equatable covers every stored property, so `decoded == original`
        // is sufficient. Main-worktree identity, createdAt, and the diff counters
        // are the fields this test specifically guards.
        #expect(decoded == original)
    }
}
