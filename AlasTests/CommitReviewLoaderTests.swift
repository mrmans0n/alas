import Foundation
import Testing
@testable import Alas

struct CommitReviewLoaderTests {
    @Test func loadsMultipleCommitFilesInIncomingOrderIntoUngroupedSession() async throws {
        let git = FakeCommitReviewGitClient(diffs: [
            "z.swift": diff(lines: [
                .init(kind: .add, text: "let z = true", oldNumber: nil, newNumber: 1),
            ]),
            "a.swift": diff(lines: [
                .init(kind: .delete, text: "let a = false", oldNumber: 1, newNumber: nil),
            ]),
        ])
        let loader = CommitReviewLoader(git: git)

        let session = try await loader.load(
            worktreePath: URL(fileURLWithPath: "/tmp/repo"),
            sha: "abc123",
            files: [
                CommitChangedFile(path: "z.swift", originalPath: nil, status: "A", add: 99, del: 99),
                CommitChangedFile(path: "a.swift", originalPath: nil, status: "D", add: 88, del: 88),
            ],
            openFileForPath: { _ in nil }
        )

        #expect(session.files.map(\.summary.path) == ["z.swift", "a.swift"])
        #expect(session.summary.files.map(\.path) == ["z.swift", "a.swift"])
        #expect(session.summary.groupsEnabled == false)
        #expect(session.summary.groups.isEmpty)
        #expect(session.files.map(\.summary.namespace) == ["commit", "commit"])
        #expect(session.files.map(\.summary.groupID) == [nil, nil])
        #expect(session.files.map(\.summary.groupTitle) == [nil, nil])
        #expect(session.files.map(\.summary.status) == [.added, .deleted])
    }

    @Test func derivesCountsFromParsedDiffInsteadOfCommitFileStats() async throws {
        let git = FakeCommitReviewGitClient(diffs: [
            "Sources/App.swift": diff(lines: [
                .init(kind: .context, text: "struct App {}", oldNumber: 1, newNumber: 1),
                .init(kind: .delete, text: "let old = 1", oldNumber: 2, newNumber: nil),
                .init(kind: .delete, text: "let older = 0", oldNumber: 3, newNumber: nil),
                .init(kind: .add, text: "let new = 1", oldNumber: nil, newNumber: 2),
            ]),
        ])
        let loader = CommitReviewLoader(git: git)

        let session = try await loader.load(
            worktreePath: URL(fileURLWithPath: "/tmp/repo"),
            sha: "abc123",
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

    @Test func passesOriginalPathForRenamesAndCopies() async throws {
        let git = FakeCommitReviewGitClient(diffs: [
            "Sources/NewName.swift": diff(lines: [
                .init(kind: .add, text: "let renamed = true", oldNumber: nil, newNumber: 1),
            ]),
            "Sources/Copied.swift": diff(lines: [
                .init(kind: .add, text: "let copied = true", oldNumber: nil, newNumber: 1),
            ]),
        ])
        let loader = CommitReviewLoader(git: git)

        let session = try await loader.load(
            worktreePath: URL(fileURLWithPath: "/tmp/repo"),
            sha: "abc123",
            files: [
                CommitChangedFile(path: "Sources/NewName.swift", originalPath: "Sources/OldName.swift", status: "R", add: 1, del: 1),
                CommitChangedFile(path: "Sources/Copied.swift", originalPath: "Sources/Original.swift", status: "C", add: 1, del: 0),
            ],
            openFileForPath: { _ in nil }
        )

        #expect(git.requests.map(\.originalPath) == ["Sources/OldName.swift", "Sources/Original.swift"])
        #expect(session.files.map(\.summary.originalPath) == ["Sources/OldName.swift", "Sources/Original.swift"])
        #expect(session.files.map(\.summary.status) == [.renamed, .copied])
    }

    @Test func rendersImagesWithProvidersAndKeepsEmptyTextDiffsAsPlaceholders() async throws {
        let git = FakeCommitReviewGitClient(diffs: [
            "Assets/logo.png": diff(lines: [
                .init(kind: .delete, text: "binary old", oldNumber: 1, newNumber: nil),
                .init(kind: .add, text: "binary new", oldNumber: nil, newNumber: 1),
            ]),
            "README.md": ParsedDiff(hunks: []),
        ])
        let loader = CommitReviewLoader(git: git)

        let worktreePath = URL(fileURLWithPath: "/tmp/repo")
        let imageFile = CommitChangedFile(
            path: "Assets/logo.png",
            originalPath: "Assets/old-logo.png",
            status: "R",
            add: 0,
            del: 0
        )
        let session = try await loader.load(
            worktreePath: worktreePath,
            sha: "abc123",
            files: [
                imageFile,
                CommitChangedFile(path: "README.md", originalPath: nil, status: "M", add: 10, del: 10),
            ],
            openFileForPath: { _ in nil }
        )

        #expect(session.files.map(\.summary.path) == ["Assets/logo.png", "README.md"])
        #expect(session.files.map(\.summary.isRenderable) == [true, false])
        #expect(session.files.map { $0.displayModel == nil } == [true, true])
        let image = try #require(session.files.first)
        #expect(image.placeholderMessage == nil)
        #expect(image.imageProvider != nil)
        #expect(git.imageProviderRequests == [
            .init(worktreePath: worktreePath, sha: "abc123", file: imageFile),
        ])
        #expect(session.files[1].placeholderMessage == "No text diff is available for this file.")
    }

    @Test func storesOpenFileClosureWhenProvidedAndNilWhenNotProvided() async throws {
        let recorder = OpenFileRecorder()
        let files = [
            CommitChangedFile(path: "Sources/App.swift", originalPath: nil, status: "M", add: 1, del: 0),
        ]
        let git = FakeCommitReviewGitClient(diffs: [
            "Sources/App.swift": diff(lines: [
                .init(kind: .add, text: "let value = 1", oldNumber: nil, newNumber: 1),
            ]),
        ])
        let loader = CommitReviewLoader(git: git)

        let withOpenFile = try await loader.load(
            worktreePath: URL(fileURLWithPath: "/tmp/repo"),
            sha: "abc123",
            files: files,
            openFileForPath: { path in
                { recorder.record(path) }
            }
        )
        let withoutOpenFile = try await loader.load(
            worktreePath: URL(fileURLWithPath: "/tmp/repo"),
            sha: "abc123",
            files: files,
            openFileForPath: { _ in nil }
        )

        let openFile = try #require(withOpenFile.files.first?.openFile)
        openFile()

        #expect(recorder.paths == ["Sources/App.swift"])
        #expect(withOpenFile.files.first?.openFile != nil)
        #expect(withoutOpenFile.files.first?.openFile == nil)
    }

    @Test func attachesContextProviderForCommitFiles() async throws {
        let snapshot = DiffReviewFileContextSnapshot(
            old: .available(["old"]),
            new: .available(["new"])
        )
        let git = FakeCommitReviewGitClient(
            diffs: [
                "Sources/NewName.swift": diff(lines: [
                    .init(kind: .delete, text: "old", oldNumber: 1, newNumber: nil),
                    .init(kind: .add, text: "new", oldNumber: nil, newNumber: 1),
                ]),
            ],
            snapshots: [
                "abc123:Sources/NewName.swift": snapshot,
            ]
        )
        let loader = CommitReviewLoader(git: git)
        let worktreePath = URL(fileURLWithPath: "/tmp/repo")

        let session = try await loader.load(
            worktreePath: worktreePath,
            sha: "abc123",
            files: [
                CommitChangedFile(
                    path: "Sources/NewName.swift",
                    originalPath: "Sources/OldName.swift",
                    status: "R",
                    add: 1,
                    del: 1
                ),
            ],
            openFileForPath: { _ in nil }
        )

        #expect(try await session.files.first?.contextProvider?.snapshot() == snapshot)
        #expect(git.contextSnapshotRequests == [
            .init(
                worktreePath: worktreePath,
                sha: "abc123",
                file: "Sources/NewName.swift",
                originalPath: "Sources/OldName.swift"
            ),
        ])
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

private final class FakeCommitReviewGitClient: CommitReviewGitClient, @unchecked Sendable {
    struct Request: Equatable {
        let worktreePath: URL
        let sha: String
        let file: String
        let originalPath: String?
    }

    private let diffs: [String: ParsedDiff]
    private let snapshots: [String: DiffReviewFileContextSnapshot]
    private let lock = NSLock()
    private var recordedRequests: [Request] = []
    private var recordedContextSnapshotRequests: [Request] = []
    private var recordedImageProviderRequests: [ImageProviderRequest] = []

    init(
        diffs: [String: ParsedDiff],
        snapshots: [String: DiffReviewFileContextSnapshot] = [:]
    ) {
        self.diffs = diffs
        self.snapshots = snapshots
    }

    var requests: [Request] {
        lock.withLock { recordedRequests }
    }

    var contextSnapshotRequests: [Request] {
        lock.withLock { recordedContextSnapshotRequests }
    }

    var imageProviderRequests: [ImageProviderRequest] {
        lock.withLock { recordedImageProviderRequests }
    }

    func diff(worktreePath: URL, sha: String, file: String, originalPath: String?) async throws -> ParsedDiff {
        lock.withLock {
            recordedRequests.append(Request(
                worktreePath: worktreePath,
                sha: sha,
                file: file,
                originalPath: originalPath
            ))
        }
        return diffs[file, default: ParsedDiff(hunks: [])]
    }

    func commitContextSnapshot(
        worktreePath: URL,
        sha: String,
        file: String,
        originalPath: String?
    ) async throws -> DiffReviewFileContextSnapshot {
        lock.withLock {
            recordedContextSnapshotRequests.append(Request(
                worktreePath: worktreePath,
                sha: sha,
                file: file,
                originalPath: originalPath
            ))
        }
        return snapshots["\(sha):\(file)", default: DiffReviewFileContextSnapshot(old: .unavailable, new: .unavailable)]
    }

    func commitImageProvider(
        worktreePath: URL,
        sha: String,
        file: CommitChangedFile
    ) -> DiffReviewImageProvider {
        lock.withLock {
            recordedImageProviderRequests.append(.init(worktreePath: worktreePath, sha: sha, file: file))
        }
        return DiffReviewImageProvider(
            id: DiffReviewImageProviderID(
                source: .commit,
                repository: worktreePath.path,
                beforeRevision: "\(sha)^",
                afterRevision: sha,
                beforePath: file.originalPath,
                afterPath: file.path
            ),
            load: {
                ImageDiffPair(before: .missing, after: .missing, oldPath: file.originalPath, kind: .modified)
            }
        )
    }

    struct ImageProviderRequest: Equatable {
        let worktreePath: URL
        let sha: String
        let file: CommitChangedFile
    }
}

private final class OpenFileRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var recordedPaths: [String] = []

    var paths: [String] {
        lock.withLock { recordedPaths }
    }

    func record(_ path: String) {
        lock.withLock {
            recordedPaths.append(path)
        }
    }
}
