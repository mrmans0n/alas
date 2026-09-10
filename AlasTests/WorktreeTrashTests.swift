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
        try WorktreeTrash.markCommitted(old, at: Date(timeIntervalSince1970: 100))
        try WorktreeTrash.markCommitted(young, at: Date(timeIntervalSince1970: 200))
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

    @Test func staleTicketsUseCommitTimeAndIgnoreUncommittedDirectories() throws {
        let common = FileManager.default.temporaryDirectory
            .appendingPathComponent("alas-trash-commit-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: common) }
        let oldCommitted = WorktreeTrash.makeTicket(
            commonGitDirectory: common,
            originalPath: URL(fileURLWithPath: "/tmp/old-committed"),
            now: Date(timeIntervalSince1970: 10),
            id: UUID()
        )
        let newlyCommitted = WorktreeTrash.makeTicket(
            commonGitDirectory: common,
            originalPath: URL(fileURLWithPath: "/tmp/newly-committed"),
            now: Date(timeIntervalSince1970: 20),
            id: UUID()
        )
        let uncommitted = WorktreeTrash.makeTicket(
            commonGitDirectory: common,
            originalPath: URL(fileURLWithPath: "/tmp/uncommitted"),
            now: Date(timeIntervalSince1970: 30),
            id: UUID()
        )
        for ticket in [oldCommitted, newlyCommitted, uncommitted] {
            try FileManager.default.createDirectory(at: ticket.stagedPath, withIntermediateDirectories: true)
            try FileManager.default.setAttributes(
                [.modificationDate: Date(timeIntervalSince1970: 1)],
                ofItemAtPath: ticket.stagedPath.path
            )
        }
        try WorktreeTrash.markCommitted(oldCommitted, at: Date(timeIntervalSince1970: 100))
        try WorktreeTrash.markCommitted(newlyCommitted, at: Date(timeIntervalSince1970: 200))

        let tickets = WorktreeTrash.staleTickets(
            commonGitDirectories: [common],
            olderThan: Date(timeIntervalSince1970: 150)
        )

        #expect(tickets == [oldCommitted])
    }

    @Test func cleanerPassesTheValidatedPathAsAnArgument() throws {
        let ticket = WorktreeTrash.makeTicket(
            commonGitDirectory: URL(fileURLWithPath: "/tmp/repo/.git"),
            originalPath: URL(fileURLWithPath: "/tmp/a name; touch nope")
        )
        var capturedExecutable: URL?
        var capturedArguments: [String] = []

        try WorktreeTrashCleaner.launch(ticket, delaySeconds: 1) { executable, arguments in
            capturedExecutable = executable
            capturedArguments = arguments
        }

        #expect(capturedExecutable?.path == "/usr/bin/nice")
        #expect(capturedArguments.last == ticket.stagedPath.path)
        #expect(capturedArguments.dropLast().last == WorktreeTrash.committedMarkerURL(for: ticket).path)
        #expect(capturedArguments.dropLast().allSatisfy { !$0.contains(ticket.stagedPath.path) })
    }

    @Test func sweepLaunchesOnlyOldTicketsFromUniqueLocalProjects() async throws {
        let repo = FileManager.default.temporaryDirectory
            .appendingPathComponent("alas-sweep-\(UUID().uuidString)")
        let linked = repo.deletingLastPathComponent()
            .appendingPathComponent("\(repo.lastPathComponent)-linked")
        defer {
            try? FileManager.default.removeItem(at: linked)
            try? FileManager.default.removeItem(at: repo)
        }
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        _ = try await Process.git(["init", "-q", "-b", "main"], cwd: repo)
        _ = try await Process.git(["commit", "-q", "--allow-empty", "-m", "init"], cwd: repo)
        _ = try await Process.git(["worktree", "add", "-q", "-b", "linked", linked.path], cwd: repo)

        let common = repo.appendingPathComponent(".git")
        let old = WorktreeTrash.makeTicket(
            commonGitDirectory: common,
            originalPath: linked,
            now: Date(timeIntervalSince1970: 100),
            id: UUID()
        )
        let young = WorktreeTrash.makeTicket(
            commonGitDirectory: common,
            originalPath: linked,
            now: Date(timeIntervalSince1970: 250),
            id: UUID()
        )
        try FileManager.default.createDirectory(at: old.stagedPath, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: young.stagedPath, withIntermediateDirectories: true)
        try WorktreeTrash.markCommitted(old, at: Date(timeIntervalSince1970: 100))
        try WorktreeTrash.markCommitted(young, at: Date(timeIntervalSince1970: 99_990))
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSince1970: 100)],
            ofItemAtPath: old.stagedPath.path
        )
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSince1970: 99_990)],
            ofItemAtPath: young.stagedPath.path
        )

        let addedAt = Date(timeIntervalSince1970: 1)
        let projects = [
            ProjectConfig(id: "main", name: "main", path: repo.path, color: "#000000", addedAt: addedAt),
            ProjectConfig(id: "linked", name: "linked", path: linked.path, color: "#000000", addedAt: addedAt),
            ProjectConfig(id: "remote", name: "remote", path: "/repo", color: "#000000", addedAt: addedAt, host: "host"),
            ProjectConfig(id: "missing", name: "missing", path: "/missing", color: "#000000", addedAt: addedAt),
        ]
        var launched: [WorktreeTrashCleanupTicket] = []

        WorktreeTrashCleaner.sweep(
            projects: projects,
            now: Date(timeIntervalSince1970: 100_000),
            launcher: { launched.append($0) }
        )

        #expect(launched == [old])
    }

    @Test func sweepRecoversCommittedTicketWhenConfiguredLinkedWorktreeWasDeleted() async throws {
        let repo = FileManager.default.temporaryDirectory
            .appendingPathComponent("alas-sweep-deleted-anchor-\(UUID().uuidString)")
        let linked = repo.deletingLastPathComponent()
            .appendingPathComponent("\(repo.lastPathComponent)-linked")
        defer {
            try? FileManager.default.removeItem(at: linked)
            try? FileManager.default.removeItem(at: repo)
        }
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        _ = try await Process.git(["init", "-q", "-b", "main"], cwd: repo)
        _ = try await Process.git(["commit", "-q", "--allow-empty", "-m", "init"], cwd: repo)
        let service = WorktreeService()
        let linkedWorktree = try await service.add(
            repoPath: repo,
            base: "main",
            branch: "linked",
            destination: linked,
            projectId: "linked-project"
        )
        let cachedWorktrees = try await service.list(repoPath: repo, projectId: "linked-project")
        let project = ProjectConfig(
            id: "linked-project",
            name: "linked",
            path: linked.path,
            color: "#000000",
            addedAt: .now,
            cachedWorktrees: cachedWorktrees
        )

        let outcome = try await service.removeFastLocal(
            repoPath: repo,
            worktree: linkedWorktree,
            deleteBranchIfMerged: false,
            force: true
        )
        let ticket: WorktreeTrashCleanupTicket
        switch outcome {
        case .staged(let stagedTicket):
            ticket = stagedTicket
        case .synchronous:
            Issue.record("Expected staged removal")
            return
        }
        defer { try? FileManager.default.removeItem(at: ticket.trashRoot) }
        #expect(throws: CocoaError.self) {
            try WorktreeTrashCleaner.launch(ticket, delaySeconds: 0) { _, _ in
                throw CocoaError(.fileWriteUnknown)
            }
        }

        var recovered: [WorktreeTrashCleanupTicket] = []
        WorktreeTrashCleaner.sweep(
            projects: [project],
            now: Date().addingTimeInterval(48 * 60 * 60),
            launcher: { recovered.append($0) }
        )

        #expect(recovered == [ticket])
    }

    @Test func liveCleanerEventuallyDeletesTheTicketDirectory() async throws {
        let common = FileManager.default.temporaryDirectory
            .appendingPathComponent("alas-cleaner-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: common) }
        let ticket = WorktreeTrash.makeTicket(
            commonGitDirectory: common,
            originalPath: URL(fileURLWithPath: "/tmp/clean-me")
        )
        try FileManager.default.createDirectory(at: ticket.stagedPath, withIntermediateDirectories: true)
        try "marker".write(
            to: ticket.stagedPath.appendingPathComponent("marker.txt"),
            atomically: true,
            encoding: .utf8
        )
        try WorktreeTrash.markCommitted(ticket)
        let committedMarker = WorktreeTrash.committedMarkerURL(for: ticket)

        try WorktreeTrashCleaner.launch(ticket, delaySeconds: 0)
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            let stagedExists = FileManager.default.fileExists(atPath: ticket.stagedPath.path)
            let markerExists = FileManager.default.fileExists(atPath: committedMarker.path)
            if !stagedExists && !markerExists { break }
            try await Task.sleep(for: .milliseconds(20))
        }

        #expect(!FileManager.default.fileExists(atPath: ticket.stagedPath.path))
        #expect(!FileManager.default.fileExists(atPath: committedMarker.path))
    }
}
