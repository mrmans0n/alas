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
        try await ProjectMutationGate.shared.withMutation(projectID: worktree.projectId) { @MainActor [self] in
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
            _ = try await writableURL(path, in: listed)
            try beforeFileChange?()
            let (folder, name) = try Self.writableFolder(path, in: listed.path)
            func refuseIfChanged() async throws {
                switch await RemoteWorktreeFileAccess.probeVersion(name, in: folder) {
                case .tooLarge: throw overCap
                case .missing:
                    if expected != nil { throw HostError.fileChanged(current: nil) }
                case .version(let current, _):
                    if current.contentHash != expected?.contentHash { throw HostError.fileChanged(current: current) }
                }
            }
            try await refuseIfChanged()
            // ponytail: replacing, the probe-then-rename window is the same race local saves have; an `O_EXCL`
            // lock file would close it if it ever bites. Creating, the rename itself refuses a file that appeared.
            do {
                return try await RemoteWorktreeFileAccess.replaceAtomically(name, in: folder, with: data, creating: expected == nil)
            } catch POSIXError.EEXIST where expected == nil {
                try await refuseIfChanged()
                throw HostError.fileChanged(current: nil)
            }
        }
    }

    /// Makes folder `path`; never its parents.
    func createListedFolder(_ path: String, in worktree: Worktree) async throws {
        try await changeListedFiles(in: worktree) { [self] listed in
            _ = try await writableURL(path, in: listed, folder: true)
            try beforeFileChange?()
            let (folder, name) = try Self.writableFolder(path, in: listed.path)
            guard mkdirat(folder.fileDescriptor, name, 0o755) != 0 else { return }
            switch errno {
            case EEXIST: throw HostError.failed(message: "\(path) already exists on the host.")
            case ENOENT: throw Self.parentGone(path)
            default: throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
        }
    }

    /// `path` in `worktree` under the real root, else invalidRequest("The host does not edit <path>."):
    /// what `writableLocation` refuses, or a path git ignores. The folder holding it must exist.
    func writableURL(_ path: String, in worktree: Worktree, folder: Bool = false) async throws -> URL {
        let url: URL
        switch Self.writableLocation(path, in: worktree.path, folder: folder) {
        case .success(let found): url = found
        case .failure(.parentGone): throw Self.parentGone(path)
        case .failure(.refused): throw HostError.invalidRequest(reason: "The host does not edit \(path).")
        }
        // A folder has no ignore rules, and its tree lists every file.
        if !isFolderWorktree(worktree), let normalized = RemoteWorktreeFileAccess.normalizedRelativePath(path),
           try await GitService().isPathIgnored(worktreePath: worktree.path, path: folder ? normalized + "/" : normalized) {
            throw HostError.invalidRequest(reason: "The host does not edit \(path).")
        }
        return url
    }

    enum WritableRefusal: Error { case refused, parentGone }

    /// `path` under `root`'s real path, by its shape alone (no git): no NUL, `..`, `.` or `.git` in any
    /// case, no symlink at any component, no nested worktree or repository on the way, the last a regular
    /// file (or a folder, with `folder`) or absent. `.parentGone` when a folder on the way is not there.
    nonisolated static func writableLocation(_ path: String, in root: URL, folder: Bool = false) -> Result<URL, WritableRefusal> {
        // Checked as a string first: nothing a bad path names is ever touched.
        guard let components = writableComponents(path) else { return .failure(.refused) }
        guard let resolvedRoot = realpath(root.path, nil) else { return .failure(.parentGone) }
        var url = URL(fileURLWithPath: String(cString: resolvedRoot), isDirectory: true)
        free(resolvedRoot)
        // lstat each component from the real root: a symlink anywhere is refused, so the
        // path cannot leave the root.
        for (index, component) in components.enumerated() {
            url.appendPathComponent(component)
            let isLast = index == components.count - 1
            var status = stat()
            guard lstat(url.path, &status) == 0 else {
                guard errno == ENOENT else { return .failure(.refused) }
                if isLast { break }
                return .failure(.parentGone)
            }
            let type = status.st_mode & S_IFMT
            guard isLast ? type == S_IFREG || (folder && type == S_IFDIR) : type == S_IFDIR else { return .failure(.refused) }
            // A nested worktree or repository answers to its own gate.
            if !isLast, lstat(url.appendingPathComponent(".git").path, &status) == 0 { return .failure(.refused) }
        }
        return .success(url)
    }

    /// `path`'s components, unless it has a NUL, `..`, `.` or `.git` in any case.
    private nonisolated static func writableComponents(_ path: String) -> [String]? {
        guard !path.contains("\0"), let normalized = RemoteWorktreeFileAccess.normalizedRelativePath(path) else { return nil }
        let components = normalized.split(separator: "/").map(String.init)
        return components.contains(where: { $0 == "." || $0.lowercased() == ".git" }) ? nil : components
    }

    /// The folder holding `path` and the name in it, the folder opened from the real root one no-follow
    /// `openat` at a time and held: a change made through it lands where `writableLocation` checked even if
    /// a folder on the way has since been swapped for a symlink. Refuses what `writableLocation` refuses on the way.
    nonisolated static func writableFolder(_ path: String, in root: URL) throws -> (folder: FileHandle, name: String) {
        let refused = HostError.invalidRequest(reason: "The host does not edit \(path).")
        guard var components = writableComponents(path), let name = components.popLast() else { throw refused }
        guard let resolvedRoot = realpath(root.path, nil) else { throw parentGone(path) }
        let rootFD = open(resolvedRoot, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        free(resolvedRoot)
        guard rootFD >= 0 else { throw errno == ENOENT ? parentGone(path) : refused }
        var folder = FileHandle(fileDescriptor: rootFD, closeOnDealloc: true)
        for component in components {
            let fd = openat(folder.fileDescriptor, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard fd >= 0 else { throw errno == ENOENT ? parentGone(path) : refused }
            folder = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
            // A nested worktree or repository answers to its own gate.
            var status = stat()
            guard fstatat(fd, ".git", &status, AT_SYMLINK_NOFOLLOW) != 0 else { throw refused }
        }
        return (folder, name)
    }

    private nonisolated static func parentGone(_ path: String) -> HostError {
        .failed(message: "The folder holding \(path) is no longer on the host.")
    }
}
