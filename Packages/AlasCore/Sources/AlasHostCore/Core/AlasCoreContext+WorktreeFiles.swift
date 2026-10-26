import Foundation
import Darwin
import AlasFeatures
import AlasModel
import AlasPlatform

extension AlasCoreContext {
    /// A paired Mac's file change in a listed worktree, under the project's gate. Refused while stopping,
    /// unlisted or archived, busy (`isWorktreeIdle`), held by a checkpoint restore, or with a restore
    /// pending. No branch check: the version is the guard.
    func changeListedFiles<T: Sendable>(in worktree: Worktree, _ body: @MainActor (Worktree) async throws -> T) async throws -> T {
        guard !worktree.path.isRemoteAlasPath else {
            throw HostError.invalidRequest(reason: "The host does not edit files of remote projects.")
        }
        return try await ProjectMutationGate.shared.withMutation(projectID: worktree.projectId) { @MainActor [self] in
            try refuseIfStopping()
            guard let listed = projects.worktrees(projectId: worktree.projectId).first(where: { $0.id == worktree.id }) else {
                throw HostError.failed(message: "The worktree changed since it was listed.")
            }
            guard !projects.isWorktreeHidden(projectId: listed.projectId, path: listed.path) else {
                throw HostError.notFound(what: "worktree \(listed.path.path) in project \(listed.projectId)")
            }
            guard isWorktreeIdle(listed) else { throw WorktreeBusyError() }
            guard !isHeldByCheckpointRestore(.worktree(listed.id)) else {
                throw HostError.failed(message: "A checkpoint restore is running on the host; save again once it finishes.")
            }
            if await environment.checkpointRecoveryBlocksRemoval(listed, in: self) {
                throw HostError.failed(message: "A checkpoint restore is pending on the host; finish it there first.")
            }
            return try await body(listed)
        }
    }

    /// Replaces `path`'s text if it is still at `expected`, or creates it when
    /// `expected` is nil and nothing is there. The bytes alone decide: a file
    /// only touched since it was read is not a conflict.
    func writeListedFile(_ path: String, text: String, expected: WorktreeFileVersion?, in worktree: Worktree) async throws -> WorktreeFileVersion {
        let data = Data(text.utf8)
        let overCap = HostError.invalidRequest(reason: "The host edits files up to \(RemoteWorktreeFileAccess.maxFileBytes / 1024) KB.")
        guard data.count <= RemoteWorktreeFileAccess.maxFileBytes else { throw overCap }
        return try await changeListedFiles(in: worktree) { [self] listed in
            let url = try await writableURL(path, in: listed)
            // ponytail: the probe-then-rename window is the same race local saves have; an `O_EXCL` lock file would
            // close it if it ever bites.
            switch await RemoteWorktreeFileAccess.probeVersion(at: url) {
            case .tooLarge: throw overCap
            case .missing:
                if expected != nil { throw HostError.fileChanged(current: nil) }
            case .version(let current, _):
                if current.contentHash != expected?.contentHash { throw HostError.fileChanged(current: current) }
            }
            return try await RemoteWorktreeFileAccess.replaceAtomically(url, with: data)
        }
    }

    /// Makes folder `path`; never its parents.
    func createListedFolder(_ path: String, in worktree: Worktree) async throws {
        try await changeListedFiles(in: worktree) { [self] listed in
            let url = try await writableURL(path, in: listed, folder: true)
            guard mkdir(url.path, 0o755) != 0 else { return }
            switch errno {
            case EEXIST: throw HostError.failed(message: "\(path) already exists on the host.")
            case ENOENT: throw Self.parentGone(path)
            default: throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
        }
    }

    /// `path` in `worktree` under the real root, else invalidRequest("The host does not edit <path>."):
    /// no NUL, `..`, `.` or `.git` in any case, no symlink at any component, the last a regular file
    /// (a folder with `folder`) or absent, and not ignored by git. The folder holding it must exist.
    func writableURL(_ path: String, in worktree: Worktree, folder: Bool = false) async throws -> URL {
        let refused = HostError.invalidRequest(reason: "The host does not edit \(path).")
        // Checked as a string first: nothing a bad path names is ever touched.
        guard !path.contains("\0"), let normalized = RemoteWorktreeFileAccess.normalizedRelativePath(path) else { throw refused }
        let components = normalized.split(separator: "/").map(String.init)
        guard !components.contains(where: { $0 == "." || $0.lowercased() == ".git" }) else { throw refused }
        guard let resolvedRoot = realpath(worktree.path.path, nil) else { throw Self.parentGone(path) }
        var url = URL(fileURLWithPath: String(cString: resolvedRoot), isDirectory: true)
        free(resolvedRoot)
        // lstat each component from the real root: a symlink anywhere is refused, so the
        // path cannot leave the root.
        for (index, component) in components.enumerated() {
            url.appendPathComponent(component)
            let isLast = index == components.count - 1
            var status = stat()
            guard lstat(url.path, &status) == 0 else {
                guard errno == ENOENT else { throw refused }
                if isLast { break }
                throw Self.parentGone(path)
            }
            guard status.st_mode & S_IFMT == (isLast && !folder ? S_IFREG : S_IFDIR) else { throw refused }
        }
        // A folder has no ignore rules, and its tree lists every file.
        if !isFolderWorktree(worktree) {
            if try await GitService().isPathIgnored(worktreePath: worktree.path, path: folder ? normalized + "/" : normalized) {
                throw refused
            }
        }
        return url
    }

    private static func parentGone(_ path: String) -> HostError {
        .failed(message: "The folder holding \(path) is no longer on the host.")
    }
}
