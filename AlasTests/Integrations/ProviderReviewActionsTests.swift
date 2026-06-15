import Foundation
import Testing
@testable import Alas

struct ProviderReviewActionsTests {
    @Test func providerDraftCommentBuildsFromActiveLocalDraft() throws {
        let session = ReviewDraftSessionID.reviewRequest(
            worktreeID: "wt",
            provider: .github,
            host: "github.com",
            repositorySlug: "mrmans0n/alas",
            number: 527
        )
        let draft = ReviewDraftComment(
            id: "draft-1",
            sessionID: session,
            fileID: DiffReviewFileID(namespace: "github", path: "Sources/App.swift"),
            path: "Sources/App.swift",
            originalPath: nil,
            side: .new,
            startLine: 12,
            endLine: 14,
            selectedText: "let value = 1",
            bodyMarkdown: "Please simplify this.",
            state: .active,
            createdAt: Date(timeIntervalSince1970: 10),
            updatedAt: Date(timeIntervalSince1970: 11)
        )

        let providerDraft = try #require(ProviderReviewDraftComment(localDraft: draft))

        #expect(providerDraft.localDraftID == "draft-1")
        #expect(providerDraft.path == "Sources/App.swift")
        #expect(providerDraft.originalPath == nil)
        #expect(providerDraft.side == .new)
        #expect(providerDraft.lineRange == 12...14)
        #expect(providerDraft.selectedText == "let value = 1")
        #expect(providerDraft.bodyMarkdown == "Please simplify this.")
    }

    @Test func providerDraftCommentRejectsNonActiveOrPublishedDrafts() {
        var draft = ReviewDraftComment(
            id: "draft-1",
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
            startLine: 12,
            endLine: nil,
            selectedText: nil,
            bodyMarkdown: "Comment",
            state: .resolved,
            createdAt: Date(timeIntervalSince1970: 10),
            updatedAt: Date(timeIntervalSince1970: 11)
        )
        #expect(ProviderReviewDraftComment(localDraft: draft) == nil)

        draft.state = .active
        draft.providerPublish = ReviewDraftProviderPublish(
            provider: .github,
            host: "github.com",
            repositorySlug: "mrmans0n/alas",
            reviewNumber: 527,
            threadID: "thread-1",
            commentID: "comment-1",
            url: URL(string: "https://github.com/mrmans0n/alas/pull/527#discussion_r1"),
            publishedAt: Date(timeIntervalSince1970: 20)
        )
        #expect(ProviderReviewDraftComment(localDraft: draft) == nil)
    }

    @Test func providerCapabilitiesExposeWriteActions() {
        #expect(CodeHostProviderCapabilities.githubCLI.canPublishReviewComments)
        #expect(CodeHostProviderCapabilities.githubCLI.canReplyToReviewThreads)
        #expect(CodeHostProviderCapabilities.githubCLI.canResolveReviewThreads)
        #expect(CodeHostProviderCapabilities.githubCLI.canUnresolveReviewThreads)
        #expect(CodeHostProviderCapabilities.githubCLI.canApproveReview)
        #expect(CodeHostProviderCapabilities.githubCLI.canRequestChanges)

        #expect(CodeHostProviderCapabilities.gitlabCLI.canPublishReviewComments)
        #expect(CodeHostProviderCapabilities.gitlabCLI.canReplyToReviewThreads)
        #expect(CodeHostProviderCapabilities.gitlabCLI.canResolveReviewThreads)
        #expect(CodeHostProviderCapabilities.gitlabCLI.canUnresolveReviewThreads)
        #expect(CodeHostProviderCapabilities.gitlabCLI.canApproveReview)
        #expect(CodeHostProviderCapabilities.gitlabCLI.canRequestChanges)

        #expect(!CodeHostProviderCapabilities.readOnly.canPublishReviewComments)
        #expect(!CodeHostProviderCapabilities.readOnly.canReplyToReviewThreads)
        #expect(!CodeHostProviderCapabilities.readOnly.canResolveReviewThreads)
        #expect(!CodeHostProviderCapabilities.readOnly.canUnresolveReviewThreads)
        #expect(!CodeHostProviderCapabilities.readOnly.canApproveReview)
        #expect(!CodeHostProviderCapabilities.readOnly.canRequestChanges)
    }
}
