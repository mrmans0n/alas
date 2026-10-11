import Foundation

public struct ACPFileWriter: Sendable {
    public let worktreeRoot: URL

    public enum Error: Swift.Error, Equatable, Sendable { case outsideWorktree(path: String) }

    public struct Result: Equatable, Sendable {
        public let added: Int
        public let removed: Int
        public let path: String
        public let oldText: String?
        public let newText: String

        public init(added: Int, removed: Int, path: String, oldText: String?, newText: String) {
            self.added = added
            self.removed = removed
            self.path = path
            self.oldText = oldText
            self.newText = newText
        }
    }

    public func write(path: String, content: String) throws -> Result {
        let logicalTarget = try resolveInsideWorktree(path: path)
        let diskTarget = try managedDiskURLInsideWorktree(path: path)

        let pre = try? String(contentsOf: diskTarget, encoding: .utf8)
        try FileManager.default.createDirectory(at: diskTarget.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try content.write(to: diskTarget, atomically: true, encoding: .utf8)
        return Self.makeResult(oldText: pre, newText: content, path: logicalTarget.path)
    }

    /// Throws `outsideWorktree` if `path` resolves outside the
    /// worktree root after symlink expansion. The returned URL preserves
    /// the requested standardized path so editor live-buffer lookups keep
    /// using the same worktree spelling as the UI.
    public func resolveInsideWorktree(path: String) throws -> URL {
        let target = URL(fileURLWithPath: path).standardizedFileURL
        let boundary = WorkspaceCheckoutBoundary(rootPath: worktreeRoot.path)
        guard (try? boundary.managedURL(for: target.path)) != nil else {
            throw Error.outsideWorktree(path: target.path)
        }
        return target
    }

    public func managedDiskURLInsideWorktree(path: String) throws -> URL {
        let target = URL(fileURLWithPath: path).standardizedFileURL
        let boundary = WorkspaceCheckoutBoundary(rootPath: worktreeRoot.path)
        do {
            return try boundary.managedURL(for: target.path)
        } catch {
            throw Error.outsideWorktree(path: target.path)
        }
    }

    /// Cheap +N/-M counts via line-set symmetric difference. Good enough for the
    /// in-chat card; the user opens the diff tab for the real per-line diff.
    public static func diffLineCount(pre: String, post: String) -> (Int, Int) {
        let a = pre.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        let b = post.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        let setA = Set(a), setB = Set(b)
        return (setB.subtracting(setA).count, setA.subtracting(setB).count)
    }

    public static func makeResult(oldText: String?, newText: String, path: String) -> Result {
        let (added, removed) = diffLineCount(pre: oldText ?? "", post: newText)
        return Result(added: added, removed: removed, path: path, oldText: oldText, newText: newText)
    }

    public init(worktreeRoot: URL) {
        self.worktreeRoot = worktreeRoot
    }
}
