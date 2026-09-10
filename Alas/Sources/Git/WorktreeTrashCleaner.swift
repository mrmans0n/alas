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
            "-n", "10", "/bin/sh", "-c",
            """
            /bin/sleep "$1"
            current=$(/usr/bin/stat -f '%d:%i' "$3" 2>/dev/null) || exit 0
            test "$current" = "$4:$5" || exit 0
            /bin/rm -rf -- "$3" && exec /bin/rm -f -- "$2"
            """,
            "alas-worktree-cleaner",
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
