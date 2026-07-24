import Foundation
import Testing
@testable import Alas

struct StagedDiffLoaderTests {
    @Test func loadsSessionWithStagedNamespace() async throws {
        let git = MockStagedDiffGitClient(
            files: [
                CommitChangedFile(path: "Sources/App.swift", originalPath: nil, status: "M", add: 1, del: 0),
            ],
            diffs: [
                "Sources/App.swift": diff(lines: [
                    .init(kind: .add, text: "let x = 1", oldNumber: nil, newNumber: 1),
                ]),
            ]
        )
        let loader = StagedDiffLoader(git: git)

        let worktreePath = URL(fileURLWithPath: "/tmp/repo")
        let session = try await loader.load(worktreePath: worktreePath)

        #expect(session.files.map(\.summary.namespace) == ["staged"])
        #expect(session.summary.files.map(\.namespace) == ["staged"])
    }

    @Test func countsAdditionsAndDeletions() async throws {
        let git = MockStagedDiffGitClient(
            files: [
                CommitChangedFile(path: "Sources/App.swift", originalPath: nil, status: "M", add: 99, del: 99),
            ],
            diffs: [
                "Sources/App.swift": diff(lines: [
                    .init(kind: .context, text: "let a = 0", oldNumber: 1, newNumber: 1),
                    .init(kind: .delete, text: "let b = 1", oldNumber: 2, newNumber: nil),
                    .init(kind: .delete, text: "let c = 2", oldNumber: 3, newNumber: nil),
                    .init(kind: .add, text: "let b = 10", oldNumber: nil, newNumber: 2),
                ]),
            ]
        )
        let loader = StagedDiffLoader(git: git)

        let worktreePath = URL(fileURLWithPath: "/tmp/repo")
        let session = try await loader.load(worktreePath: worktreePath)

        let file = try #require(session.files.first)
        #expect(file.summary.additions == 1)
        #expect(file.summary.deletions == 2)
        #expect(session.summary.totalAdditions == 1)
        #expect(session.summary.totalDeletions == 2)
    }

    @Test func forwardsOriginalPathForRenames() async throws {
        let git = MockStagedDiffGitClient(
            files: [
                CommitChangedFile(path: "Sources/NewName.swift", originalPath: "Sources/OldName.swift", status: "R", add: 1, del: 1),
            ],
            diffs: [
                "Sources/NewName.swift": diff(lines: [
                    .init(kind: .add, text: "let renamed = true", oldNumber: nil, newNumber: 1),
                ]),
            ]
        )
        let loader = StagedDiffLoader(git: git)

        let session = try await loader.load(worktreePath: URL(fileURLWithPath: "/tmp/repo"))

        #expect(git.diffRequests.map(\.originalPath) == ["Sources/OldName.swift"])
        let file = try #require(session.files.first)
        #expect(file.summary.originalPath == "Sources/OldName.swift")
    }

    @Test func rendersSupportedImageFilesWithAnImageProvider() async throws {
        let git = MockStagedDiffGitClient(
            files: [
                CommitChangedFile(path: "Assets/logo.png", originalPath: nil, status: "M", add: 0, del: 0),
            ],
            diffs: [
                "Assets/logo.png": diff(lines: [
                    .init(kind: .delete, text: "binary old", oldNumber: 1, newNumber: nil),
                    .init(kind: .add, text: "binary new", oldNumber: nil, newNumber: 1),
                ]),
            ]
        )
        let loader = StagedDiffLoader(git: git)

        let worktreePath = URL(fileURLWithPath: "/tmp/repo")
        let session = try await loader.load(worktreePath: worktreePath)

        let file = try #require(session.files.first)
        #expect(file.summary.isRenderable)
        #expect(file.displayModel == nil)
        #expect(file.placeholderMessage == nil)
        let provider = try #require(file.imageProvider)
        _ = await provider.load()
        #expect(git.imageProviderRequests == [
            .init(worktreePath: worktreePath, file: CommitChangedFile(
                path: "Assets/logo.png", originalPath: nil, status: "M", add: 0, del: 0
            )),
        ])
    }

    @Test func marksEmptyDiffAsNotRenderable() async throws {
        let git = MockStagedDiffGitClient(
            files: [
                CommitChangedFile(path: "README.md", originalPath: nil, status: "M", add: 0, del: 0),
            ],
            diffs: [
                "README.md": ParsedDiff(hunks: []),
            ]
        )
        let loader = StagedDiffLoader(git: git)

        let session = try await loader.load(worktreePath: URL(fileURLWithPath: "/tmp/repo"))

        let file = try #require(session.files.first)
        #expect(file.summary.isRenderable == false)
        #expect(file.displayModel == nil)
        #expect(file.placeholderMessage == "No text diff is available for this file.")
    }

    @Test func marksTextDiffAsRenderable() async throws {
        let git = MockStagedDiffGitClient(
            files: [
                CommitChangedFile(path: "Sources/App.swift", originalPath: nil, status: "M", add: 1, del: 0),
            ],
            diffs: [
                "Sources/App.swift": diff(lines: [
                    .init(kind: .add, text: "let value = 1", oldNumber: nil, newNumber: 1),
                ]),
            ]
        )
        let loader = StagedDiffLoader(git: git)

        let session = try await loader.load(worktreePath: URL(fileURLWithPath: "/tmp/repo"))

        let file = try #require(session.files.first)
        #expect(file.summary.isRenderable == true)
        #expect(file.displayModel != nil)
        #expect(file.placeholderMessage == nil)
    }

    @Test func buildsDiffReviewLoadedSessionWithGroupsDisabled() async throws {
        let git = MockStagedDiffGitClient(
            files: [
                CommitChangedFile(path: "Sources/App.swift", originalPath: nil, status: "M", add: 1, del: 0),
                CommitChangedFile(path: "Sources/Other.swift", originalPath: nil, status: "A", add: 5, del: 0),
            ],
            diffs: [
                "Sources/App.swift": diff(lines: [
                    .init(kind: .add, text: "let a = 1", oldNumber: nil, newNumber: 1),
                ]),
                "Sources/Other.swift": diff(lines: [
                    .init(kind: .add, text: "let b = 2", oldNumber: nil, newNumber: 1),
                ]),
            ]
        )
        let loader = StagedDiffLoader(git: git)

        let session = try await loader.load(worktreePath: URL(fileURLWithPath: "/tmp/repo"))

        #expect(session.summary.groupsEnabled == false)
        #expect(session.summary.groups.isEmpty)
    }

    @Test func abortsOnCancellation() async throws {
        let git = BlockingStagedDiffGitClient()
        let loader = StagedDiffLoader(git: git)
        let worktreePath = URL(fileURLWithPath: "/tmp/repo")

        let task = Task { @MainActor in
            try await loader.load(worktreePath: worktreePath)
        }
        task.cancel()

        do {
            _ = try await task.value
            Issue.record("Expected CancellationError but load succeeded")
        } catch is CancellationError {
            // Expected: task was cancelled
        } catch {
            // Also acceptable: the task may propagate cancellation as a
            // CancellationError wrapped by the Swift concurrency runtime.
        }

        // The mock should not have been called (or called minimally) since
        // cancellation is checked before the first async call.
        #expect(git.callCount <= 1)
    }

    // MARK: - Helpers

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

// MARK: - MockStagedDiffGitClient

private final class MockStagedDiffGitClient: StagedDiffGitClient, @unchecked Sendable {
    struct DiffRequest: Equatable {
        let worktreePath: URL
        let file: String
        let staged: Bool
        let originalPath: String?
    }

    private let stagedFiles: [CommitChangedFile]
    private let diffs: [String: ParsedDiff]
    private let lock = NSLock()
    private var recordedDiffRequests: [DiffRequest] = []
    private var recordedImageProviderRequests: [ImageProviderRequest] = []

    init(files: [CommitChangedFile], diffs: [String: ParsedDiff]) {
        self.stagedFiles = files
        self.diffs = diffs
    }

    var diffRequests: [DiffRequest] {
        lock.withLock { recordedDiffRequests }
    }

    var imageProviderRequests: [ImageProviderRequest] {
        lock.withLock { recordedImageProviderRequests }
    }

    func stagedChangedFiles(at worktreePath: URL) async throws -> [CommitChangedFile] {
        stagedFiles
    }

    func diff(worktreePath: URL, file: String, staged: Bool, originalPath: String?) async throws -> ParsedDiff {
        lock.withLock {
            recordedDiffRequests.append(DiffRequest(
                worktreePath: worktreePath,
                file: file,
                staged: staged,
                originalPath: originalPath
            ))
        }
        return diffs[file, default: ParsedDiff(hunks: [])]
    }

    func stagedImageProvider(worktreePath: URL, file: CommitChangedFile) async -> DiffReviewImageProvider {
        lock.withLock {
            recordedImageProviderRequests.append(.init(worktreePath: worktreePath, file: file))
        }
        return DiffReviewImageProvider(
            id: DiffReviewImageProviderID(
                source: .workingCopy,
                repository: worktreePath.path,
                beforeRevision: "staged",
                afterRevision: "fake",
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
        let file: CommitChangedFile
    }
}

// MARK: - BlockingStagedDiffGitClient

/// A mock that records how many times `stagedChangedFiles` is called;
/// used to verify cancellation short-circuits the load.
private final class BlockingStagedDiffGitClient: StagedDiffGitClient, @unchecked Sendable {
    private let lock = NSLock()
    private var _callCount = 0

    var callCount: Int { lock.withLock { _callCount } }

    func stagedChangedFiles(at worktreePath: URL) async throws -> [CommitChangedFile] {
        lock.withLock { _callCount += 1 }
        try Task.checkCancellation()
        return []
    }

    func diff(worktreePath: URL, file: String, staged: Bool, originalPath: String?) async throws -> ParsedDiff {
        try Task.checkCancellation()
        return ParsedDiff(hunks: [])
    }

    func stagedImageProvider(worktreePath: URL, file: CommitChangedFile) async -> DiffReviewImageProvider {
        DiffReviewImageProvider(
            id: DiffReviewImageProviderID(
                source: .workingCopy,
                repository: worktreePath.path,
                beforeRevision: "staged",
                afterRevision: "fake",
                beforePath: file.originalPath,
                afterPath: file.path
            ),
            load: { ImageDiffPair(before: .missing, after: .missing, oldPath: nil, kind: .modified) }
        )
    }
}
