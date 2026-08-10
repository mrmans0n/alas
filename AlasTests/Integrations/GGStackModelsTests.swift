import Foundation
import Testing
@testable import Alas

struct GGStackModelsTests {
    static let fixture = """
    {
      "version": 1,
      "stack": {
        "name": "agent-inbox",
        "base": "main",
        "total_commits": 3,
        "synced_commits": 2,
        "current_position": 3,
        "behind_base": null,
        "entries": [
          {"position": 1, "sha": "aaaaaaa", "title": "chore: config plumbing",
           "gg_id": "id-1", "gg_parent": null, "pr_number": 837, "pr_state": "merged",
           "approved": true, "ci_status": "success", "is_current": false,
           "in_merge_train": false, "merge_train_position": null},
          {"position": 2, "sha": "bbbbbbb", "title": "feat: stack section UI",
           "gg_id": "id-2", "gg_parent": "id-1", "pr_number": 840, "pr_state": "open",
           "approved": true, "ci_status": "running", "is_current": false,
           "in_merge_train": false, "merge_train_position": null},
          {"position": 3, "sha": "ccccccc", "title": "feat: sidebar badge",
           "gg_id": "id-3", "gg_parent": "id-2", "pr_number": null, "pr_state": null,
           "approved": false, "ci_status": null, "is_current": true,
           "in_merge_train": false, "merge_train_position": null}
        ]
      }
    }
    """

    @Test func decodesSingleStackResponse() throws {
        let snapshot = try GGStackSnapshot.decode(fromJSON: Data(Self.fixture.utf8))
        let stack = try #require(snapshot.stack)
        #expect(stack.name == "agent-inbox")
        #expect(stack.base == "main")
        #expect(stack.totalCommits == 3)
        #expect(stack.syncedCommits == 2)
        #expect(stack.currentPosition == 3)
        #expect(stack.entries.count == 3)
        let first = stack.entries[0]
        #expect(first.prNumber == 837)
        #expect(first.prState == .merged)
        #expect(first.ciStatus == .success)
        #expect(first.approved)
        #expect(first.id == "id-1")
        #expect(stack.entries[2].prState == nil)
        #expect(stack.entries[2].isCurrent)
    }

    @Test func nonStackResponseDecodesWithNilStack() throws {
        let json = #"{"version": 1, "current_stack": null, "stacks": []}"#
        let snapshot = try GGStackSnapshot.decode(fromJSON: Data(json.utf8))
        #expect(snapshot.stack == nil)
    }

    @Test func unknownEnumStringsDecodeAsNil() throws {
        let json = Self.fixture
            .replacingOccurrences(of: "\"merged\"", with: "\"locked\"")
            .replacingOccurrences(of: "\"success\"", with: "\"exploded\"")
        let snapshot = try GGStackSnapshot.decode(fromJSON: Data(json.utf8))
        let stack = try #require(snapshot.stack)
        #expect(stack.entries[0].prState == nil)
        #expect(stack.entries[0].ciStatus == nil)
    }

    @Test func unsupportedSchemaVersionThrows() {
        let json = #"{"version": 99, "stack": null}"#
        #expect(throws: GGServiceError.unsupportedSchema(99)) {
            _ = try GGStackSnapshot.decode(fromJSON: Data(json.utf8))
        }
    }

    @Test func summaryCountsMergedEntries() throws {
        let snapshot = try GGStackSnapshot.decode(fromJSON: Data(Self.fixture.utf8))
        let summary = try #require(snapshot.stack?.summary)
        #expect(summary.merged == 1)
        #expect(summary.total == 3)
    }

    @Test func entryMatchesFullCommitSHAByPrefix() throws {
        let snapshot = try GGStackSnapshot.decode(fromJSON: Data(Self.fixture.utf8))
        let stack = try #require(snapshot.stack)
        let full = "bbbbbbb" + String(repeating: "0", count: 33)
        #expect(stack.entry(matchingCommitSHA: full)?.prNumber == 840)
        #expect(stack.entry(matchingCommitSHA: "ddddddd") == nil)
    }

    @Test func projectsCompleteStackRowsInDescendingPositionOrder() throws {
        let full1 = String(repeating: "a", count: 40)
        let full2 = String(repeating: "b", count: 40)
        let full3 = String(repeating: "c", count: 40)
        let full4 = String(repeating: "d", count: 40)
        let stack = GGStack(
            name: "stack",
            base: "main",
            totalCommits: 4,
            syncedCommits: 0,
            currentPosition: 2,
            behindBase: nil,
            entries: [
                GGStackEntry(position: 1, sha: String(full1.prefix(7)), title: "one"),
                GGStackEntry(position: 2, sha: String(full2.prefix(7)), title: "two", isCurrent: true),
                GGStackEntry(position: 3, sha: String(full3.prefix(7)), title: "three"),
                GGStackEntry(position: 4, sha: String(full4.prefix(7)), title: "four"),
            ]
        )
        let infosBySHA = [
            full2: commit(sha: full2),
            full4: commit(sha: full4),
            full1: commit(sha: full1),
            full3: commit(sha: full3),
        ]

        let projected = try stack.projectCommits(infosBySHA)

        #expect(projected.map(\.sha) == [full4, full3, full2, full1])
        #expect(stack.relation(for: stack.entries[3]) == .aboveCurrent)
        #expect(stack.relation(for: stack.entries[1]) == .current)
        #expect(stack.relation(for: stack.entries[0]) == .belowCurrent)
        #expect(stack.currentPositionIndicator(for: stack.entries[1]) == GGCurrentPositionIndicator(
            text: "Current · 2 of 4",
            accessibilityLabel: "Current GG commit, position 2 of 4"
        ))
        #expect(stack.currentPositionIndicator(for: stack.entries[3]) == nil)
    }

    @Test func projectionRejectsMissingEntriesAndInconsistentCurrentPosition() throws {
        let full = String(repeating: "a", count: 40)
        let entry = GGStackEntry(position: 1, sha: String(full.prefix(7)), title: "one", isCurrent: true)
        let missingStack = GGStack(
            name: "stack", base: "main", totalCommits: 1, syncedCommits: 0,
            currentPosition: 1, behindBase: nil, entries: [entry]
        )
        #expect(throws: GGStackCommitProjectionError.missingCommit(sha: entry.sha)) {
            _ = try missingStack.projectCommits([:])
        }

        let inconsistentStack = GGStack(
            name: "stack", base: "main", totalCommits: 1, syncedCommits: 0,
            currentPosition: 1, behindBase: nil,
            entries: [GGStackEntry(position: 1, sha: entry.sha, title: "one")]
        )
        #expect(inconsistentStack.relation(for: inconsistentStack.entries[0]) == .unknown)
        #expect(inconsistentStack.currentPositionIndicator(for: inconsistentStack.entries[0]) == nil)

        let nilPositionStack = GGStack(
            name: "stack", base: "main", totalCommits: 1, syncedCommits: 0,
            currentPosition: nil, behindBase: nil, entries: [entry]
        )
        #expect(nilPositionStack.relation(for: nilPositionStack.entries[0]) == .unknown)
        #expect(nilPositionStack.currentPositionIndicator(for: nilPositionStack.entries[0]) == nil)

        let tip = GGStackEntry(position: 4, sha: entry.sha, title: "tip", isCurrent: true)
        let tipStack = GGStack(
            name: "stack", base: "main", totalCommits: 4, syncedCommits: 0,
            currentPosition: 4, behindBase: nil,
            entries: [
                GGStackEntry(position: 1, sha: "one", title: "one"),
                GGStackEntry(position: 2, sha: "two", title: "two"),
                GGStackEntry(position: 3, sha: "three", title: "three"),
                tip,
            ]
        )
        #expect(tipStack.currentPositionIndicator(for: tip) == nil)
    }

    private func commit(sha: String) -> CommitInfo {
        CommitInfo(
            sha: sha,
            shortSha: String(sha.prefix(7)),
            author: "Test",
            authorInitials: "T",
            date: .now,
            subject: "subject",
            conventionalTag: nil,
            filesChanged: 0,
            insertions: 0,
            deletions: 0
        )
    }
}
