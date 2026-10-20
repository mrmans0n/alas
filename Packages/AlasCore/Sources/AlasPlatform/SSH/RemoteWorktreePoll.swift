import Foundation
import AlasFoundation
import AlasModel

public struct RemoteWorktreePollEntry: Equatable, Sendable {
    public let path: String
    public let head: String
    /// Full ref (`refs/heads/x`); nil when detached.
    public let branch: String?

    public init(path: String, head: String, branch: String?) {
        self.path = path
        self.head = head
        self.branch = branch
    }
}

public struct RemoteWorktreePollDelta: Equatable, Sendable {
    /// Worktree path to display branch label, for `applyHeadUpdates`.
    public let branchLabelsByPath: [String: String]
    /// True when any existing worktree HEAD moved.
    public let headMoved: Bool
    /// True when worktrees were added/removed or any HEAD moved.
    public let topologyChanged: Bool

    public init(branchLabelsByPath: [String: String], headMoved: Bool, topologyChanged: Bool) {
        self.branchLabelsByPath = branchLabelsByPath
        self.headMoved = headMoved
        self.topologyChanged = topologyChanged
    }
}

/// Pure snapshot/delta logic behind `RemoteProjectGitWatcher`. One
/// `git worktree list --porcelain` per poll yields paths, HEAD shas, and
/// branches for every worktree in a single ssh round trip.
public enum RemoteWorktreePoll: Sendable {
    public static func parse(porcelain: String, anchor: String = "") -> [RemoteWorktreePollEntry] {
        var entries: [RemoteWorktreePollEntry] = []
        var path: String?
        var head = ""
        var branch: String?

        func flush() {
            if let path {
                entries.append(RemoteWorktreePollEntry(path: path, head: head, branch: branch))
            }
            path = nil
            head = ""
            branch = nil
        }

        for rawLine in porcelain.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(rawLine)
            if line.isEmpty {
                flush()
            } else if line.hasPrefix("worktree ") {
                flush()
                path = RemotePath.virtualizing(String(line.dropFirst("worktree ".count)), like: anchor)
            } else if line.hasPrefix("HEAD ") {
                head = String(line.dropFirst("HEAD ".count))
            } else if line.hasPrefix("branch ") {
                branch = String(line.dropFirst("branch ".count))
            }
        }
        flush()
        return entries
    }

    public static func label(forBranch branch: String?) -> String {
        guard let branch else { return "(detached)" }
        return branch.hasPrefix("refs/heads/")
            ? String(branch.dropFirst("refs/heads/".count))
            : branch
    }

    public static func classify(
        old: [RemoteWorktreePollEntry],
        new: [RemoteWorktreePollEntry]
    ) -> RemoteWorktreePollDelta? {
        guard old != new else { return nil }

        let oldByPath = Dictionary(uniqueKeysWithValues: old.map { ($0.path, $0) })
        let pathSetChanged = Set(oldByPath.keys) != Set(new.map(\.path))
        var branchLabelsByPath: [String: String] = [:]
        var headMoved = false

        for entry in new {
            guard let previous = oldByPath[entry.path] else { continue }
            if previous.branch != entry.branch {
                branchLabelsByPath[entry.path] = label(forBranch: entry.branch)
            }
            if previous.head != entry.head {
                headMoved = true
            }
        }

        return RemoteWorktreePollDelta(
            branchLabelsByPath: branchLabelsByPath,
            headMoved: headMoved,
            topologyChanged: pathSetChanged || headMoved
        )
    }
}
