import AppKit
import Foundation
import SwiftUI
import Testing
@testable import Alas

@MainActor
@Suite(.serialized)
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

    @Test func handoffFromReopenedSessionDoesNotFollowStaleReplacementAlias() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
            .appendingPathComponent("review-sessions.json")
        let store = ReviewSessionStore(url: url)
        let source = Self.record(id: "source", sha: "source", updatedAt: 1)
        var retargeted = source
        retargeted.id = ReviewSessionID(rawValue: "retargeted")
        retargeted.target = ReviewSessionTarget.commit(
            worktreeID: "wt-1",
            repositoryPath: URL(fileURLWithPath: "/repo"),
            sha: "retargeted",
            title: "Review retargeted"
        )
        retargeted.updatedAt = Date(timeIntervalSince1970: 2)
        var reopened = source
        reopened.updatedAt = Date(timeIntervalSince1970: 3)
        let handoff = Self.handoff(sessionID: source.id)

        try store.save(source)
        try store.replace(id: source.id, with: retargeted)
        try store.save(reopened)

        let updated = ReviewSessionHandoffPersistence.record(
            handoff,
            currentRecord: reopened,
            originRecordID: source.id,
            sessionStore: store,
            persistsState: true,
            now: { Date(timeIntervalSince1970: 4) }
        )

        #expect(updated?.id == source.id)
        #expect(try store.load(id: source.id)?.handoffs == [handoff])
        #expect(try store.loadReplacement(for: source.id)?.handoffs.isEmpty == true)
    }

    @Test func handoffStartedBeforeRetargetStillFollowsReplacementAlias() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
            .appendingPathComponent("review-sessions.json")
        let store = ReviewSessionStore(url: url)
        let source = Self.record(id: "source", sha: "source", updatedAt: 1)
        var retargeted = source
        retargeted.id = ReviewSessionID(rawValue: "retargeted")
        retargeted.updatedAt = Date(timeIntervalSince1970: 2)
        var reopened = source
        reopened.updatedAt = Date(timeIntervalSince1970: 3)
        let handoff = Self.handoff(sessionID: source.id)

        try store.save(source)
        try store.replace(id: source.id, with: retargeted)
        try store.save(reopened)

        let updated = ReviewSessionHandoffPersistence.record(
            handoff,
            currentRecord: retargeted,
            originRecordID: source.id,
            sessionStore: store,
            persistsState: true,
            now: { Date(timeIntervalSince1970: 4) }
        )

        #expect(updated?.id == retargeted.id)
        #expect(try store.loadReplacement(for: source.id)?.handoffs == [handoff])
        #expect(try store.load(id: source.id)?.handoffs.isEmpty == true)
    }

    @Test func sendFailureFromReopenedSessionDoesNotFollowStaleReplacementAlias() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
            .appendingPathComponent("review-sessions.json")
        let store = ReviewSessionStore(url: url)
        let source = Self.record(id: "source", sha: "source", updatedAt: 1)
        var retargeted = source
        retargeted.id = ReviewSessionID(rawValue: "retargeted")
        var reopened = source
        reopened.updatedAt = Date(timeIntervalSince1970: 3)

        try store.save(source)
        try store.replace(id: source.id, with: retargeted)
        try store.save(reopened)

        let updated = ReviewSessionHandoffPersistence.recordSendFailure(
            TestPersistenceError(),
            currentRecord: reopened,
            originRecordID: source.id,
            sessionStore: store,
            persistsState: true,
            now: { Date(timeIntervalSince1970: 4) }
        )

        #expect(updated.id == source.id)
        #expect(try store.load(id: source.id)?.lastSendError == "Failed to send to agent: save failed")
        #expect(try store.loadReplacement(for: source.id)?.lastSendError == nil)
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

    @Test func providerMutationControllerPublishesOnlySelectedDraftIDs() async throws {
        let sessionID = ReviewDraftSessionID.reviewRequest(
            worktreeID: "wt",
            provider: .github,
            host: "github.com",
            repositorySlug: "mrmans0n/alas",
            number: 527
        )
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("alas-provider-selected-publish-\(UUID().uuidString)", isDirectory: true)
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
            bodyMarkdown: "Publish this."
        )
        let selected = try #require(draftController.comments.first)
        try draftController.add(
            anchor: DiffReviewLineAnchor(
                path: "Sources/Other.swift",
                side: .new,
                line: 8,
                rowIndex: 0,
                selectedText: "let other = 1"
            ),
            fileID: DiffReviewFileID(namespace: "github", path: "Sources/Other.swift"),
            bodyMarkdown: "Keep local."
        )
        let request = Self.reviewRequest(provider: .github)
        let provider = RecordingProviderReviewMutator(
            kind: .github,
            publishResult: ProviderReviewPublishResult(
                published: [],
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

        _ = try await controller.publishReview(
            remote: request.remote,
            reviewRequest: request,
            decision: .comment,
            summaryBody: "Review from Alas",
            cwd: URL(fileURLWithPath: "/repo"),
            localDraftIDs: [selected.id]
        )

        let publishedRequest = try #require(provider.publishRequests().first)
        #expect(publishedRequest.comments.map(\.localDraftID) == [selected.id])
    }

    @Test func providerPublishPlannerIgnoresAlreadyPublishedAndInvalidDrafts() {
        var published = Self.providerDraftComment(id: "published")
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
        let valid = Self.providerDraftComment(id: "valid")
        let resolved = Self.providerDraftComment(id: "resolved", state: .resolved)
        let missingAnchor = Self.providerDraftComment(id: "missing-anchor", side: .unknown)
        let empty = Self.providerDraftComment(id: "empty", bodyMarkdown: " \n ")

        let comments = [published, valid, resolved, missingAnchor, empty]

        #expect(ProviderReviewPublishPlanner.publishableDrafts(comments).map(\.id) == ["valid"])
        #expect(ProviderReviewPublishPlanner.unpublishableMessages(comments) == [
            "Sources/published.swift: already published to GitHub.",
            "Sources/resolved.swift: draft is resolved.",
            "Sources/missing-anchor.swift: missing line anchor.",
            "Sources/empty.swift: empty comment.",
        ])
    }

    @Test func providerMutationControllerRejectsStaleSelectedDraftWithoutPublishing() async throws {
        let sessionID = ReviewDraftSessionID.reviewRequest(
            worktreeID: "wt",
            provider: .github,
            host: "github.com",
            repositorySlug: "mrmans0n/alas",
            number: 527
        )
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("alas-provider-stale-selected-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let draftController = ReviewDraftCommentController(
            sessionID: sessionID,
            store: ReviewDraftCommentStore(
                store: PersistenceStore(),
                url: directory.appendingPathComponent("drafts.json")
            )
        )
        try draftController.load()
        let request = Self.reviewRequest(provider: .github)
        let provider = RecordingProviderReviewMutator(
            kind: .github,
            publishResult: ProviderReviewPublishResult(
                published: [],
                failed: [],
                refreshedRequest: request,
                warnings: []
            )
        )
        let controller = ProviderReviewMutationController(
            provider: provider,
            draftController: draftController
        )

        do {
            _ = try await controller.publishReview(
                remote: request.remote,
                reviewRequest: request,
                decision: .comment,
                summaryBody: "Review from Alas",
                cwd: URL(fileURLWithPath: "/repo"),
                localDraftIDs: ["missing-draft"]
            )
            Issue.record("Expected stale selected draft publish to throw")
        } catch let error as ProviderReviewMutationControllerError {
            #expect(error == .noPublishableSelectedDrafts)
        }

        #expect(provider.publishRequests().isEmpty)
    }

    @Test func providerMutationControllerRejectsEmptyCommentReviewWithoutPublishing() async throws {
        let sessionID = ReviewDraftSessionID.reviewRequest(
            worktreeID: "wt",
            provider: .github,
            host: "github.com",
            repositorySlug: "mrmans0n/alas",
            number: 527
        )
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("alas-provider-empty-comment-review-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let draftController = ReviewDraftCommentController(
            sessionID: sessionID,
            store: ReviewDraftCommentStore(
                store: PersistenceStore(),
                url: directory.appendingPathComponent("drafts.json")
            )
        )
        try draftController.load()
        let request = Self.reviewRequest(provider: .github)
        let provider = RecordingProviderReviewMutator(
            kind: .github,
            publishResult: ProviderReviewPublishResult(
                published: [],
                failed: [],
                refreshedRequest: request,
                warnings: []
            )
        )
        let controller = ProviderReviewMutationController(
            provider: provider,
            draftController: draftController
        )

        do {
            _ = try await controller.publishReview(
                remote: request.remote,
                reviewRequest: request,
                decision: .comment,
                summaryBody: "Review from Alas",
                cwd: URL(fileURLWithPath: "/repo")
            )
            Issue.record("Expected empty comment review publish to throw")
        } catch let error as ProviderReviewMutationControllerError {
            #expect(error == .noPublishableDraftsForCommentReview)
        }

        #expect(provider.publishRequests().isEmpty)
    }

    @Test func providerMutationControllerAllowsDecisionOnlyApproveWithoutDrafts() async throws {
        let sessionID = ReviewDraftSessionID.reviewRequest(
            worktreeID: "wt",
            provider: .github,
            host: "github.com",
            repositorySlug: "mrmans0n/alas",
            number: 527
        )
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("alas-provider-decision-only-review-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let draftController = ReviewDraftCommentController(
            sessionID: sessionID,
            store: ReviewDraftCommentStore(
                store: PersistenceStore(),
                url: directory.appendingPathComponent("drafts.json")
            )
        )
        try draftController.load()
        let request = Self.reviewRequest(provider: .github)
        let provider = RecordingProviderReviewMutator(
            kind: .github,
            publishResult: ProviderReviewPublishResult(
                published: [],
                failed: [],
                refreshedRequest: request,
                warnings: []
            )
        )
        let controller = ProviderReviewMutationController(
            provider: provider,
            draftController: draftController
        )

        _ = try await controller.publishReview(
            remote: request.remote,
            reviewRequest: request,
            decision: .approve,
            summaryBody: "Looks good.",
            cwd: URL(fileURLWithPath: "/repo")
        )

        let publishedRequest = try #require(provider.publishRequests().first)
        #expect(publishedRequest.comments.isEmpty)
        #expect(publishedRequest.decision == .approve)
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
        var summaryBody = ""
        let view = ProviderReviewPublishConfirmationView(
            providerName: "GitHub",
            reviewIdentity: "PR #527",
            commentCount: 2,
            unpublishableMessages: ["Sources/Old.swift: line is outdated"],
            allowedDecisions: [.comment, .approve, .requestChanges],
            selectedDecision: Binding(get: { selectedDecision }, set: { selectedDecision = $0 }),
            summaryBody: Binding(get: { summaryBody }, set: { summaryBody = $0 }),
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

    @Test func providerPublishConfirmationDisablesCommentDecisionWithNoComments() throws {
        var selectedDecision = ProviderReviewDecision.comment
        var summaryBody = ""
        var didConfirm = false
        let view = ProviderReviewPublishConfirmationView(
            providerName: "GitHub",
            reviewIdentity: "PR #527",
            commentCount: 0,
            unpublishableMessages: ["Sources/App.swift: already published to GitHub."],
            allowedDecisions: [.comment, .approve, .requestChanges],
            selectedDecision: Binding(get: { selectedDecision }, set: { selectedDecision = $0 }),
            summaryBody: Binding(get: { summaryBody }, set: { summaryBody = $0 }),
            isPublishing: false,
            errorMessage: nil,
            onCancel: {},
            onConfirm: { didConfirm = true }
        )
        .environment(\.theme, try ThemeStore().current)

        let host = NSHostingView(rootView: view.frame(width: 420, height: 260))
        host.layoutSubtreeIfNeeded()

        #expect(!pressAccessibilityElement(withAccessibilityIdentifier: "provider-review-publish-confirm", in: host))
        #expect(!didConfirm)
    }

    @Test func providerPublishConfirmationRequiresSummaryForRequestChanges() throws {
        var selectedDecision = ProviderReviewDecision.requestChanges
        var emptySummaryBody = ""
        var emptyDidConfirm = false
        let emptyView = ProviderReviewPublishConfirmationView(
            providerName: "GitHub",
            reviewIdentity: "PR #527",
            commentCount: 2,
            unpublishableMessages: [],
            allowedDecisions: [.comment, .approve, .requestChanges],
            selectedDecision: Binding(get: { selectedDecision }, set: { selectedDecision = $0 }),
            summaryBody: Binding(get: { emptySummaryBody }, set: { emptySummaryBody = $0 }),
            isPublishing: false,
            errorMessage: nil,
            onCancel: {},
            onConfirm: { emptyDidConfirm = true }
        )
        .environment(\.theme, try ThemeStore().current)

        let emptyHost = NSHostingView(rootView: emptyView.frame(width: 420, height: 360))
        emptyHost.layoutSubtreeIfNeeded()

        #expect(subview(withAccessibilityIdentifier: "provider-review-publish-summary", in: emptyHost) != nil)
        #expect(!pressAccessibilityElement(withAccessibilityIdentifier: "provider-review-publish-confirm", in: emptyHost))
        #expect(!emptyDidConfirm)

        var filledSummaryBody = "Please address the inline notes before merging."
        var filledDidConfirm = false
        let filledView = ProviderReviewPublishConfirmationView(
            providerName: "GitHub",
            reviewIdentity: "PR #527",
            commentCount: 2,
            unpublishableMessages: [],
            allowedDecisions: [.comment, .approve, .requestChanges],
            selectedDecision: Binding(get: { selectedDecision }, set: { selectedDecision = $0 }),
            summaryBody: Binding(get: { filledSummaryBody }, set: { filledSummaryBody = $0 }),
            isPublishing: false,
            errorMessage: nil,
            onCancel: {},
            onConfirm: { filledDidConfirm = true }
        )
        .environment(\.theme, try ThemeStore().current)

        let filledHost = NSHostingView(rootView: filledView.frame(width: 420, height: 360))
        filledHost.layoutSubtreeIfNeeded()

        #expect(pressAccessibilityElement(withAccessibilityIdentifier: "provider-review-publish-confirm", in: filledHost))
        #expect(filledDidConfirm)
    }

    @Test func providerPublishConfirmationHidesUnsupportedReviewDecisions() throws {
        var selectedDecision = ProviderReviewDecision.comment
        var summaryBody = ""
        let view = ProviderReviewPublishConfirmationView(
            providerName: "GitLab",
            reviewIdentity: "MR !42",
            commentCount: 1,
            unpublishableMessages: [],
            allowedDecisions: [.comment, .approve],
            selectedDecision: Binding(get: { selectedDecision }, set: { selectedDecision = $0 }),
            summaryBody: Binding(get: { summaryBody }, set: { summaryBody = $0 }),
            isPublishing: false,
            errorMessage: nil,
            onCancel: {},
            onConfirm: {}
        )
        .environment(\.theme, try ThemeStore().current)

        let host = NSHostingView(rootView: view.frame(width: 420, height: 260))
        host.layoutSubtreeIfNeeded()
        let description = recursiveDescription(host)

        #expect(description.contains("Comment"))
        #expect(description.contains("Approve"))
        #expect(!description.contains("Request changes"))
    }

    @Test func reviewSessionShowsPublishReviewForProviderContextWithDraftsAndOpensPublishConfirmation() async throws {
        let request = Self.reviewRequest(provider: .github)
        let target = Self.reviewRequestTarget(provider: .github, request: request)
        let record = ReviewSessionRecord(
            id: target.id,
            target: target,
            createdAt: Date(timeIntervalSince1970: 1),
            updatedAt: Date(timeIntervalSince1970: 1)
        )
        let loaded = Self.loadedReviewRequestContext(provider: .github, request: request)
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("alas-review-session-publish-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let draftStore = ReviewDraftCommentStore(
            store: PersistenceStore(),
            url: directory.appendingPathComponent("drafts.json")
        )
        let draftController = ReviewDraftCommentController(
            sessionID: target.draftSessionID,
            store: draftStore,
            now: { Date(timeIntervalSince1970: 10) }
        )
        try draftController.load()
        try draftController.add(
            anchor: DiffReviewLineAnchor(
                path: "Sources/App.swift",
                side: .new,
                line: 2,
                rowIndex: 0,
                selectedText: "let b = 3"
            ),
            fileID: loaded.session.files[0].id,
            bodyMarkdown: "Please fix this."
        )
        let provider = RecordingProviderReviewMutator(
            kind: .github,
            publishResult: ProviderReviewPublishResult(
                published: [],
                failed: [],
                refreshedRequest: request,
                warnings: []
            )
        )
        let view = ReviewSessionTabView.testView(
            record: record,
            loaded: loaded,
            draftCommentStore: draftStore,
            provider: provider
        )
        .environment(\.theme, try ThemeStore().current)

        let host = NSHostingView(rootView: view.frame(width: 1200, height: 720))
        host.layoutSubtreeIfNeeded()

        #expect(subview(withAccessibilityIdentifier: "review-draft-summary-publish-review", in: host) != nil)
        #expect(pressAccessibilityElement(withAccessibilityIdentifier: "review-draft-summary-publish-review", in: host))
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        host.layoutSubtreeIfNeeded()
        #expect(subview(withAccessibilityIdentifier: "provider-review-publish-confirmation", in: host) != nil)
        #expect(subview(withAccessibilityIdentifier: "provider-review-publish-confirm", in: host) != nil)
    }

    @Test func reviewSessionShowsPublishReviewForProviderContextWithoutDraftsAndOpensPublishConfirmation() async throws {
        let request = Self.reviewRequest(provider: .github)
        let target = Self.reviewRequestTarget(provider: .github, request: request)
        let record = ReviewSessionRecord(
            id: target.id,
            target: target,
            createdAt: Date(timeIntervalSince1970: 1),
            updatedAt: Date(timeIntervalSince1970: 1)
        )
        let loaded = Self.loadedReviewRequestContext(provider: .github, request: request)
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("alas-review-session-decision-only-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let draftStore = ReviewDraftCommentStore(
            store: PersistenceStore(),
            url: directory.appendingPathComponent("drafts.json")
        )
        let provider = RecordingProviderReviewMutator(
            kind: .github,
            publishResult: ProviderReviewPublishResult(
                published: [],
                failed: [],
                refreshedRequest: request,
                warnings: []
            )
        )
        let view = ReviewSessionTabView.testView(
            record: record,
            loaded: loaded,
            draftCommentStore: draftStore,
            provider: provider
        )
        .environment(\.theme, try ThemeStore().current)

        let host = NSHostingView(rootView: view.frame(width: 1200, height: 720))
        host.layoutSubtreeIfNeeded()

        #expect(subview(withAccessibilityIdentifier: "review-draft-summary-publish-review", in: host) != nil)
        #expect(pressAccessibilityElement(withAccessibilityIdentifier: "review-draft-summary-publish-review", in: host))
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        host.layoutSubtreeIfNeeded()
        #expect(subview(withAccessibilityIdentifier: "provider-review-publish-confirmation", in: host) != nil)
        #expect(subview(withAccessibilityIdentifier: "provider-review-publish-confirm", in: host) != nil)
        #expect(pressAccessibilityElement(withAccessibilityIdentifier: "provider-review-publish-confirm", in: host))
        let deadline = Date().addingTimeInterval(1)
        while provider.publishRequests().isEmpty, Date() < deadline {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        #expect(provider.publishRequests().map(\.decision) == [.approve])
    }

    @Test func reviewSessionShowsProviderPublishWarningsAfterSuccessfulPublish() async throws {
        let request = Self.reviewRequest(provider: .github)
        let target = Self.reviewRequestTarget(provider: .github, request: request)
        let record = ReviewSessionRecord(
            id: target.id,
            target: target,
            createdAt: Date(timeIntervalSince1970: 1),
            updatedAt: Date(timeIntervalSince1970: 1)
        )
        let loaded = Self.loadedReviewRequestContext(provider: .github, request: request)
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("alas-review-session-provider-warning-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let draftStore = ReviewDraftCommentStore(
            store: PersistenceStore(),
            url: directory.appendingPathComponent("drafts.json")
        )
        let provider = RecordingProviderReviewMutator(
            kind: .github,
            publishResult: ProviderReviewPublishResult(
                published: [],
                failed: [],
                refreshedRequest: request,
                warnings: ["Provider comments were published, but the approval was not submitted."]
            )
        )
        let view = ReviewSessionTabView.testView(
            record: record,
            loaded: loaded,
            draftCommentStore: draftStore,
            provider: provider
        )
        .environment(\.theme, try ThemeStore().current)

        let host = NSHostingView(rootView: view.frame(width: 1200, height: 720))
        host.layoutSubtreeIfNeeded()

        #expect(pressAccessibilityElement(withAccessibilityIdentifier: "review-draft-summary-publish-review", in: host))
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        host.layoutSubtreeIfNeeded()
        #expect(pressAccessibilityElement(withAccessibilityIdentifier: "provider-review-publish-confirm", in: host))

        let deadline = Date().addingTimeInterval(1)
        while subview(withAccessibilityIdentifier: "review-session-provider-error", in: host) == nil, Date() < deadline {
            try await Task.sleep(nanoseconds: 10_000_000)
            RunLoop.current.run(until: Date().addingTimeInterval(0.01))
            host.layoutSubtreeIfNeeded()
        }

        let description = recursiveDescription(host)
        #expect(subview(withAccessibilityIdentifier: "provider-review-publish-confirmation", in: host) == nil)
        #expect(subview(withAccessibilityIdentifier: "review-session-provider-error", in: host) != nil)
        #expect(description.contains("approval was not submitted"))
    }

    @Test func reviewSessionShowsProviderFeedbackOpenAndCopyActions() throws {
        let thread = ReviewThreadSummary(
            id: "thread-1",
            author: "reviewer",
            body: "Please fix this.",
            url: URL(string: "https://github.com/mrmans0n/alas/pull/527#discussion_r1"),
            isResolved: false,
            isActionable: true,
            location: ReviewThreadLocation(path: "Sources/App.swift", originalPath: nil, line: 2, side: .new, providerPosition: nil),
            providerThreadID: "thread-provider-1",
            providerCommentID: "comment-provider-1"
        )
        let request = Self.reviewRequest(provider: .github, threads: [thread])
        let target = Self.reviewRequestTarget(provider: .github, request: request)
        let record = ReviewSessionRecord(
            id: target.id,
            target: target,
            createdAt: Date(timeIntervalSince1970: 1),
            updatedAt: Date(timeIntervalSince1970: 1)
        )
        let loaded = Self.loadedReviewRequestContext(provider: .github, request: request)
        let view = ReviewSessionTabView.testView(
            record: record,
            loaded: loaded,
            provider: RecordingProviderReviewMutator(
                kind: .github,
                publishResult: ProviderReviewPublishResult(
                    published: [],
                    failed: [],
                    refreshedRequest: request,
                    warnings: []
                )
            )
        )
        .environment(\.theme, try ThemeStore().current)

        let host = NSHostingView(rootView: view.frame(width: 1200, height: 720))
        host.layoutSubtreeIfNeeded()

        #expect(subview(withAccessibilityIdentifier: "diff-review-inline-feedback-action-open-thread-1", in: host) != nil)
        #expect(subview(withAccessibilityIdentifier: "diff-review-inline-feedback-action-copy-thread-1", in: host) != nil)
    }

    @Test func reviewSessionKeepsNonActionableProviderFeedbackReadOnly() throws {
        let thread = ReviewThreadSummary(
            id: "thread-1",
            author: "reviewer",
            body: "This outdated comment should remain visible.",
            url: URL(string: "https://github.com/mrmans0n/alas/pull/527#discussion_r1"),
            isResolved: false,
            isActionable: false,
            location: ReviewThreadLocation(path: "Sources/App.swift", originalPath: nil, line: 2, side: .new, providerPosition: nil),
            providerThreadID: "thread-provider-1",
            providerCommentID: "comment-provider-1"
        )
        let request = Self.reviewRequest(provider: .github, threads: [thread])
        let target = Self.reviewRequestTarget(provider: .github, request: request)
        let record = ReviewSessionRecord(
            id: target.id,
            target: target,
            createdAt: Date(timeIntervalSince1970: 1),
            updatedAt: Date(timeIntervalSince1970: 1)
        )
        let loaded = Self.loadedReviewRequestContext(provider: .github, request: request)
        let view = ReviewSessionTabView.testView(
            record: record,
            loaded: loaded,
            provider: RecordingProviderReviewMutator(
                kind: .github,
                publishResult: ProviderReviewPublishResult(
                    published: [],
                    failed: [],
                    refreshedRequest: request,
                    warnings: []
                )
            )
        )
        .environment(\.theme, try ThemeStore().current)

        let feedback = try #require(ReviewSessionTabView.inlineFeedbackByFileID(
            threads: [Self.reviewThread(thread)],
            files: [Self.summary(path: "Sources/App.swift", namespace: "github")],
            providerName: "GitHub"
        )[DiffReviewFileID(namespace: "github", path: "Sources/App.swift")]?.first)
        #expect(feedback.status == .unknown)

        let host = NSHostingView(rootView: view.frame(width: 1200, height: 720))
        host.layoutSubtreeIfNeeded()

        #expect(subview(withAccessibilityIdentifier: "diff-review-inline-feedback-action-open-thread-1", in: host) != nil)
        #expect(subview(withAccessibilityIdentifier: "diff-review-inline-feedback-action-copy-thread-1", in: host) != nil)
        #expect(subview(withAccessibilityIdentifier: "diff-review-inline-feedback-action-reply-thread-1", in: host) == nil)
        #expect(subview(withAccessibilityIdentifier: "diff-review-inline-feedback-action-resolve-thread-1", in: host) == nil)
    }

    @Test func reviewSessionShowsProviderThreadMutationFailureOutsidePublishSheet() async throws {
        let thread = ReviewThreadSummary(
            id: "thread-1",
            author: "reviewer",
            body: "Please fix this.",
            url: URL(string: "https://github.com/mrmans0n/alas/pull/527#discussion_r1"),
            isResolved: false,
            isActionable: true,
            location: ReviewThreadLocation(path: "Sources/App.swift", originalPath: nil, line: 2, side: .new, providerPosition: nil),
            providerThreadID: "thread-provider-1",
            providerCommentID: "comment-provider-1"
        )
        let request = Self.reviewRequest(provider: .github, threads: [thread])
        let target = Self.reviewRequestTarget(provider: .github, request: request)
        let record = ReviewSessionRecord(
            id: target.id,
            target: target,
            createdAt: Date(timeIntervalSince1970: 1),
            updatedAt: Date(timeIntervalSince1970: 1)
        )
        let loaded = Self.loadedReviewRequestContext(provider: .github, request: request)
        let view = ReviewSessionTabView.testView(
            record: record,
            loaded: loaded,
            provider: RecordingProviderReviewMutator(
                kind: .github,
                publishResult: ProviderReviewPublishResult(
                    published: [],
                    failed: [],
                    refreshedRequest: request,
                    warnings: []
                ),
                mutationError: CodeHostProviderError.malformedOutput("resolve failed")
            )
        )
        .environment(\.theme, try ThemeStore().current)

        let host = NSHostingView(rootView: view.frame(width: 1200, height: 720))
        host.layoutSubtreeIfNeeded()

        #expect(subview(withAccessibilityIdentifier: "provider-review-publish-confirmation", in: host) == nil)
        #expect(pressAccessibilityElement(withAccessibilityIdentifier: "diff-review-inline-feedback-action-resolve-thread-1", in: host))

        let deadline = Date().addingTimeInterval(1)
        while subview(withAccessibilityIdentifier: "review-session-provider-error", in: host) == nil, Date() < deadline {
            try await Task.sleep(nanoseconds: 10_000_000)
            RunLoop.current.run(until: Date().addingTimeInterval(0.01))
            host.layoutSubtreeIfNeeded()
        }

        let description = recursiveDescription(host)
        #expect(subview(withAccessibilityIdentifier: "provider-review-publish-confirmation", in: host) == nil)
        #expect(subview(withAccessibilityIdentifier: "review-session-provider-error", in: host) != nil)
        #expect(description.contains("resolve failed"))
    }

    @Test func reviewSessionShowsProviderThreadMutationWarningsOutsidePublishSheet() async throws {
        let thread = ReviewThreadSummary(
            id: "thread-1",
            author: "reviewer",
            body: "Please fix this.",
            url: URL(string: "https://github.com/mrmans0n/alas/pull/527#discussion_r1"),
            isResolved: false,
            isActionable: true,
            location: ReviewThreadLocation(path: "Sources/App.swift", originalPath: nil, line: 2, side: .new, providerPosition: nil),
            providerThreadID: "thread-provider-1",
            providerCommentID: "comment-provider-1"
        )
        let request = Self.reviewRequest(provider: .github, threads: [thread])
        let target = Self.reviewRequestTarget(provider: .github, request: request)
        let record = ReviewSessionRecord(
            id: target.id,
            target: target,
            createdAt: Date(timeIntervalSince1970: 1),
            updatedAt: Date(timeIntervalSince1970: 1)
        )
        let loaded = Self.loadedReviewRequestContext(provider: .github, request: request)
        let view = ReviewSessionTabView.testView(
            record: record,
            loaded: loaded,
            provider: RecordingProviderReviewMutator(
                kind: .github,
                publishResult: ProviderReviewPublishResult(
                    published: [],
                    failed: [],
                    refreshedRequest: request,
                    warnings: []
                ),
                mutationWarnings: ["GitHub thread was updated, but Alas could not refresh the PR: temporary API failure"]
            )
        )
        .environment(\.theme, try ThemeStore().current)

        let host = NSHostingView(rootView: view.frame(width: 1200, height: 720))
        host.layoutSubtreeIfNeeded()

        #expect(subview(withAccessibilityIdentifier: "provider-review-publish-confirmation", in: host) == nil)
        #expect(pressAccessibilityElement(withAccessibilityIdentifier: "diff-review-inline-feedback-action-resolve-thread-1", in: host))

        let deadline = Date().addingTimeInterval(1)
        while subview(withAccessibilityIdentifier: "review-session-provider-error", in: host) == nil, Date() < deadline {
            try await Task.sleep(nanoseconds: 10_000_000)
            RunLoop.current.run(until: Date().addingTimeInterval(0.01))
            host.layoutSubtreeIfNeeded()
        }

        let description = recursiveDescription(host)
        #expect(subview(withAccessibilityIdentifier: "provider-review-publish-confirmation", in: host) == nil)
        #expect(subview(withAccessibilityIdentifier: "review-session-provider-error", in: host) != nil)
        #expect(description.contains("could not refresh the PR"))
    }

    @Test func fileIDLookupFindsFeedbackOwningFile() {
        let fileA = DiffReviewFileID(namespace: "github", path: "A.swift")
        let fileB = DiffReviewFileID(namespace: "github", path: "B.swift")
        func feedback(_ id: String, path: String) -> DiffReviewInlineFeedback {
            DiffReviewInlineFeedback(
                id: id,
                providerName: "GitHub",
                author: "reviewer",
                bodyPreview: "body",
                status: .actionable,
                providerURL: nil,
                anchor: DiffReviewInlineFeedbackAnchor(path: path, line: 1, side: .new),
                evidenceItemID: id
            )
        }
        let grouped: [DiffReviewFileID: [DiffReviewInlineFeedback]] = [
            fileA: [feedback("fb-a", path: "A.swift")],
            fileB: [feedback("fb-b", path: "B.swift")],
        ]

        #expect(ReviewSessionTabView.fileID(forFeedbackID: "fb-b", in: grouped) == fileB)
        #expect(ReviewSessionTabView.fileID(forFeedbackID: "missing", in: grouped) == nil)
    }

    @Test func selectingGitHubFeedbackInRailFocusesItInDiff() throws {
        let thread = ReviewThreadSummary(
            id: "thread-1",
            author: "reviewer",
            body: "Please fix this.",
            url: URL(string: "https://github.com/mrmans0n/alas/pull/527#discussion_r1"),
            isResolved: false,
            isActionable: true,
            location: ReviewThreadLocation(path: "Sources/App.swift", originalPath: nil, line: 2, side: .new, providerPosition: nil),
            providerThreadID: "thread-provider-1",
            providerCommentID: "comment-provider-1"
        )
        let request = Self.reviewRequest(provider: .github, threads: [thread])
        let target = Self.reviewRequestTarget(provider: .github, request: request)
        let record = ReviewSessionRecord(
            id: target.id,
            target: target,
            createdAt: Date(timeIntervalSince1970: 1),
            updatedAt: Date(timeIntervalSince1970: 1)
        )
        let loaded = Self.loadedReviewRequestContext(provider: .github, request: request)
        let view = ReviewSessionTabView.testView(
            record: record,
            loaded: loaded,
            provider: RecordingProviderReviewMutator(
                kind: .github,
                publishResult: ProviderReviewPublishResult(
                    published: [],
                    failed: [],
                    refreshedRequest: request,
                    warnings: []
                )
            )
        )
        .environment(\.theme, try ThemeStore().current)

        let host = NSHostingView(rootView: view.frame(width: 1200, height: 720))
        host.layoutSubtreeIfNeeded()

        #expect(subview(withAccessibilityIdentifier: "review-summary-feedback-thread-1", in: host) != nil)
        #expect(subview(withAccessibilityIdentifier: "diff-review-inline-feedback-focused-thread-1", in: host) == nil)

        #expect(pressAccessibilityElement(withAccessibilityIdentifier: "review-summary-feedback-thread-1", in: host))

        let deadline = Date().addingTimeInterval(1)
        while subview(withAccessibilityIdentifier: "diff-review-inline-feedback-focused-thread-1", in: host) == nil,
              Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.01))
            host.layoutSubtreeIfNeeded()
        }

        #expect(subview(withAccessibilityIdentifier: "diff-review-inline-feedback-focused-thread-1", in: host) != nil)
    }

    @Test func externalCommentChangeReloadsTheSessionRecordNotJustDraftComments() throws {
        let target = ReviewSessionTarget.localChanges(
            worktreeID: "wt-1",
            repositoryPath: URL(fileURLWithPath: "/repo"),
            scope: .all
        )
        let initialRecord = ReviewSessionRecord(
            id: target.id,
            target: target,
            createdAt: Date(timeIntervalSince1970: 1),
            updatedAt: Date(timeIntervalSince1970: 1)
        )
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("alas-review-session-external-reload-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let sessionStore = ReviewSessionStore(url: directory.appendingPathComponent("sessions.json"))

        // Simulate what an external `review_resolve` already wrote to disk
        // (e.g. a handoff/session flipped to addressed) before this tab
        // reacts to the change notification.
        var externallyUpdatedRecord = initialRecord
        externallyUpdatedRecord.lastSendError = "external change reached the disk"
        try sessionStore.save(externallyUpdatedRecord)

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
        let request = Self.reviewRequest(provider: .github)
        let view = ReviewSessionTabView.testView(
            record: initialRecord,
            loaded: loaded,
            sessionStore: sessionStore,
            provider: FakeProviderReviewMutator(
                kind: .github,
                result: ProviderReviewPublishResult(published: [], failed: [], refreshedRequest: request, warnings: [])
            )
        )
        .environment(\.theme, try ThemeStore().current)

        let host = NSHostingView(rootView: view.frame(width: 900, height: 700))
        host.layoutSubtreeIfNeeded()
        #expect(!recursiveDescription(host).contains("external change reached the disk"))

        NotificationCenter.default.post(name: .alasReviewDraftCommentsDidChangeExternally, object: nil)
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        host.layoutSubtreeIfNeeded()

        #expect(recursiveDescription(host).contains("external change reached the disk"))
    }

    @Test func providerFeedbackMatcherPrefersExactOldSidePathWhenOriginalPathIsMissing() {
        let modified = DiffReviewFileSummary(
            path: "Sources/App.swift",
            namespace: "github-pr",
            groupID: nil,
            groupTitle: nil,
            status: .modified,
            additions: 1,
            deletions: 1,
            isRenderable: true
        )
        let copied = DiffReviewFileSummary(
            path: "Sources/CopiedApp.swift",
            namespace: "github-pr",
            groupID: nil,
            groupTitle: nil,
            status: .copied,
            additions: 1,
            deletions: 0,
            isRenderable: true,
            originalPath: "Sources/App.swift"
        )
        let matcher = ReviewSessionInlineFeedbackFileMatcher(files: [modified, copied])

        let match = matcher.file(for: ReviewThreadLocation(
            path: "Sources/App.swift",
            originalPath: nil,
            line: 7,
            side: .old,
            providerPosition: nil
        ))

        #expect(match?.path == "Sources/App.swift")
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

    private func subviews(withAccessibilityIdentifier identifier: String, in view: NSView) -> [NSView] {
        var matches: [NSView] = []
        if view.accessibilityIdentifier() == identifier {
            matches.append(view)
        }
        matches.append(contentsOf: view.subviews.flatMap { subviews(withAccessibilityIdentifier: identifier, in: $0) })
        return matches
    }

    private func pressAccessibilityElement(withAccessibilityIdentifier identifier: String, in view: NSView) -> Bool {
        for match in subviews(withAccessibilityIdentifier: identifier, in: view) {
            if match.accessibilityPerformPress() {
                return true
            }
        }
        return false
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

    private static func reviewRequest(provider: CodeHostKind, threads: [ReviewThreadSummary] = []) -> ReviewRequest {
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
            threads: threads.map(Self.reviewThread)
        )
    }

    private static func reviewThread(_ summary: ReviewThreadSummary) -> ReviewThread {
        ReviewThread(
            id: summary.id,
            path: summary.location?.path,
            line: summary.location?.line,
            startLine: nil,
            originalLine: nil,
            diffHunk: nil,
            isResolved: summary.isResolved,
            isOutdated: !summary.isActionable,
            isFileLevel: summary.location?.line == nil,
            comments: [
                ReviewComment(
                    id: summary.providerCommentID ?? summary.id,
                    author: summary.author,
                    body: summary.body,
                    url: summary.url,
                    createdAt: nil,
                    viewerCanUpdate: true,
                    viewerCanDelete: true,
                    isPending: false
                ),
            ],
            viewerCanResolve: summary.isActionable,
            viewerCanReply: summary.isActionable,
            url: summary.url
        )
    }

    private static func providerDraftComment(
        id: String,
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
            originalPath: nil,
            side: side,
            startLine: 12,
            endLine: nil,
            selectedText: "let value = 1",
            bodyMarkdown: bodyMarkdown,
            state: state,
            createdAt: Date(timeIntervalSince1970: 1),
            updatedAt: Date(timeIntervalSince1970: 2)
        )
    }

    private static func reviewRequestTarget(provider: CodeHostKind, request: ReviewRequest) -> ReviewSessionTarget {
        ReviewSessionTarget.reviewRequest(
            worktreeID: "wt",
            repositoryPath: URL(fileURLWithPath: "/repo"),
            provider: provider,
            host: request.remote.host,
            repositorySlug: request.remote.repositorySlug,
            number: request.number,
            url: request.url,
            title: request.title,
            headSHA: "abc123"
        )
    }

    private static func loadedReviewRequestContext(provider: CodeHostKind, request: ReviewRequest) -> ReviewSessionLoadedContext {
        let summary = DiffReviewFileSummary(
            path: "Sources/App.swift",
            namespace: provider == .github ? "github-pr" : "gitlab-mr",
            groupID: nil,
            groupTitle: nil,
            status: .modified,
            additions: 1,
            deletions: 1,
            isRenderable: true
        )
        return ReviewSessionLoadedContext(
            session: DiffReviewLoadedSession(
                files: [
                    DiffReviewFileSectionModel(
                        summary: summary,
                        parsedDiff: parsedDiff(),
                        displayModel: displayModel(),
                        placeholderMessage: nil,
                        openFile: nil,
                        contextProvider: nil
                    ),
                ],
                summary: DiffReviewSessionModel(files: [summary], groupsEnabled: false)
            ),
            feedbackTarget: ReviewFeedbackTarget(
                title: request.title,
                repositoryPath: "/repo",
                providerDescription: request.displayIdentity,
                sourceDescription: request.displayIdentity
            ),
            providerContext: ReviewSessionProviderContext(remote: request.remote, reviewRequest: request)
        )
    }

    private static func parsedDiff() -> ParsedDiff {
        DiffParser.parse("""
        diff --git a/Sources/App.swift b/Sources/App.swift
        --- a/Sources/App.swift
        +++ b/Sources/App.swift
        @@ -1,2 +1,2 @@
         let a = 1
        -let b = 2
        +let b = 3
        """)
    }

    private static func displayModel() -> DiffDisplayModel {
        DiffDisplayModelBuilder.build(diff: parsedDiff(), filePath: "Sources/App.swift")
    }

    private struct FakeProviderReviewMutator: CodeHostProvider {
        let kind: CodeHostKind
        let result: ProviderReviewPublishResult

        func isAvailable(cwd: URL) async -> Bool { true }
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

    private final class RecordingProviderReviewMutator: CodeHostProvider, @unchecked Sendable {
        let kind: CodeHostKind
        let capabilities: CodeHostProviderCapabilities
        private let publishResult: ProviderReviewPublishResult
        private let mutationError: Error?
        private let mutationWarnings: [String]
        private let lock = NSLock()
        private var recordedPublishRequests: [ProviderReviewPublishRequest] = []

        init(
            kind: CodeHostKind,
            capabilities: CodeHostProviderCapabilities = .githubCLI,
            publishResult: ProviderReviewPublishResult,
            mutationError: Error? = nil,
            mutationWarnings: [String] = []
        ) {
            self.kind = kind
            self.capabilities = capabilities
            self.publishResult = publishResult
            self.mutationError = mutationError
            self.mutationWarnings = mutationWarnings
        }

        func publishRequests() -> [ProviderReviewPublishRequest] {
            lock.lock()
            defer { lock.unlock() }
            return recordedPublishRequests
        }

        func isAvailable(cwd: URL) async -> Bool { true }
        func isAuthenticated(remote: CodeHostRemote, cwd: URL) async -> Bool { true }
        func currentReviewRequest(
            remote: CodeHostRemote,
            branch: String,
            headOwner: String?,
            baseBranch: String,
            cwd: URL
        ) async throws -> ReviewRequest? {
            publishResult.refreshedRequest
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
            publishResult.refreshedRequest.url
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
            throw CodeHostProviderError.malformedOutput("RecordingProviderReviewMutator does not provide check evidence details.")
        }
        func feedbackEvidence(remote: CodeHostRemote, request: ReviewRequest, cwd: URL) async throws -> [ReviewEvidenceItem] { [] }
        func feedbackEvidenceDetail(
            remote: CodeHostRemote,
            request: ReviewRequest,
            item: ReviewEvidenceItem,
            cwd: URL
        ) async throws -> ReviewEvidenceDetail {
            throw CodeHostProviderError.malformedOutput("RecordingProviderReviewMutator does not provide feedback evidence details.")
        }
        func rerunFailedChecks(
            remote: CodeHostRemote,
            branch: String,
            headSHA: String,
            request: ReviewRequest?,
            cwd: URL
        ) async throws {}
        func publishReview(_ request: ProviderReviewPublishRequest) async throws -> ProviderReviewPublishResult {
            lock.lock()
            recordedPublishRequests.append(request)
            lock.unlock()
            return publishResult
        }
        func mutateReviewThread(_ mutation: ProviderThreadMutation) async throws -> ProviderThreadMutationResult {
            if let mutationError {
                throw mutationError
            }
            return ProviderThreadMutationResult(
                refreshedRequest: publishResult.refreshedRequest,
                providerURL: publishResult.refreshedRequest.url,
                warnings: mutationWarnings
            )
        }
    }

    private static func record(id: String, sha: String, updatedAt: TimeInterval) -> ReviewSessionRecord {
        let target = ReviewSessionTarget.commit(
            worktreeID: "wt-1",
            repositoryPath: URL(fileURLWithPath: "/repo"),
            sha: sha,
            title: "Review \(sha)"
        )
        return ReviewSessionRecord(
            id: ReviewSessionID(rawValue: id),
            target: target,
            createdAt: Date(timeIntervalSince1970: 1),
            updatedAt: Date(timeIntervalSince1970: updatedAt)
        )
    }

    private static func handoff(sessionID: ReviewSessionID) -> ReviewFeedbackHandoff {
        ReviewFeedbackHandoff(
            id: "handoff-1",
            sessionID: sessionID,
            commentIDs: ["draft-1"],
            target: .existingSession(worktreeID: "wt-1", sessionID: "acp-1", title: "Codex"),
            createdAt: Date(timeIntervalSince1970: 30),
            promptRevision: "revision-1",
            status: .sent
        )
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
