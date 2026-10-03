import Darwin
import Foundation

/// `files.read` and `files.write`: plugin paths resolved inside one worktree.
enum PluginFiles {
    /// Half the 1 MiB message limit, like `PluginHTTP.maxBodyBytes`, so a file's content, JSON-escaped, still fits
    /// in the reply as a rule. A reply that still does not fit is refused like any other.
    static let maxFileBytes = 512 << 10
    static let maxListEntries = 2000

    /// Where `path`, relative to `root`, really leads, or why it may not be used. Refuses absolute paths, `..`,
    /// anything that resolves outside `root`, through symlinks too, and anything with a component named `.git`,
    /// compared case-folded on the resolved path: in a linked worktree `.git` points git at the repository.
    /// Parts of the path that do not exist yet are kept as written. An empty path or `.` is `root` itself.
    /// ponytail: resolved once, then used; a symlink swapped in between is followed. Open with O_NOFOLLOW per
    /// component if plugins ever race the user.
    static func resolve(_ path: String, in root: URL) -> Result<URL, PluginFilesError> {
        guard !path.hasPrefix("/") else { return .failure(.refused("\(path) is not relative")) }
        let components = path.split(separator: "/").map(String.init).filter { $0 != "." }
        guard !components.contains("..") else { return .failure(.refused("\(path) uses ..")) }
        guard let realRoot = realPath(root.path) else { return .failure(.notFound("the worktree")) }
        var current = realRoot
        for (index, component) in components.enumerated() {
            let candidate = current + "/" + component
            var info = stat()
            guard lstat(candidate, &info) == 0 else {
                // Not there yet: the rest is kept as written.
                current = ([candidate] + components[(index + 1)...]).joined(separator: "/")
                break
            }
            // A symlink that leads nowhere, or in circles, is refused: writing through it would land wherever it points.
            guard let real = realPath(candidate) else { return .failure(.refused("\(path) has a broken symlink")) }
            current = real
        }
        guard current == realRoot || current.hasPrefix(realRoot + "/") else {
            return .failure(.refused("\(path) leaves the worktree"))
        }
        let inside = current.dropFirst(realRoot.count).split(separator: "/")
        guard !inside.contains(where: { $0.lowercased() == ".git" }) else {
            return .failure(.refused("\(path) is inside .git"))
        }
        return .success(URL(fileURLWithPath: current))
    }

    private static func realPath(_ path: String) -> String? {
        guard let resolved = realpath(path, nil) else { return nil }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    static func read(_ path: String, in root: URL) -> Result<String, PluginFilesError> {
        resolve(path, in: root).flatMap { url in
            guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
                  values.isRegularFile == true
            else { return .failure(.notFound(path)) }
            guard (values.fileSize ?? 0) <= maxFileBytes else { return .failure(.refused("\(path) is larger than 512 KiB")) }
            guard let data = try? Data(contentsOf: url) else { return .failure(.notFound(path)) }
            guard let text = String(data: data, encoding: .utf8) else { return .failure(.refused("\(path) is not UTF-8 text")) }
            return .success(text)
        }
    }

    static func list(_ dir: String, in root: URL) -> Result<PluginFileListResult, PluginFilesError> {
        resolve(dir, in: root).flatMap { url in
            guard let names = try? FileManager.default.contentsOfDirectory(atPath: url.path) else {
                return .failure(.notFound(dir.isEmpty ? "." : dir))
            }
            // ponytail: every name is read and sorted before the cap, off the main actor; enumerate with a bound if
            // directories of millions of entries show up.
            let visible = names.filter { $0.lowercased() != ".git" }.sorted()
            // Names that JSON-escape badly could still overflow the reply, so the list also stops at half the
            // message limit of encoded names.
            var budget = maxFileBytes
            let fitting = visible.prefix(maxListEntries).prefix { name in
                budget -= ((try? JSONEncoder().encode(name).count) ?? name.utf8.count * 6) + 32
                return budget >= 0
            }
            let entries = fitting.map { name in
                let type = (try? FileManager.default.attributesOfItem(atPath: url.appending(path: name).path))?[.type] as? FileAttributeType
                let kind = switch type {
                case .typeDirectory?: "directory"
                case .typeSymbolicLink?: "symlink"
                default: "file"
                }
                return PluginFileListResult.Entry(name: name, kind: kind)
            }
            return .success(PluginFileListResult(entries: Array(entries), truncated: visible.count > entries.count))
        }
    }

    /// Creates missing folders on the way, all inside the worktree because the path resolved there.
    static func write(_ path: String, content: String, in root: URL) -> Result<Void, PluginFilesError> {
        guard content.utf8.count <= maxFileBytes else { return .failure(.refused("content is larger than 512 KiB")) }
        return resolve(path, in: root).flatMap { url in
            var isDirectory: ObjCBool = false
            if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue {
                return .failure(.refused("\(path) is a folder"))
            }
            do {
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try Data(content.utf8).write(to: url, options: .atomic)
                return .success(())
            } catch {
                return .failure(.refused("could not write \(path): \(error.localizedDescription)"))
            }
        }
    }
}

/// A `file/*` request, carried out on this Mac or by the Alas helper on an SSH host (API 11).
enum PluginFileRequest: Equatable, Sendable {
    case read(path: String)
    case list(dir: String)
    case write(path: String, content: String)
}

/// Where a `file/*` request for a worktree goes.
enum PluginFileRoute: Equatable, Sendable {
    case local(URL)
    /// The worktree's real path on `host`.
    case remote(host: String, root: String)
    case refused(String)
}

/// Why a remote file request could not reach the helper.
enum PluginRemoteFileProblem: Error, Equatable {
    case unreachable
    case helperMissing
}

extension PluginFiles {
    static func perform(_ request: PluginFileRequest, in root: URL) -> Result<PluginFileReply, PluginFilesError> {
        switch request {
        case .read(let path): read(path, in: root).map { .read(PluginFileReadResult(content: $0)) }
        case .list(let dir): list(dir, in: root).map { .list($0) }
        case .write(let path, let content): write(path, content: content, in: root).map { .written }
        }
    }

    /// Local worktrees are used here. A remote one only when the plugin declares `remote` (API 11); otherwise it gets
    /// API 10's refusal, which names the host.
    static func route(_ location: PluginWorktreeLocation?, worktree: String, remote: Bool) -> PluginFileRoute {
        switch location {
        case .local(let root)?: .local(root)
        case .remote(let host, let root)? where remote: .remote(host: host, root: root)
        case .remote(let host, _)?: .refused(remoteRefusal(worktree, host: host))
        case nil: .refused("unknown worktree \(worktree)")
        }
    }

    static func remoteRefusal(_ worktree: String, host: String) -> String {
        "worktree \(worktree) is on remote host \(host); plugins can't run commands or use files there yet"
    }

    /// Carries out `request` in the worktree at `root` on `host`, through the Alas helper there, which checks the
    /// path and does the work in one call. Without the helper the request is refused: a shell command cannot check
    /// and act atomically.
    static func remote(
        _ request: PluginFileRequest, host: String, root: String
    ) async -> Result<PluginFileReply, PluginFilesError> {
        do {
            // The probe tells a host that is down from one without the helper, and is cached per host.
            guard let capabilities = await RemoteHostCapabilityStore.shared.capabilities(for: host) else {
                throw PluginRemoteFileProblem.unreachable
            }
            guard capabilities.helperHandshake != nil else { throw PluginRemoteFileProblem.helperMissing }
            let client = await RemoteHelperClientPool.shared.client(for: host)
            switch request {
            case .read(let path):
                return .success(.read(try await client.pluginFile(
                    "fs/scoped-read", RemoteHelperScopedPathParams(root: root, path: path))))
            case .list(let dir):
                return .success(.list(try await client.pluginFile(
                    "fs/scoped-list", RemoteHelperScopedListParams(root: root, dir: dir))))
            case .write(let path, let content):
                let _: PluginEmptyPayload = try await client.pluginFile(
                    "fs/scoped-write", RemoteHelperScopedWriteParams(root: root, path: path, content: content))
                return .success(.written)
            }
        } catch {
            return .failure(remoteFailure(error, host: host))
        }
    }

    /// What the plugin is told when a remote file request fails. The helper's own refusals pass through as they are.
    static func remoteFailure(_ error: Error, host: String) -> PluginFilesError {
        let unreachable = PluginFilesError.refused("remote host \(host) is unreachable")
        switch error {
        case PluginRemoteFileProblem.unreachable: return unreachable
        case PluginRemoteFileProblem.helperMissing:
            return .refused("the Alas helper is not installed on remote host \(host); plugins need it to use files there")
        case RemoteHelperClientError.jsonrpc(let error) where error.code == -32601:
            return .refused("the Alas helper on remote host \(host) is out of date; plugins need a newer one to use files there")
        case RemoteHelperClientError.jsonrpc(let error): return .refused(error.message)
        case RemoteHelperClientError.decoding(let message): return .refused("the Alas helper on \(host) answered badly: \(message)")
        default: return unreachable
        }
    }
}

/// What a `file/*` request answers.
enum PluginFileReply: Encodable, Equatable, Sendable {
    case read(PluginFileReadResult)
    case list(PluginFileListResult)
    case written

    func encode(to encoder: Encoder) throws {
        switch self {
        case .read(let result): try result.encode(to: encoder)
        case .list(let result): try result.encode(to: encoder)
        case .written: try PluginEmptyPayload().encode(to: encoder)
        }
    }
}

struct RemoteHelperScopedPathParams: Encodable {
    let root: String
    let path: String
}

struct RemoteHelperScopedListParams: Encodable {
    let root: String
    let dir: String
}

struct RemoteHelperScopedWriteParams: Encodable {
    let root: String
    let path: String
    let content: String
}

enum PluginFilesError: Error, Equatable {
    case refused(String)
    case notFound(String)

    var message: String {
        switch self {
        case .refused(let reason): reason
        case .notFound(let what): "\(what) does not exist"
        }
    }
}

struct PluginFileParams: Decodable, Sendable {
    let worktree: String
    let path: String
}

struct PluginFileListParams: Decodable, Sendable {
    let worktree: String
    let dir: String?
}

struct PluginFileWriteParams: Decodable, Sendable {
    let worktree: String
    let path: String
    let content: String
}

struct PluginFileReadResult: Codable, Equatable, Sendable {
    let content: String
}

struct PluginFileListResult: Codable, Equatable, Sendable {
    struct Entry: Codable, Equatable, Sendable {
        let name: String
        let kind: String
    }

    let entries: [Entry]
    let truncated: Bool
}
