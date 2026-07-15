import Foundation
import Testing
@testable import Alas

@Suite("Review handoff progress")
struct ReviewHandoffProgressTests {
    private func makeRecord(handoffs: [ReviewFeedbackHandoff], status: ReviewSessionStatus) -> ReviewSessionRecord {
        let target = ReviewSessionTarget.localChanges(
            worktreeID: "wt-1",
            repositoryPath: URL(fileURLWithPath: "/repo"),
            scope: .all
        )
        return ReviewSessionRecord(
            id: target.id,
            target: target,
            status: status,
            handoffs: handoffs,
            createdAt: Date(timeIntervalSince1970: 1),
            updatedAt: Date(timeIntervalSince1970: 1)
        )
    }

    private func makeHandoff(id: String, commentIDs: [String], status: ReviewFeedbackHandoffStatus = .sent) -> ReviewFeedbackHandoff {
        ReviewFeedbackHandoff(
            id: id,
            sessionID: ReviewSessionID(rawValue: "session"),
            commentIDs: commentIDs,
            target: .newChat(agentID: "claude", title: "New chat"),
            createdAt: Date(timeIntervalSince1970: 1),
            promptRevision: "rev",
            status: status
        )
    }

    @Test func marksHandoffAndSessionAddressedWhenAllCommentsResolve() throws {
        let record = makeRecord(handoffs: [makeHandoff(id: "h1", commentIDs: ["c1", "c2"])], status: .sent)
        let now = Date(timeIntervalSince1970: 99)

        let updated = ReviewHandoffProgress.recomputingAddressed(
            record: record,
            isResolved: { _ in true },
            now: now
        )

        #expect(updated?.handoffs.map(\.status) == [.addressed])
        #expect(updated?.status == .addressed)
        #expect(updated?.updatedAt == now)
    }

    @Test func leavesPartiallyResolvedHandoffsAlone() throws {
        let record = makeRecord(handoffs: [makeHandoff(id: "h1", commentIDs: ["c1", "c2"])], status: .sent)

        let updated = ReviewHandoffProgress.recomputingAddressed(
            record: record,
            isResolved: { $0 == "c1" },
            now: Date(timeIntervalSince1970: 99)
        )

        #expect(updated == nil)
    }

    @Test func sessionStaysSentWhileAnotherHandoffIsOpen() throws {
        let record = makeRecord(
            handoffs: [
                makeHandoff(id: "h1", commentIDs: ["c1"]),
                makeHandoff(id: "h2", commentIDs: ["c2"]),
            ],
            status: .sent
        )

        let updated = ReviewHandoffProgress.recomputingAddressed(
            record: record,
            isResolved: { $0 == "c1" },
            now: Date(timeIntervalSince1970: 99)
        )

        #expect(updated?.handoffs.map(\.status) == [.addressed, .sent])
        #expect(updated?.status == .sent)
    }

    @Test func recordsWithNoHandoffsNeverChange() throws {
        let record = makeRecord(handoffs: [], status: .active)
        #expect(ReviewHandoffProgress.recomputingAddressed(record: record, isResolved: { _ in true }, now: Date()) == nil)
    }

    @Test func reopeningACommentDemotesAnAddressedHandoffAndSession() throws {
        let record = makeRecord(
            handoffs: [makeHandoff(id: "h1", commentIDs: ["c1"], status: .addressed)],
            status: .addressed
        )
        let now = Date(timeIntervalSince1970: 99)

        let updated = ReviewHandoffProgress.recomputingAddressed(
            record: record,
            isResolved: { _ in false },
            now: now
        )

        #expect(updated?.handoffs.map(\.status) == [.sent])
        #expect(updated?.status == .sent)
        #expect(updated?.updatedAt == now)
    }

    @Test func reopeningLeavesAnArchivedSessionsOwnStatusAlone() throws {
        let record = makeRecord(
            handoffs: [makeHandoff(id: "h1", commentIDs: ["c1"], status: .addressed)],
            status: .archived
        )

        let updated = ReviewHandoffProgress.recomputingAddressed(
            record: record,
            isResolved: { _ in false },
            now: Date(timeIntervalSince1970: 99)
        )

        #expect(updated?.handoffs.map(\.status) == [.sent])
        #expect(updated?.status == .archived)
    }

    @Test func reopeningOneOfTwoAddressedHandoffsDemotesTheSessionButNotItsSibling() throws {
        let record = makeRecord(
            handoffs: [
                makeHandoff(id: "h1", commentIDs: ["c1"], status: .addressed),
                makeHandoff(id: "h2", commentIDs: ["c2"], status: .addressed),
            ],
            status: .addressed
        )

        let updated = ReviewHandoffProgress.recomputingAddressed(
            record: record,
            isResolved: { $0 == "c2" },
            now: Date(timeIntervalSince1970: 99)
        )

        #expect(updated?.handoffs.map(\.status) == [.sent, .addressed])
        #expect(updated?.status == .sent)
    }
}
