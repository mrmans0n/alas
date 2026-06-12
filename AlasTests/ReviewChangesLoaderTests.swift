import Foundation
import Testing
@testable import Alas

struct ReviewChangesLoaderTests {
    @Test func buildsSectionsForStagedAndUnstagedTextDiffs() async throws {
        let unstagedDiff = ParsedDiff(hunks: [
            ParsedDiff.Hunk(
                header: "@@ -1,2 +1,3 @@",
                oldStart: 1,
                newStart: 1,
                lines: [
                    .init(kind: .context, text: "struct A {}", oldNumber: 1, newNumber: 1),
                    .init(kind: .add, text: "let value = 1", oldNumber: nil, newNumber: 2),
                ]
            ),
        ])
        let stagedDiff = ParsedDiff(hunks: [
            ParsedDiff.Hunk(
                header: "@@ -0,0 +1,1 @@",
                oldStart: 0,
                newStart: 1,
                lines: [
                    .init(kind: .add, text: "struct B {}", oldNumber: nil, newNumber: 1),
                ]
            ),
        ])
        let git = FakeReviewChangesGitClient(
            status: [
                ChangedFile(path: "a.swift", status: "M", stage: .unstaged, add: 2, del: 1, renameFrom: nil),
                ChangedFile(path: "b.swift", status: "A", stage: .staged, add: 1, del: 0, renameFrom: nil),
            ],
            diffs: [
                .init(path: "a.swift", staged: false): unstagedDiff,
                .init(path: "b.swift", staged: true): stagedDiff,
            ]
        )
        let loader = ReviewChangesLoader(git: git)

        let session = try await loader.load(worktreePath: URL(fileURLWithPath: "/tmp/repo"))

        #expect(session.files.map(\.id.rawValue) == ["unstaged:a.swift", "staged:b.swift"])
        #expect(session.files.map(\.displayModel?.filePath) == ["a.swift", "b.swift"])
        #expect(session.files.map { $0.openFile == nil } == [true, true])
        #expect(session.summary.groups.map(\.id) == ["unstaged", "staged"])
        #expect(session.summary.groups.map(\.title) == ["Unstaged", "Staged"])
    }

    @Test func keepsUnsupportedFilesVisibleAsPlaceholders() async throws {
        let git = FakeReviewChangesGitClient(
            status: [
                ChangedFile(path: "image.png", status: "M", stage: .unstaged, add: 0, del: 0, renameFrom: nil),
            ],
            diffs: [
                .init(path: "image.png", staged: false): ParsedDiff(hunks: []),
            ]
        )
        let loader = ReviewChangesLoader(git: git)

        let session = try await loader.load(worktreePath: URL(fileURLWithPath: "/tmp/repo"))

        let file = try #require(session.files.first)
        #expect(file.summary.path == "image.png")
        #expect(file.summary.groupID == "unstaged")
        #expect(file.summary.reviewChangesSource == .unstaged)
        #expect(file.summary.isRenderable == false)
        #expect(file.placeholderMessage != nil)
    }

    @Test func derivesCountsFromSideSpecificDiffsForSamePathChanges() async throws {
        let git = FakeReviewChangesGitClient(
            status: [
                ChangedFile(path: "a.swift", status: "M", stage: .staged, add: 99, del: 88, renameFrom: nil),
                ChangedFile(path: "a.swift", status: "M", stage: .unstaged, add: 99, del: 88, renameFrom: nil),
            ],
            diffs: [
                .init(path: "a.swift", staged: false): diff(lines: [
                    .init(kind: .delete, text: "let oldUnstaged = 1", oldNumber: 1, newNumber: nil),
                    .init(kind: .add, text: "let newUnstaged = 1", oldNumber: nil, newNumber: 1),
                    .init(kind: .add, text: "let otherUnstaged = 2", oldNumber: nil, newNumber: 2),
                ]),
                .init(path: "a.swift", staged: true): diff(lines: [
                    .init(kind: .delete, text: "let oldStaged = 1", oldNumber: 1, newNumber: nil),
                    .init(kind: .delete, text: "let olderStaged = 0", oldNumber: 2, newNumber: nil),
                    .init(kind: .add, text: "let newStaged = 1", oldNumber: nil, newNumber: 1),
                ]),
            ]
        )
        let loader = ReviewChangesLoader(git: git)

        let session = try await loader.load(worktreePath: URL(fileURLWithPath: "/tmp/repo"))

        #expect(session.files.map(\.id.rawValue) == ["unstaged:a.swift", "staged:a.swift"])
        #expect(session.files.map(\.summary.additions) == [2, 1])
        #expect(session.files.map(\.summary.deletions) == [1, 2])
        #expect(session.summary.totalAdditions == 3)
        #expect(session.summary.totalDeletions == 3)
    }

    @Test func propagatesRenameMetadataToSummary() async throws {
        let git = FakeReviewChangesGitClient(
            status: [
                ChangedFile(path: "new.swift", status: "R", stage: .unstaged, add: 42, del: 24, renameFrom: "old.swift"),
            ],
            diffs: [
                .init(path: "new.swift", staged: false): diff(lines: [
                    .init(kind: .add, text: "let renamed = true", oldNumber: nil, newNumber: 1),
                ]),
            ]
        )
        let loader = ReviewChangesLoader(git: git)

        let session = try await loader.load(worktreePath: URL(fileURLWithPath: "/tmp/repo"))

        let file = try #require(session.files.first)
        #expect(file.summary.originalPath == "old.swift")
    }

    @Test func includesOriginalPathWhenLoadingStagedRenameDiff() async throws {
        let git = FakeReviewChangesGitClient(
            status: [
                ChangedFile(path: "new.swift", status: "R", stage: .staged, add: 1, del: 1, renameFrom: "old.swift"),
            ],
            diffs: [
                .init(path: "new.swift", staged: true, originalPath: "old.swift"): diff(lines: [
                    .init(kind: .delete, text: "let oldName = true", oldNumber: 1, newNumber: nil),
                    .init(kind: .add, text: "let newName = true", oldNumber: nil, newNumber: 1),
                ]),
            ]
        )
        let loader = ReviewChangesLoader(git: git)

        let session = try await loader.load(worktreePath: URL(fileURLWithPath: "/tmp/repo"))

        let file = try #require(session.files.first)
        #expect(file.summary.originalPath == "old.swift")
        #expect(file.summary.isRenderable)
        #expect(file.summary.additions == 1)
        #expect(file.summary.deletions == 1)
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

private struct FakeReviewChangesGitClient: ReviewChangesGitClient {
    var status: [ChangedFile]
    var diffs: [DiffKey: ParsedDiff]

    func status(worktreePath: URL) async throws -> [ChangedFile] {
        status
    }

    func diff(worktreePath: URL, file: String, staged: Bool, originalPath: String?) async throws -> ParsedDiff {
        diffs[DiffKey(path: file, staged: staged, originalPath: originalPath), default: ParsedDiff(hunks: [])]
    }
}

private struct DiffKey: Hashable {
    let path: String
    let staged: Bool
    var originalPath: String? = nil
}
