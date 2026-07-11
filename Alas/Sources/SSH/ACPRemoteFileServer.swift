import Foundation

/// Remote ACP file serving uses lexical containment. Resolving remote
/// symlinks would require an additional ssh round trip per request.
struct ACPRemoteFileServer {
    enum ServerError: Error, LocalizedError {
        case outsideWorktree(String)
        case unreadable(String)

        var errorDescription: String? {
            switch self {
            case let .outsideWorktree(path): "Path is outside the worktree: \(path)"
            case let .unreadable(detail): "Could not read remote file: \(detail)"
            }
        }
    }

    let host: String
    let worktreeRoot: String

    func resolveInsideWorktree(path: String) throws -> String {
        let absolute = path.hasPrefix("/") ? path : worktreeRoot + "/" + path
        let normalized = URL(fileURLWithPath: absolute).standardizedFileURL.path
        guard normalized == worktreeRoot || normalized.hasPrefix(worktreeRoot + "/") else {
            throw ServerError.outsideWorktree(path)
        }
        return normalized
    }

    func read(path: String, liveBuffer: String?) async throws -> String {
        if let liveBuffer { return liveBuffer }
        switch try await RemoteFileAccess.read(host: host, path: path) {
        case let .file(data, _):
            guard let text = String(data: data, encoding: .utf8) else { throw ServerError.unreadable("not valid UTF-8") }
            return text
        case .missing: throw ServerError.unreadable("no such file")
        case .directory: throw ServerError.unreadable("path is a directory")
        case let .unreadable(detail): throw ServerError.unreadable(detail)
        }
    }

    func write(path: String, content: String) async throws -> ACPFileWriter.Result {
        let previous = try? await read(path: path, liveBuffer: nil)
        _ = try await RemoteFileAccess.write(host: host, path: path, content: content)
        return ACPFileWriter.makeResult(oldText: previous ?? "", newText: content, path: path)
    }
}
