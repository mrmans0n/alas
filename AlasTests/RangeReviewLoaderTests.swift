import Foundation
import Testing
@testable import Alas

struct RangeReviewLoaderTests {
    @Test func loadsRangeFilesInOrderIntoUngroupedSession() async throws {
        let git = FakeRangeReviewGitClient(diffs: [
            "z.swift": diff(lines: [.init(kind: .add, text: "let z = true", oldNumber: nil, newNumber: 1)]),
            "a.swift": diff(lines: [.init(kind: .delete, text: "let a = false", oldNumber: 1, newNumber: nil)]),
        ])
        let loader = RangeReviewLoader(git: git)

        let session = try await loader.load(
            worktreePath: URL(fileURLWithPath: "/tmp/repo"),
            base: "aaa", head: "bbb", threeDot: false,
            files: [
                CommitChangedFile(path: "z.swift", originalPath: nil, status: "A", add: 1, del: 0),
                CommitChangedFile(path: "a.swift", originalPath: nil, status: "D", add: 0, del: 1),
            ],
            openFileForPath: { _ in nil }
        )

        #expect(session.files.map(\.summary.path) == ["z.swift", "a.swift"])
        #expect(session.summary.groupsEnabled == false)
    }

    private func diff(lines: [ParsedDiff.Hunk.Line]) -> ParsedDiff {
        ParsedDiff(hunks: [
            ParsedDiff.Hunk(
                header: "@@ -1,\(lines.count) +1,\(lines.count) @@",
                oldStart: 1,
                newStart: 1,
                lines: lines
            ),
        ])
    }
}

private final class FakeRangeReviewGitClient: RangeReviewGitClient, @unchecked Sendable {
    private let diffs: [String: ParsedDiff]
    init(diffs: [String: ParsedDiff]) { self.diffs = diffs }

    func rangeDiff(worktreePath: URL, base: String, head: String, threeDot: Bool, file: String, originalPath: String?) async throws -> ParsedDiff {
        diffs[file, default: ParsedDiff(hunks: [])]
    }

    func rangeContextSnapshot(worktreePath: URL, base: String, head: String, threeDot: Bool, file: String, originalPath: String?) async throws -> DiffReviewFileContextSnapshot {
        DiffReviewFileContextSnapshot(old: .unavailable, new: .unavailable)
    }
}
