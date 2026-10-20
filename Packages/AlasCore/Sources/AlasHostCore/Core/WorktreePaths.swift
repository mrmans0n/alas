import Foundation
import AlasFoundation
import AlasModel
import AlasPlatform
import AlasFeatures
import AlasCode
import AlasAgents

/// Which worktree a path is in, by path components first and file identity
/// when symlinks or a case-insensitive volume make the strings differ.
public enum WorktreePaths {
    public struct FileIdentity: Equatable, Sendable {
        let systemNumber: UInt64
        let fileNumber: UInt64
    }

    /// The worktree owning `directory`: the one rooted exactly at it, or
    /// else the one it sits inside of, the most specific when worktrees nest.
    ///
    /// The exact-root check runs first: a directory that is itself the root
    /// of a nested worktree must resolve to that nested worktree, not to the
    /// parent it is a deeper descendant of.
    public static func worktree(owning directory: String, in worktrees: [Worktree]) -> Worktree? {
        let url = URL(fileURLWithPath: directory).standardizedFileURL
        // `cwd` comes from the CLI's logical `$PWD`, which preserves symlinks,
        // so the directory may itself be a symlink to a worktree root. Resolve
        // symlinks on both sides before comparing file identities.
        if let directoryIdentity = fileIdentity(at: url.resolvingSymlinksInPath().path),
           let exactMatch = worktrees.first(where: {
               fileIdentity(at: $0.path.resolvingSymlinksInPath().path) == directoryIdentity
           }) {
            return exactMatch
        }
        return containing(url, in: worktrees)?.worktree
    }

    /// The deepest worktree whose root is an ancestor of `url`, and the path
    /// below that root.
    public static func containing(_ url: URL, in worktrees: [Worktree]) -> (worktree: Worktree, relativePath: String)? {
        var bestMatch: (worktree: Worktree, relativePath: String, rootComponentCount: Int)?
        for worktree in worktrees {
            guard let match = relativePathAndDepth(for: url, in: worktree.path.standardizedFileURL) else { continue }
            if let currentBest = bestMatch, match.rootComponentCount <= currentBest.rootComponentCount { continue }
            bestMatch = (worktree, match.relativePath, match.rootComponentCount)
        }
        return bestMatch.map { ($0.worktree, $0.relativePath) }
    }

    static func relativePathAndDepth(for url: URL, in rootURL: URL) -> (relativePath: String, rootComponentCount: Int)? {
        if let match = relativePathAndDepth(
            targetComponents: url.standardizedFileURL.pathComponents,
            rootComponents: rootURL.pathComponents
        ) {
            return match
        }
        return relativePathAndDepth(
            targetComponents: url.resolvingSymlinksInPath().standardizedFileURL.pathComponents,
            rootComponents: rootURL.resolvingSymlinksInPath().standardizedFileURL.pathComponents
        ) ?? fileSystemRelativePathAndDepth(for: url, in: rootURL)
    }

    static func relativePathAndDepth(
        targetComponents: [String],
        rootComponents: [String]
    ) -> (relativePath: String, rootComponentCount: Int)? {
        guard targetComponents.count > rootComponents.count,
              Array(targetComponents.prefix(rootComponents.count)) == rootComponents else { return nil }
        let relative = targetComponents.dropFirst(rootComponents.count).joined(separator: "/")
        guard !relative.isEmpty else { return nil }
        return (relative, rootComponents.count)
    }

    private static func fileSystemRelativePathAndDepth(for url: URL, in rootURL: URL) -> (relativePath: String, rootComponentCount: Int)? {
        guard let rootIdentity = fileIdentity(at: rootURL.path) else { return nil }
        var ancestor = url.deletingLastPathComponent()
        var relativeComponents = [url.lastPathComponent]
        while ancestor.path != "/" {
            if fileIdentity(at: ancestor.path) == rootIdentity {
                return (relativeComponents.reversed().joined(separator: "/"), rootURL.pathComponents.count)
            }
            relativeComponents.append(ancestor.lastPathComponent)
            ancestor.deleteLastPathComponent()
        }
        return nil
    }

    public static func fileIdentity(at path: String) -> FileIdentity? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: path),
              let systemNumber = attributes[.systemNumber] as? NSNumber,
              let fileNumber = attributes[.systemFileNumber] as? NSNumber else { return nil }
        return FileIdentity(systemNumber: systemNumber.uint64Value, fileNumber: fileNumber.uint64Value)
    }
}
