import Foundation
import Testing
@testable import Alas

@Suite(.serialized)
struct WorktreeTrashTests {
    @Test func ticketIsAnImmediateRecognizableChildOfTrashRoot() throws {
        let common = URL(fileURLWithPath: "/tmp/repo/.git")
        let original = URL(fileURLWithPath: "/tmp/feature/odd name")
        let id = try #require(UUID(uuidString: "12345678-1234-1234-1234-123456789abc"))

        let ticket = WorktreeTrash.makeTicket(
            commonGitDirectory: common,
            originalPath: original,
            now: Date(timeIntervalSince1970: 1_789_041_600),
            id: id
        )

        #expect(ticket.trashRoot == common.appendingPathComponent("alas/trash").standardizedFileURL)
        #expect(ticket.stagedPath.deletingLastPathComponent().path == ticket.trashRoot.path)
        #expect(ticket.stagedPath.lastPathComponent.hasSuffix(".1789041600.12345678-1234-1234-1234-123456789abc"))
        #expect(WorktreeTrash.isValid(ticket))
        #expect(!WorktreeTrash.isValid(.init(
            trashRoot: ticket.trashRoot,
            stagedPath: ticket.trashRoot.appendingPathComponent("nested/entry")
        )))
        #expect(!WorktreeTrash.isValid(.init(
            trashRoot: URL(fileURLWithPath: "/tmp"),
            stagedPath: URL(fileURLWithPath: "/tmp/worktree.alas-worktree.1.12345678-1234-1234-1234-123456789abc")
        )))
    }

    @Test func staleTicketsKeepOnlyOldValidDirectoriesAndDeduplicateRoots() throws {
        let common = FileManager.default.temporaryDirectory
            .appendingPathComponent("alas-trash-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: common) }
        let old = WorktreeTrash.makeTicket(
            commonGitDirectory: common,
            originalPath: URL(fileURLWithPath: "/tmp/old"),
            now: Date(timeIntervalSince1970: 100),
            id: UUID()
        )
        let young = WorktreeTrash.makeTicket(
            commonGitDirectory: common,
            originalPath: URL(fileURLWithPath: "/tmp/young"),
            now: Date(timeIntervalSince1970: 200),
            id: UUID()
        )
        try FileManager.default.createDirectory(at: old.stagedPath, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: young.stagedPath, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: old.trashRoot.appendingPathComponent("unrecognized"),
            withIntermediateDirectories: true
        )
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSince1970: 100)],
            ofItemAtPath: old.stagedPath.path
        )
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSince1970: 200)],
            ofItemAtPath: young.stagedPath.path
        )

        let tickets = WorktreeTrash.staleTickets(
            commonGitDirectories: [common, common],
            olderThan: Date(timeIntervalSince1970: 150)
        )

        #expect(tickets == [old])
    }
}
