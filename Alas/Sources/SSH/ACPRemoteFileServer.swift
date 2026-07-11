import Foundation

enum RemotePathContainment {
    enum ContainmentError: Error, LocalizedError {
        case outsideWorktree(String)

        var errorDescription: String? {
            switch self {
            case let .outsideWorktree(path): "Path is outside the worktree: \(path)"
            }
        }
    }

    static func lexicallyResolveInsideWorktree(path: String, worktreeRoot: String) throws -> String {
        let absolute = path.hasPrefix("/") ? path : worktreeRoot + "/" + path
        let normalized = URL(fileURLWithPath: absolute).standardizedFileURL.path
        guard normalized == worktreeRoot || normalized.hasPrefix(worktreeRoot + "/") else {
            throw ContainmentError.outsideWorktree(path)
        }
        return normalized
    }

    static func containmentProbeCommand(path: String, worktreeRoot: String) -> String {
        let root = SSHCommand.shellQuote(worktreeRoot)
        let target = SSHCommand.shellQuote(path)
        return """
        root=\(root); target=\(target); parent=$(dirname "$target"); existing="$parent"; \
        while [ ! -e "$existing" ]; do next=$(dirname "$existing"); [ "$next" = "$existing" ] && exit 3; existing="$next"; done; \
        root_phys=$(cd "$root" && pwd -P) || exit 4; existing_phys=$(cd "$existing" && pwd -P) || exit 5; \
        case "$existing_phys" in "$root_phys"|"$root_phys"/*) exit 0 ;; *) exit 6 ;; esac
        """
    }

    static func verifyRemoteContainment(host: String, path: String, worktreeRoot: String) async throws {
        let target = try lexicallyResolveInsideWorktree(path: path, worktreeRoot: worktreeRoot)
        let result = try await RemoteExec.run(host: host, cwd: nil, command: containmentProbeCommand(path: target, worktreeRoot: worktreeRoot))
        if RemoteExec.isConnectionFailure(exitCode: result.exitCode) {
            throw RemoteFileAccessError.connectionFailed(result.stderr)
        }
        guard result.exitCode == 0 else {
            throw ContainmentError.outsideWorktree(path)
        }
    }
}

/// Remote ACP file serving uses lexical containment first, then a remote
/// physical-parent containment probe before touching the file.
struct ACPRemoteFileServer {
    enum ServerError: Error, LocalizedError {
        case outsideWorktree(String)
        case unreadable(String)
        case leaseLost

        var errorDescription: String? {
            switch self {
            case let .outsideWorktree(path): "Path is outside the worktree: \(path)"
            case let .unreadable(detail): "Could not read remote file: \(detail)"
            case .leaseLost: "Session lease was lost before the remote write."
            }
        }
    }

    let host: String
    let worktreeRoot: String

    func lexicallyResolveInsideWorktree(path: String) throws -> String {
        do {
            return try RemotePathContainment.lexicallyResolveInsideWorktree(path: path, worktreeRoot: worktreeRoot)
        } catch {
            throw ServerError.outsideWorktree(path)
        }
    }

    func read(path: String, liveBuffer: String?) async throws -> String {
        if let liveBuffer { return liveBuffer }
        let target = try lexicallyResolveInsideWorktree(path: path)
        try await verifyRemoteContainment(path: target)
        switch try await RemoteFileAccess.read(host: host, path: target) {
        case let .file(data, _):
            guard let text = String(data: data, encoding: .utf8) else { throw ServerError.unreadable("not valid UTF-8") }
            return text
        case .missing: throw ServerError.unreadable("no such file")
        case .directory: throw ServerError.unreadable("path is a directory")
        case .symlink: throw ServerError.unreadable("path is a symbolic link")
        case let .unreadable(detail): throw ServerError.unreadable(detail)
        }
    }

    func write(
        path: String,
        content: String,
        beforeRemoteWrite: (@MainActor @Sendable () async throws -> Void)? = nil
    ) async throws -> ACPFileWriter.Result {
        let target = try lexicallyResolveInsideWorktree(path: path)
        try await verifyRemoteContainment(path: target)
        let previous = try? await read(path: target, liveBuffer: nil)
        let mkdir = try await RemoteExec.run(host: host, cwd: nil, command: RemoteFileOps.mkdirCommand(parentOf: target))
        if RemoteExec.isConnectionFailure(exitCode: mkdir.exitCode) {
            throw RemoteFileAccessError.connectionFailed(mkdir.stderr)
        }
        guard mkdir.exitCode == 0 else {
            throw ServerError.unreadable(mkdir.stderr)
        }
        try await beforeRemoteWrite?()
        _ = try await RemoteFileAccess.write(host: host, path: target, content: content)
        return ACPFileWriter.makeResult(oldText: previous, newText: content, path: target)
    }

    func containmentProbeCommand(path: String) -> String {
        RemotePathContainment.containmentProbeCommand(path: path, worktreeRoot: worktreeRoot)
    }

    func verifyRemoteContainment(path: String) async throws {
        do {
            try await RemotePathContainment.verifyRemoteContainment(host: host, path: path, worktreeRoot: worktreeRoot)
        } catch RemotePathContainment.ContainmentError.outsideWorktree(_) {
            throw ServerError.outsideWorktree(path)
        } catch {
            throw error
        }
    }
}
