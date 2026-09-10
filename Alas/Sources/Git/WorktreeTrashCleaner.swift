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

        var errorDescription: String? {
            "Refusing to clean a path outside the Alas worktree trash directory."
        }
    }

    static func launch(
        _ ticket: WorktreeTrashCleanupTicket,
        delaySeconds: Int = 1,
        spawn: Spawn = spawnDetached
    ) throws {
        guard WorktreeTrash.isValid(ticket) else { throw CleanerError.invalidTicket }
        try spawn(URL(fileURLWithPath: "/usr/bin/nice"), [
            "-n", "10", "/bin/sh", "-c",
            "/bin/sleep \"$1\"; /bin/rm -rf -- \"$3\" && exec /bin/rm -f -- \"$2\"",
            "alas-worktree-cleaner",
            String(max(0, delaySeconds)),
            WorktreeTrash.committedMarkerURL(for: ticket).path,
            ticket.stagedPath.path,
        ])
    }

    static func sweep(
        projects: [ProjectConfig],
        now: Date = Date(),
        launcher: Launcher = { try launch($0) }
    ) {
        let commonDirectories = projects.compactMap { project -> URL? in
            guard project.host == nil else { return nil }
            let path = URL(fileURLWithPath: project.path)
            guard !path.isRemoteAlasPath else { return nil }
            return WorktreeService.localCommonGitDirectory(forWorktreeAt: path)
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
