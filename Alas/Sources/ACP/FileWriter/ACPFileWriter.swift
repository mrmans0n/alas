import Foundation

struct ACPFileWriter {
    let worktreeRoot: URL

    enum Error: Swift.Error, Equatable { case outsideWorktree(path: String) }

    struct Result: Equatable {
        let added: Int
        let removed: Int
        let path: String
        let oldText: String?
        let newText: String
    }

    func write(path: String, content: String) throws -> Result {
        let target = try resolveInsideWorktree(path: path)

        let pre = try? String(contentsOf: target, encoding: .utf8)
        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try content.write(to: target, atomically: true, encoding: .utf8)
        return Self.makeResult(oldText: pre, newText: content, path: target.path)
    }

    /// Throws `outsideWorktree` if `path` resolves outside the
    /// worktree root after symlink expansion. Returned URL is the
    /// resolved absolute target — safe to read or write. Used by both
    /// the write path AND the read path so the worktree boundary is
    /// enforced symmetrically.
    func resolveInsideWorktree(path: String) throws -> URL {
        let target = URL(fileURLWithPath: path).standardizedFileURL
        let boundary = WorkspaceCheckoutBoundary(rootPath: worktreeRoot.path)
        guard let resolved = try? boundary.managedURL(for: target.path) else {
            throw Error.outsideWorktree(path: target.path)
        }
        return resolved
    }

    /// Cheap +N/-M counts via line-set symmetric difference. Good enough for the
    /// in-chat card; the user opens the diff tab for the real per-line diff.
    static func diffLineCount(pre: String, post: String) -> (Int, Int) {
        let a = pre.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        let b = post.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        let setA = Set(a), setB = Set(b)
        return (setB.subtracting(setA).count, setA.subtracting(setB).count)
    }

    static func makeResult(oldText: String?, newText: String, path: String) -> Result {
        let (added, removed) = diffLineCount(pre: oldText ?? "", post: newText)
        return Result(added: added, removed: removed, path: path, oldText: oldText, newText: newText)
    }
}
