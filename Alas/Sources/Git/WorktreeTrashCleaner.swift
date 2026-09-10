import Foundation
import os

enum WorktreeTrashCleaner {
    typealias Launcher = (WorktreeTrashCleanupTicket) throws -> Void
    typealias Spawn = (URL, [String]) throws -> Void

    private static let logger = Logger(
        subsystem: "io.nlopez.alas",
        category: "worktree-trash"
    )

    enum CleanerError: LocalizedError {
        case invalidTicket
        case replacedDirectory

        var errorDescription: String? {
            switch self {
            case .invalidTicket:
                "Refusing to clean a path outside the Alas worktree trash directory."
            case .replacedDirectory:
                "Refusing to clean a replaced worktree trash directory."
            }
        }
    }

    static func launch(
        _ ticket: WorktreeTrashCleanupTicket,
        delaySeconds: Int = 1,
        spawn: Spawn = spawnDetached
    ) throws {
        guard WorktreeTrash.isValid(ticket) else { throw CleanerError.invalidTicket }
        guard WorktreeTrash.matchesDirectoryIdentity(ticket) else {
            throw CleanerError.replacedDirectory
        }
        try spawn(URL(fileURLWithPath: "/usr/bin/nice"), [
            "-n", "10", "/usr/bin/python3", "-c",
            """
            import errno
            import os
            import sys
            import time
            import uuid

            def remove_contents(dirfd):
                for name in os.listdir(dirfd):
                    try:
                        childfd = os.open(
                            name,
                            os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW,
                            dir_fd=dirfd,
                        )
                    except OSError as error:
                        if error.errno in (errno.ENOTDIR, errno.ELOOP):
                            try:
                                os.unlink(name, dir_fd=dirfd)
                            except FileNotFoundError:
                                pass
                            continue
                        if error.errno == errno.ENOENT:
                            continue
                        raise
                    try:
                        remove_contents(childfd)
                    finally:
                        os.close(childfd)
                    try:
                        os.rmdir(name, dir_fd=dirfd)
                    except FileNotFoundError:
                        pass

            time.sleep(max(0, int(sys.argv[1])))
            marker = sys.argv[2]
            staged = sys.argv[3]
            expected_device = int(sys.argv[4])
            expected_inode = int(sys.argv[5])
            parent, name = os.path.split(staged)
            private_name = f".{name}.deleting.{os.getpid()}.{uuid.uuid4().hex}"
            parentfd = os.open(parent, os.O_RDONLY | os.O_DIRECTORY)
            stagedfd = None
            renamedfd = None
            try:
                stagedfd = os.open(
                    name,
                    os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW,
                    dir_fd=parentfd,
                )
                stat = os.fstat(stagedfd)
                if (stat.st_dev, stat.st_ino) != (expected_device, expected_inode):
                    sys.exit(0)
                os.rename(name, private_name, src_dir_fd=parentfd, dst_dir_fd=parentfd)
                renamedfd = os.open(
                    private_name,
                    os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW,
                    dir_fd=parentfd,
                )
                renamed_stat = os.fstat(renamedfd)
                if (renamed_stat.st_dev, renamed_stat.st_ino) != (expected_device, expected_inode):
                    try:
                        os.rename(private_name, name, src_dir_fd=parentfd, dst_dir_fd=parentfd)
                    except OSError:
                        pass
                    sys.exit(0)
                remove_contents(renamedfd)
                try:
                    os.rmdir(private_name, dir_fd=parentfd)
                except FileNotFoundError:
                    pass
                try:
                    os.unlink(marker)
                except FileNotFoundError:
                    pass
            except FileNotFoundError:
                pass
            finally:
                if renamedfd is not None:
                    os.close(renamedfd)
                if stagedfd is not None:
                    os.close(stagedfd)
                os.close(parentfd)
            """,
            String(max(0, delaySeconds)),
            WorktreeTrash.committedMarkerURL(for: ticket).path,
            ticket.stagedPath.path,
            String(ticket.directoryIdentity.systemNumber),
            String(ticket.directoryIdentity.fileNumber),
        ])
    }

    static func sweep(
        projects: [ProjectConfig],
        now: Date = Date(),
        launcher: Launcher = { try launch($0) }
    ) {
        let commonDirectories = projects.flatMap { project -> [URL] in
            guard project.host == nil else { return [] }
            let paths = [URL(fileURLWithPath: project.path)]
                + project.cachedWorktrees.map(\.path)
            return paths.compactMap { path in
                guard !path.isRemoteAlasPath else { return nil }
                return WorktreeService.localCommonGitDirectory(forWorktreeAt: path)
            }
        }
        let cutoff = now.addingTimeInterval(-24 * 60 * 60)
        for ticket in WorktreeTrash.staleTickets(
            commonGitDirectories: commonDirectories,
            olderThan: cutoff
        ) {
            do {
                try launcher(ticket)
            } catch {
                logger.error(
                    "Could not launch stale worktree cleanup for \(ticket.stagedPath.path, privacy: .public): \(error.localizedDescription, privacy: .public)"
                )
            }
        }
    }

    private static func spawnDetached(executable: URL, arguments: [String]) throws {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        process.qualityOfService = .utility
        try process.run()
    }
}
