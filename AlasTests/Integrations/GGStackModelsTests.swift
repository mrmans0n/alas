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
}
