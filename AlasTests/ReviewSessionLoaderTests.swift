import Foundation
import Testing
@testable import Alas

@Suite("Review session loader")
struct ReviewSessionLoaderTests {
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
}
