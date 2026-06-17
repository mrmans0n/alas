import Foundation
import Testing
@testable import Alas

@MainActor
struct PendingReviewTests {
    @Test func stagingAddsToList() {
        let pr = PendingReview(worktreePath: .temporaryDirectory.appending(path: UUID().uuidString))
        let comment = StagedComment(
            id: UUID(),
            threadID: "t1",
            filePath: "Sources/Foo.swift",
            line: 42,
            body: "Looks good",
            suggestion: nil
        )
        pr.stage(comment)
        #expect(pr.staged.count == 1)
        #expect(pr.staged[0].body == "Looks good")
    }

    @Test func removeByIDDropsEntry() {
        let pr = PendingReview(worktreePath: .temporaryDirectory.appending(path: UUID().uuidString))
        let c1 = StagedComment(id: UUID(), threadID: nil, filePath: "A.swift", line: 1, body: "c1", suggestion: nil)
        let c2 = StagedComment(id: UUID(), threadID: nil, filePath: "B.swift", line: 2, body: "c2", suggestion: nil)
        pr.stage(c1)
        pr.stage(c2)
        pr.remove(id: c1.id)
        #expect(pr.staged.count == 1)
        #expect(pr.staged[0].id == c2.id)
    }

    @Test func clearEmptiesList() {
        let pr = PendingReview(worktreePath: .temporaryDirectory.appending(path: UUID().uuidString))
        pr.stage(StagedComment(id: UUID(), threadID: nil, filePath: "A.swift", line: 1, body: "x", suggestion: nil))
        pr.clear()
        #expect(pr.staged.isEmpty)
    }

    @Test func persistenceRoundTrip() throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let pr1 = PendingReview(worktreePath: dir)
        let comment = StagedComment(
            id: UUID(),
            threadID: "t1",
            filePath: "Sources/Bar.swift",
            line: 10,
            body: "Needs a test",
            suggestion: "let x = 1"
        )
        pr1.stage(comment)

        let pr2 = PendingReview(worktreePath: dir)
        #expect(pr2.staged.count == 1)
        #expect(pr2.staged[0].body == "Needs a test")
        #expect(pr2.staged[0].suggestion == "let x = 1")
    }
}
