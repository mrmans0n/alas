import Foundation
import AlasFoundation
import AlasModel
import AlasPlatform
import AlasFeatures
import AlasCode

/// Remote ACP file serving uses lexical containment first, then a remote
/// physical-parent containment probe before touching the file.
public struct ACPRemoteFileServer: Sendable {
    public enum ServerError: Error, LocalizedError, Sendable {
        case outsideWorktree(String)
        case unreadable(String)
        case leaseLost

        public var errorDescription: String? {
            switch self {
            case let .outsideWorktree(path): "Path is outside the worktree: \(path)"
            case let .unreadable(detail): "Could not read remote file: \(detail)"
            case .leaseLost: "Session lease was lost before the remote write."
            }
        }
    }

    public let host: String
    public let worktreeRoot: String

    public func lexicallyResolveInsideWorktree(path: String) throws -> String {
        do {
            return try RemotePathContainment.lexicallyResolveInsideWorktree(path: path, worktreeRoot: worktreeRoot)
        } catch {
            throw ServerError.outsideWorktree(path)
        }
    }

    public func read(path: String, liveBuffer: String?) async throws -> String {
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

    public func write(
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

    public func containmentProbeCommand(path: String) -> String {
        RemotePathContainment.containmentProbeCommand(path: path, worktreeRoot: worktreeRoot)
    }

    public func verifyRemoteContainment(path: String) async throws {
        do {
            try await RemotePathContainment.verifyRemoteContainment(host: host, path: path, worktreeRoot: worktreeRoot)
        } catch RemotePathContainment.ContainmentError.outsideWorktree(_) {
            throw ServerError.outsideWorktree(path)
        } catch {
            throw error
        }
    }

    public init(host: String, worktreeRoot: String) {
        self.host = host
        self.worktreeRoot = worktreeRoot
    }
}
