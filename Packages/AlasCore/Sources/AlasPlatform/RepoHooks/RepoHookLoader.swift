import Foundation
import AlasFoundation
import AlasModel

public struct RepoHookLoader: Sendable {
    public static let maximumBytes = 256 * 1024

    public enum ReadResult: Sendable {
        case data(Data)
        case missing
        case failed(String)
    }

    public typealias Reader = @Sendable (_ event: RepoHookEvent, _ worktreeRoot: URL, _ host: String?) async -> ReadResult

    private let reader: Reader

    public init(reader: @escaping Reader = RepoHookLoader.liveRead) {
        self.reader = reader
    }

    public func load(event: RepoHookEvent, worktreeRoot: URL, host: String?) async -> RepoHookLoadResult {
        let source = host.map(RepoHookSource.remote) ?? .local

        switch await reader(event, worktreeRoot, host) {
        case .missing:
            return .missing(source: source)
        case let .failed(message):
            return .failed(source: source, message: message)
        case let .data(bytes):
            return Self.result(event: event, source: source, bytes: bytes)
        }
    }

    /// The hook for `event` as committed at `ref`, rather than as checked
    /// out: what a worktree created from `ref` will have. Symlinks are
    /// followed inside the tree as the disk loader follows them on a
    /// checkout, so the hash covers the bytes the hook will run.
    public static func loadCommitted(event: RepoHookEvent, ref: String, repoPath: URL, host: String?) async -> RepoHookLoadResult {
        let source = host.map(RepoHookSource.remote) ?? .local
        do {
            switch try await readCommitted(path: event.relativePath, ref: ref, repoPath: repoPath) {
            case .missing:
                return .missing(source: source)
            case let .failed(message):
                return .failed(source: source, message: message)
            case let .data(bytes):
                return result(event: event, source: source, bytes: bytes)
            }
        } catch {
            return .failed(source: source, message: "Could not read hook: \(error.localizedDescription)")
        }
    }

    private struct TreeEntry {
        let mode: String
        let object: String
        let size: Int?
    }

    /// Resolves `path` component by component in `ref`'s tree, following
    /// symlinks relative to their directory, and reads the blob it lands on.
    private static func readCommitted(path: String, ref: String, repoPath: URL) async throws -> ReadResult {
        var lookups = 0
        /// The tree entry at `components`: `.some(nil)` when the tree has
        /// none, nil when the lookup itself failed (unknown ref, git error,
        /// too many lookups). Paths are literal: a link target can't smuggle in pathspec magic.
        func entry(_ components: [String]) async throws -> TreeEntry?? {
            lookups += 1
            guard lookups <= 256 else { return nil }
            let requested = components.joined(separator: "/")
            let output = try await Process.gitData(
                ["--literal-pathspecs", "ls-tree", "-l", "-z", "--full-tree", ref, "--", requested], cwd: repoPath)
            guard output.exitCode == 0 else { return nil }
            guard let line = output.stdout.split(separator: 0).first,
                  let text = String(data: line, encoding: .utf8),
                  let tab = text.firstIndex(of: "\t"),
                  text[text.index(after: tab)...] == requested
            else { return .some(nil) }
            let fields = text[..<tab].split(separator: " ")
            guard fields.count == 4 else { return nil }
            return TreeEntry(mode: String(fields[0]), object: String(fields[2]), size: Int(fields[3]))
        }

        var resolved: [String] = []
        var pending = path.split(separator: "/").map(String.init)
        var followedSymlinks = 0
        var final: TreeEntry?
        while !pending.isEmpty {
            let component = pending.removeFirst()
            if component == "." || component.isEmpty { continue }
            if component == ".." {
                guard !resolved.isEmpty else { return .failed("Hook resolves outside the worktree") }
                resolved.removeLast()
                final = nil
                continue
            }
            guard case let .some(lookup) = try await entry(resolved + [component]) else {
                return .failed("Could not read hook")
            }
            guard let found = lookup else {
                return followedSymlinks > 0 ? .failed("Hook symlink could not be resolved safely") : .missing
            }
            if found.mode == "120000" {
                followedSymlinks += 1
                // The kernel's MAXSYMLINKS and PATH_MAX - 1.
                guard followedSymlinks <= 32, let size = found.size, size > 0, size <= 1023 else {
                    return .failed("Hook symlink could not be resolved safely")
                }
                let data = try await Process.gitDataPrefix(["cat-file", "blob", found.object], cwd: repoPath, maxBytes: size + 1)
                guard data.count == size, let target = String(data: data, encoding: .utf8) else {
                    return .failed("Hook symlink could not be resolved safely")
                }
                // An absolute target names a path on the host, not in the new worktree.
                guard !target.hasPrefix("/") else { return .failed("Hook resolves outside the worktree") }
                pending = target.split(separator: "/").map(String.init) + pending
                final = nil
                continue
            }
            if found.mode != "040000", !pending.isEmpty { return .missing }
            resolved.append(component)
            final = found
        }

        guard !resolved.contains(where: { $0.caseInsensitiveCompare(".git") == .orderedSame }) else {
            return .failed("Hook resolves inside .git")
        }
        guard let final, final.mode == "100644" || final.mode == "100755" else {
            return .failed("Hook is not a regular file")
        }
        guard let size = final.size, size <= maximumBytes else {
            return .failed("Hook exceeds the 256 KiB limit")
        }
        let bytes = try await Process.gitDataPrefix(["cat-file", "blob", final.object], cwd: repoPath, maxBytes: maximumBytes + 1)
        guard bytes.count == size else { return .failed("Could not read hook") }
        return .data(bytes)
    }

    private static func result(event: RepoHookEvent, source: RepoHookSource, bytes: Data) -> RepoHookLoadResult {
        guard let text = String(data: bytes, encoding: .utf8) else {
            return .failed(source: source, message: "Hook is not valid UTF-8")
        }
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return .empty(source: source)
        }
        return .loaded(.init(
            event: event,
            source: source,
            bytes: bytes,
            text: text,
            hash: RepoHookTrust.hash(event: event, bytes: bytes)
        ))
    }

    public static func liveRead(event: RepoHookEvent, worktreeRoot: URL, host: String?) async -> ReadResult {
        if let host {
            return await readRemote(event: event, worktreeRoot: worktreeRoot, host: host)
        }
        return readLocal(event: event, worktreeRoot: worktreeRoot)
    }

    private static func readLocal(event: RepoHookEvent, worktreeRoot: URL) -> ReadResult {
        let root = worktreeRoot.resolvingSymlinksInPath().standardizedFileURL
        let target = root.appendingPathComponent(event.relativePath)
        let resolved = target.resolvingSymlinksInPath().standardizedFileURL

        guard isContained(resolved, by: root) else {
            return .failed("Hook resolves outside the worktree")
        }
        guard !containsGitDirectory(resolved, relativeTo: root) else {
            return .failed("Hook resolves inside .git")
        }
        let values: URLResourceValues
        do {
            values = try resolved.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        } catch {
            if isMissingPathError(error) {
                if containsDanglingSymlink(in: target, relativeTo: root) {
                    return .failed("Hook symlink could not be resolved safely")
                }
                return .missing
            }
            return .failed("Could not read hook: \(error.localizedDescription)")
        }
        guard values.isRegularFile == true else {
            return .failed("Hook is not a regular file")
        }
        guard (values.fileSize ?? 0) <= maximumBytes else {
            return .failed("Hook exceeds the 256 KiB limit")
        }

        do {
            let handle = try FileHandle(forReadingFrom: resolved)
            defer { try? handle.close() }
            let bytes = try handle.read(upToCount: maximumBytes + 1) ?? Data()
            guard bytes.count <= maximumBytes else {
                return .failed("Hook exceeds the 256 KiB limit")
            }
            return .data(bytes)
        } catch {
            return .failed("Could not read hook: \(error.localizedDescription)")
        }
    }

    private static func readRemote(event: RepoHookEvent, worktreeRoot: URL, host: String) async -> ReadResult {
        do {
            switch try await RemotePathContainment.containedResolvedRead(
                host: host,
                path: worktreeRoot.appendingPathComponent(event.relativePath).path,
                worktreeRoot: worktreeRoot.path,
                maxBytes: maximumBytes
            ) {
            case let .ok(byteSize, prefix):
                guard byteSize <= maximumBytes, prefix.count == byteSize else {
                    return .failed("Hook exceeds the 256 KiB limit")
                }
                return .data(prefix)
            case .missing:
                return .missing
            case .outsideWorktree:
                return .failed("Hook resolves outside the worktree or inside .git")
            case .directory:
                return .failed("Hook is a directory")
            case .symlink:
                return .failed("Hook symlink could not be resolved safely")
            case .unreadable:
                return .failed("Could not read hook")
            }
        } catch let error as RemoteFileAccessError {
            switch error {
            case .connectionFailed(let detail):
                return .failed("SSH connection failed: \(detail)")
            case .fileTooLarge:
                return .failed("Hook exceeds the 256 KiB limit")
            default:
                return .failed("Could not read hook")
            }
        } catch {
            return .failed("Could not read hook: \(error.localizedDescription)")
        }
    }

    private static func isMissingPathError(_ error: Error) -> Bool {
        let error = error as NSError
        if error.domain == NSCocoaErrorDomain {
            return error.code == CocoaError.Code.fileReadNoSuchFile.rawValue
        }
        guard error.domain == NSPOSIXErrorDomain else { return false }
        return error.code == POSIXErrorCode.ENOENT.rawValue
            || error.code == POSIXErrorCode.ENOTDIR.rawValue
    }

    private static func containsDanglingSymlink(in target: URL, relativeTo root: URL) -> Bool {
        var current = root
        for component in target.pathComponents.dropFirst(root.pathComponents.count) {
            current.appendPathComponent(component)
            guard (try? current.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true else {
                continue
            }
            if !FileManager.default.fileExists(atPath: current.path) {
                return true
            }
        }
        return false
    }

    private static func isContained(_ url: URL, by root: URL) -> Bool {
        url.path == root.path || url.path.hasPrefix(root.path + "/")
    }

    private static func containsGitDirectory(_ url: URL, relativeTo root: URL) -> Bool {
        let relativePath = String(url.path.dropFirst(root.path.count))
        return relativePath.split(separator: "/").contains { $0.caseInsensitiveCompare(".git") == .orderedSame }
    }
}
