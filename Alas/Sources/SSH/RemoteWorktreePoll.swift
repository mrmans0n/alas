import Foundation

struct RemoteWorktreePollEntry: Equatable {
    let path: String
    let head: String
    /// Full ref (`refs/heads/x`); nil when detached.
    let branch: String?
}

struct RemoteWorktreePollDelta: Equatable {
    /// Worktree path to display branch label, for `applyHeadUpdates`.
    let branchLabelsByPath: [String: String]
    /// True when any existing worktree HEAD moved.
    let headMoved: Bool
    /// True when worktrees were added/removed or any HEAD moved.
    let topologyChanged: Bool
}

/// Pure snapshot/delta logic behind `RemoteProjectGitWatcher`. One
/// `git worktree list --porcelain` per poll yields paths, HEAD shas, and
/// branches for every worktree in a single ssh round trip.
enum RemoteWorktreePoll {
    static func parse(porcelain: String) -> [RemoteWorktreePollEntry] {
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
                path = String(line.dropFirst("worktree ".count))
            } else if line.hasPrefix("HEAD ") {
                head = String(line.dropFirst("HEAD ".count))
            } else if line.hasPrefix("branch ") {
                branch = String(line.dropFirst("branch ".count))
            }
        }
        flush()
        return entries
    }

    static func label(forBranch branch: String?) -> String {
        guard let branch else { return "(detached)" }
        return branch.hasPrefix("refs/heads/")
            ? String(branch.dropFirst("refs/heads/".count))
            : branch
    }

    static func classify(
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
