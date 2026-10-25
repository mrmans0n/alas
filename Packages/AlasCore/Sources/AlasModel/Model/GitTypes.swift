import Foundation
import AlasFoundation

public enum WorktreeStatus: String, Codable, Sendable {
    case clean, dirty, running
}

public struct Worktree: Identifiable, Equatable, Codable, Sendable {
    public let id: String           // stable id derived from absolute path
    public let projectId: String
    public var name: String         // display name (usually the branch)
    public var branch: String
    public var path: URL
    /// Nil for legacy or synthetic rows whose identity has not been read from Git.
    public var isMainWorktree: Bool?
    public var status: WorktreeStatus
    public var lastActivity: Date
    public var createdAt: Date
    /// Random identity persisted inside this concrete worktree's Git administrative directory.
    public var lineageID: String?
    public var addedLines: Int = 0
    public var deletedLines: Int = 0

    /// `WorktreeService` records a detached HEAD as this literal branch value.
    public var isDetached: Bool { branch == "(detached)" }

    /// Label that tells worktrees apart in lists: the branch, or the checkout
    /// directory name when HEAD is detached (every detached worktree shares
    /// the same branch value) or there is no branch (folder projects).
    public var title: String { isDetached || branch.isEmpty ? path.lastPathComponent : branch }

    public enum CodingKeys: String, CodingKey, Sendable {
        case id, projectId, name, branch, path, isMainWorktree, status,
             lastActivity, createdAt, lineageID, addedLines, deletedLines
    }

    public init(
        id: String,
        projectId: String,
        name: String,
        branch: String,
        path: URL,
        isMainWorktree: Bool? = nil,
        status: WorktreeStatus,
        lastActivity: Date,
        createdAt: Date? = nil,
        lineageID: String? = nil,
        addedLines: Int = 0,
        deletedLines: Int = 0
    ) {
        self.id = id
        self.projectId = projectId
        self.name = name
        self.branch = branch
        self.path = path
        self.isMainWorktree = isMainWorktree
        self.status = status
        self.lastActivity = lastActivity
        self.createdAt = createdAt ?? lastActivity
        self.lineageID = lineageID
        self.addedLines = addedLines
        self.deletedLines = deletedLines
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        projectId = try c.decode(String.self, forKey: .projectId)
        name = try c.decode(String.self, forKey: .name)
        branch = try c.decode(String.self, forKey: .branch)
        path = try c.decode(URL.self, forKey: .path)
        isMainWorktree = try c.decodeIfPresent(Bool.self, forKey: .isMainWorktree)
        status = try c.decode(WorktreeStatus.self, forKey: .status)
        lastActivity = try c.decode(Date.self, forKey: .lastActivity)
        createdAt = (try? c.decode(Date.self, forKey: .createdAt)) ?? lastActivity
        lineageID = try? c.decode(String.self, forKey: .lineageID)
        addedLines = (try? c.decode(Int.self, forKey: .addedLines)) ?? 0
        deletedLines = (try? c.decode(Int.self, forKey: .deletedLines)) ?? 0
    }

    public static func makeId(path: URL) -> String {
        path.standardizedFileURL.path
    }
}

public struct ChangedFile: Identifiable, Equatable, Codable, Sendable {
    public var id: String { "\(stage.rawValue):\(path)" }
    public let path: String
    public let status: String   // "A" | "M" | "D" | "R" | "U" (unmerged)
    public let stage: ChangeStage
    public let add: Int
    public let del: Int
    public let renameFrom: String?
    /// Non-nil when this file is in a git unmerged (conflicted) state.
    /// Nil for all clean changes. Defaulted for Codable back-compat.
    public var conflict: ConflictKind? = nil

    public init(path: String, status: String, stage: ChangeStage, add: Int, del: Int, renameFrom: String?, conflict: ConflictKind? = nil) {
        self.path = path
        self.status = status
        self.stage = stage
        self.add = add
        self.del = del
        self.renameFrom = renameFrom
        self.conflict = conflict
    }
}

extension ChangedFile {
    /// The paths git must touch to act on this change. A staged rename names
    /// its original path too, or restoring only the new side would leave the
    /// deletion of the old one staged.
    public var gitPaths: [String] {
        if status == "R", let from = renameFrom, !from.isEmpty {
            return [path, from]
        }
        return [path]
    }

    /// Paths to discard for the given file path. Expands staged renames into
    /// both new and original paths so the deletion of the old side is also
    /// restored. Returns `[]` if the path is not in `changes` (stale request).
    public static func discardPaths(forFileAt path: String, in changes: [ChangedFile]) -> [String] {
        guard let file = changes.first(where: { $0.path == path }) else { return [] }
        return file.gitPaths
    }

    /// Paths to discard for every change under a folder (recursive). Folders
    /// in the Changes tree are virtual — built from changed paths only — so
    /// a prefix match against `"<folder>/"` is exhaustive. Staged renames
    /// under the folder include their original path even if the origin lives
    /// outside the folder (rare but possible after a refactor).
    public static func discardPaths(forFolderAt folder: String, in changes: [ChangedFile]) -> [String] {
        let prefix = folder.hasSuffix("/") ? folder : folder + "/"
        let matching = changes.filter { $0.path.hasPrefix(prefix) }
        return matching.flatMap(\.gitPaths)
    }

    /// Every changed path in the worktree (staged + unstaged + untracked),
    /// with staged renames expanded.
    public static func discardPaths(forAllIn changes: [ChangedFile]) -> [String] {
        // Deduplicate while preserving first-seen order.
        var seen = Set<String>()
        var out: [String] = []
        for file in changes {
            for p in file.gitPaths where seen.insert(p).inserted {
                out.append(p)
            }
        }
        return out
    }
}

public enum ChangeStage: String, Codable, Sendable {
    case staged
    case unstaged
}

public enum FileVisibility: String, Equatable, Codable, Sendable {
    case tracked
    case untracked
    case ignored
    case excluded
}

public enum DirectoryChildrenState: String, Equatable, Codable, Sendable {
    case loaded
    case notLoaded
    case loading
    case failed
}

public struct FileTreeNode: Identifiable, Equatable, Codable, Sendable {
    public var id: String { "\(kind.rawValue):\(path)" }
    public let name: String
    public let path: String          // relative to repo root
    public let kind: Kind
    public var children: [FileTreeNode]?
    public var badge: String?        // "A"|"M"|"D"|"R" if status non-empty
    public var visibility: FileVisibility = .tracked
    public var childrenState: DirectoryChildrenState = .loaded
    public var isSubmodule: Bool = false

    public enum Kind: String, Codable, Sendable { case dir, file }

    /// Recursively drops `.ignored`/`.excluded` nodes, but keeps a directory
    /// if any of its (recursively filtered) children remain visible —
    /// gitignore rules don't un-track a path that's already in the index, so
    /// an ignored directory can still contain tracked descendants reachable
    /// only through it. Operates on the EAGER `children` arrays a tree build
    /// populates for a directory with a visible descendant (see
    /// `GitService.fileTree`'s `hasVisibleDescendant` check); a node whose
    /// `children` is nil (lazy, not-yet-loaded) is treated as having none.
    ///
    /// Shared by `FileTreeListView.filteredNodes` (native desktop Files tab) and
    /// `AppState.remoteFileNodes` (remote wire boundary) so both surfaces
    /// keep such a directory reachable, without the data-layer function
    /// depending on a SwiftUI view type.
    public nonisolated static func filteredKeepingVisibleDescendants(
        _ nodes: [FileTreeNode]
    ) -> [FileTreeNode] {
        nodes.compactMap { node in
            let offGit = node.visibility == .ignored || node.visibility == .excluded
            if node.kind == .file {
                return offGit ? nil : node
            }
            var copy = node
            let visibleChildren = filteredKeepingVisibleDescendants(node.children ?? [])
            copy.children = visibleChildren
            if offGit && visibleChildren.isEmpty {
                return nil
            }
            return copy
        }
    }

    public init(name: String, path: String, kind: Kind, children: [FileTreeNode]? = nil, badge: String? = nil, visibility: FileVisibility = .tracked, childrenState: DirectoryChildrenState = .loaded, isSubmodule: Bool = false) {
        self.name = name
        self.path = path
        self.kind = kind
        self.children = children
        self.badge = badge
        self.visibility = visibility
        self.childrenState = childrenState
        self.isSubmodule = isSubmodule
    }
}

/// Classification of a git unmerged (conflicted) file. Mirrors git's
/// porcelain=v2 `u XY` two-letter code where each letter is one of
/// `D`eleted, `A`dded, `U`pdated on each side.
public enum ConflictKind: String, Codable, Equatable, Sendable {
    case bothModified       // UU
    case bothAdded          // AA
    case bothDeleted        // DD
    case addedByUs          // AU
    case addedByThem        // UA
    case deletedByUs        // DU
    case deletedByThem      // UD

    /// Returns nil for `XY` pairs that don't represent a conflict.
    public static func fromPorcelainXY(_ xy: String) -> ConflictKind? {
        switch xy {
        case "UU": return .bothModified
        case "AA": return .bothAdded
        case "DD": return .bothDeleted
        case "AU": return .addedByUs
        case "UA": return .addedByThem
        case "DU": return .deletedByUs
        case "UD": return .deletedByThem
        default:   return nil
        }
    }
}

/// The three sides of a conflicted file, plus the on-disk merged
/// buffer with conflict markers. Loaded via `GitService.conflictedFile`.
public struct ConflictedFile: Equatable, Sendable {
    public let relativePath: String
    public let kind: ConflictKind
    public let base: String?      // nil for `bothAdded` (no common ancestor)
    public let local: String?     // nil for `deletedByUs`
    public let remote: String?    // nil for `deletedByThem`
    public let merged: String     // the on-disk file with conflict markers
    public let isBinary: Bool

    public init(relativePath: String, kind: ConflictKind, base: String?, local: String?, remote: String?, merged: String, isBinary: Bool) {
        self.relativePath = relativePath
        self.kind = kind
        self.base = base
        self.local = local
        self.remote = remote
        self.merged = merged
        self.isBinary = isBinary
    }
}

/// An in-progress conflict-producing operation. Detected by the presence
/// of marker files inside `.git`: `MERGE_HEAD`, `rebase-merge/`,
/// `CHERRY_PICK_HEAD`, or `REVERT_HEAD`.
public enum MergeOperation: Equatable, Sendable {
    /// Merging another branch into the current one.
    /// - sourceBranch: the branch being merged in (read from MERGE_MSG / MERGE_HEAD ref)
    case merge(sourceBranch: String?)

    /// Rebase in progress. `plan` is the parsed contents of
    /// `.git/rebase-merge/git-rebase-todo` plus `done`.
    case rebase(plan: RebasePlan)

    /// Cherry-picking a single commit. `sha` and the first line of the
    /// commit message are exposed for the operation card.
    case cherryPick(sha: String, summary: String)

    /// Reverting a single commit. `sha` and the first line of the commit
    /// message are exposed for the operation card.
    case revert(sha: String, summary: String)
}

public struct RebasePlan: Equatable, Sendable {
    public let ontoBranch: String?    // target ref, read from rebase-merge/onto
    public let sourceBranch: String?  // original branch, read from rebase-merge/head-name
    public let commits: [RebasePlanCommit]
    public var currentIndex: Int? {
        commits.firstIndex(where: { $0.state == .current })
    }

    public init(ontoBranch: String?, sourceBranch: String?, commits: [RebasePlanCommit]) {
        self.ontoBranch = ontoBranch
        self.sourceBranch = sourceBranch
        self.commits = commits
    }
}

public struct RebasePlanCommit: Equatable, Sendable {
    public enum State: Equatable, Sendable { case done, current, pending }
    public let sha: String          // short SHA as it appears in the todo file
    public let summary: String      // first line of commit message
    public let state: State

    public init(sha: String, summary: String, state: State) {
        self.sha = sha
        self.summary = summary
        self.state = state
    }
}

/// Outcome of running an operation that may produce conflicts.
public enum MergeResult: Equatable, Sendable {
    case clean
    case conflict(files: [ChangedFile])
    case error(message: String)
}
