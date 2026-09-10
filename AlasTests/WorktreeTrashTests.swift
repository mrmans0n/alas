import Foundation
import Testing
@testable import Alas

@Suite(.serialized)
struct WorktreeTrashTests {
    @Test func ticketIsAnImmediateRecognizableChildOfTrashRoot() throws {
        let common = FileManager.default.temporaryDirectory
            .appendingPathComponent("alas-ticket-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: common) }
        let id = try #require(UUID(uuidString: "12345678-1234-1234-1234-123456789abc"))

        let ticket = try makeStagedTicket(
            commonGitDirectory: common,
            originalBaseName: "odd name",
            now: Date(timeIntervalSince1970: 1_789_041_600),
            id: id
        )

        #expect(ticket.trashRoot.path == common.appendingPathComponent("alas/trash").standardizedFileURL.path)
        #expect(ticket.stagedPath.deletingLastPathComponent().path == ticket.trashRoot.path)
        #expect(ticket.stagedPath.lastPathComponent.hasSuffix(".1789041600.12345678-1234-1234-1234-123456789abc"))
        #expect(WorktreeTrash.isValid(ticket))
        #expect(!WorktreeTrash.isValid(.init(
            trashRoot: ticket.trashRoot,
            stagedPath: ticket.trashRoot.appendingPathComponent("nested/entry"),
            directoryIdentity: ticket.directoryIdentity
        )))
        #expect(!WorktreeTrash.isValid(.init(
            trashRoot: URL(fileURLWithPath: "/tmp"),
            stagedPath: URL(fileURLWithPath: "/tmp/worktree.alas-worktree.1.12345678-1234-1234-1234-123456789abc"),
            directoryIdentity: ticket.directoryIdentity
        )))
    }

    @Test func staleTicketsKeepOnlyOldValidDirectoriesAndDeduplicateRoots() throws {
        let common = FileManager.default.temporaryDirectory
            .appendingPathComponent("alas-trash-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: common) }
        let old = try makeStagedTicket(
            commonGitDirectory: common,
            originalBaseName: "old",
            now: Date(timeIntervalSince1970: 100),
            id: UUID()
        )
        let young = try makeStagedTicket(
            commonGitDirectory: common,
            originalBaseName: "young",
            now: Date(timeIntervalSince1970: 200),
            id: UUID()
        )
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
        let oldCommitted = try makeStagedTicket(
            commonGitDirectory: common,
            originalBaseName: "old-committed",
            now: Date(timeIntervalSince1970: 10),
            id: UUID()
        )
        let newlyCommitted = try makeStagedTicket(
            commonGitDirectory: common,
            originalBaseName: "newly-committed",
            now: Date(timeIntervalSince1970: 20),
            id: UUID()
        )
        let uncommitted = try makeStagedTicket(
            commonGitDirectory: common,
            originalBaseName: "uncommitted",
            now: Date(timeIntervalSince1970: 30),
            id: UUID()
        )
        for ticket in [oldCommitted, newlyCommitted, uncommitted] {
            try FileManager.default.setAttributes(
                [.modificationDate: Date(timeIntervalSince1970: 1)],
                ofItemAtPath: ticket.stagedPath.path
            )
        }
        try WorktreeTrash.markCommitted(oldCommitted, at: Date(timeIntervalSince1970: 100))
        try WorktreeTrash.markCommitted(newlyCommitted, at: Date(timeIntervalSince1970: 200))
        try Data("100\n".utf8).write(
            to: WorktreeTrash.committedMarkerURL(for: uncommitted)
        )

        let tickets = WorktreeTrash.staleTickets(
            commonGitDirectories: [common],
            olderThan: Date(timeIntervalSince1970: 150)
        )

        #expect(tickets == [oldCommitted])
    }

    @Test func cleanerPassesTheValidatedPathAsAnArgument() throws {
        let common = FileManager.default.temporaryDirectory
            .appendingPathComponent("alas-cleaner-args-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: common) }
        let ticket = try makeStagedTicket(
            commonGitDirectory: common,
            originalBaseName: "a name; touch nope"
        )
        var capturedExecutable: URL?
        var capturedArguments: [String] = []

        try WorktreeTrashCleaner.launch(ticket, delaySeconds: 1) { executable, arguments in
            capturedExecutable = executable
            capturedArguments = arguments
        }

        #expect(capturedExecutable?.path == "/usr/bin/nice")
        #expect(capturedArguments[2] == "/usr/bin/python3")
        #expect(capturedArguments[7] == ticket.stagedPath.path)
        #expect(capturedArguments[6] == WorktreeTrash.committedMarkerURL(for: ticket).path)
        #expect(!capturedArguments[4].contains(ticket.stagedPath.path))
        #expect(capturedArguments[4].contains("except Exception:"))
        #expect(capturedArguments[4].contains(
            "os.rename(private_name, name, src_dir_fd=parentfd, dst_dir_fd=parentfd)"
        ))
    }

    @Test func cleanerReplacementSurvivesWhenSwappedBeforeCleanerLaunch() throws {
        let common = FileManager.default.temporaryDirectory
            .appendingPathComponent("alas-cleaner-swap-\(UUID().uuidString)")
        let original = common.appendingPathComponent("original")
        let displaced = common.appendingPathComponent("displaced")
        defer { try? FileManager.default.removeItem(at: common) }
        try FileManager.default.createDirectory(at: original, withIntermediateDirectories: true)
        let ticket = try WorktreeTrash.makeTicket(
            commonGitDirectory: common,
            originalPath: original
        )
        try FileManager.default.createDirectory(
            at: ticket.trashRoot,
            withIntermediateDirectories: true
        )
        try FileManager.default.moveItem(at: original, to: ticket.stagedPath)
        try WorktreeTrash.markCommitted(ticket, at: Date(timeIntervalSince1970: 100))
        let replacementMarker = ticket.stagedPath.appendingPathComponent("replacement.txt")

        try WorktreeTrashCleaner.launch(ticket, delaySeconds: 0) { executable, arguments in
            try FileManager.default.moveItem(at: ticket.stagedPath, to: displaced)
            try FileManager.default.createDirectory(
                at: ticket.stagedPath,
                withIntermediateDirectories: true
            )
            try "keep".write(to: replacementMarker, atomically: true, encoding: .utf8)
            let process = Foundation.Process()
            process.executableURL = executable
            process.arguments = arguments
            try process.run()
            process.waitUntilExit()
        }

        #expect(FileManager.default.fileExists(atPath: replacementMarker.path))
        #expect(FileManager.default.fileExists(
            atPath: WorktreeTrash.committedMarkerURL(for: ticket).path
        ))
        let staleTickets = WorktreeTrash.staleTickets(
            commonGitDirectories: [common],
            olderThan: Date(timeIntervalSince1970: 200)
        )
        #expect(staleTickets.isEmpty)
    }

    @Test func liveCleanerDoesNotDeleteReplacementSwappedInAfterLaunch() async throws {
        let common = FileManager.default.temporaryDirectory
            .appendingPathComponent("alas-cleaner-live-swap-\(UUID().uuidString)")
        let displaced = common.appendingPathComponent("displaced")
        defer { try? FileManager.default.removeItem(at: common) }
        let ticket = try makeStagedTicket(
            commonGitDirectory: common,
            originalBaseName: "clean-me"
        )
        try "trash".write(
            to: ticket.stagedPath.appendingPathComponent("trash.txt"),
            atomically: true,
            encoding: .utf8
        )
        try WorktreeTrash.markCommitted(ticket)
        let replacementMarker = ticket.stagedPath.appendingPathComponent("replacement.txt")
        let committedMarker = WorktreeTrash.committedMarkerURL(for: ticket)

        try WorktreeTrashCleaner.launch(ticket, delaySeconds: 1)
        try FileManager.default.moveItem(at: ticket.stagedPath, to: displaced)
        try FileManager.default.createDirectory(
            at: ticket.stagedPath,
            withIntermediateDirectories: true
        )
        try "keep".write(to: replacementMarker, atomically: true, encoding: .utf8)
        try await Task.sleep(for: .milliseconds(1_500))

        #expect(FileManager.default.fileExists(atPath: replacementMarker.path))
        #expect(FileManager.default.fileExists(atPath: displaced.path))
        #expect(FileManager.default.fileExists(atPath: committedMarker.path))
    }

    @Test(arguments: [0o000, 0o500])
    func liveCleanerDeletesDirectoriesWithoutOwnerWritePermission(permissions: Int) async throws {
        let common = FileManager.default.temporaryDirectory
            .appendingPathComponent("alas-cleaner-unreadable-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: common) }
        let ticket = try makeStagedTicket(
            commonGitDirectory: common,
            originalBaseName: "clean-me"
        )
        let unreadable = ticket.stagedPath.appendingPathComponent("unreadable")
        try FileManager.default.createDirectory(at: unreadable, withIntermediateDirectories: true)
        try "trash".write(
            to: unreadable.appendingPathComponent("trash.txt"),
            atomically: true,
            encoding: .utf8
        )
        try FileManager.default.setAttributes(
            [.posixPermissions: permissions],
            ofItemAtPath: unreadable.path
        )
        defer {
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o700],
                ofItemAtPath: unreadable.path
            )
        }
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

    @Test func liveCleanerDeletesUserImmutableFiles() async throws {
        let common = FileManager.default.temporaryDirectory
            .appendingPathComponent("alas-cleaner-immutable-\(UUID().uuidString)")
        defer { try? chflags("nouchg", at: common, recursive: true) }
        defer { try? FileManager.default.removeItem(at: common) }
        let ticket = try makeStagedTicket(
            commonGitDirectory: common,
            originalBaseName: "clean-me"
        )
        let lockedFile = ticket.stagedPath.appendingPathComponent("locked.txt")
        try "trash".write(to: lockedFile, atomically: true, encoding: .utf8)
        try chflags("uchg", at: lockedFile)
        defer { try? chflags("nouchg", at: lockedFile) }
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

    @Test func staleSweepDoesNotSpawnCleanerForReplacementDirectory() async throws {
        let repo = FileManager.default.temporaryDirectory
            .appendingPathComponent("alas-stale-cleaner-swap-\(UUID().uuidString)")
        let original = repo.deletingLastPathComponent()
            .appendingPathComponent("\(repo.lastPathComponent)-original")
        let displaced = repo.deletingLastPathComponent()
            .appendingPathComponent("\(repo.lastPathComponent)-displaced")
        defer {
            try? FileManager.default.removeItem(at: original)
            try? FileManager.default.removeItem(at: displaced)
            try? FileManager.default.removeItem(at: repo)
        }
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        _ = try await Process.git(["init", "-q", "-b", "main"], cwd: repo)
        _ = try await Process.git(["commit", "-q", "--allow-empty", "-m", "init"], cwd: repo)
        try FileManager.default.createDirectory(at: original, withIntermediateDirectories: true)
        let ticket = try WorktreeTrash.makeTicket(
            commonGitDirectory: repo.appendingPathComponent(".git"),
            originalPath: original,
            now: Date(timeIntervalSince1970: 100)
        )
        try FileManager.default.createDirectory(
            at: ticket.trashRoot,
            withIntermediateDirectories: true
        )
        try FileManager.default.moveItem(at: original, to: ticket.stagedPath)
        try WorktreeTrash.markCommitted(ticket, at: Date(timeIntervalSince1970: 100))
        let replacementMarker = ticket.stagedPath.appendingPathComponent("replacement.txt")
        var cleanerSpawned = false
        var sweepLaunched = false

        WorktreeTrashCleaner.sweep(
            projects: [ProjectConfig(
                id: "main",
                name: "main",
                path: repo.path,
                color: "#000000",
                addedAt: Date(timeIntervalSince1970: 1)
            )],
            now: Date(timeIntervalSince1970: 100_000),
            launcher: { discoveredTicket in
                sweepLaunched = true
                try FileManager.default.moveItem(at: discoveredTicket.stagedPath, to: displaced)
                try FileManager.default.createDirectory(
                    at: discoveredTicket.stagedPath,
                    withIntermediateDirectories: true
                )
                try "keep".write(to: replacementMarker, atomically: true, encoding: .utf8)
                try WorktreeTrashCleaner.launch(discoveredTicket, delaySeconds: 0) { _, _ in
                    cleanerSpawned = true
                }
            }
        )

        #expect(sweepLaunched)
        #expect(!cleanerSpawned)
        #expect(FileManager.default.fileExists(atPath: replacementMarker.path))
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
        let old = try makeStagedTicket(
            commonGitDirectory: common,
            originalBaseName: "old",
            now: Date(timeIntervalSince1970: 100),
            id: UUID()
        )
        let young = try makeStagedTicket(
            commonGitDirectory: common,
            originalBaseName: "young",
            now: Date(timeIntervalSince1970: 250),
            id: UUID()
        )
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

    @Test(arguments: [true, false])
    func sweepReconcilesPendingDeletionWithGitRegistration(registrationRemoved: Bool) async throws {
        let repo = FileManager.default.temporaryDirectory
            .appendingPathComponent("alas-pending-recovery-\(UUID().uuidString)")
        let original = repo.deletingLastPathComponent()
            .appendingPathComponent("\(repo.lastPathComponent)-linked")
        defer {
            try? FileManager.default.removeItem(at: original)
            try? FileManager.default.removeItem(at: repo)
        }
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        _ = try await Process.git(["init", "-q", "-b", "main"], cwd: repo)
        _ = try await Process.git(["commit", "-q", "--allow-empty", "-m", "init"], cwd: repo)
        _ = try await WorktreeService().add(
            repoPath: repo, base: "main", branch: "linked", destination: original, projectId: "p"
        )
        let gitDirectory = try #require(WorktreeService.localGitDirectory(forWorktreeAt: original))
        let ticket = try WorktreeTrash.makeTicket(
            commonGitDirectory: repo.appendingPathComponent(".git"), originalPath: original
        )
        try FileManager.default.createDirectory(at: ticket.trashRoot, withIntermediateDirectories: true)
        let identifier = ticket.stagedPath.lastPathComponent.split(separator: ".").last!
        let pending = ticket.trashRoot.appendingPathComponent(".alas-worktree-deletion-pending.\(identifier)")
        let metadata = [
            "1", "100", String(ticket.directoryIdentity.systemNumber),
            String(ticket.directoryIdentity.fileNumber), ticket.stagedPath.lastPathComponent,
            Data(original.standardizedFileURL.path.utf8).base64EncodedString(),
            Data(gitDirectory.lastPathComponent.utf8).base64EncodedString(), "",
        ].joined(separator: "\n")
        try Data(metadata.utf8).write(to: pending, options: .atomic)
        try FileManager.default.moveItem(at: original, to: ticket.stagedPath)
        if registrationRemoved {
            let removal = try await Process.git(["worktree", "remove", original.path], cwd: repo)
            try #require(removal.exitCode == 0)
        }
        let project = ProjectConfig(id: "p", name: "repo", path: repo.path, color: "#000000", addedAt: .now)
        var recovered: [WorktreeTrashCleanupTicket] = []
        WorktreeTrashCleaner.sweep(projects: [project], launcher: { recovered.append($0) })
        #expect(recovered == (registrationRemoved ? [ticket] : []))
        #expect(FileManager.default.fileExists(
            atPath: (registrationRemoved ? ticket.stagedPath : original).path
        ))
        #expect(!FileManager.default.fileExists(
            atPath: (registrationRemoved ? original : ticket.stagedPath).path
        ))
    }

    @Test func sweepReconcilesPendingDeletionWithLongOriginalPath() async throws {
        let repo = FileManager.default.temporaryDirectory
            .appendingPathComponent("alas-pending-long-recovery-\(UUID().uuidString)")
        let original = try longWorktreePath(
            root: repo.deletingLastPathComponent(),
            prefix: "\(repo.lastPathComponent)-linked"
        )
        defer {
            try? FileManager.default.removeItem(at: original)
            try? FileManager.default.removeItem(at: repo)
        }
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        _ = try await Process.git(["init", "-q", "-b", "main"], cwd: repo)
        _ = try await Process.git(["commit", "-q", "--allow-empty", "-m", "init"], cwd: repo)
        _ = try await WorktreeService().add(
            repoPath: repo, base: "main", branch: "linked", destination: original, projectId: "p"
        )
        let gitDirectory = try #require(WorktreeService.localGitDirectory(forWorktreeAt: original))
        let ticket = try WorktreeTrash.makeTicket(
            commonGitDirectory: repo.appendingPathComponent(".git"), originalPath: original
        )
        try FileManager.default.createDirectory(at: ticket.trashRoot, withIntermediateDirectories: true)
        try WorktreeTrash.markPending(
            ticket,
            originalPath: original,
            linkedGitDirectory: gitDirectory,
            at: Date(timeIntervalSince1970: 100)
        )
        let pendingSize = try #require(
            FileManager.default.attributesOfItem(
                atPath: WorktreeTrash.pendingMarkerURL(for: ticket).path
            )[.size] as? NSNumber
        )
        #expect(pendingSize.uint64Value > 1_024)
        try FileManager.default.moveItem(at: original, to: ticket.stagedPath)
        try FileManager.default.removeItem(at: gitDirectory)
        let project = ProjectConfig(id: "p", name: "repo", path: repo.path, color: "#000000", addedAt: .now)
        var recovered: [WorktreeTrashCleanupTicket] = []

        WorktreeTrashCleaner.sweep(
            projects: [project],
            now: Date(timeIntervalSince1970: 100_000),
            launcher: { recovered.append($0) }
        )

        #expect(recovered == [ticket])
    }

    @Test func liveCleanerEventuallyDeletesTheTicketDirectory() async throws {
        let common = FileManager.default.temporaryDirectory
            .appendingPathComponent("alas-cleaner-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: common) }
        let ticket = try makeStagedTicket(
            commonGitDirectory: common,
            originalBaseName: "clean-me"
        )
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

    private func makeStagedTicket(
        commonGitDirectory: URL,
        originalBaseName: String,
        now: Date = Date(),
        id: UUID = UUID()
    ) throws -> WorktreeTrashCleanupTicket {
        let source = commonGitDirectory
            .appendingPathComponent("alas/test-sources/\(UUID().uuidString)")
            .appendingPathComponent(originalBaseName)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        let ticket = try WorktreeTrash.makeTicket(
            commonGitDirectory: commonGitDirectory,
            originalPath: source,
            now: now,
            id: id
        )
        try FileManager.default.createDirectory(
            at: ticket.trashRoot,
            withIntermediateDirectories: true
        )
        try FileManager.default.moveItem(at: source, to: ticket.stagedPath)
        return ticket
    }

    private func longWorktreePath(root: URL, prefix: String) throws -> URL {
        var path = root.appendingPathComponent(prefix)
        var index = 0
        while path.standardizedFileURL.path.utf8.count < 780 {
            path.appendPathComponent("segment-\(index)-abcdefghijklmnopqrstuvwxyz")
            index += 1
        }
        try FileManager.default.createDirectory(
            at: path.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        return path
    }

    private func chflags(_ flags: String, at url: URL, recursive: Bool = false) throws {
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        let process = Foundation.Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/chflags")
        process.arguments = recursive ? ["-R", flags, url.path] : [flags, url.path]
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw CocoaError(.fileWriteUnknown)
        }
    }
}
