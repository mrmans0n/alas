import Foundation
import Testing
@testable import Alas

@Suite("Review session loader")
struct ReviewSessionLoaderTests {
    @MainActor
    @Test func productionLoaderLoadsLocalChangesFromWorktree() async throws {
        let repo = FileManager.default.temporaryDirectory
            .appendingPathComponent("alas-review-session-loader-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: repo) }
        _ = try await Process.git(["init", "-q", "-b", "main"], cwd: repo)

        let worktree = Worktree(
            id: Worktree.makeId(path: repo),
            projectId: "project-1",
            name: "main",
            branch: "main",
            path: repo,
            status: .clean,
            lastActivity: Date(timeIntervalSince1970: 1)
        )
        let target = ReviewSessionTarget.localChanges(
            worktreeID: worktree.id,
            repositoryPath: repo,
            scope: .all
        )
        let loader = ReviewSessionLoader.production(
            appState: AppState(store: MemoryStore()),
            worktree: worktree
        )

        let loaded = try await loader.load(target: target)
        let draftCommitTarget = ReviewSessionTarget.draftCommit(
            worktreeID: worktree.id,
            repositoryPath: repo
        )
        let draftCommitLoaded = try await loader.load(target: draftCommitTarget)

        #expect(loaded.session.files.isEmpty)
        #expect(loaded.feedbackTarget.title == "Review all changes")
        #expect(draftCommitLoaded.session.files.isEmpty)
        #expect(draftCommitLoaded.feedbackTarget.title == "Review draft commit")
    }

    @Test func localChangesLoaderBuildsGroupedSessionAndFeedbackTarget() async throws {
        let target = ReviewSessionTarget.localChanges(
            worktreeID: "wt-1",
            repositoryPath: URL(fileURLWithPath: "/repo"),
            scope: .all
        )
        let loader = ReviewSessionLoader(
            localChanges: { target in
                #expect(target.kind == .localChanges)
                let summary = DiffReviewFileSummary(
                    path: "Sources/A.swift",
                    namespace: "unstaged",
                    groupID: "unstaged",
                    groupTitle: "Unstaged",
                    status: .modified,
                    additions: 1,
                    deletions: 0,
                    isRenderable: true
                )
                return DiffReviewLoadedSession(
                    files: [DiffReviewFileSectionModel(summary: summary, parsedDiff: nil, displayModel: nil, placeholderMessage: nil, openFile: nil)],
                    summary: DiffReviewSessionModel(files: [summary], groupsEnabled: true)
                )
            }
        )

        let loaded = try await loader.load(target: target)

        #expect(loaded.session.summary.fileCount == 1)
        #expect(loaded.feedbackTarget.title == "Review all changes")
        #expect(loaded.feedbackTarget.repositoryPath == "/repo")
        #expect(loaded.feedbackTarget.sourceDescription == "Local changes: all")
    }

    @Test func commitLoaderBuildsPinnedSourceDescription() async throws {
        let target = ReviewSessionTarget.commit(
            worktreeID: "wt-1",
            repositoryPath: URL(fileURLWithPath: "/repo"),
            sha: "deadbeef",
            title: "Review deadbeef"
        )
        let loader = ReviewSessionLoader(
            commit: { target in
                #expect(target.revisionDescription == "deadbeef")
                return DiffReviewLoadedSession(files: [], summary: DiffReviewSessionModel(files: [], groupsEnabled: false))
            }
        )

        let loaded = try await loader.load(target: target)

        #expect(loaded.feedbackTarget.sourceDescription == "Commit deadbeef")
    }

    private struct MemoryStore: PersistenceStoreProtocol {
        func write<T: Encodable>(_ value: T, to url: URL) throws {}

        func readIfExists<T: Decodable>(_ type: T.Type, from url: URL) throws -> T? {
            nil
        }
    }
}
