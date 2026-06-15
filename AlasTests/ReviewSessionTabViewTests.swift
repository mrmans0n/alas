import AppKit
import Foundation
import SwiftUI
import Testing
@testable import Alas

@MainActor
struct ReviewSessionTabViewTests {
    @Test func initialLoadPublicationDoesNotRequestPersistenceForRestoredSelection() {
        let selected = DiffReviewFileID(namespace: "unstaged", path: "A.swift")
        let target = ReviewSessionTarget.localChanges(
            worktreeID: "wt-1",
            repositoryPath: URL(fileURLWithPath: "/repo"),
            scope: .all
        )
        let record = ReviewSessionRecord(
            id: target.id,
            target: target,
            selectedFileID: selected,
            focusedCommentID: "draft-1",
            createdAt: .init(timeIntervalSince1970: 1),
            updatedAt: .init(timeIntervalSince1970: 20)
        )
        let loaded = ReviewSessionLoadedContext(
            session: DiffReviewLoadedSession(
                files: [Self.file(path: "A.swift", namespace: "unstaged")],
                summary: DiffReviewSessionModel(
                    files: [Self.summary(path: "A.swift", namespace: "unstaged")],
                    groupsEnabled: true
                )
            ),
            feedbackTarget: ReviewFeedbackTarget(
                title: target.title,
                repositoryPath: "/repo",
                providerDescription: nil,
                sourceDescription: target.sourceDescription
            ),
            providerContext: nil
        )

        let publication = ReviewSessionTabLoadPublication.initial(record: record, loaded: loaded)

        #expect(publication.record.updatedAt == Date(timeIntervalSince1970: 20))
        #expect(publication.selectedFileID == selected)
        #expect(publication.focusedDraftCommentID == "draft-1")
        #expect(!publication.shouldPersistSelectionState)
    }

    @Test func loadCoordinatorRejectsOlderCompletionAfterNewerLoadStarts() {
        var coordinator = ReviewSessionTabLoadCoordinator()
        let older = coordinator.begin()
        let newer = coordinator.begin()
        var published = "newer"

        if coordinator.canPublish(older) {
            published = "older"
        }

        #expect(!coordinator.canPublish(older))
        #expect(coordinator.canPublish(newer))
        #expect(published == "newer")

        coordinator.finish(newer)
        #expect(!coordinator.canPublish(older))
    }

    @Test func rendersLoadedSessionTitleAndSummaryRail() throws {
        let target = ReviewSessionTarget.localChanges(
            worktreeID: "wt-1",
            repositoryPath: URL(fileURLWithPath: "/repo"),
            scope: .all
        )
        let record = ReviewSessionRecord(
            id: target.id,
            target: target,
            createdAt: .init(timeIntervalSince1970: 1),
            updatedAt: .init(timeIntervalSince1970: 1)
        )
        let summary = DiffReviewFileSummary(
            path: "A.swift",
            namespace: "unstaged",
            groupID: "unstaged",
            groupTitle: "Unstaged",
            status: .modified,
            additions: 1,
            deletions: 0,
            isRenderable: false
        )
        let loaded = ReviewSessionLoadedContext(
            session: DiffReviewLoadedSession(
                files: [
                    DiffReviewFileSectionModel(
                        summary: summary,
                        parsedDiff: nil,
                        displayModel: nil,
                        placeholderMessage: "No diff",
                        openFile: nil,
                        contextProvider: nil
                    ),
                ],
                summary: DiffReviewSessionModel(files: [summary], groupsEnabled: true)
            ),
            feedbackTarget: ReviewFeedbackTarget(
                title: target.title,
                repositoryPath: "/repo",
                providerDescription: nil,
                sourceDescription: target.sourceDescription
            ),
            providerContext: nil
        )
        let view = ReviewSessionTabView.preview(record: record, loaded: loaded)
            .environment(\.theme, try ThemeStore().current)

        let host = NSHostingView(rootView: view.frame(width: 900, height: 700))
        host.layoutSubtreeIfNeeded()

        #expect(recursiveDescription(host).contains("Review all changes"))
        #expect(subview(withAccessibilityIdentifier: "review-draft-summary-rail", in: host) != nil)
    }

    @Test func rendersSentStateForRecordWithHandoff() throws {
        let target = ReviewSessionTarget.localChanges(
            worktreeID: "wt-1",
            repositoryPath: URL(fileURLWithPath: "/repo"),
            scope: .all
        )
        let handoff = ReviewFeedbackHandoff(
            id: "handoff-1",
            sessionID: target.id,
            commentIDs: ["draft-1"],
            target: .existingSession(worktreeID: "wt-1", sessionID: "acp-1", title: "Codex"),
            createdAt: Date(timeIntervalSince1970: 30),
            promptRevision: "revision-1",
            status: .sent
        )
        let record = ReviewSessionRecord(
            id: target.id,
            target: target,
            handoffs: [handoff],
            createdAt: .init(timeIntervalSince1970: 1),
            updatedAt: .init(timeIntervalSince1970: 30)
        )
        let summary = Self.summary(path: "A.swift", namespace: "unstaged")
        let loaded = ReviewSessionLoadedContext(
            session: DiffReviewLoadedSession(
                files: [Self.file(path: "A.swift", namespace: "unstaged")],
                summary: DiffReviewSessionModel(files: [summary], groupsEnabled: true)
            ),
            feedbackTarget: ReviewFeedbackTarget(
                title: target.title,
                repositoryPath: "/repo",
                providerDescription: nil,
                sourceDescription: target.sourceDescription
            ),
            providerContext: nil
        )
        let view = ReviewSessionTabView.preview(record: record, loaded: loaded)
            .environment(\.theme, try ThemeStore().current)

        let host = NSHostingView(rootView: view.frame(width: 900, height: 700))
        host.layoutSubtreeIfNeeded()

        #expect(recursiveDescription(host).contains("Sent to agent"))
    }

    @Test func handoffPersistenceFailureKeepsSuccessfulSendVisible() throws {
        let target = ReviewSessionTarget.localChanges(
            worktreeID: "wt-1",
            repositoryPath: URL(fileURLWithPath: "/repo"),
            scope: .all
        )
        let handoff = ReviewFeedbackHandoff(
            id: "handoff-1",
            sessionID: target.id,
            commentIDs: ["draft-1"],
            target: .existingSession(worktreeID: "wt-1", sessionID: "acp-1", title: "Codex"),
            createdAt: Date(timeIntervalSince1970: 30),
            promptRevision: "revision-1",
            status: .sent
        )
        let record = ReviewSessionRecord(
            id: target.id,
            target: target,
            createdAt: .init(timeIntervalSince1970: 1),
            updatedAt: .init(timeIntervalSince1970: 1)
        )
        let store = ReviewSessionStore(
            store: FailingPersistenceStore(error: TestPersistenceError()),
            url: URL(fileURLWithPath: "/tmp/review-sessions.json")
        )

        let updated = ReviewSessionHandoffPersistence.record(
            handoff,
            currentRecord: record,
            sessionStore: store,
            persistsState: true,
            now: { Date(timeIntervalSince1970: 40) }
        )

        #expect(updated?.handoffs.isEmpty == true)
        #expect(updated?.lastSendError == "Sent to agent, but failed to save handoff record: save failed")

        let loaded = ReviewSessionLoadedContext(
            session: DiffReviewLoadedSession(
                files: [Self.file(path: "A.swift", namespace: "unstaged")],
                summary: DiffReviewSessionModel(files: [Self.summary(path: "A.swift", namespace: "unstaged")], groupsEnabled: true)
            ),
            feedbackTarget: ReviewFeedbackTarget(
                title: target.title,
                repositoryPath: "/repo",
                providerDescription: nil,
                sourceDescription: target.sourceDescription
            ),
            providerContext: nil
        )
        let view = ReviewSessionTabView.preview(record: try #require(updated), loaded: loaded)
            .environment(\.theme, try ThemeStore().current)

        let host = NSHostingView(rootView: view.frame(width: 900, height: 700))
        host.layoutSubtreeIfNeeded()

        #expect(recursiveDescription(host).contains("Sent to agent, but failed to save handoff record: save failed"))
    }

    @Test func providerMutationControllerPublishesDraftsAndMarksResults() async throws {
        let sessionID = ReviewDraftSessionID.reviewRequest(
            worktreeID: "wt",
            provider: .github,
            host: "github.com",
            repositorySlug: "mrmans0n/alas",
            number: 527
        )
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("alas-provider-mutation-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = ReviewDraftCommentStore(
            store: PersistenceStore(),
            url: directory.appendingPathComponent("drafts.json")
        )
        let draftController = ReviewDraftCommentController(
            sessionID: sessionID,
            store: store,
            now: { Date(timeIntervalSince1970: 200) }
        )
        try draftController.load()
        try draftController.add(
            anchor: DiffReviewLineAnchor(
                path: "Sources/App.swift",
                side: .new,
                line: 12,
                rowIndex: 0,
                selectedText: "let value = 1"
            ),
            fileID: DiffReviewFileID(namespace: "github", path: "Sources/App.swift"),
            bodyMarkdown: "Please fix this."
        )
        let added = try #require(draftController.comments.first)
        let request = Self.reviewRequest(provider: .github)
        let provider = FakeProviderReviewMutator(
            kind: .github,
            result: ProviderReviewPublishResult(
                published: [
                    ProviderReviewPublishedComment(
                        localDraftID: added.id,
                        providerThreadID: "thread-1",
                        providerCommentID: "comment-1",
                        providerURL: URL(string: "https://github.com/mrmans0n/alas/pull/527#discussion_r1")
                    ),
                ],
                failed: [],
                refreshedRequest: request,
                warnings: []
            )
        )
        let controller = ProviderReviewMutationController(
            provider: provider,
            draftController: draftController,
            now: { Date(timeIntervalSince1970: 300) }
        )

        let outcome = try await controller.publishReview(
            remote: request.remote,
            reviewRequest: request,
            decision: .comment,
            summaryBody: "Review from Alas",
            cwd: URL(fileURLWithPath: "/repo")
        )

        #expect(outcome.refreshedRequest.number == 527)
        let updated = try #require(draftController.comments.first)
        #expect(updated.providerPublish?.threadID == "thread-1")
        #expect(updated.providerPublish?.commentID == "comment-1")
        #expect(updated.providerPublish?.publishedAt == Date(timeIntervalSince1970: 300))
        #expect(updated.providerPublish?.provider == .github)
        #expect(updated.providerError == nil)
    }

    @Test func providerMutationControllerKeepsFailedDraftsActiveWithError() async throws {
        let sessionID = ReviewDraftSessionID.reviewRequest(
            worktreeID: "wt",
            provider: .gitlab,
            host: "gitlab.example.com",
            repositorySlug: "platform/alas",
            number: 42
        )
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("alas-provider-mutation-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = ReviewDraftCommentStore(
            store: PersistenceStore(),
            url: directory.appendingPathComponent("drafts.json")
        )
        let draftController = ReviewDraftCommentController(
            sessionID: sessionID,
            store: store,
            now: { Date(timeIntervalSince1970: 200) }
        )
        try draftController.load()
        try draftController.add(
            anchor: DiffReviewLineAnchor(
                path: "Sources/App.swift",
                side: .new,
                line: 12,
                rowIndex: 0,
                selectedText: ""
            ),
            fileID: DiffReviewFileID(namespace: "gitlab", path: "Sources/App.swift"),
            bodyMarkdown: "Please fix this."
        )
        let added = try #require(draftController.comments.first)
        let request = Self.reviewRequest(provider: .gitlab)
        let provider = FakeProviderReviewMutator(
            kind: .gitlab,
            result: ProviderReviewPublishResult(
                published: [],
                failed: [
                    ProviderReviewFailedComment(
                        localDraftID: added.id,
                        message: "line is not commentable"
                    ),
                ],
                refreshedRequest: request,
                warnings: []
            )
        )
        let controller = ProviderReviewMutationController(
            provider: provider,
            draftController: draftController,
            now: { Date(timeIntervalSince1970: 300) }
        )

        _ = try await controller.publishReview(
            remote: request.remote,
            reviewRequest: request,
            decision: .comment,
            summaryBody: "Review from Alas",
            cwd: URL(fileURLWithPath: "/repo")
        )

        let updated = try #require(draftController.comments.first)
        #expect(updated.providerPublish == nil)
        #expect(updated.providerError?.message == "line is not commentable")
        #expect(updated.providerError?.provider == .gitlab)
        #expect(updated.providerError?.occurredAt == Date(timeIntervalSince1970: 300))
        #expect(updated.state == .active)
    }

    @Test func reviewSessionLoadedContextCarriesProviderContextForProviderSessions() async throws {
        let request = Self.reviewRequest(provider: .github)
        let target = ReviewSessionTarget.reviewRequest(
            worktreeID: "wt-1",
            repositoryPath: URL(fileURLWithPath: "/repo"),
            provider: .github,
            host: "github.com",
            repositorySlug: "mrmans0n/alas",
            number: request.number,
            url: request.url,
            title: request.title,
            headSHA: "abc123"
        )
        let providerLoaded = ReviewSessionProviderLoadedSession(
            loadedSession: DiffReviewLoadedSession(files: [], summary: DiffReviewSessionModel(files: [], groupsEnabled: false)),
            providerContext: ReviewSessionProviderContext(remote: request.remote, reviewRequest: request)
        )
        let loader = ReviewSessionLoader(reviewRequest: { target in
            #expect(target.kind == .reviewRequest)
            return providerLoaded
        })

        let loaded = try await loader.load(target: target)

        #expect(loaded.providerContext?.remote == request.remote)
        #expect(loaded.providerContext?.reviewRequest == request)
    }

    @Test func providerMutationControllerFactoryRequiresLoadedProviderContext() throws {
        let request = Self.reviewRequest(provider: .github)
        let session = DiffReviewLoadedSession(files: [], summary: DiffReviewSessionModel(files: [], groupsEnabled: false))
        let providerLoaded = ReviewSessionLoadedContext(
            session: session,
            feedbackTarget: ReviewFeedbackTarget(
                title: "Review provider writes",
                repositoryPath: "/repo",
                providerDescription: "GitHub mrmans0n/alas #527",
                sourceDescription: "PR #527"
            ),
            providerContext: ReviewSessionProviderContext(remote: request.remote, reviewRequest: request)
        )
        let localLoaded = ReviewSessionLoadedContext(
            session: session,
            feedbackTarget: ReviewFeedbackTarget(
                title: "Review all changes",
                repositoryPath: "/repo",
                providerDescription: nil,
                sourceDescription: "Local changes: all"
            ),
            providerContext: nil
        )
        let draftController = ReviewDraftCommentController(
            sessionID: .reviewRequest(
                worktreeID: "wt",
                provider: .github,
                host: "github.com",
                repositorySlug: "mrmans0n/alas",
                number: 527
            ),
            store: ReviewDraftCommentStore(
                store: PersistenceStore(),
                url: FileManager.default.temporaryDirectory
                    .appendingPathComponent("alas-provider-mutation-\(UUID().uuidString).json")
            )
        )
        let provider = FakeProviderReviewMutator(
            kind: .github,
            result: ProviderReviewPublishResult(
                published: [],
                failed: [],
                refreshedRequest: request,
                warnings: []
            )
        )
        let registry = CodeHostProviderRegistry(providers: [.github: provider])

        #expect(ReviewSessionTabView.makeProviderMutationController(
            loaded: providerLoaded,
            draftCommentController: draftController,
            providerRegistry: registry,
            now: Date.init
        ) != nil)
        #expect(ReviewSessionTabView.makeProviderMutationController(
            loaded: localLoaded,
            draftCommentController: draftController,
            providerRegistry: registry,
            now: Date.init
        ) == nil)
        #expect(ReviewSessionTabView.makeProviderMutationController(
            loaded: providerLoaded,
            draftCommentController: nil,
            providerRegistry: registry,
            now: Date.init
        ) == nil)
    }

    @Test func providerPublishConfirmationListsProviderDecisionAndCommentCount() throws {
        var selectedDecision = ProviderReviewDecision.comment
        let view = ProviderReviewPublishConfirmationView(
            providerName: "GitHub",
            reviewIdentity: "PR #527",
            commentCount: 2,
            unpublishableMessages: ["Sources/Old.swift: line is outdated"],
            selectedDecision: Binding(get: { selectedDecision }, set: { selectedDecision = $0 }),
            isPublishing: false,
            errorMessage: nil,
            onCancel: {},
            onConfirm: {}
        )
        .environment(\.theme, try ThemeStore().current)

        let host = NSHostingView(rootView: view.frame(width: 420, height: 260))
        host.layoutSubtreeIfNeeded()
        let description = recursiveDescription(host)

        #expect(description.contains("GitHub"))
        #expect(description.contains("PR #527"))
        #expect(description.contains("2 comments"))
        #expect(description.contains("line is outdated"))
        #expect(subview(withAccessibilityIdentifier: "provider-review-publish-confirmation", in: host) != nil)
    }

    private func recursiveDescription(_ view: NSView) -> String {
        ([view.accessibilityLabel(), view.accessibilityIdentifier()] + view.subviews.map(recursiveDescription))
            .compactMap { $0 }
            .joined(separator: "\n")
    }

    private func subview(withAccessibilityIdentifier identifier: String, in view: NSView) -> NSView? {
        if view.accessibilityIdentifier() == identifier {
            return view
        }
        return view.subviews.lazy.compactMap { subview(withAccessibilityIdentifier: identifier, in: $0) }.first
    }

    private static func summary(path: String, namespace: String) -> DiffReviewFileSummary {
        DiffReviewFileSummary(
            path: path,
            namespace: namespace,
            groupID: namespace,
            groupTitle: "Unstaged",
            status: .modified,
            additions: 1,
            deletions: 0,
            isRenderable: false
        )
    }

    private static func file(path: String, namespace: String) -> DiffReviewFileSectionModel {
        DiffReviewFileSectionModel(
            summary: summary(path: path, namespace: namespace),
            parsedDiff: nil,
            displayModel: nil,
            placeholderMessage: "No diff",
            openFile: nil,
            contextProvider: nil
        )
    }

    private static func remote(kind: CodeHostKind = .github) -> CodeHostRemote {
        let host = kind == .github ? "github.com" : "gitlab.example.com"
        let owner = kind == .github ? "mrmans0n" : "platform"
        return CodeHostRemote(
            kind: kind,
            host: host,
            owner: owner,
            repository: "alas",
            remoteName: "origin",
            webURL: URL(string: "https://\(host)/\(owner)/alas")!
        )
    }

    private static func reviewRequest(provider: CodeHostKind) -> ReviewRequest {
        let remote = Self.remote(kind: provider)
        return ReviewRequest(
            remote: remote,
            number: provider == .github ? 527 : 42,
            title: "Review provider writes",
            url: remote.webURL.appendingPathComponent(provider == .github ? "pull/527" : "merge_requests/42"),
            state: .open,
            isDraft: false,
            headRefName: "feature/provider-writes",
            baseRefName: "main",
            reviewDecision: .unknown,
            mergeState: .unknown,
            checks: [],
            threads: []
        )
    }

    private struct FakeProviderReviewMutator: CodeHostProvider {
        let kind: CodeHostKind
        let result: ProviderReviewPublishResult

        func isAvailable() async -> Bool { true }
        func isAuthenticated(remote: CodeHostRemote, cwd: URL) async -> Bool { true }
        func currentReviewRequest(
            remote: CodeHostRemote,
            branch: String,
            headOwner: String?,
            baseBranch: String,
            cwd: URL
        ) async throws -> ReviewRequest? {
            result.refreshedRequest
        }
        func createReviewRequest(
            remote: CodeHostRemote,
            branch: String,
            headOwner: String?,
            baseBranch: String,
            title: String,
            body: String,
            isDraft: Bool,
            cwd: URL
        ) async throws -> URL {
            result.refreshedRequest.url
        }
        func checks(remote: CodeHostRemote, request: ReviewRequest, cwd: URL) async throws -> [ReviewCheck] { [] }
        func reviewDiff(remote: CodeHostRemote, request: ReviewRequest, cwd: URL) async throws -> String { "" }
        func failedCheckEvidence(remote: CodeHostRemote, request: ReviewRequest, cwd: URL) async throws -> [ReviewEvidenceItem] { [] }
        func checkEvidenceDetail(
            remote: CodeHostRemote,
            request: ReviewRequest,
            item: ReviewEvidenceItem,
            cwd: URL
        ) async throws -> ReviewEvidenceDetail {
            throw CodeHostProviderError.malformedOutput("FakeProviderReviewMutator does not provide check evidence details.")
        }
        func feedbackEvidence(remote: CodeHostRemote, request: ReviewRequest, cwd: URL) async throws -> [ReviewEvidenceItem] { [] }
        func feedbackEvidenceDetail(
            remote: CodeHostRemote,
            request: ReviewRequest,
            item: ReviewEvidenceItem,
            cwd: URL
        ) async throws -> ReviewEvidenceDetail {
            throw CodeHostProviderError.malformedOutput("FakeProviderReviewMutator does not provide feedback evidence details.")
        }
        func rerunFailedChecks(
            remote: CodeHostRemote,
            branch: String,
            headSHA: String,
            request: ReviewRequest?,
            cwd: URL
        ) async throws {}
        func publishReview(_ request: ProviderReviewPublishRequest) async throws -> ProviderReviewPublishResult {
            result
        }
        func mutateReviewThread(_ mutation: ProviderThreadMutation) async throws -> ProviderThreadMutationResult {
            ProviderThreadMutationResult(
                refreshedRequest: result.refreshedRequest,
                providerURL: result.refreshedRequest.url
            )
        }
    }

    private struct TestPersistenceError: LocalizedError {
        var errorDescription: String? { "save failed" }
    }

    private struct FailingPersistenceStore: PersistenceStoreProtocol {
        let error: Error

        func write<T: Encodable>(_ value: T, to url: URL) throws {
            throw error
        }

        func readIfExists<T: Decodable>(_ type: T.Type, from url: URL) throws -> T? {
            nil
        }
    }
}
