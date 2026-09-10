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
            import stat as stat_module
            import sys
            import time
            import uuid

            def open_directory(name, dirfd):
                flags = os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW
                try:
                    fd = os.open(name, flags, dir_fd=dirfd)
                except PermissionError:
                    os.chmod(name, 0o700, dir_fd=dirfd, follow_symlinks=False)
                    fd = os.open(name, flags, dir_fd=dirfd)
                mode = stat_module.S_IMODE(os.fstat(fd).st_mode)
                if (mode & 0o700) != 0o700:
                    os.fchmod(fd, mode | 0o700)
                return fd

            def remove_contents(dirfd):
                for name in os.listdir(dirfd):
                    try:
                        childfd = open_directory(name, dirfd)
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
            renamed = False
            try:
                stagedfd = open_directory(name, parentfd)
                staged_stat = os.fstat(stagedfd)
                if (staged_stat.st_dev, staged_stat.st_ino) != (expected_device, expected_inode):
                    sys.exit(0)
                os.rename(name, private_name, src_dir_fd=parentfd, dst_dir_fd=parentfd)
                renamed = True
                renamedfd = open_directory(private_name, parentfd)
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
                renamed = False
                try:
                    os.unlink(marker)
                except FileNotFoundError:
                    pass
            except FileNotFoundError:
                pass
            except Exception:
                if renamed:
                    if renamedfd is not None:
                        os.close(renamedfd)
                        renamedfd = None
                    try:
                        os.rename(private_name, name, src_dir_fd=parentfd, dst_dir_fd=parentfd)
                    except OSError:
                        pass
                raise
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
