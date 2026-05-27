import Foundation

struct ACPFileWriter {
    let worktreeRoot: URL

    enum Error: Swift.Error, Equatable { case outsideWorktree(path: String) }

    struct Result: Equatable { let added: Int
    let removed: Int
    let path: String }

    func write(path: String, content: String) throws -> Result {
        let target = URL(fileURLWithPath: path).standardizedFileURL
        let root = worktreeRoot.standardizedFileURL
        guard target.resolvingSymlinksInPath().path.hasPrefix(root.resolvingSymlinksInPath().path + "/") ||
              target.resolvingSymlinksInPath().path == root.resolvingSymlinksInPath().path
        else { throw Error.outsideWorktree(path: target.path) }

        let pre = (try? String(contentsOf: target, encoding: .utf8)) ?? ""
        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try content.write(to: target, atomically: true, encoding: .utf8)
        let (added, removed) = Self.diffLineCount(pre: pre, post: content)
        return Result(added: added, removed: removed, path: target.path)
    }

    /// Cheap +N/-M counts via line-set symmetric difference. Good enough for the
    /// in-chat card; the user opens the diff tab for the real per-line diff.
    static func diffLineCount(pre: String, post: String) -> (Int, Int) {
        let a = pre.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        let b = post.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        let setA = Set(a), setB = Set(b)
        return (setB.subtracting(setA).count, setA.subtracting(setB).count)
    }
}
