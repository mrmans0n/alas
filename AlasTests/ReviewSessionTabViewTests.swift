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
            )
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
            )
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
            )
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
            )
        )
        let view = ReviewSessionTabView.preview(record: try #require(updated), loaded: loaded)
            .environment(\.theme, try ThemeStore().current)

        let host = NSHostingView(rootView: view.frame(width: 900, height: 700))
        host.layoutSubtreeIfNeeded()

        #expect(recursiveDescription(host).contains("Sent to agent, but failed to save handoff record: save failed"))
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
