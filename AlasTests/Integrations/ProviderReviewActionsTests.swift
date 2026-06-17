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
        #expect(CodeHostProviderCapabilities.githubCLI.canComment)
        #expect(CodeHostProviderCapabilities.githubCLI.canReply)
        #expect(CodeHostProviderCapabilities.githubCLI.canResolve)
        #expect(CodeHostProviderCapabilities.githubCLI.canEditComment)
        #expect(CodeHostProviderCapabilities.githubCLI.canDeleteComment)
        #expect(CodeHostProviderCapabilities.githubCLI.canSubmitReview)

        #expect(CodeHostProviderCapabilities.gitlabCLI.canComment)
        #expect(CodeHostProviderCapabilities.gitlabCLI.canReply)
        #expect(CodeHostProviderCapabilities.gitlabCLI.canResolve)
        #expect(CodeHostProviderCapabilities.gitlabCLI.canEditComment)
        #expect(CodeHostProviderCapabilities.gitlabCLI.canDeleteComment)
        #expect(CodeHostProviderCapabilities.gitlabCLI.canSubmitReview)

        #expect(!CodeHostProviderCapabilities.readOnly.canComment)
        #expect(!CodeHostProviderCapabilities.readOnly.canReply)
        #expect(!CodeHostProviderCapabilities.readOnly.canResolve)
        #expect(!CodeHostProviderCapabilities.readOnly.canEditComment)
        #expect(!CodeHostProviderCapabilities.readOnly.canDeleteComment)
        #expect(!CodeHostProviderCapabilities.readOnly.canSubmitReview)
    }
}
