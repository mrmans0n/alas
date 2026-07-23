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
        #expect(session.files.map(\.summary.namespace) == ["range", "range"])
        #expect(session.files.map(\.summary.status) == [.added, .deleted])
    }

    @Test func derivesCountsFromParsedDiffInsteadOfCommitFileStats() async throws {
        let git = FakeRangeReviewGitClient(diffs: [
            "Sources/App.swift": diff(lines: [
                .init(kind: .context, text: "struct App {}", oldNumber: 1, newNumber: 1),
                .init(kind: .delete, text: "let old = 1", oldNumber: 2, newNumber: nil),
                .init(kind: .delete, text: "let older = 0", oldNumber: 3, newNumber: nil),
                .init(kind: .add, text: "let new = 1", oldNumber: nil, newNumber: 2),
            ]),
        ])
        let loader = RangeReviewLoader(git: git)

        let session = try await loader.load(
            worktreePath: URL(fileURLWithPath: "/tmp/repo"),
            base: "aaa", head: "bbb", threeDot: false,
            files: [
                CommitChangedFile(path: "Sources/App.swift", originalPath: nil, status: "M", add: 999, del: 888),
            ],
            openFileForPath: { _ in nil }
        )

        let file = try #require(session.files.first)
        #expect(file.summary.additions == 1)
        #expect(file.summary.deletions == 2)
        #expect(session.summary.totalAdditions == 1)
        #expect(session.summary.totalDeletions == 2)
    }

    @Test @MainActor func attachesImageProviderOnlyWhenTheRangeClientSuppliesOne() async throws {
        let provider = imageProvider(path: "Assets/logo.png", before: "merge-base", after: "head")
        let git = FakeRangeReviewGitClient(
            diffs: ["Assets/logo.png": ParsedDiff(hunks: [])],
            imageProvider: provider
        )
        let loader = RangeReviewLoader(git: git)

        let session = try await loader.load(
            worktreePath: URL(fileURLWithPath: "/tmp/repo"),
            base: "base", head: "head", threeDot: true,
            files: [CommitChangedFile(path: "Assets/logo.png", originalPath: nil, status: "M", add: 0, del: 0)],
            openFileForPath: { _ in nil }
        )

        let section = try #require(session.files.first)
        #expect(section.summary.isRenderable)
        #expect(section.placeholderMessage == nil)
        #expect(section.imageProvider?.id == provider.id)
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

@MainActor
private func imageProvider(path: String, before: String, after: String) -> DiffReviewImageProvider {
    DiffReviewImageProvider(
        id: DiffReviewImageProviderID(
            source: .range,
            repository: "/tmp/repo",
            beforeRevision: before,
            afterRevision: after,
            beforePath: path,
            afterPath: path
        ),
        load: {
            ImageDiffPair(before: .missing, after: .missing, oldPath: nil, kind: .modified)
        }
    )
}

private final class FakeRangeReviewGitClient: RangeReviewGitClient, @unchecked Sendable {
    private let diffs: [String: ParsedDiff]
    private let imageProvider: DiffReviewImageProvider?
    init(diffs: [String: ParsedDiff], imageProvider: DiffReviewImageProvider? = nil) {
        self.diffs = diffs
        self.imageProvider = imageProvider
    }

    func resolvedRangeTrees(worktreePath: URL, base: String, head: String, threeDot: Bool) async throws -> (before: String, after: String) {
        (before: "resolved-\(base)", after: "resolved-\(head)")
    }

    func rangeDiff(worktreePath: URL, revisions: (before: String, after: String), file: String, originalPath: String?) async throws -> ParsedDiff {
        diffs[file, default: ParsedDiff(hunks: [])]
    }

    func rangeContextSnapshot(worktreePath: URL, base: String, head: String, threeDot: Bool, file: String, originalPath: String?) async throws -> DiffReviewFileContextSnapshot {
        DiffReviewFileContextSnapshot(old: .unavailable, new: .unavailable)
    }

    func rangeImageProvider(worktreePath: URL, revisions: (before: String, after: String), file: CommitChangedFile) -> DiffReviewImageProvider {
        imageProvider ?? DiffReviewImageProvider(
            id: DiffReviewImageProviderID(
                source: .range,
                repository: worktreePath.path,
                beforeRevision: revisions.before,
                afterRevision: revisions.after,
                beforePath: file.originalPath,
                afterPath: file.path
            ),
            load: { ImageDiffPair(before: .missing, after: .missing, oldPath: nil, kind: .modified) }
        )
    }
}
