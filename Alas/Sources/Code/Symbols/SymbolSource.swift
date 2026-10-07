import Foundation

/// Reads one worktree file for symbol extraction, locally or over SSH.
enum SymbolSource {
    static let maxBytes = 1_000_000

    static func read(root: URL, relativePath: String) async -> String? {
        guard isSafeRelativePath(relativePath) else { return nil }
        if let host = RemoteHostRegistry.shared.host(forPath: root.path) {
            // Resolves every component on the host, so an intermediate
            // symlink cannot escape the worktree either.
            guard case .ok(let byteSize, let data) = try? await RemotePathContainment.containedResolvedRead(
                host: host, path: root.appendingPathComponent(relativePath).path,
                worktreeRoot: root.path, maxBytes: maxBytes),
                  byteSize <= maxBytes, data.count == byteSize else { return nil }
            return String(data: data, encoding: .utf8)
        }
        return await Task.detached(priority: .userInitiated) {
            guard let url = containedLocalURL(root: root, relativePath: relativePath) else { return nil }
            return readBounded(url, within: root)
        }.value
    }

    /// Reads at most `maxBytes + 1` bytes of a regular file inside `root`.
    /// - Non-blocking open plus `fstat`, so a FIFO or device never stalls.
    /// - Containment is re-checked on the opened descriptor's physical path
    ///   (`F_GETPATH`), so a file or directory swapped for a symlink after
    ///   `containedLocalURL` approved the path is still rejected.
    /// - A file that grew past the cap is rejected instead of read whole.
    static func readBounded(_ url: URL, within root: URL) -> String? {
        let descriptor = open(url.path, O_RDONLY | O_NONBLOCK | O_CLOEXEC)
        guard descriptor >= 0 else { return nil }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        var info = stat()
        guard fstat(descriptor, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG,
              let opened = openedPath(descriptor),
              isContained(URL(fileURLWithPath: opened), in: root) else { return nil }
        // A throwing read is a failure (nil), never an empty file: an empty
        // result would be indexed with the current stamp and never retried.
        let data: Data
        do { data = try handle.read(upToCount: maxBytes + 1) ?? Data() } catch { return nil }
        guard data.count <= maxBytes else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private static func openedPath(_ descriptor: Int32) -> String? {
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        guard fcntl(descriptor, F_GETPATH, &buffer) != -1 else { return nil }
        return String(cString: buffer)
    }

    /// The file's physical URL when it resolves, symlinks included, to a
    /// location strictly inside the physical worktree root and outside
    /// `.git` (matching `RemotePathContainment` on the remote side).
    static func containedLocalURL(root: URL, relativePath: String) -> URL? {
        guard isSafeRelativePath(relativePath) else { return nil }
        let resolved = root.appendingPathComponent(relativePath).resolvingSymlinksInPath().standardizedFileURL
        return isContained(resolved, in: root) ? resolved : nil
    }

    /// `physical` (already resolved) lies strictly inside `root`'s physical
    /// path and has no `.git` component below it.
    private static func isContained(_ physical: URL, in root: URL) -> Bool {
        let rootComponents = root.resolvingSymlinksInPath().standardizedFileURL.pathComponents
        let components = physical.standardizedFileURL.pathComponents
        return components.count > rootComponents.count
            && Array(components.prefix(rootComponents.count)) == rootComponents
            && !components.dropFirst(rootComponents.count).contains(where: { $0.lowercased() == ".git" })
    }

    /// Worktree-relative, no `..`, not absolute, never inside `.git`.
    static func isSafeRelativePath(_ path: String) -> Bool {
        guard !path.isEmpty, !path.hasPrefix("/"), !path.hasPrefix("~") else { return false }
        return !path.split(separator: "/").contains { $0 == ".." || $0.lowercased() == ".git" }
    }
}
