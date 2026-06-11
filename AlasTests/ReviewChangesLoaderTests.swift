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
        #expect(session.summary.sections.map(\.source) == [.unstaged, .staged])
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
        #expect(file.summary.isRenderable == false)
        #expect(file.placeholderMessage != nil)
    }
}

private struct FakeReviewChangesGitClient: ReviewChangesGitClient {
    var status: [ChangedFile]
    var diffs: [DiffKey: ParsedDiff]

    func status(worktreePath: URL) async throws -> [ChangedFile] {
        status
    }

    func diff(worktreePath: URL, file: String, staged: Bool) async throws -> ParsedDiff {
        diffs[DiffKey(path: file, staged: staged), default: ParsedDiff(hunks: [])]
    }
}

private struct DiffKey: Hashable {
    let path: String
    let staged: Bool
}
