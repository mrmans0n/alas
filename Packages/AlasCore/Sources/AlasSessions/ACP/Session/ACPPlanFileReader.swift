import AlasPlatform
import Darwin
import Foundation

/// Reads a plan review's negotiated plan file on the session's host.
///
/// The file usually lives outside the worktree, so this never goes through
/// the agent-facing `fs/read_text_file` path or its containment. It is kept
/// narrow instead: the only caller passes the exact path of the plan review
/// it is showing, and only a regular file of at most `maxBytes` UTF-8 bytes
/// is ever returned. The inline plan text is what gets approved; the file
/// only backs the secondary "Open plan file" affordance.
public struct ACPPlanFileReader: Sendable {
    public static let maxBytes = 1_048_576
    public typealias Fetch = @Sendable (_ host: String?, _ path: String, _ maxBytes: Int) async throws -> RemoteReadResult

    private let fetch: Fetch

    public init(fetch: @escaping Fetch = ACPPlanFileReader.live) {
        self.fetch = fetch
    }

    public func read(path: String, host: String?) async -> ACPPlanFileReadResult {
        guard path.hasPrefix("/") else { return .notRegularFile }
        do {
            switch try await fetch(host, path, Self.maxBytes) {
            case .file(let data, let mtime):
                guard data.count <= Self.maxBytes else { return .tooLarge }
                guard let text = String(data: data, encoding: .utf8) else { return .notUTF8 }
                // Hashed like the inline plan text, so the card compares
                // one definition of the digest.
                return .file(text: text, sha256: ACPPlanReviewPresentation.sha256Hex(text), modified: mtime)
            case .missing: return .missing
            case .directory, .symlink: return .notRegularFile
            case .unreadable(let message): return .unreachable(message)
            }
        } catch RemoteFileAccessError.fileTooLarge {
            return .tooLarge
        } catch {
            return .unreachable(String(describing: error))
        }
    }

    /// Local disk when `host` is nil, else a bounded read on that host.
    public static let live: Fetch = { host, path, maxBytes in
        if let host {
            return try await RemoteFileAccess.read(host: host, path: path, maxBytes: maxBytes)
        }
        return try readLocal(path: path, maxBytes: maxBytes)
    }

    /// Opens without following a final symlink and checks the opened file,
    /// so a swap between the check and the read cannot redirect it.
    /// Anything but a regular file (a FIFO would block a plain read) reports
    /// as a directory, which the reader maps to not-a-regular-file.
    static func readLocal(path: String, maxBytes: Int) throws -> RemoteReadResult {
        let fd = open(path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        if fd < 0 {
            let code = errno
            switch code {
            case ENOENT, ENOTDIR: return .missing
            case ELOOP: return .symlink
            default: return .unreadable(String(cString: strerror(code)))
            }
        }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        var info = stat()
        guard fstat(fd, &info) == 0 else { return .unreadable(String(cString: strerror(errno))) }
        guard info.st_mode & S_IFMT == S_IFREG else { return .directory }
        guard info.st_size <= maxBytes else { throw RemoteFileAccessError.fileTooLarge }
        let data = try handle.read(upToCount: maxBytes + 1) ?? Data()
        // The file grew after the size check.
        guard data.count <= maxBytes else { throw RemoteFileAccessError.fileTooLarge }
        return .file(data: data, mtime: Date(timeIntervalSince1970: TimeInterval(info.st_mtimespec.tv_sec) + TimeInterval(info.st_mtimespec.tv_nsec) / 1e9))
    }
}
