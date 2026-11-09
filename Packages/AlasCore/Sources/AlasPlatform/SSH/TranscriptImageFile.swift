import Foundation
import ImageIO
import AlasModel

/// Resolves transcript images on the machine that owns the session. Unlike
/// editor reads, screenshots may live outside the worktree.
public enum TranscriptImageFile {
    public enum Location: Equatable, Sendable {
        case local(URL)
        case ssh(host: String, path: String)
    }

    public static let maxBytes = 10 * 1024 * 1024

    public static func resolve(_ source: String, root: URL?) -> Location? {
        guard let root, !source.isEmpty else { return nil }
        let path: String
        if let url = URL(string: source), let scheme = url.scheme {
            guard scheme.lowercased() == "file", url.host == nil || url.host == "" || url.host == "localhost" else { return nil }
            path = url.path
        } else {
            path = source
        }
        guard !path.isEmpty, !path.utf8.contains(0) else { return nil }
        let remote = RemotePath.split(root.path)
        if let virtual = RemotePath.split(path) {
            guard virtual.host == remote?.host else { return nil }
        }
        let base = remote?.realPath ?? root.path
        let realPath = RemotePath.realPath(path)
        let resolved = realPath.hasPrefix("/") ? URL(fileURLWithPath: realPath)
            : URL(fileURLWithPath: base).appendingPathComponent(realPath)
        if let remote {
            return .ssh(host: remote.host, path: resolved.standardizedFileURL.path)
        }
        return .local(resolved.resolvingSymlinksInPath().standardizedFileURL)
    }

    /// Validate on the serving host before sending bytes to a peer. File names
    /// are not reliable image identifiers, especially for generated assets.
    public static func isImage(_ data: Data) -> Bool {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return false }
        return CGImageSourceGetCount(source) > 0
    }

    public static func read(_ source: String, root: URL?, maxBytes: Int = maxBytes) async -> Data? {
        guard maxBytes >= 0, maxBytes < Int.max, let location = resolve(source, root: root) else { return nil }
        switch location {
        case .ssh(let host, let path):
            guard case .file(let data, _) = try? await RemoteFileAccess.read(host: host, path: path, maxBytes: maxBytes)
            else { return nil }
            return data
        case .local(let url):
            return await Task.detached {
                guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
                      values.isRegularFile == true, let size = values.fileSize, size <= maxBytes,
                      let handle = try? FileHandle(forReadingFrom: url) else { return nil as Data? }
                defer { try? handle.close() }
                guard let data = try? handle.read(upToCount: maxBytes + 1), data.count <= maxBytes else { return nil }
                return data
            }.value
        }
    }
}
