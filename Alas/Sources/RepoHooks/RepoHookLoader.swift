import Foundation

struct RepoHookLoader: Sendable {
    static let maximumBytes = 256 * 1024

    enum ReadResult: Sendable {
        case data(Data)
        case missing
        case failed(String)
    }

    typealias Reader = @Sendable (_ event: RepoHookEvent, _ worktreeRoot: URL, _ host: String?) async -> ReadResult

    private let reader: Reader

    init(reader: @escaping Reader = RepoHookLoader.liveRead) {
        self.reader = reader
    }

    func load(event: RepoHookEvent, worktreeRoot: URL, host: String?) async -> RepoHookLoadResult {
        let source = host.map(RepoHookSource.remote) ?? .local

        switch await reader(event, worktreeRoot, host) {
        case .missing:
            return .missing(source: source)
        case let .failed(message):
            return .failed(source: source, message: message)
        case let .data(bytes):
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
    }

    private static func liveRead(event: RepoHookEvent, worktreeRoot: URL, host: String?) async -> ReadResult {
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
        guard FileManager.default.fileExists(atPath: resolved.path) else {
            return .missing
        }

        do {
            let values = try resolved.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            guard values.isRegularFile == true else {
                return .failed("Hook is not a regular file")
            }
            guard (values.fileSize ?? 0) <= maximumBytes else {
                return .failed("Hook exceeds the 256 KiB limit")
            }

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

    private static func isContained(_ url: URL, by root: URL) -> Bool {
        url.path == root.path || url.path.hasPrefix(root.path + "/")
    }

    private static func containsGitDirectory(_ url: URL, relativeTo root: URL) -> Bool {
        let relativePath = String(url.path.dropFirst(root.path.count))
        return relativePath.split(separator: "/").contains { $0.caseInsensitiveCompare(".git") == .orderedSame }
    }
}
