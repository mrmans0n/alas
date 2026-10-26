import Foundation
import Testing
@testable import AlasCore

/// `ProviderReviewPublisher` is `@MainActor`, and the `record` closures below
/// mutate test-local state.
@MainActor
struct ProviderReviewPublisherTests {
    private actor RecordingPublisher: CodeHostProvider {
        nonisolated let kind: CodeHostKind = .github
        let result: ProviderReviewPublishResult
        private(set) var requests: [ProviderReviewPublishRequest] = []

        init(result: ProviderReviewPublishResult) {
            self.result = result
        }

        func publishReview(_ request: ProviderReviewPublishRequest) async throws -> ProviderReviewPublishResult {
            requests.append(request)
            return result
        }

        func isAvailable(cwd: URL) async -> Bool { true }
        func isAuthenticated(remote: CodeHostRemote, cwd: URL) async -> Bool { true }
        func currentReviewRequest(
            remote: CodeHostRemote, branch: String, headOwner: String?, baseBranch: String, cwd: URL
        ) async throws -> ReviewRequest? {
            nil
        }
        func createReviewRequest(
            remote: CodeHostRemote, branch: String, headOwner: String?, baseBranch: String,
            title: String, body: String, isDraft: Bool, cwd: URL
        ) async throws -> URL {
            throw CodeHostProviderError.unsupportedProvider(kind)
        }
        func checks(remote: CodeHostRemote, request: ReviewRequest, cwd: URL) async throws -> [ReviewCheck] { [] }
        func rerunFailedChecks(
            remote: CodeHostRemote, branch: String, headSHA: String, request: ReviewRequest?, cwd: URL
        ) async throws {}
    }

    private static let remote = CodeHostRemote(
        kind: .github,
        host: "github.com",
        owner: "mrmans0n",
        repository: "alas",
        remoteName: "origin",
        webURL: URL(string: "https://github.com/mrmans0n/alas")!
    )

    private static let request = ReviewRequest(
        remote: remote,
        number: 527,
        title: "Review provider writes",
        url: URL(string: "https://github.com/mrmans0n/alas/pull/527")!,
        state: .open,
        isDraft: false,
        headRefName: "feature/provider-writes",
        baseRefName: "main",
        reviewDecision: .unknown,
        mergeState: .unknown,
        checks: [],
        threads: []
    )

    private static func draft(
        _ id: String,
        side: DiffReviewInlineFeedbackSide = .new,
        state: ReviewDraftCommentState = .active,
        bodyMarkdown: String = "Please fix this."
    ) -> ReviewDraftComment {
        ReviewDraftComment(
            id: id,
            sessionID: .reviewRequest(
                worktreeID: "wt",
                provider: .github,
                host: "github.com",
                repositorySlug: "mrmans0n/alas",
                number: 527
            ),
            fileID: DiffReviewFileID(namespace: "github-pr", path: "Sources/\(id).swift"),
            path: "Sources/\(id).swift",
            side: side,
            startLine: 12,
            selectedText: "let value = 1",
            bodyMarkdown: bodyMarkdown,
            state: state,
            createdAt: Date(timeIntervalSince1970: 1),
            updatedAt: Date(timeIntervalSince1970: 2)
        )
    }

    private static func emptyResult() -> ProviderReviewPublishResult {
        ProviderReviewPublishResult(published: [], failed: [], refreshedRequest: request, warnings: [])
    }

    @Test func publishRecordsEachDraftsOutcome() async throws {
        let now = Date(timeIntervalSince1970: 300)
        let provider = RecordingPublisher(result: ProviderReviewPublishResult(
            published: [
                ProviderReviewPublishedComment(
                    localDraftID: "a", providerThreadID: "t1", providerCommentID: "c1", providerURL: nil
                ),
            ],
            failed: [ProviderReviewFailedComment(localDraftID: "b", message: "line is not commentable")],
            refreshedRequest: Self.request,
            warnings: []
        ))
        var recorded: [(String, ProviderReviewDraftOutcome)] = []

        _ = try await ProviderReviewPublisher.publish(
            [Self.draft("a"), Self.draft("b")], selecting: nil,
            to: Self.request, remote: Self.remote,
            decision: .comment, summaryBody: "", cwd: URL(fileURLWithPath: "/repo"),
            provider: provider, now: { now },
            record: { recorded.append(($0, $1)) }
        )

        let published = ReviewDraftProviderPublish(
            provider: .github, host: "github.com", repositorySlug: "mrmans0n/alas", reviewNumber: 527,
            threadID: "t1", commentID: "c1", url: nil, publishedAt: now
        )
        let failed = ReviewDraftProviderError(provider: .github, message: "line is not commentable", occurredAt: now)
        #expect(recorded.map(\.0) == ["a", "b"])
        #expect(recorded.map(\.1) == [.published(published), .failed(failed)])
    }

    @Test(arguments: [
        (["a"], ProviderReviewDecision.comment, ["a"], nil),
        (["missing"], .comment, nil, ProviderReviewPublishError.noPublishableSelectedDrafts),
        (nil, .comment, nil, .noPublishableDraftsForCommentReview),
        (nil, .approve, [], nil),
    ] as [([String]?, ProviderReviewDecision, [String]?, ProviderReviewPublishError?)])
    func whatAPublishSends(
        ids: [String]?, decision: ProviderReviewDecision, sent: [String]?, refusal: ProviderReviewPublishError?
    ) async throws {
        let provider = RecordingPublisher(result: Self.emptyResult())
        let drafts = ids == nil ? [] : [Self.draft("a")]
        let publish = {
            try await ProviderReviewPublisher.publish(
                drafts, selecting: ids.map(Set.init),
                to: Self.request, remote: Self.remote,
                decision: decision, summaryBody: "", cwd: URL(fileURLWithPath: "/repo"),
                provider: provider, now: Date.init,
                record: { _, _ in }
            )
        }

        if let refusal {
            await #expect(throws: refusal) { _ = try await publish() }
            #expect(await provider.requests.isEmpty)
        } else {
            _ = try await publish()
            let requests = await provider.requests
            #expect(requests.map { $0.comments.map(\.localDraftID) } == [sent ?? []])
            #expect(requests.map(\.decision) == [decision])
        }
    }

    @Test func publishPlannerIgnoresAlreadyPublishedAndInvalidDrafts() {
        var published = Self.draft("published")
        published.providerPublish = ReviewDraftProviderPublish(
            provider: .github,
            host: "github.com",
            repositorySlug: "mrmans0n/alas",
            reviewNumber: 527,
            threadID: "thread-1",
            commentID: "comment-1",
            url: nil,
            publishedAt: Date(timeIntervalSince1970: 20)
        )
        let valid = Self.draft("valid")
        let resolved = Self.draft("resolved", state: .resolved)
        let missingAnchor = Self.draft("missing-anchor", side: .unknown)
        let empty = Self.draft("empty", bodyMarkdown: " \n ")

        let comments = [published, valid, resolved, missingAnchor, empty]

        #expect(ProviderReviewPublishPlanner.publishableDrafts(comments).map(\.id) == ["valid"])
        #expect(ProviderReviewPublishPlanner.unpublishableMessages(comments) == [
            "Sources/published.swift: already published to GitHub.",
            "Sources/resolved.swift: draft is resolved.",
            "Sources/missing-anchor.swift: missing line anchor.",
            "Sources/empty.swift: empty comment.",
        ])
    }
}
