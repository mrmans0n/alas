import Foundation
import Testing
@testable import Alas

@Suite("Review draft models")
struct ReviewDraftModelsTests {
    @Test func localChangesSessionIDIsStableForSameWorktree() {
        let first = ReviewDraftSessionID.localChanges(
            worktreeID: "wt-1",
            worktreePath: URL(fileURLWithPath: "/repo"),
            scope: .all
        )
        let second = ReviewDraftSessionID.localChanges(
            worktreeID: "wt-1",
            worktreePath: URL(fileURLWithPath: "/repo"),
            scope: .all
        )

        #expect(first == second)
        #expect(first.rawValue.contains("local-changes"))
        #expect(first.rawValue.contains("wt-1"))
    }

    @Test func commitAndProviderSessionsDoNotCollide() {
        let commit = ReviewDraftSessionID.commit(
            worktreeID: "wt",
            repositoryPath: URL(fileURLWithPath: "/repo"),
            sha: "abc123"
        )
        let pr = ReviewDraftSessionID.reviewRequest(
            worktreeID: "wt",
            provider: .github,
            host: "github.com",
            repositorySlug: "mrmans0n/alas",
            number: 520
        )

        #expect(commit != pr)
        #expect(commit.sourceKind == .commit)
        #expect(pr.sourceKind == .reviewRequest)
    }

    @Test func draftCommentRangeNormalizesLineOrder() {
        let comment = ReviewDraftComment(
            id: "c1",
            sessionID: .localChanges(
                worktreeID: "wt",
                worktreePath: URL(fileURLWithPath: "/repo"),
                scope: .all
            ),
            fileID: DiffReviewFileID(namespace: "unstaged", path: "Sources/App.swift"),
            path: "Sources/App.swift",
            originalPath: nil,
            side: .new,
            startLine: 8,
            endLine: 3,
            selectedText: "let value = 1",
            bodyMarkdown: "Please extract this.",
            state: .active,
            createdAt: Date(timeIntervalSince1970: 1),
            updatedAt: Date(timeIntervalSince1970: 2)
        )

        #expect(comment.normalizedLineRange == 3...8)
        #expect(comment.isActive)
    }

    @Test func draftCommentDecodesLegacyJSONWithoutProviderFields() throws {
        let json = """
        {
          "id": "legacy",
          "sessionID": "local-changes\\u001fwt\\u001f/repo\\u001fall",
          "fileID": {
            "namespace": "unstaged",
            "path": "Sources/App.swift"
          },
          "path": "Sources/App.swift",
          "originalPath": null,
          "side": "new",
          "startLine": 8,
          "endLine": null,
          "selectedText": "let value = 1",
          "bodyMarkdown": "Please extract this.",
          "state": "active",
          "createdAt": 1,
          "updatedAt": 2
        }
        """.data(using: .utf8)!

        let comment = try JSONDecoder().decode(ReviewDraftComment.self, from: json)

        #expect(comment.id == "legacy")
        #expect(comment.anchor == .line(
            side: .new,
            startLine: 8,
            endLine: nil,
            selectedText: "let value = 1"
        ))
        #expect(comment.providerPublish == nil)
        #expect(comment.providerError == nil)
    }

    @Test func draftCommentRoundTripsFileAndImageAnchors() throws {
        let anchors: [ReviewDraftCommentAnchor] = [
            .file,
            .image(side: .new, normalizedX: 0.625, normalizedY: 0.25),
        ]

        for (index, anchor) in anchors.enumerated() {
            let comment = ReviewDraftComment(
                id: "anchor-\(index)",
                sessionID: .localChanges(
                    worktreeID: "wt",
                    worktreePath: URL(fileURLWithPath: "/repo"),
                    scope: .all
                ),
                fileID: DiffReviewFileID(namespace: "unstaged", path: "image.png"),
                path: "image.png",
                originalPath: nil,
                anchor: anchor,
                bodyMarkdown: "Check this.",
                state: .active,
                createdAt: Date(timeIntervalSince1970: 1),
                updatedAt: Date(timeIntervalSince1970: 2)
            )

            let data = try JSONEncoder().encode(comment)
            let decoded = try JSONDecoder().decode(ReviewDraftComment.self, from: data)

            #expect(decoded.anchor == anchor)
            #expect(decoded.normalizedLineRange == nil)
        }
    }

    @Test func draftCommentRoundTripsProviderPublishAndErrorMetadata() throws {
        let comment = ReviewDraftComment(
            id: "published",
            sessionID: .reviewRequest(
                worktreeID: "wt",
                provider: .github,
                host: "github.com",
                repositorySlug: "mrmans0n/alas",
                number: 527
            ),
            fileID: DiffReviewFileID(namespace: "github", path: "Sources/App.swift"),
            path: "Sources/App.swift",
            originalPath: nil,
            side: .new,
            startLine: 8,
            endLine: nil,
            selectedText: "let value = 1",
            bodyMarkdown: "Please extract this.",
            state: .active,
            createdAt: Date(timeIntervalSince1970: 1),
            updatedAt: Date(timeIntervalSince1970: 2),
            providerPublish: ReviewDraftProviderPublish(
                provider: .github,
                host: "github.com",
                repositorySlug: "mrmans0n/alas",
                reviewNumber: 527,
                threadID: "thread-1",
                commentID: "comment-1",
                url: URL(string: "https://github.com/mrmans0n/alas/pull/527#discussion_r1"),
                publishedAt: Date(timeIntervalSince1970: 3)
            ),
            providerError: ReviewDraftProviderError(
                provider: .github,
                message: "line is outdated",
                occurredAt: Date(timeIntervalSince1970: 4)
            )
        )

        let data = try JSONEncoder().encode(comment)
        let decoded = try JSONDecoder().decode(ReviewDraftComment.self, from: data)

        #expect(decoded == comment)
    }
}
